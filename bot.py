 #!/usr/bin/env python3
"""Stand Loader Configurator Bot - Render + Supabase."""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import discord
from discord import app_commands
from discord.ext import commands
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN", "")
BUYER_ROLE_ID = int(os.getenv("BUYER_ROLE_ID", "0") or "0")
STAFF_ROLE_ID = int(os.getenv("STAFF_ROLE_ID", "0") or "0")
MAIN_SCRIPT_URL = os.getenv(
    "MAIN_SCRIPT_URL",
    "https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/StandMain.lua",
)
KEY_API_BASE = os.getenv("KEY_API_BASE", "").rstrip("/")
# Secure-only loaders: do NOT bake plaintext StandMain into the Discord /loader file.
# Set EMBED_MAIN_FALLBACK=1 only for emergency debugging (exposes full source in the loader).
EMBED_MAIN_FALLBACK = os.getenv("EMBED_MAIN_FALLBACK", "0").strip() in ("1", "true", "yes", "on")
ALLOW_PLAIN_URL_FALLBACK = os.getenv("ALLOW_PLAIN_URL_FALLBACK", "0").strip() in ("1", "true", "yes", "on")
SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY = os.getenv("SUPABASE_KEY", "")

TABLE = "stand_configs"
BLACKLIST_TABLE = "stand_blacklist"
STATUS_TABLE = "stand_status"
CHANGELOG_TABLE = "stand_changelog"
KEY_STOCK_TABLE = "key_stock"
ROBLOX_KEYS_TABLE = "roblox_keys"

# Shared secret for Roblox KeySystem → POST /api/v1/dispense-key
# Must match BACKEND_SECRET in KeySystem.lua
REGISTER_KEY_SECRET = (os.getenv("REGISTER_KEY_SECRET") or "").strip()

# Status / changelog channels
STATUS_CHANNEL_ID = int(os.getenv("STATUS_CHANNEL_ID", "1554079705022595174") or "1554079705022595174")
CHANGELOG_CHANNEL_ID = int(os.getenv("CHANGELOG_CHANNEL_ID", "1553592489728933934") or "1553592489728933934")
# Public URL of this bot (Render) so loaders can poll /api/status during inject
PUBLIC_BOT_URL = (
    os.getenv("PUBLIC_BOT_URL")
    or os.getenv("RENDER_EXTERNAL_URL")
    or ""
).rstrip("/")

# 🟢 up | 🔴 down | 🔵 updating | 🟡 detected
STATUS_DOTS = {
    "up": "🟢",
    "down": "🔴",
    "updating": "🔵",
    "detected": "🟡",
}
STATUS_LABELS = {
    "up": "Online",
    "down": "Down / Maintenance",
    "updating": "Updating",
    "detected": "Detected",
}
STATUS_COLORS = {
    "up": 0x2ECC71,       # green
    "down": 0xE74C3C,     # red
    "updating": 0x3498DB, # blue
    "detected": 0xF1C40F, # yellow
}
# States that block buyers from /loader and block script inject
MAINTENANCE_BLOCK_STATES = frozenset({"down", "updating"})
# Channel name format: "{dot}｜Stand"  e.g. 🟢｜Stand
STATUS_CHANNEL_LABEL = os.getenv("STATUS_CHANNEL_LABEL", "Executive Stand")
STATUS_FILE = Path(__file__).resolve().parent / "data" / "system_status.json"
DEPLOY_FILE = Path(__file__).resolve().parent / "data" / "last_deploy.json"
# Files watched for automatic changelog on restart/redeploy
_WATCHED_FILES = ("bot.py", "StandMain.lua", "requirements.txt", "render.yaml")

# Track last status (persisted so restarts keep maintenance lock)
_current_status: str = "up"
_status_note: str = ""


def _load_persisted_status() -> None:
    """Load status from Supabase (preferred) then fall back to local JSON file."""
    global _current_status, _status_note
    loaded = False

    # Prefer Supabase so status survives Render ephemeral disk / multi-instance
    if supabase:
        try:
            res = (
                supabase.table(STATUS_TABLE)
                .select("status, note")
                .eq("id", "current")
                .limit(1)
                .execute()
            )
            rows = res.data or []
            if rows:
                st = str(rows[0].get("status") or "up").lower().strip()
                if st in STATUS_DOTS:
                    _current_status = st
                _status_note = str(rows[0].get("note") or "")
                loaded = True
        except Exception as e:
            print("load status from supabase error:", e)

    if not loaded:
        try:
            if STATUS_FILE.is_file():
                data = json.loads(STATUS_FILE.read_text(encoding="utf-8"))
                st = str(data.get("status") or "up").lower().strip()
                if st in STATUS_DOTS:
                    _current_status = st
                _status_note = str(data.get("note") or "")
        except Exception as e:
            print("load status file error:", e)


