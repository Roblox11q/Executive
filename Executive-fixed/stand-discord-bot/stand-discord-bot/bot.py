#!/usr/bin/env python3
"""Stand Loader Configurator Bot - Render + Supabase."""
from __future__ import annotations

import json
import os
import tempfile
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
SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY = os.getenv("SUPABASE_KEY", "")

TABLE = "stand_configs"
BLACKLIST_TABLE = "stand_blacklist"

supabase: Optional[Client] = None
if SUPABASE_URL and SUPABASE_KEY:
    supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
else:
    print("WARNING: SUPABASE_URL / SUPABASE_KEY not set")


def default_config() -> dict:
    return {
        "owner": "",
        "key": "",
        "alts": {},
        "controllers": [],  # extra Roblox usernames that can command alts
        "rank": "free",  # free | premium | bypass
        "gun": "[DoubleBarrel]",
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


SLOT_NAMES = {1: "left", 2: "right", 3: "behind", 4: "front", 5: "left2", 6: "behind2"}


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
    a("    getgenv().StandConfig = StandConfig")
    a("    getgenv().script_key = script_key")
    a("end)")
    a("")
    a("-- KEY VALIDATION")
    a(f"local KEY_API_BASE = {api_base}")
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
    a("-- Load main script (embedded first, URL fallback)")
    a("local function loadMain()")
    if main_src:
        # Embed source so MAIN_SCRIPT_URL does not need to work
        a("    -- Embedded StandMain.lua (no network needed)")
        a("    local src = [=[")
        a(main_src)
        a("]=]")
        a("    local fn, err = loadstring(src)")
        a("    if not fn then")
        a("        error(\"embed compile failed: \" .. tostring(err))")
        a("    end")
        a("    fn()")
        a("    return true")
    else:
        a(f"    local MAIN_URL = {main_url}")
        a("    print(\"[Stand] Fetching main from:\", MAIN_URL)")
        a("    local body = game:HttpGet(MAIN_URL)")
        a("    if type(body) ~= \"string\" or #body < 50 then")
        a("        error(\"HttpGet returned empty/short body — check MAIN_SCRIPT_URL\")")
        a("    end")
        a("    local fn, err = loadstring(body)")
        a("    if not fn then")
        a("        error(\"compile failed: \" .. tostring(err))")
        a("    end")
        a("    fn()")
        a("    return true")
    a("end")
    a("")
    a("local ok, err = pcall(loadMain)")
    a("if not ok then")
    a("    warn(\"[Stand] Failed to load main:\", err)")
    a("    pcall(function()")
    a("        game:GetService(\"StarterGui\"):SetCore(\"SendNotification\", {")
    a("            Title = \"Stand\",")
    a("            Text = \"Main script failed — see F9\",")
    a("            Duration = 8,")
    a("        })")
    a("    end)")
    a("else")
    a("    print(\"[Stand] Loader finished — main should print 'Main loaded'\")")
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


@bot.event
async def on_ready():
    try:
        synced = await bot.tree.sync()
        print(f"Synced {len(synced)} commands")
    except Exception as e:
        print("Sync error:", e)
    print(f"Logged in as {bot.user}")
    print(f"Buyer role: {BUYER_ROLE_ID} | Supabase: {'yes' if supabase else 'NO'}")


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
    app_commands.Choice(name="1 left", value=1),
    app_commands.Choice(name="2 right", value=2),
    app_commands.Choice(name="3 behind", value=3),
    app_commands.Choice(name="4 front", value=4),
    app_commands.Choice(name="5 left2", value=5),
    app_commands.Choice(name="6 behind2", value=6),
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
    anim="Idle anim asset",
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
    set_field("anim", anim, "Anim")
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


@bot.tree.command(name="blacklist", description="[Staff] Blacklist a Discord user from the bot")
@app_commands.describe(user="Discord user to blacklist", reason="Reason")
async def blacklist_cmd(
    interaction: discord.Interaction,
    user: discord.User,
    reason: str = "No reason",
):
    if not await staff_check(interaction):
        return
    set_blacklist(user.id, reason, interaction.user.id)
    # wipe their config so script/key is useless
    clear_user(user.id)
    await interaction.response.send_message(
        f"Blacklisted **{user}** (`{user.id}`)\nReason: {reason}\nTheir config was wiped.",
        ephemeral=True,
    )


@bot.tree.command(name="unblacklist", description="[Staff] Remove a user from the blacklist")
@app_commands.describe(user="Discord user to unblacklist")
async def unblacklist_cmd(interaction: discord.Interaction, user: discord.User):
    if not await staff_check(interaction):
        return
    clear_blacklist(user.id)
    await interaction.response.send_message(
        f"Unblacklisted **{user}** (`{user.id}`).",
        ephemeral=True,
    )


@bot.tree.command(name="checkblacklist", description="[Staff] Check if a user is blacklisted")
@app_commands.describe(user="Discord user")
async def checkblacklist_cmd(interaction: discord.Interaction, user: discord.User):
    if not await staff_check(interaction):
        return
    flagged = is_blacklisted(user.id)
    await interaction.response.send_message(
        f"**{user}** (`{user.id}`) is **{'BLACKLISTED' if flagged else 'not blacklisted'}**.",
        ephemeral=True,
    )


@bot.tree.command(name="forceunlink", description="[Staff] Wipe a buyer's config")
@app_commands.describe(user="Discord user whose config to wipe")
async def forceunlink_cmd(interaction: discord.Interaction, user: discord.User):
    if not await staff_check(interaction):
        return
    clear_user(user.id)
    await interaction.response.send_message(
        f"Wiped config for **{user}** (`{user.id}`).",
        ephemeral=True,
    )


@bot.tree.command(name="staffview", description="[Staff] View a buyer's linked owner/alts")
@app_commands.describe(user="Discord user")
async def staffview_cmd(interaction: discord.Interaction, user: discord.User):
    if not await staff_check(interaction):
        return
    cfg = get_user_cfg(user.id)
    alts = cfg.get("alts") or {}
    ctrls = cfg.get("controllers") or []
    embed = discord.Embed(title=f"Config for {user}", color=0xE74C3C)
    embed.add_field(name="Owner", value=f"`{cfg.get('owner') or '—'}`", inline=True)
    embed.add_field(name="Rank", value=f"`{cfg.get('rank') or 'free'}`", inline=True)
    embed.add_field(name="Prefix", value=f"`{cfg.get('prefix')}`", inline=True)
    embed.add_field(name="Gun", value=f"`{cfg.get('gun')}`", inline=True)
    embed.add_field(name="Blacklisted", value=str(is_blacklisted(user.id)), inline=True)
    if alts:
        lines = [f"`{n}` slot {s}" for n, s in alts.items()]
        embed.add_field(name="Alts", value="\n".join(lines)[:1000], inline=False)
    if ctrls:
        embed.add_field(name="Controllers", value=", ".join(f"`{c}`" for c in ctrls), inline=False)
    await interaction.response.send_message(embed=embed, ephemeral=True)


@bot.tree.command(name="setrank", description="[Staff] Set buyer rank: free / premium / bypass")
@app_commands.describe(user="Discord user", rank="free, premium, or bypass (shield)")
@app_commands.choices(rank=[
    app_commands.Choice(name="free", value="free"),
    app_commands.Choice(name="premium", value="premium"),
    app_commands.Choice(name="bypass (shield)", value="bypass"),
])
async def setrank_cmd(
    interaction: discord.Interaction,
    user: discord.User,
    rank: app_commands.Choice[str],
):
    if not await staff_check(interaction):
        return
    cfg = get_user_cfg(user.id)
    cfg["rank"] = rank.value
    set_user_cfg(user.id, cfg)
    await interaction.response.send_message(
        f"Set **{user}** rank to **`{rank.value}`**.\n"
        f"They must run `/loader` again and re-inject alts.\n"
        f"• free — default\n"
        f"• premium — can benx/pkick free users\n"
        f"• bypass — immune to premium; can command free + premium",
        ephemeral=True,
    )


async def _start_http():
    """Minimal HTTP server so Render free Web Service stays up."""
    from aiohttp import web

    async def health(_request):
        return web.Response(text="Stand Discord bot online")

    app = web.Application()
    app.router.add_get("/", health)
    app.router.add_get("/health", health)
    runner = web.AppRunner(app)
    await runner.setup()
    port = int(os.environ.get("PORT", "10000"))
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    print(f"HTTP health server on 0.0.0.0:{port}")


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