def _save_persisted_status() -> None:
    """Persist status to local file + Supabase (best-effort)."""
    payload = {
        "status": _current_status,
        "note": _status_note,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    # Local file (works even without Supabase)
    try:
        STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATUS_FILE.write_text(
            json.dumps(
                {
                    "status": _current_status,
                    "note": _status_note,
                    "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                },
                indent=2,
            ),
            encoding="utf-8",
        )
    except Exception as e:
        print("save status file error:", e)

    # Supabase stand_status (shared across restarts / instances)
    if supabase:
        try:
            supabase.table(STATUS_TABLE).upsert(
                {
                    "id": "current",
                    "status": _current_status,
                    "note": _status_note,
                    "updated_at": payload["updated_at"],
                }
            ).execute()
        except Exception as e:
            print("save status to supabase error:", e)


def get_system_status() -> str:
    return _current_status if _current_status in STATUS_DOTS else "up"


def is_maintenance() -> bool:
    """True when buyers must not use the product (down or updating)."""
    return get_system_status() in MAINTENANCE_BLOCK_STATES


def maintenance_message() -> str:
    st = get_system_status()
    label = STATUS_LABELS.get(st, st)
    dot = STATUS_DOTS.get(st, "🔴")
    extra = f"\n{_status_note}" if _status_note else ""
    return (
        f"{dot} **System is {label}** (`{st}`).\n"
        f"The script and loader are **disabled** until status is 🟢 Online."
        f"{extra}"
    )


supabase: Optional[Client] = None
if SUPABASE_URL and SUPABASE_KEY:
    supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
else:
    print("WARNING: SUPABASE_URL / SUPABASE_KEY not set")

# Load after supabase client exists so we can prefer stand_status table
_load_persisted_status()


def default_config() -> dict:
    return {
        "owner": "",
        "key": "",
        "alts": {},
        "controllers": [],  # extra Roblox usernames that can command alts
        "rank": "free",  # free | premium | bypass
        "gun": "[Double-Barrel SG]",  # Da Hood name; script aliases DoubleBarrel for Hood Customs
        "prefix": ".",
        "anim": "rbxassetid://125405104081365",
        "char_user": 1,
        "char_random": False,
        "slot": 2,
        "mute_gun_sounds": True,
        "auto_mask": True,
        "auto_armor": True,
        "muscle": True,
        "muscle_size": 15000,
        "inf": True,
        "armor_max": True,
    }


def merge_defaults(cfg: dict) -> dict:
    base = default_config()
    for k, v in base.items():
        if k not in cfg:
            cfg[k] = v
    if not isinstance(cfg.get("alts"), dict):
        cfg["alts"] = {}
    if not isinstance(cfg.get("controllers"), list):
        cfg["controllers"] = []
    return cfg


def get_user_cfg(discord_id) -> dict:
    key = str(discord_id)
    if not supabase:
        return default_config()
    try:
        res = supabase.table(TABLE).select("config").eq("discord_id", key).limit(1).execute()
        if res.data:
            cfg = res.data[0].get("config") or {}
            if isinstance(cfg, str):
                cfg = json.loads(cfg)
            return merge_defaults(dict(cfg))
    except Exception as e:
        print("get_user_cfg error:", e)
    return default_config()


def set_user_cfg(discord_id, cfg: dict) -> None:
    key = str(discord_id)
    if not supabase:
        print("set_user_cfg skipped - no supabase")
        return
    payload = {"discord_id": key, "config": cfg}
    try:
        # upsert by primary key
        supabase.table(TABLE).upsert(payload).execute()
    except Exception as e:
        print("set_user_cfg error:", e)


def clear_user(discord_id) -> None:
    key = str(discord_id)
    if not supabase:
        return
    try:
        supabase.table(TABLE).delete().eq("discord_id", key).execute()
    except Exception as e:
        print("clear_user error:", e)


def _collect_ranked_owners() -> dict:
    """Map Roblox owner name -> rank for premium/bypass users (embedded into every loader)."""
    out: dict = {}
    if not supabase:
        return out
    try:
        res = supabase.table(TABLE).select("config").execute()
        for row in res.data or []:
            cfg = row.get("config") or {}
            if isinstance(cfg, str):
                try:
                    cfg = json.loads(cfg)
                except Exception:
                    continue
            owner = (cfg.get("owner") or "").strip()
            rank = str(cfg.get("rank") or "free").lower()
            if owner and rank in ("premium", "bypass"):
                out[owner] = rank
    except Exception as e:
        print("_collect_ranked_owners error:", e)
    return out


SLOT_NAMES = {
    1: "left float",
    2: "right float",
    3: "behind float",
    4: "front float",
    5: "far left float",
    6: "high back float",
}


def lua_bool(v: bool) -> str:
    return "true" if v else "false"


def lua_str(s) -> str:
    return json.dumps(str(s))


def _load_stand_main_source() -> str:
    """Read StandMain.lua next to this file so the loader can embed it."""
    candidates = [
        Path(__file__).resolve().parent / "StandMain.lua",
        Path.cwd() / "StandMain.lua",
    ]
    for p in candidates:
        if p.is_file():
            return p.read_text(encoding="utf-8")
    return ""


def generate_loader(cfg: dict) -> str:
    alts = cfg.get("alts") or {}
    alt_lines = []
    for name, slot in alts.items():
        if not name:
            continue
        comment = SLOT_NAMES.get(int(slot), "slot")
        alt_lines.append(f"        [{lua_str(name)}] = {int(slot)}, -- {comment}")
    alts_block = "\n".join(alt_lines) if alt_lines else "        -- add alts with /addalt"
    owner = lua_str(cfg.get("owner") or "")
    gun = lua_str(cfg.get("gun") or "[Double-Barrel SG]")
    prefix = lua_str(cfg.get("prefix") or ".")
    anim = lua_str(cfg.get("anim") or "")
    main_url = lua_str(MAIN_SCRIPT_URL)
    user_key = lua_str(cfg.get("key") or "")
    api_base = lua_str(KEY_API_BASE or "")
    main_src = _load_stand_main_source()

    parts = []
    a = parts.append
    a("--[[")
    a("    STAND BOT LOADER")
    a("    Generated by Executive config bot")
    a("    Run on ALTS ONLY — owner controls via public chat (no inject needed on main)")
    a("]]")
    a("")
    a(f"script_key = {user_key}")
    a("")
    a("local StandConfig = {")
    a(f"    Owner = {owner},")
    a(f"    Gun = {gun},")
    a(f"    Prefix = {prefix},")
    a(f"    Anim = {anim},")
    a("    Char = {")
    a(f"        User = {int(cfg.get('char_user') or 1)},")
    a(f"        Random = {lua_bool(bool(cfg.get('char_random')))},")
    a("    },")
    a(f"    Slot = {int(cfg.get('slot') or 2)},")
    a(f"    MuteGunSounds = {lua_bool(bool(cfg.get('mute_gun_sounds', True)))},")
    a(f"    AutoMask = {lua_bool(bool(cfg.get('auto_mask', True)))},")
    a(f"    AutoArmor = {lua_bool(bool(cfg.get('auto_armor', True)))},")
    a(f"    Muscle = {lua_bool(bool(cfg.get('muscle', True)))},")
    a(f"    MuscleSize = {int(cfg.get('muscle_size') or 15000)},")
    a(f"    Inf = {lua_bool(bool(cfg.get('inf', True)))},")
    a(f"    ArmorMax = {lua_bool(bool(cfg.get('armor_max', True)))},")
    rank = str(cfg.get("rank") or "free").lower()
    if rank not in ("free", "premium", "bypass"):
        rank = "free"
    a(f"    Rank = {lua_str(rank)},")
    a("    Alts = {")
    a(alts_block)
    a("    },")
    controllers = cfg.get("controllers") or []
    ctrl_lines = []
    for name in controllers:
        if name:
            ctrl_lines.append(f"        {lua_str(str(name))},")
    ctrl_block = "\n".join(ctrl_lines) if ctrl_lines else "        -- /addcontroller"
    a("    Controllers = {")
    a(ctrl_block)
    a("    },")
    # RankedOwners: all known premium/bypass Roblox owners (for free scripts to obey)
    ranked = _collect_ranked_owners()
    ranked_lines = []
    for rname, rrank in ranked.items():
        ranked_lines.append(f"        [{lua_str(rname)}] = {lua_str(rrank)},")
    a("    RankedOwners = {")
    a("\n".join(ranked_lines) if ranked_lines else "        -- staff /setrank")
    a("    },")
    a("}")
    a("")
    a("_G.StandConfig = StandConfig")
    a("pcall(function()")
    a("    if getgenv then")
    a("        getgenv().StandConfig = StandConfig")
    a("        getgenv().script_key = script_key")
    a("    end")
    a("    if shared then shared.StandConfig = StandConfig end")
    a("end)")
    a("")
    a("-- KEY VALIDATION + MAINTENANCE GATE")
    a(f"local KEY_API_BASE = {api_base}")
    status_api = lua_str(PUBLIC_BOT_URL or KEY_API_BASE or "")
    a(f"local STATUS_API_BASE = {status_api}")
    a("local function getHWID()")
    a("    local h = \"unknown\"")
    a("    pcall(function()")
    a("        if gethwid then h = tostring(gethwid())")
    a("        elseif getexecutorname then h = tostring(getexecutorname()) .. \"-\" .. tostring(game:GetService(\"Players\").LocalPlayer.UserId)")
    a("        else h = tostring(game:GetService(\"Players\").LocalPlayer.UserId) end")
    a("    end)")
    a("    return h")
    a("end")
    a("")
    a("local function httpRequest(opts)")
    a("    local req = (syn and syn.request) or http_request or request or (http and http.request)")
    a("    if not req then return nil, \"no request function\" end")
    a("    local ok, res = pcall(req, opts)")
    a("    if not ok then return nil, tostring(res) end")
    a("    return res, nil")
    a("end")
    a("")
    a("-- Block inject while Discord status is down / updating")
    a("local function checkMaintenance()")
    a("    if type(STATUS_API_BASE) ~= \"string\" or STATUS_API_BASE == \"\" then")
    a("        return true, \"skip\"")
    a("    end")
    a("    local HttpService = game:GetService(\"HttpService\")")
    a("    local res, err = httpRequest({")
    a("        Url = STATUS_API_BASE .. \"/api/status\",")
    a("        Method = \"GET\",")
    a("    })")
    a("    if not res then")
    a("        -- if status API unreachable, allow (do not soft-lock all users on network blip)")
    a("        warn(\"[Stand] Status check failed:\", err)")
    a("        return true, \"unreachable\"")
    a("    end")
    a("    local code = res.StatusCode or res.Status or 0")
    a("    local raw = res.Body or res.body or \"\"")
    a("    local okj, data = pcall(function() return HttpService:JSONDecode(raw) end)")
    a("    if code >= 200 and code < 300 and okj and type(data) == \"table\" then")
    a("        local st = string.lower(tostring(data.status or \"up\"))")
    a("        if st == \"down\" or st == \"updating\" then")
    a("            local msg = tostring(data.message or data.note or (\"System is \" .. st))")
    a("            return false, msg")
    a("        end")
    a("        return true, st")
    a("    end")
    a("    return true, \"ok\"")
    a("end")
    a("")
    a("print(\"[Stand] Checking system status...\")")
    a("local mok, mmsg = checkMaintenance()")
    a("if not mok then")
    a("    warn(\"[Stand] Blocked — maintenance:\", mmsg)")
    a("    pcall(function()")
    a("        game:GetService(\"StarterGui\"):SetCore(\"SendNotification\", {")
    a("            Title = \"Stand — Maintenance\",")
    a("            Text = tostring(mmsg),")
    a("            Duration = 8,")
    a("        })")
    a("    end)")
    a("    return")
    a("end")
    a("")
    a("local function validateKey()")
    a("    if type(script_key) ~= \"string\" or script_key == \"\" then")
    a("        return false, \"No key set - use Discord /setuploader\"")
    a("    end")
    a("    if KEY_API_BASE == \"\" then")
    a("        warn(\"[Stand] KEY_API_BASE empty - skipping validate\")")
    a("        return true, \"skip\"")
    a("    end")
    a("    local HttpService = game:GetService(\"HttpService\")")
    a("    local body = HttpService:JSONEncode({ key = script_key, hwid = getHWID() })")
    a("    local res, err = httpRequest({")
    a("        Url = KEY_API_BASE .. \"/api/v1/validate\",")
    a("        Method = \"POST\",")
    a("        Headers = { [\"Content-Type\"] = \"application/json\" },")
    a("        Body = body,")
    a("    })")
    a("    if not res then return false, \"request failed: \" .. tostring(err) end")
    a("    local code = res.StatusCode or res.Status or 0")
    a("    local raw = res.Body or res.body or \"\"")
    a("    local okj, data = pcall(function() return HttpService:JSONDecode(raw) end)")
    a("    if code >= 200 and code < 300 then")
    a("        if okj and type(data) == \"table\" then")
    a("            if data.valid == false or data.success == false then")
    a("                return false, tostring(data.message or data.error or \"invalid key\")")
    a("            end")
    a("        end")
    a("        return true, \"ok\"")
    a("    end")
    a("    local msg = raw")
    a("    if okj and type(data) == \"table\" then")
    a("        msg = tostring(data.message or data.error or raw)")
    a("    end")
    a("    return false, \"HTTP \" .. tostring(code) .. \" \" .. tostring(msg)")
    a("end")
    a("")
    a("print(\"[Stand] Validating key...\")")
    a("local vok, vmsg = validateKey()")
    a("if not vok then")
    a("    warn(\"[Stand] Key validation failed:\", vmsg)")
    a("    pcall(function()")
    a("        game:GetService(\"StarterGui\"):SetCore(\"SendNotification\", {")
    a("            Title = \"Stand\",")
    a("            Text = \"Invalid key: \" .. tostring(vmsg),")
    a("            Duration = 6,")
    a("        })")
    a("    end)")
    a("    return")
    a("end")
    a("print(\"[Stand] Key OK |\", vmsg)")
    a("print(\"[Stand] Config loaded | Owner:\", StandConfig.Owner)")
    a("")
    a("-- SECURE SCRIPT DELIVERY (auth token -> obfuscated payload)")
    a("-- Uses License Hub POST /api/v1/auth then POST /api/v1/script (no plaintext HttpGet)")
    a("local function fetchSecureMain()")
    a('    if type(KEY_API_BASE) ~= "string" or KEY_API_BASE == "" then')
    a('        return nil, "KEY_API_BASE empty"')
    a('    end')
    a('    if type(script_key) ~= "string" or script_key == "" then')
    a('        return nil, "no script_key"')
    a('    end')
    a('    local HttpService = game:GetService("HttpService")')
    a('    local hwid = getHWID()')
    a('    print("[Stand] Auth...")')
    a('    local authBody = HttpService:JSONEncode({ key = script_key, hwid = hwid })')
    a('    local res1, err1 = httpRequest({')
    a('        Url = KEY_API_BASE .. "/api/v1/auth",')
    a('        Method = "POST",')
    a('        Headers = { ["Content-Type"] = "application/json" },')
    a('        Body = authBody,')
    a('    })')
    a('    if not res1 then return nil, "auth request failed: " .. tostring(err1) end')
    a('    local code1 = res1.StatusCode or res1.Status or 0')
    a('    local raw1 = res1.Body or res1.body or ""')
    a('    if code1 < 200 or code1 >= 300 then')
    a('        local msg = raw1')
    a('        pcall(function()')
    a('            local d = HttpService:JSONDecode(raw1)')
    a('            msg = tostring(d.reason or d.message or d.error or raw1)')
    a('        end)')
    a('        return nil, "auth HTTP " .. tostring(code1) .. " " .. tostring(msg)')
    a('    end')
    a('    local okA, auth = pcall(function() return HttpService:JSONDecode(raw1) end)')
    a('    if not okA or type(auth) ~= "table" or type(auth.token) ~= "string" then')
    a('        return nil, "auth: no token"')
    a('    end')
    a('    print("[Stand] Fetching protected script...")')
    a('    local loadBody = HttpService:JSONEncode({ token = auth.token, hwid = hwid })')
    a('    local res2, err2 = httpRequest({')
    a('        Url = KEY_API_BASE .. "/api/v1/script",')
    a('        Method = "POST",')
    a('        Headers = { ["Content-Type"] = "application/json" },')
    a('        Body = loadBody,')
    a('    })')
    a('    if not res2 then return nil, "script request failed: " .. tostring(err2) end')
    a('    local code2 = res2.StatusCode or res2.Status or 0')
    a('    local raw2 = res2.Body or res2.body or ""')
    a('    if code2 < 200 or code2 >= 300 then')
    a('        local msg = raw2')
    a('        pcall(function()')
    a('            local d = HttpService:JSONDecode(raw2)')
    a('            msg = tostring(d.reason or d.message or d.error or raw2)')
    a('        end)')
    a('        return nil, "script HTTP " .. tostring(code2) .. " " .. tostring(msg)')
    a('    end')
    a('    local okP, pack = pcall(function() return HttpService:JSONDecode(raw2) end)')
    a('    if not okP or type(pack) ~= "table" then')
    a('        return nil, "script: bad JSON"')
    a('    end')
    a('    if type(pack.run) == "string" and #pack.run > 50 then')
    a('        return pack.run, nil')
    a('    end')
    a('    return nil, "script: missing run payload"')
    a('end')
    a('')
    a('local function runMainSource(src, label)')
    a('    if type(src) ~= "string" or #src < 50 then')
    a('        error("main source empty or too short (" .. tostring(label) .. ")")')
    a('    end')
    a('    pcall(function()')
    a('        _G.StandConfig = StandConfig')
    a('        if getgenv then getgenv().StandConfig = StandConfig end')
    a('        if shared then shared.StandConfig = StandConfig end')
    a('    end)')
    a('    local boot = "do\\n"')
    a('        .. "local c = (getgenv and getgenv().StandConfig) or rawget(_G, \\"StandConfig\\") or (shared and shared.StandConfig)\\n"')
    a('        .. "if type(c) == \\"table\\" then\\n"')
    a('        .. "  if getgenv then getgenv().StandConfig = c end\\n"')
    a('        .. "  _G.StandConfig = c\\n"')
    a('        .. "  if shared then shared.StandConfig = c end\\n"')
    a('        .. "end\\nend\\n"')
    a('    src = boot .. src')
    a('    print("[Stand] Compiling main |", label, "| bytes:", #src)')
    a('    local fn, err = loadstring(src)')
    a('    if not fn then error("compile failed: " .. tostring(err)) end')
    a('    pcall(function()')
    a('        if setfenv and getgenv then setfenv(fn, getgenv()) end')
    a('    end)')
    a('    print("[Stand] Running main...")')
    a('    fn()')
    a('end')
    a('')
    a('local function loadMain()')
    a('    local src, ferr = fetchSecureMain()')
    a('    if src then')
    a('        print("[Stand] Secure delivery OK")')
    a('        runMainSource(src, "secure")')
    a('        return')
    a('    end')
    a('    warn("[Stand] Secure delivery failed:", ferr)')
    if EMBED_MAIN_FALLBACK and main_src and len(main_src) > 50:
        a('    print("[Stand] Falling back to embedded main (INSECURE - EMBED_MAIN_FALLBACK=1)")')
        a('    local emb = [=[')
        a(main_src)
        a(']=]')
        a('    runMainSource(emb, "embedded")')
        a('    return')
    if ALLOW_PLAIN_URL_FALLBACK:
        a(f"    local MAIN_URL = {main_url}")
        a('    if type(MAIN_URL) == "string" and MAIN_URL ~= "" and not string.find(MAIN_URL, "YOUR_USER", 1, true) then')
        a('        print("[Stand] Falling back to plain MAIN_URL (unprotected)")')
        a('        local body')
        a('        pcall(function() body = game:HttpGet(MAIN_URL) end)')
        a('        if type(body) ~= "string" or #body < 50 then')
        a('            local res = httpRequest({ Url = MAIN_URL, Method = "GET" })')
        a('            body = res and (res.Body or res.body) or body')
        a('        end')
        a('        if type(body) == "string" and #body > 50 then')
        a('            runMainSource(body, "plain-url")')
        a('            return')
        a('        end')
        a('    end')
    a('    error("Secure delivery failed: " .. tostring(ferr or "unknown") .. " | Upload script on product + valid key/HWID. No plaintext fallback.")')
    a('end')
    a('')
    a("local ok, err = pcall(loadMain)")
    a("if not ok then")
    a("    print(\"[Stand] Failed to load main:\", err)")
    a("    warn(\"[Stand] Failed to load main:\", err)")
    a("    pcall(function()")
    a("        game:GetService(\"StarterGui\"):SetCore(\"SendNotification\", {")
    a("            Title = \"Stand\",")
    a("            Text = \"Main script failed — see F9\",")
    a("            Duration = 8,")
    a("        })")
    a("    end)")
    a("end")
    a("")
    return "\n".join(parts)



intents = discord.Intents.default()
intents.members = True
bot = commands.Bot(command_prefix="!", intents=intents)


def has_buyer_role(interaction: discord.Interaction) -> bool:
    if BUYER_ROLE_ID == 0:
        return True
    if not isinstance(interaction.user, discord.Member):
        return False
    return any(r.id == BUYER_ROLE_ID for r in interaction.user.roles)


def has_staff_role(interaction: discord.Interaction) -> bool:
    if STAFF_ROLE_ID == 0:
        # fall back: administrators
        if isinstance(interaction.user, discord.Member):
            return interaction.user.guild_permissions.administrator
        return False
    if not isinstance(interaction.user, discord.Member):
        return False
    return any(r.id == STAFF_ROLE_ID for r in interaction.user.roles)


def is_blacklisted(discord_id) -> bool:
    if not supabase:
        return False
    try:
        res = (
            supabase.table(BLACKLIST_TABLE)
            .select("discord_id")
            .eq("discord_id", str(discord_id))
            .limit(1)
            .execute()
        )
        return bool(res.data)
    except Exception as e:
        print("is_blacklisted error:", e)
        return False


def set_blacklist(discord_id, reason: str, by_id: int) -> None:
    if not supabase:
        return
    try:
        supabase.table(BLACKLIST_TABLE).upsert(
            {
                "discord_id": str(discord_id),
                "reason": reason or "",
                "by": str(by_id),
            }
        ).execute()
    except Exception as e:
        print("set_blacklist error:", e)


def clear_blacklist(discord_id) -> None:
    if not supabase:
        return
    try:
        supabase.table(BLACKLIST_TABLE).delete().eq("discord_id", str(discord_id)).execute()
    except Exception as e:
        print("clear_blacklist error:", e)


async def buyer_check(interaction: discord.Interaction) -> bool:
    if is_blacklisted(interaction.user.id):
        await interaction.response.send_message(
            "You are **blacklisted** from this bot.",
            ephemeral=True,
        )
        return False
    # Maintenance / updating: block all non-staff buyers (loader + config)
    if is_maintenance() and not has_staff_role(interaction):
        await interaction.response.send_message(
            maintenance_message(),
            ephemeral=True,
        )
        return False
    if has_buyer_role(interaction):
        return True
    await interaction.response.send_message(
        "You need the **buyer** role to use this command.",
        ephemeral=True,
    )
    return False


async def staff_check(interaction: discord.Interaction) -> bool:
    if has_staff_role(interaction):
        return True
    await interaction.response.send_message(
        "Staff only.",
        ephemeral=True,
    )
    return False


def _status_channel_name(status: str) -> str:
    """Channel name: 🟢｜Stand  /  🔴｜Stand  /  🔵｜Stand  /  🟡｜Stand"""
    dot = STATUS_DOTS.get(status, "🟢")
    label = (STATUS_CHANNEL_LABEL or "Executive Stand").strip() or "Executive Stand"
    # Discord allows emoji + fullwidth bar + text
    return f"{dot}｜{label}"


async def update_status_channel(
    status: str,
    *,
    note: str = "",
    by: Optional[discord.abc.User] = None,
    announce: bool = True,
) -> Optional[str]:
    """
    Rename status channel with colored dot and optionally post an embed.
    status: up | down | updating | detected
    Persists status so loaders + Discord commands stay blocked across restarts.
    Returns error string or None on success.
    """
    global _current_status, _status_note
    status = (status or "up").lower().strip()
    if status not in STATUS_DOTS:
        return f"Invalid status `{status}`. Use: up, down, updating, detected"

    _current_status = status
    if note is not None and str(note).strip():
        _status_note = str(note).strip()
    elif status == "up":
        _status_note = ""
    _save_persisted_status()

    channel = bot.get_channel(STATUS_CHANNEL_ID)
    if channel is None:
        try:
            channel = await bot.fetch_channel(STATUS_CHANNEL_ID)
        except Exception as e:
            return f"Cannot fetch status channel: {e}"

    new_name = _status_channel_name(status)
    try:
        if hasattr(channel, "edit"):
            await channel.edit(name=new_name, reason=f"Status → {status}")
    except Exception as e:
        print("status channel rename error:", e)

    label = STATUS_LABELS.get(status, status)
    color = STATUS_COLORS.get(status, 0x95A5A6)
    dot = STATUS_DOTS.get(status, "⚪")
    blocked = status in MAINTENANCE_BLOCK_STATES

    if announce and isinstance(channel, discord.TextChannel):
        desc = note.strip() if note and note.strip() else None
        embed = discord.Embed(
            title=f"{dot} System Status — {label}",
            color=color,
            description=desc,
        )
        embed.add_field(name="Status", value=f"{dot} **{label}** (`{status}`)", inline=True)
        embed.add_field(
            name="Script access",
            value="**Blocked** for users" if blocked else "**Open**",
            inline=True,
        )
        if by:
            embed.add_field(name="Updated by", value=str(by), inline=True)
        embed.set_footer(text="Executive Stand")
        try:
            await channel.send(embed=embed)
        except Exception as e:
            print("status channel message error:", e)
            return f"Saved status but failed to post: {e}"

    return None


async def post_changelog(
    title: str,
    notes: str,
    *,
    version: str = "",
    by: Optional[discord.abc.User] = None,
    automatic: bool = False,
) -> Optional[str]:
    """Post a changelog embed to the changelog channel and persist to Supabase. Returns error or None."""
    channel = bot.get_channel(CHANGELOG_CHANNEL_ID)
    if channel is None:
        try:
            channel = await bot.fetch_channel(CHANGELOG_CHANNEL_ID)
        except Exception as e:
            return f"Cannot fetch changelog channel: {e}"

    if not isinstance(channel, discord.TextChannel):
        return "Changelog channel is not a text channel"

    by_label = str(by) if by else ("Auto (deploy)" if automatic else "System")

    embed = discord.Embed(
        title=f"📝 {title.strip() or 'Update'}",
        description=notes.strip() or "_No details provided._",
        color=0x9B59B6,
    )
    if version and version.strip():
        embed.add_field(name="Build", value=f"`{version.strip()}`", inline=True)
    embed.add_field(name="Posted by", value=by_label, inline=True)
    embed.set_footer(text="Executive Stand — Changelog")

    try:
        await channel.send(embed=embed)
    except Exception as e:
        return f"Failed to post changelog: {e}"

    # Persist to stand_changelog (best-effort; Discord post already succeeded)
    if supabase:
        try:
            supabase.table(CHANGELOG_TABLE).insert(
                {
                    "title": (title or "Update").strip() or "Update",
                    "notes": (notes or "").strip(),
                    "version": (version or "").strip(),
                    "by": by_label,
                    "automatic": bool(automatic),
                }
            ).execute()
        except Exception as e:
            print("save changelog to supabase error:", e)

    return None


def _file_sha256(path: Path) -> Optional[str]:
    try:
        if not path.is_file():
            return None
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def _compute_deploy_snapshot() -> dict:
    """Hash watched project files for change detection."""
    base = Path(__file__).resolve().parent
    files: dict[str, dict] = {}
    for name in _WATCHED_FILES:
        p = base / name
        digest = _file_sha256(p)
        if digest:
            try:
                size = p.stat().st_size
            except OSError:
                size = 0
            files[name] = {"sha256": digest, "size": size}
    # Combined build id from all hashes
    combo = hashlib.sha256()
    for name in sorted(files.keys()):
        combo.update(name.encode())
        combo.update(files[name]["sha256"].encode())
    return {
        "build": combo.hexdigest()[:12],
        "files": files,
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
    }


def _load_last_deploy() -> dict:
    try:
        if DEPLOY_FILE.is_file():
            return json.loads(DEPLOY_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        print("load last_deploy error:", e)
    return {}


def _save_last_deploy(snap: dict) -> None:
    try:
        DEPLOY_FILE.parent.mkdir(parents=True, exist_ok=True)
        DEPLOY_FILE.write_text(json.dumps(snap, indent=2), encoding="utf-8")
    except Exception as e:
        print("save last_deploy error:", e)


def _auto_changelog_notes(prev: dict, curr: dict) -> tuple[str, str]:
    """
    Build title + notes automatically from file hash changes.
    Returns (title, notes).
    """
    prev_files = (prev or {}).get("files") or {}
    curr_files = (curr or {}).get("files") or {}
    build = curr.get("build") or "unknown"
    when = curr.get("at") or datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    changed: list[str] = []
    added: list[str] = []
    removed: list[str] = []

    for name, meta in curr_files.items():
        old = prev_files.get(name)
        if not old:
            added.append(name)
        elif old.get("sha256") != meta.get("sha256"):
            old_sz = old.get("size") or 0
            new_sz = meta.get("size") or 0
            delta = new_sz - old_sz
            sign = "+" if delta >= 0 else ""
            changed.append(f"• `{name}` updated ({sign}{delta} bytes)")

    for name in prev_files:
        if name not in curr_files:
            removed.append(name)

    lines: list[str] = [
        f"**Automatic deploy detected** at `{when}`",
        f"Build id: `{build}`",
        "",
    ]
    if changed:
        lines.append("**Changed files**")
        lines.extend(changed)
        lines.append("")
    if added:
        lines.append("**New files**")
        lines.extend(f"• `{n}`" for n in added)
        lines.append("")
    if removed:
        lines.append("**Removed files**")
        lines.extend(f"• `{n}`" for n in removed)
        lines.append("")

    if not changed and not added and not removed:
        lines.append("_No watched file changes (first run or identical deploy)._")
    else:
        lines.append("Users: run `/loader` again and re-inject alts after this update.")

    title = f"Auto update — build `{build}`"
    if changed:
        # Short hint from first changed file names
        names = [c.split("`")[1] for c in changed if "`" in c][:3]
        if names:
            title = f"Auto update — {', '.join(names)}"

    return title, "\n".join(lines).strip()


async def auto_changelog_on_deploy() -> None:
    """
    On every bot start: if bot.py / StandMain.lua / etc. changed since last run,
    post a changelog automatically (no staff title/notes required).
    """
    curr = _compute_deploy_snapshot()
    prev = _load_last_deploy()
    prev_build = (prev or {}).get("build")
    curr_build = curr.get("build")

    if prev_build and prev_build == curr_build:
        print(f"Deploy unchanged build={curr_build} — no auto changelog")
        return

    title, notes = _auto_changelog_notes(prev, curr)
    first = not prev_build
    if first:
        title = f"Deploy online — build `{curr_build}`"
        notes = (
            f"**Bot started** at `{curr.get('at')}`\n"
            f"Build id: `{curr_build}`\n\n"
            f"Tracking: {', '.join(f'`{n}`' for n in curr.get('files', {})) or '—'}\n"
            f"_Future redeploys that change these files will post here automatically._"
        )

    err = await post_changelog(
        title=title,
        notes=notes,
        version=str(curr_build or ""),
        automatic=True,
    )
    if err:
        print("auto changelog error:", err)
    else:
        print(f"Auto changelog posted build={curr_build} first={first}")

    _save_last_deploy(curr)


@bot.event
async def on_ready():
    try:
        synced = await bot.tree.sync()
        print(f"Synced {len(synced)} commands")
    except Exception as e:
        print("Sync error:", e)
    print(f"Logged in as {bot.user}")
    print(f"Buyer role: {BUYER_ROLE_ID} | Supabase: {'yes' if supabase else 'NO'}")
    print(f"System status: {get_system_status()} | maintenance_block={is_maintenance()}")
    # Refresh status channel from persisted state (do NOT force online — keep maintenance locks)
    try:
        err = await update_status_channel(
            get_system_status(),
            note=_status_note or f"Bot process online — status `{get_system_status()}`",
            announce=True,
        )
        if err:
            print("on_ready status update:", err)
    except Exception as e:
        print("on_ready status error:", e)

    # Automatic changelog whenever watched files change between deploys
    try:
        await auto_changelog_on_deploy()
    except Exception as e:
        print("on_ready auto changelog error:", e)


@bot.tree.command(name="setuploader", description="Set owner account + license key")
@app_commands.describe(
    owner="Roblox username of the MAIN account",
    key="Your license key (XXXX-XXXX)",
)
async def setuploader(interaction: discord.Interaction, owner: str, key: str):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    cfg["owner"] = owner.strip()
    cfg["key"] = key.strip()
    set_user_cfg(interaction.user.id, cfg)
    alt_count = len(cfg.get("alts") or {})
    masked = cfg["key"][:4] + "****" if len(cfg["key"]) >= 4 else "****"
    await interaction.response.send_message(
        f"**Owner set to** `{cfg['owner']}`\n"
        f"**Key saved:** `{masked}`\n"
        f"Linked alts: **{alt_count}**\n"
        f"Next: `/addalt` then `/config` then `/loader`",
        ephemeral=True,
    )


@bot.tree.command(name="addalt", description="Link an alt with a formation slot")
@app_commands.describe(username="Roblox username of the alt", slot="Formation slot")
@app_commands.choices(slot=[
    app_commands.Choice(name="1 left float", value=1),
    app_commands.Choice(name="2 right float", value=2),
    app_commands.Choice(name="3 behind float", value=3),
    app_commands.Choice(name="4 front float", value=4),
    app_commands.Choice(name="5 far left float", value=5),
    app_commands.Choice(name="6 high back float", value=6),
])
async def addalt(interaction: discord.Interaction, username: str, slot: app_commands.Choice[int]):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    name = username.strip()
    if not name:
        await interaction.response.send_message("Invalid username.", ephemeral=True)
        return
    cfg.setdefault("alts", {})[name] = int(slot.value)
    set_user_cfg(interaction.user.id, cfg)
    await interaction.response.send_message(
        f"Added alt **{name}** -> slot **{slot.value}** ({SLOT_NAMES.get(slot.value, '?')})",
        ephemeral=True,
    )


@bot.tree.command(name="removealt", description="Remove one linked alt")
@app_commands.describe(username="Roblox username to remove")
async def removealt(interaction: discord.Interaction, username: str):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    name = username.strip()
    alts = cfg.get("alts") or {}
    removed = None
    for k in list(alts.keys()):
        if k.lower() == name.lower():
            removed = k
            del alts[k]
            break
    cfg["alts"] = alts
    set_user_cfg(interaction.user.id, cfg)
    if removed:
        await interaction.response.send_message(f"Removed alt **{removed}**.", ephemeral=True)
    else:
        await interaction.response.send_message("Alt not found.", ephemeral=True)


@bot.tree.command(name="config", description="Configure loader options (omit args to view)")
@app_commands.describe(
    gun="Gun name e.g. [Double-Barrel SG]",
    prefix="Command prefix",
    mute_gun_sounds="Mute gun sounds",
    auto_mask="Auto mask",
    auto_armor="Auto armor",
    muscle="Muscle",
    muscle_size="Muscle size",
    inf="Inf helpers",
    armor_max="Armor max",
    fallback_slot="Default slot 0-6",
    anim="Idle anim asset id (e.g. 125405104081365 or rbxassetid://...)",
    char_user="Avatar userId",
    char_random="Random avatar",
)
async def config_cmd(
    interaction: discord.Interaction,
    gun: Optional[str] = None,
    prefix: Optional[str] = None,
    mute_gun_sounds: Optional[bool] = None,
    auto_mask: Optional[bool] = None,
    auto_armor: Optional[bool] = None,
    muscle: Optional[bool] = None,
    muscle_size: Optional[int] = None,
    inf: Optional[bool] = None,
    armor_max: Optional[bool] = None,
    fallback_slot: Optional[app_commands.Range[int, 0, 6]] = None,
    anim: Optional[str] = None,
    char_user: Optional[int] = None,
    char_random: Optional[bool] = None,
):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    changes = []

    def set_field(key, val, label):
        if val is not None:
            cfg[key] = val
            changes.append(f"{label}: `{val}`")

    set_field("gun", gun, "Gun")
    set_field("prefix", prefix, "Prefix")
    set_field("mute_gun_sounds", mute_gun_sounds, "MuteGunSounds")
    set_field("auto_mask", auto_mask, "AutoMask")
    set_field("auto_armor", auto_armor, "AutoArmor")
    set_field("muscle", muscle, "Muscle")
    set_field("muscle_size", muscle_size, "MuscleSize")
    set_field("inf", inf, "Inf")
    set_field("armor_max", armor_max, "ArmorMax")
    set_field("slot", fallback_slot, "Fallback slot")
    if anim is not None:
        # Normalize: allow bare numeric IDs
        a = str(anim).strip()
        if a.isdigit():
            a = f"rbxassetid://{a}"
        cfg["anim"] = a
        changes.append(f"Anim: `{a}`")
    set_field("char_user", char_user, "Char.User")
    set_field("char_random", char_random, "Char.Random")
    set_user_cfg(interaction.user.id, cfg)

    if not changes:
        embed = discord.Embed(title="Your config", color=0xB45AFF)
        embed.add_field(name="Owner", value=f"`{cfg.get('owner') or 'not set'}`", inline=True)
        embed.add_field(name="Gun", value=f"`{cfg.get('gun')}`", inline=True)
        embed.add_field(name="Prefix", value=f"`{cfg.get('prefix')}`", inline=True)
        embed.add_field(name="MuteGunSounds", value=str(cfg.get("mute_gun_sounds")), inline=True)
        embed.add_field(name="AutoMask", value=str(cfg.get("auto_mask")), inline=True)
        embed.add_field(name="AutoArmor", value=str(cfg.get("auto_armor")), inline=True)
        embed.add_field(name="Muscle", value=f"{cfg.get('muscle')} ({cfg.get('muscle_size')})", inline=True)
        embed.add_field(name="Inf / ArmorMax", value=f"{cfg.get('inf')} / {cfg.get('armor_max')}", inline=True)
        embed.add_field(name="Fallback slot", value=str(cfg.get("slot")), inline=True)
        embed.add_field(name="Anim", value=f"`{cfg.get('anim') or 'none'}`", inline=False)
        embed.add_field(name="Char", value=f"User `{cfg.get('char_user')}` / Random `{cfg.get('char_random')}`", inline=False)
        await interaction.response.send_message(embed=embed, ephemeral=True)
        return

    await interaction.response.send_message(
        "**Updated:**\n" + "\n".join(f"- {c}" for c in changes),
        ephemeral=True,
    )


@bot.tree.command(name="mylinks", description="Show owner and all linked alts")
async def mylinks(interaction: discord.Interaction):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    alts = cfg.get("alts") or {}
    embed = discord.Embed(title="Your linked accounts", color=0xB45AFF)
    embed.add_field(name="Owner (main)", value=f"`{cfg.get('owner') or 'not set'}`", inline=False)
    k = cfg.get("key") or ""
    masked = (k[:4] + "****") if len(k) >= 4 else ("not set" if not k else "****")
    embed.add_field(name="License key", value=f"`{masked}`", inline=False)
    if alts:
        lines = [
            f"`{name}` -> slot **{slot}** ({SLOT_NAMES.get(int(slot), '?')})"
            for name, slot in alts.items()
        ]
        embed.add_field(name=f"Alts ({len(alts)})", value="\n".join(lines), inline=False)
    else:
        embed.add_field(name="Alts", value="*None - use /addalt*", inline=False)
    ctrls = cfg.get("controllers") or []
    if ctrls:
        embed.add_field(
            name="Controllers",
            value=", ".join(f"`{c}`" for c in ctrls),
            inline=False,
        )
    embed.set_footer(text="Use /loader to generate your script")
    await interaction.response.send_message(embed=embed, ephemeral=True)


@bot.tree.command(name="unlink", description="Unlink ALL accounts and reset config")
async def unlink(interaction: discord.Interaction):
    if not await buyer_check(interaction):
        return
    clear_user(interaction.user.id)
    await interaction.response.send_message(
        "All linked accounts and config cleared.",
        ephemeral=True,
    )



@bot.tree.command(name="setkey", description="Update your license key")
@app_commands.describe(key="Your license key (XXXX-XXXX)")
async def setkey(interaction: discord.Interaction, key: str):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    cfg["key"] = key.strip()
    set_user_cfg(interaction.user.id, cfg)
    masked = cfg["key"][:4] + "****" if len(cfg["key"]) >= 4 else "****"
    await interaction.response.send_message(
        f"Key updated: `{masked}`\nRun `/loader` again to get a new file.",
        ephemeral=True,
    )


@bot.tree.command(name="loader", description="Generate your personal StandLoader.lua")
async def loader_cmd(interaction: discord.Interaction):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    if not cfg.get("owner"):
        await interaction.response.send_message(
            "Set an owner first with `/setuploader`.",
            ephemeral=True,
        )
        return
    if not cfg.get("key"):
        await interaction.response.send_message(
            "Set your license key with `/setuploader` or `/setkey`.",
            ephemeral=True,
        )
        return

    source = generate_loader(cfg)
    # temp file for discord.File (Render has no persistent local data needed)
    tmp = Path(tempfile.gettempdir()) / f"loader_{interaction.user.id}.lua"
    tmp.write_text(source, encoding="utf-8")
    file = discord.File(tmp, filename="StandLoader.lua")
    embed = discord.Embed(
        title="Your StandLoader.lua",
        description=(
            f"Owner: `{cfg['owner']}`\n"
            f"Alts: **{len(cfg.get('alts') or {})}**\n"
            f"Gun: `{cfg.get('gun')}` | Prefix: `{cfg.get('prefix')}`\n\n"
            "**Inject on ALTS only.** Owner just types commands in public chat "
            "(no script needed on main)."
        ),
        color=0xB45AFF,
    )
    await interaction.response.send_message(embed=embed, file=file, ephemeral=True)


@bot.tree.command(name="addcontroller", description="Allow another Roblox user to control your alts via chat")
@app_commands.describe(username="Roblox username who can type commands")
async def addcontroller(interaction: discord.Interaction, username: str):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    name = username.strip()
    if not name:
        await interaction.response.send_message("Invalid username.", ephemeral=True)
        return
    ctrls = list(cfg.get("controllers") or [])
    low = {c.lower() for c in ctrls}
    if name.lower() not in low:
        ctrls.append(name)
    cfg["controllers"] = ctrls
    set_user_cfg(interaction.user.id, cfg)
    await interaction.response.send_message(
        f"Controller **`{name}`** added. Run `/loader` again and re-inject alts.\n"
        f"They can type the same prefix commands as the owner.",
        ephemeral=True,
    )


@bot.tree.command(name="removecontroller", description="Remove a controller username")
@app_commands.describe(username="Roblox username to remove")
async def removecontroller(interaction: discord.Interaction, username: str):
    if not await buyer_check(interaction):
        return
    cfg = get_user_cfg(interaction.user.id)
    name = username.strip().lower()
    ctrls = [c for c in (cfg.get("controllers") or []) if c.lower() != name]
    cfg["controllers"] = ctrls
    set_user_cfg(interaction.user.id, cfg)
    await interaction.response.send_message(
        f"Controller **`{username}`** removed. Re-run `/loader`.",
        ephemeral=True,
    )


# -------------------- STAFF --------------------



# Staff commands (blacklist, status, etc.) live in staff_bot.py

async def _start_http():
    """HTTP server: health, loader status, Roblox key stock + dispense."""
    import hmac
    from aiohttp import web

    VALID_PRODUCTS = ("stand", "premium", "shield")

    async def health(_request):
        st = get_system_status()
        if st in MAINTENANCE_BLOCK_STATES:
            return web.Response(
                text=f"Stand Discord bot — {st}",
                status=503,
            )
        return web.Response(text="Stand Discord bot online")

    async def api_status(_request):
        st = get_system_status()
        blocked = st in MAINTENANCE_BLOCK_STATES
        payload = {
            "status": st,
            "label": STATUS_LABELS.get(st, st),
            "blocked": blocked,
            "message": (
                _status_note
                or (
                    "System is under maintenance. Try again later."
                    if blocked
                    else "Online"
                )
            ),
            "note": _status_note,
        }
        return web.json_response(payload, status=503 if blocked else 200)

    async def api_stock(_request):
        """GET /api/v1/stock — available (unreserved) key counts for Roblox shop."""
        stock = {p: 0 for p in VALID_PRODUCTS}
        if not supabase:
            return web.json_response({"ok": False, "error": "database unavailable", "stock": stock}, status=503)
        try:
            for p in VALID_PRODUCTS:
                res = (
                    supabase.table(KEY_STOCK_TABLE)
                    .select("id", count="exact")
                    .eq("product", p)
                    .eq("reserved", False)
                    .execute()
                )
                count = getattr(res, "count", None)
                if count is None:
                    count = len(res.data or [])
                stock[p] = int(count or 0)
            return web.json_response({"ok": True, "stock": stock})
        except Exception as e:
            print(f"[api/stock] error: {e}")
            return web.json_response({"ok": False, "error": str(e), "stock": stock}, status=500)

    async def api_dispense_key(request):
        """POST /api/v1/dispense-key — reserve one License Hub key for a Roblox buyer."""
        if not REGISTER_KEY_SECRET:
            return web.json_response({"ok": False, "error": "REGISTER_KEY_SECRET not configured"}, status=503)
        if not supabase:
            return web.json_response({"ok": False, "error": "database unavailable"}, status=503)

        try:
            body = await request.json()
        except Exception:
            return web.json_response({"ok": False, "error": "invalid json"}, status=400)

        if not isinstance(body, dict):
            return web.json_response({"ok": False, "error": "invalid body"}, status=400)

        secret = str(body.get("secret") or "")
        if not hmac.compare_digest(secret, REGISTER_KEY_SECRET):
            return web.json_response({"ok": False, "error": "unauthorized"}, status=401)

        product = str(body.get("product") or "").strip().lower()
        if product not in VALID_PRODUCTS:
            return web.json_response({"ok": False, "error": "invalid product"}, status=400)

        try:
            roblox_user_id = int(body.get("roblox_user_id") or 0)
        except (TypeError, ValueError):
            roblox_user_id = 0
        roblox_username = str(body.get("roblox_username") or "")[:64]

        if roblox_user_id <= 0:
            return web.json_response({"ok": False, "error": "invalid roblox_user_id"}, status=400)

        now = datetime.now(timezone.utc).isoformat()

        try:
            # Already assigned a key for this product + user? Reuse it (idempotent).
            existing = (
                supabase.table(KEY_STOCK_TABLE)
                .select("key")
                .eq("product", product)
                .eq("assigned_to_roblox_user_id", roblox_user_id)
                .eq("reserved", True)
                .limit(1)
                .execute()
            )
            rows = existing.data or []
            if rows and rows[0].get("key"):
                return web.json_response({"ok": True, "key": rows[0]["key"], "reused": True})

            # Next available key
            avail = (
                supabase.table(KEY_STOCK_TABLE)
                .select("id, key")
                .eq("product", product)
                .eq("reserved", False)
                .order("id")
                .limit(1)
                .execute()
            )
            avail_rows = avail.data or []
            if not avail_rows:
                return web.json_response({"ok": False, "error": "out of stock"}, status=409)

            row = avail_rows[0]
            key = row["key"]
            row_id = row["id"]

            # Reserve only if still unreserved (best-effort race guard)
            updated = (
                supabase.table(KEY_STOCK_TABLE)
                .update(
                    {
                        "reserved": True,
                        "reserved_at": now,
                        "assigned_to_roblox_user_id": roblox_user_id,
                        "assigned_to_roblox_username": roblox_username,
                        "assigned_at": now,
                    }
                )
                .eq("id", row_id)
                .eq("reserved", False)
                .execute()
            )
            if not (updated.data):
                return web.json_response({"ok": False, "error": "race — try again"}, status=409)

            # History row (best-effort)
            try:
                supabase.table(ROBLOX_KEYS_TABLE).upsert(
                    {
                        "key": key,
                        "product": product,
                        "roblox_user_id": roblox_user_id,
                        "roblox_username": roblox_username,
                    },
                    on_conflict="key",
                ).execute()
            except Exception as e:
                print(f"[api/dispense-key] roblox_keys upsert: {e}")

            print(f"[api/dispense-key] dispensed {product} key to rbx={roblox_user_id} ({roblox_username})")
            return web.json_response({"ok": True, "key": key, "reused": False})
        except Exception as e:
            print(f"[api/dispense-key] error: {e}")
            return web.json_response({"ok": False, "error": str(e)}, status=500)

    app = web.Application()
    app.router.add_get("/", health)
    app.router.add_get("/health", health)
    app.router.add_get("/api/status", api_status)
    app.router.add_get("/api/v1/status", api_status)
    app.router.add_get("/api/v1/stock", api_stock)
    app.router.add_post("/api/v1/dispense-key", api_dispense_key)
    runner = web.AppRunner(app)
    await runner.setup()
    port = int(os.environ.get("PORT", "10000"))
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    print(
        f"HTTP on 0.0.0.0:{port} | status={get_system_status()} | "
        f"stock+dispense={'on' if REGISTER_KEY_SECRET else 'OFF (set REGISTER_KEY_SECRET)'}"
    )


async def _amain():
    if not TOKEN:
        raise SystemExit("Set DISCORD_TOKEN")
    if not supabase:
        print("WARNING: running without Supabase - configs will not persist")
    await _start_http()
    await bot.start(TOKEN)


if __name__ == "__main__":
    import asyncio
    asyncio.run(_amain())
