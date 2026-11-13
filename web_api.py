"""
Executive Stand — Web dashboard API (Discord OAuth + config).

Mounted by bot.py's aiohttp server. Uses the same Supabase helpers
(get_user_cfg / set_user_cfg / generate_loader / is_blacklisted / …).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import urlencode

from aiohttp import ClientSession, web

# ── Env ──────────────────────────────────────────────────────────────
DISCORD_CLIENT_ID = (os.getenv("DISCORD_CLIENT_ID") or "").strip()
DISCORD_CLIENT_SECRET = (os.getenv("DISCORD_CLIENT_SECRET") or "").strip()
# Must match the Discord app redirect exactly, e.g. https://your.onrender.com/auth/callback
DISCORD_REDIRECT_URI = (
    os.getenv("DISCORD_REDIRECT_URI")
    or (
        (os.getenv("PUBLIC_BOT_URL") or os.getenv("RENDER_EXTERNAL_URL") or "").rstrip("/")
        + "/auth/callback"
        if (os.getenv("PUBLIC_BOT_URL") or os.getenv("RENDER_EXTERNAL_URL"))
        else ""
    )
).strip()
SESSION_SECRET = (os.getenv("SESSION_SECRET") or "").strip()
if not SESSION_SECRET:
    # Never fall back to a known default in production — forged sessions would be trivial.
    SESSION_SECRET = (os.getenv("DISCORD_CLIENT_SECRET") or "").strip()
if not SESSION_SECRET:
    import warnings
    warnings.warn(
        "SESSION_SECRET is unset. Set a long random SESSION_SECRET env var. "
        "Using ephemeral secret for this process only.",
        RuntimeWarning,
        stacklevel=1,
    )
    SESSION_SECRET = secrets.token_hex(32)
# Comma-separated Discord user IDs that get is_admin on the site (fallback)
ADMIN_DISCORD_IDS = {
    x.strip()
    for x in (os.getenv("ADMIN_DISCORD_IDS") or "").split(",")
    if x.strip()
}
# Discord role IDs required for admin panel access (user needs ANY of these)
ADMIN_ROLE_IDS = {
    x.strip()
    for x in (
        os.getenv("ADMIN_ROLE_IDS")
        or "1550996904790200361,1553595331516694569"
    ).split(",")
    if x.strip()
}
GUILD_ID = (os.getenv("GUILD_ID") or "").strip()
# Bot token used to look up member roles (prefer staff bot, fall back to user bot)
DISCORD_BOT_TOKEN = (
    os.getenv("STAFF_DISCORD_TOKEN") or os.getenv("DISCORD_TOKEN") or ""
).strip()
TOKEN_TTL_SEC = int(os.getenv("SESSION_TTL_SEC", "604800"))  # 7 days
OAUTH_SCOPES = "identify"

# Stripe
STRIPE_SECRET_KEY = (os.getenv("STRIPE_SECRET_KEY") or "").strip()
STRIPE_WEBHOOK_SECRET = (os.getenv("STRIPE_WEBHOOK_SECRET") or "").strip()
STRIPE_PRICE_PREMIUM = (os.getenv("STRIPE_PRICE_PREMIUM") or "").strip()
STRIPE_PRICE_BYPASS = (os.getenv("STRIPE_PRICE_BYPASS") or "").strip()
PUBLIC_URL = (
    os.getenv("PUBLIC_BOT_URL") or os.getenv("RENDER_EXTERNAL_URL") or ""
).rstrip("/")

# Tickets — shared with staff_bot.py via data/tickets.json
STAFF_ROLE_ID = (os.getenv("STAFF_ROLE_ID") or "").strip()
TICKET_CATEGORY_ID = (os.getenv("TICKET_CATEGORY_ID") or "").strip()
TICKET_DATA_FILE = Path(__file__).resolve().parent / "data" / "tickets.json"

# Website form categories → Discord channel metadata
WEB_TICKET_CATEGORIES = {
    "general": {
        "label": "General Support",
        "description": "General questions and help",
        "emoji": "💬",
        "color": 0x5865F2,
        "slug": "general",
    },
    "billing": {
        "label": "Billing",
        "description": "Plans, payments, refunds",
        "emoji": "💰",
        "color": 0xF1C40F,
        "slug": "billing",
    },
    "bug": {
        "label": "Bug Report",
        "description": "Something is broken",
        "emoji": "🐛",
        "color": 0xE74C3C,
        "slug": "bug",
    },
    "appeal": {
        "label": "Ban Appeal",
        "description": "Contest a ban or restriction",
        "emoji": "⚖️",
        "color": 0x9B59B6,
        "slug": "appeal",
    },
    "feature": {
        "label": "Feature Request",
        "description": "Suggest an improvement",
        "emoji": "✨",
        "color": 0x2ECC71,
        "slug": "feature",
    },
    "development": {
        "label": "Development",
        "description": "Report a bug",
        "emoji": "❓",
        "color": 0x5865F2,
        "slug": "development",
    },
    "partnership": {
        "label": "Partnership",
        "description": "Affiliate / partnership inquiry",
        "emoji": "🔧",
        "color": 0x2ECC71,
        "slug": "partnership",
    },
}


def oauth_configured() -> bool:
    return bool(DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET and DISCORD_REDIRECT_URI)


# ── JWT-ish signed token (no extra deps) ─────────────────────────────
def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def issue_token(user: dict) -> str:
    payload = {
        "sub": str(user["id"]),
        "username": user.get("username") or "",
        "global_name": user.get("global_name") or user.get("username") or "",
        "avatar": user.get("avatar") or "",
        "discriminator": user.get("discriminator") or "0",
        "iat": int(time.time()),
        "exp": int(time.time()) + TOKEN_TTL_SEC,
    }
    body = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = _b64url(
        hmac.new(SESSION_SECRET.encode(), body.encode(), hashlib.sha256).digest()
    )
    return f"{body}.{sig}"


def verify_token(token: str) -> Optional[dict]:
    if not token or "." not in token:
        return None
    try:
        body, sig = token.rsplit(".", 1)
        expected = _b64url(
            hmac.new(SESSION_SECRET.encode(), body.encode(), hashlib.sha256).digest()
        )
        if not hmac.compare_digest(sig, expected):
            return None
        payload = json.loads(_b64url_decode(body))
        if int(payload.get("exp", 0)) < int(time.time()):
            return None
        return payload
    except Exception:
        return None


def token_from_request(request: web.Request) -> Optional[str]:
    auth = request.headers.get("Authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    # cookie fallback
    return request.cookies.get("es_token")


# ── Helpers injected from bot.py ─────────────────────────────────────
class Deps:
    get_user_cfg: Callable[[Any], dict]
    set_user_cfg: Callable[[Any, dict], None]
    clear_user: Callable[[Any], None]
    default_config: Callable[[], dict]
    merge_defaults: Callable[[dict], dict]
    generate_loader: Callable[[dict], str]
    is_blacklisted: Callable[[Any], bool]
    set_blacklist: Callable[[Any, str, int], None]
    clear_blacklist: Callable[[Any], None]
    get_system_status: Callable[[], str]
    update_status_channel: Callable[..., Any]
    post_changelog: Callable[..., Any]
    supabase: Any
    TABLE: str
    BLACKLIST_TABLE: str
    CHANGELOG_TABLE: str
    KEY_STOCK_TABLE: str


deps = Deps()


def bind_deps(**kwargs) -> None:
    for k, v in kwargs.items():
        setattr(deps, k, v)


# ── Auth middleware helpers ──────────────────────────────────────────
async def require_user(request: web.Request) -> dict:
    """Return token payload or raise 401."""
    tok = token_from_request(request)
    payload = verify_token(tok or "")
    if not payload:
        raise web.HTTPUnauthorized(text=json.dumps({"ok": False, "error": "not authenticated"}), content_type="application/json")
    discord_id = str(payload["sub"])
    if deps.is_blacklisted(discord_id):
        raise web.HTTPForbidden(text=json.dumps({"ok": False, "error": "blacklisted"}), content_type="application/json")
    return payload


# Cache of admin role checks: discord_id -> (is_admin, expires_at)
_admin_cache: dict[str, tuple[bool, float]] = {}
_ADMIN_CACHE_TTL = 120.0  # seconds


async def check_member_has_admin_role(discord_id: str) -> bool:
    """True if the member has any ADMIN_ROLE_IDS in GUILD_ID (via bot token)."""
    if not GUILD_ID or not DISCORD_BOT_TOKEN or not ADMIN_ROLE_IDS:
        return False
    now = time.time()
    cached = _admin_cache.get(str(discord_id))
    if cached and cached[1] > now:
        return cached[0]
    url = f"https://discord.com/api/v10/guilds/{GUILD_ID}/members/{discord_id}"
    headers = {"Authorization": f"Bot {DISCORD_BOT_TOKEN}"}
    try:
        async with ClientSession() as session:
            async with session.get(url, headers=headers, timeout=8) as resp:
                if resp.status != 200:
                    _admin_cache[str(discord_id)] = (False, now + 30)
                    return False
                data = await resp.json()
                roles = {str(r) for r in (data.get("roles") or [])}
                ok = bool(roles & ADMIN_ROLE_IDS)
                _admin_cache[str(discord_id)] = (ok, now + _ADMIN_CACHE_TTL)
                return ok
    except Exception as e:
        print(f"[admin-role-check] {e}")
        return False


def is_admin_id(discord_id: str) -> bool:
    """Synchronous fallback: explicit user ID allowlist only."""
    return str(discord_id) in ADMIN_DISCORD_IDS


async def is_admin_user(discord_id: str) -> bool:
    """Admin if listed in ADMIN_DISCORD_IDS or has one of the required roles."""
    if is_admin_id(discord_id):
        return True
    return await check_member_has_admin_role(discord_id)


def user_public(payload: dict, cfg: dict, *, is_admin: bool | None = None) -> dict:
    did = str(payload["sub"])
    rank = str(cfg.get("rank") or "free").lower()
    if rank not in ("free", "premium", "bypass"):
        rank = "free"
    avatar = payload.get("avatar") or ""
    avatar_url = ""
    if avatar:
        ext = "gif" if str(avatar).startswith("a_") else "png"
        avatar_url = f"https://cdn.discordapp.com/avatars/{did}/{avatar}.{ext}?size=128"
    admin_flag = is_admin if is_admin is not None else is_admin_id(did)
    return {
        "id": did,
        "discord_id": did,
        "username": payload.get("username") or "",
        "global_name": payload.get("global_name") or payload.get("username") or "",
        "discriminator": payload.get("discriminator") or "0",
        "avatar": avatar,
        "avatar_url": avatar_url,
        "plan": rank,
        "rank": rank,
        "owner": cfg.get("owner") or "",
        "alts": cfg.get("alts") or {},
        "is_admin": admin_flag,
    }


# ── Route handlers ───────────────────────────────────────────────────
async def auth_discord(_request: web.Request) -> web.Response:
    if not oauth_configured():
        return web.json_response(
            {
                "ok": False,
                "error": "Discord OAuth not configured. Set DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET, DISCORD_REDIRECT_URI.",
            },
            status=503,
        )
    params = {
        "client_id": DISCORD_CLIENT_ID,
        "redirect_uri": DISCORD_REDIRECT_URI,
        "response_type": "code",
        "scope": OAUTH_SCOPES,
        "prompt": "consent",
    }
    url = "https://discord.com/api/oauth2/authorize?" + urlencode(params)
    raise web.HTTPFound(url)


async def auth_callback(request: web.Request) -> web.Response:
    if not oauth_configured():
        return web.Response(text="OAuth not configured", status=503)

    err = request.query.get("error")
    if err:
        return web.Response(text=f"Discord OAuth error: {err}", status=400)

    code = request.query.get("code")
    if not code:
        return web.Response(text="Missing code", status=400)

    # Exchange code for token
    async with ClientSession() as session:
        data = {
            "client_id": DISCORD_CLIENT_ID,
            "client_secret": DISCORD_CLIENT_SECRET,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": DISCORD_REDIRECT_URI,
        }
        async with session.post(
            "https://discord.com/api/oauth2/token",
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        ) as resp:
            token_json = await resp.json()
            if resp.status != 200:
                return web.Response(
                    text=f"Token exchange failed: {token_json}", status=400
                )
        access = token_json.get("access_token")
        if not access:
            return web.Response(text="No access_token", status=400)

        async with session.get(
            "https://discord.com/api/users/@me",
            headers={"Authorization": f"Bearer {access}"},
        ) as resp:
            user = await resp.json()
            if resp.status != 200:
                return web.Response(text=f"User fetch failed: {user}", status=400)

    discord_id = str(user["id"])
    if deps.is_blacklisted(discord_id):
        return web.Response(
            text="You are blacklisted from Executive Stand.", status=403
        )

    # Ensure config row exists
    cfg = deps.get_user_cfg(discord_id)
    deps.set_user_cfg(discord_id, cfg)

    token = issue_token(user)
    # Redirect to SPA with token in hash (never sent to server on subsequent nav)
    # Also set httpOnly cookie for same-origin API convenience
    base = (
        os.getenv("PUBLIC_BOT_URL")
        or os.getenv("RENDER_EXTERNAL_URL")
        or ""
    ).rstrip("/") or ""
    dest = f"{base}/#token={token}"
    response = web.HTTPFound(dest)
    response.set_cookie(
        "es_token",
        token,
        max_age=TOKEN_TTL_SEC,
        httponly=True,
        samesite="Lax",
        secure=True,
        path="/",
    )
    raise response


async def api_me(request: web.Request) -> web.Response:
    payload = await require_user(request)
    cfg = deps.get_user_cfg(payload["sub"])
    admin = await is_admin_user(str(payload["sub"]))
    return web.json_response({"ok": True, "user": user_public(payload, cfg, is_admin=admin)})


async def api_logout(_request: web.Request) -> web.Response:
    resp = web.json_response({"ok": True})
    resp.del_cookie("es_token", path="/")
    return resp


async def api_delete_account(request: web.Request) -> web.Response:
    """Permanently delete the signed-in user's stand config and related data."""
    payload = await require_user(request)
    discord_id = str(payload["sub"])
    try:
        body = await request.json()
    except Exception:
        body = {}
    confirm = str(body.get("confirm") or "").strip().upper()
    if confirm not in ("DELETE", "DELETE MY ACCOUNT"):
        return web.json_response(
            {"ok": False, "error": 'Type "DELETE" to confirm account deletion'},
            status=400,
        )

    if not deps.supabase:
        return web.json_response({"ok": False, "error": "database unavailable"}, status=503)

    try:
        # Remove config
        deps.supabase.table("stand_configs").delete().eq("discord_id", discord_id).execute()
        # Best-effort: clear claimed_by on any keys, close open tickets owned by user
        try:
            deps.supabase.table("key_stock").update(
                {"claimed_by_discord_id": None}
            ).eq("claimed_by_discord_id", discord_id).execute()
        except Exception:
            pass
        try:
            deps.supabase.table("stand_tickets").update(
                {"closed": True, "closed_by": "account_deleted", "closed_at": datetime.now(timezone.utc).isoformat()}
            ).eq("opener_id", discord_id).eq("closed", False).execute()
        except Exception:
            pass
        print(f"[api/delete-account] deleted discord_id={discord_id}")
    except Exception as e:
        print(f"[api/delete-account] {e}")
        return web.json_response({"ok": False, "error": str(e)}, status=500)

    resp = web.json_response({"ok": True, "deleted": True})
    resp.del_cookie("es_token", path="/")
    return resp


async def api_get_config(request: web.Request) -> web.Response:
    payload = await require_user(request)
    cfg = deps.get_user_cfg(payload["sub"])
    admin = await is_admin_user(str(payload["sub"]))
    safe = dict(cfg)
    return web.json_response({"ok": True, "config": safe, "user": user_public(payload, cfg, is_admin=admin)})


ALLOWED_CONFIG_KEYS = {
    "owner",
    "key",
    "alts",
    "controllers",
    "gun",
    "prefix",
    "anim",
    "char_user",
    "char_random",
    "slot",
    "mute_gun_sounds",
    "auto_mask",
    "auto_armor",
    "muscle",
    "muscle_size",
    "inf",
    "armor_max",
    "friendly_fire_prevention",
}


async def api_save_config(request: web.Request) -> web.Response:
    payload = await require_user(request)
    did = payload["sub"]
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    if not isinstance(body, dict):
        return web.json_response({"ok": False, "error": "invalid body"}, status=400)

    cfg = deps.get_user_cfg(did)
    rank = str(cfg.get("rank") or "free").lower()

    # Apply allowed fields only — rank is never client-writable
    for k, v in body.items():
        if k not in ALLOWED_CONFIG_KEYS:
            continue
        if k == "alts":
            if not isinstance(v, dict):
                continue
            # plan limits
            limits = {"free": 2, "premium": 10, "bypass": 9999}
            limit = limits.get(rank, 2)
            cleaned = {}
            for name, slot in v.items():
                name = str(name).strip()
                if not name:
                    continue
                try:
                    slot_i = int(slot)
                except Exception:
                    slot_i = 2
                cleaned[name] = max(1, min(6, slot_i))
                if len(cleaned) >= limit:
                    break
            cfg["alts"] = cleaned
        elif k == "controllers":
            if isinstance(v, list):
                cfg["controllers"] = [str(x).strip() for x in v if str(x).strip()][:20]
        elif k in (
            "mute_gun_sounds",
            "auto_mask",
            "auto_armor",
            "muscle",
            "inf",
            "armor_max",
            "char_random",
            "friendly_fire_prevention",
        ):
            cfg[k] = bool(v)
        elif k in ("char_user", "slot", "muscle_size"):
            try:
                cfg[k] = int(v)
            except Exception:
                pass
        elif k in ("owner", "key", "gun", "prefix", "anim"):
            cfg[k] = str(v).strip() if v is not None else ""

    # Non-bypass cannot enable inf / char_random
    if rank != "bypass":
        cfg["inf"] = False
        cfg["char_random"] = False

    cfg = deps.merge_defaults(cfg)
    deps.set_user_cfg(did, cfg)
    admin = await is_admin_user(str(payload["sub"]))
    return web.json_response({"ok": True, "config": cfg, "user": user_public(payload, cfg, is_admin=admin)})


async def api_loader(request: web.Request) -> web.Response:
    payload = await require_user(request)
    cfg = deps.get_user_cfg(payload["sub"])
    source = deps.generate_loader(cfg)
    return web.Response(
        text=source,
        content_type="text/plain",
        headers={
            "Content-Disposition": 'attachment; filename="StandLoader.lua"',
        },
    )


async def api_loader_preview(request: web.Request) -> web.Response:
    payload = await require_user(request)
    cfg = deps.get_user_cfg(payload["sub"])
    source = deps.generate_loader(cfg)
    return web.json_response({"ok": True, "source": source})


async def api_changelog(_request: web.Request) -> web.Response:
    entries = []
    if deps.supabase:
        try:
            res = (
                deps.supabase.table(deps.CHANGELOG_TABLE)
                .select("*")
                .order("created_at", desc=True)
                .limit(20)
                .execute()
            )
            for row in res.data or []:
                entries.append(
                    {
                        "title": row.get("title") or "Update",
                        "notes": row.get("notes") or "",
                        "version": row.get("version") or "",
                        "by": row.get("by") or "",
                        "date": row.get("created_at") or "",
                        "automatic": bool(row.get("automatic")),
                    }
                )
        except Exception as e:
            print("[api/changelog]", e)
    return web.json_response({"ok": True, "entries": entries})


async def api_status_public(_request: web.Request) -> web.Response:
    # thin alias already exists; keep for SPA
    st = deps.get_system_status()
    return web.json_response({"ok": True, "status": st})


# ── Admin ────────────────────────────────────────────────────────────
async def require_admin(request: web.Request) -> dict:
    payload = await require_user(request)
    if not await is_admin_user(str(payload["sub"])):
        raise web.HTTPForbidden(text=json.dumps({"ok": False, "error": "admin only — requires staff role"}), content_type="application/json")
    return payload


async def api_admin_users(request: web.Request) -> web.Response:
    await require_admin(request)
    users = []
    if deps.supabase:
        try:
            res = deps.supabase.table(deps.TABLE).select("discord_id,config,updated_at,created_at").execute()
            for row in res.data or []:
                cfg = row.get("config") or {}
                if isinstance(cfg, str):
                    try:
                        cfg = json.loads(cfg)
                    except Exception:
                        cfg = {}
                users.append(
                    {
                        "discord_id": row.get("discord_id"),
                        "owner": cfg.get("owner") or "",
                        "plan": cfg.get("rank") or "free",
                        "alts": len(cfg.get("alts") or {}),
                        "joined": row.get("created_at") or row.get("updated_at") or "",
                    }
                )
        except Exception as e:
            print("[api/admin/users]", e)
            return web.json_response({"ok": False, "error": str(e)}, status=500)
    return web.json_response({"ok": True, "users": users})


async def api_admin_set_plan(request: web.Request) -> web.Response:
    await require_admin(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    target = str(body.get("discord_id") or "").strip()
    plan = str(body.get("plan") or "free").lower()
    if plan not in ("free", "premium", "bypass"):
        return web.json_response({"ok": False, "error": "invalid plan"}, status=400)
    if not target:
        return web.json_response({"ok": False, "error": "discord_id required"}, status=400)
    cfg = deps.get_user_cfg(target)
    cfg["rank"] = plan
    deps.set_user_cfg(target, cfg)
    return web.json_response({"ok": True, "discord_id": target, "plan": plan})


async def api_admin_blacklist(request: web.Request) -> web.Response:
    admin = await require_admin(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    target = str(body.get("discord_id") or "").strip()
    reason = str(body.get("reason") or "").strip()
    action = str(body.get("action") or "add").lower()
    if not target:
        return web.json_response({"ok": False, "error": "discord_id required"}, status=400)
    if action == "remove":
        deps.clear_blacklist(target)
    else:
        deps.set_blacklist(target, reason, int(admin["sub"]))
    return web.json_response({"ok": True})


async def api_admin_blacklist_list(request: web.Request) -> web.Response:
    await require_admin(request)
    rows = []
    if deps.supabase:
        try:
            res = deps.supabase.table(deps.BLACKLIST_TABLE).select("*").execute()
            for r in res.data or []:
                rows.append(
                    {
                        "discord_id": r.get("discord_id"),
                        "reason": r.get("reason") or "",
                        "date": r.get("created_at") or r.get("at") or "",
                        "by": r.get("by") or "",
                    }
                )
        except Exception as e:
            print("[api/admin/blacklist]", e)
    return web.json_response({"ok": True, "blacklist": rows})


async def api_admin_analytics(request: web.Request) -> web.Response:
    await require_admin(request)
    total = premium = bypass = blacklisted = keys = 0
    if deps.supabase:
        try:
            res = deps.supabase.table(deps.TABLE).select("config").execute()
            total = len(res.data or [])
            for row in res.data or []:
                cfg = row.get("config") or {}
                if isinstance(cfg, str):
                    try:
                        cfg = json.loads(cfg)
                    except Exception:
                        cfg = {}
                rank = str(cfg.get("rank") or "free").lower()
                if rank == "premium":
                    premium += 1
                elif rank == "bypass":
                    bypass += 1
        except Exception as e:
            print("[analytics users]", e)
        try:
            bl = deps.supabase.table(deps.BLACKLIST_TABLE).select("discord_id", count="exact").execute()
            blacklisted = getattr(bl, "count", None) or len(bl.data or [])
        except Exception:
            pass
        try:
            ks = (
                deps.supabase.table(deps.KEY_STOCK_TABLE)
                .select("id", count="exact")
                .eq("reserved", False)
                .execute()
            )
            keys = getattr(ks, "count", None) or len(ks.data or [])
        except Exception:
            pass
    mrr = premium * 8 + bypass * 18
    return web.json_response(
        {
            "ok": True,
            "total_users": total,
            "premium": premium,
            "bypass": bypass,
            "mrr": mrr,
            "keys_available": keys,
            "blacklisted": blacklisted,
        }
    )


# ── Admin: Key stock CRUD ────────────────────────────────────────────
async def api_admin_keys_list(request: web.Request) -> web.Response:
    await require_admin(request)
    rows = []
    if deps.supabase:
        try:
            res = (
                deps.supabase.table(deps.KEY_STOCK_TABLE)
                .select("*")
                .order("created_at", desc=True)
                .limit(500)
                .execute()
            )
            for r in res.data or []:
                rows.append(
                    {
                        "id": r.get("id"),
                        "key": r.get("key"),
                        "product": r.get("product") or "stand",
                        "reserved": bool(r.get("reserved")),
                        "assigned_to_roblox_username": r.get("assigned_to_roblox_username") or "",
                        "assigned_to_roblox_user_id": r.get("assigned_to_roblox_user_id"),
                        "claimed_by_discord_id": r.get("claimed_by_discord_id") or "",
                        "created_at": r.get("created_at") or "",
                    }
                )
        except Exception as e:
            print("[api/admin/keys]", e)
            return web.json_response({"ok": False, "error": str(e)}, status=500)
    return web.json_response({"ok": True, "keys": rows})


async def api_admin_keys_add(request: web.Request) -> web.Response:
    await require_admin(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    key = str(body.get("key") or "").strip()
    product = str(body.get("product") or "stand").strip().lower()
    if not key:
        return web.json_response({"ok": False, "error": "key required"}, status=400)
    if product not in ("stand", "premium", "bypass", "shield"):
        return web.json_response({"ok": False, "error": "invalid product"}, status=400)
    if not deps.supabase:
        return web.json_response({"ok": False, "error": "database unavailable"}, status=503)
    try:
        res = (
            deps.supabase.table(deps.KEY_STOCK_TABLE)
            .insert({"key": key, "product": product, "reserved": False})
            .execute()
        )
        row = (res.data or [None])[0]
        if not row:
            return web.json_response({"ok": False, "error": "insert failed"}, status=500)
        return web.json_response(
            {
                "ok": True,
                "key": {
                    "id": row.get("id"),
                    "key": row.get("key"),
                    "product": row.get("product"),
                    "reserved": False,
                    "assigned_to_roblox_username": "",
                },
            }
        )
    except Exception as e:
        msg = str(e)
        if "duplicate" in msg.lower() or "unique" in msg.lower():
            return web.json_response({"ok": False, "error": "key already exists"}, status=409)
        print("[api/admin/keys add]", e)
        return web.json_response({"ok": False, "error": msg}, status=500)


async def api_admin_keys_delete(request: web.Request) -> web.Response:
    await require_admin(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    key_id = body.get("id")
    key_val = str(body.get("key") or "").strip()
    if key_id is None and not key_val:
        return web.json_response({"ok": False, "error": "id or key required"}, status=400)
    if not deps.supabase:
        return web.json_response({"ok": False, "error": "database unavailable"}, status=503)
    try:
        q = deps.supabase.table(deps.KEY_STOCK_TABLE).delete()
        if key_id is not None:
            q = q.eq("id", int(key_id))
        else:
            q = q.eq("key", key_val)
        q.execute()
        return web.json_response({"ok": True})
    except Exception as e:
        print("[api/admin/keys delete]", e)
        return web.json_response({"ok": False, "error": str(e)}, status=500)


# ── Admin: System status + changelog ─────────────────────────────────
VALID_STATUSES = frozenset({"up", "down", "updating", "detected"})


async def api_admin_set_status(request: web.Request) -> web.Response:
    """Set global Stand status: renames Discord status channel, updates bot presence, persists."""
    admin = await require_admin(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)

    status = str(body.get("status") or "").lower().strip()
    note = str(body.get("note") or "").strip()
    if status not in VALID_STATUSES:
        return web.json_response(
            {"ok": False, "error": f"invalid status; use: {', '.join(sorted(VALID_STATUSES))}"},
            status=400,
        )

    update_fn = getattr(deps, "update_status_channel", None)
    if not callable(update_fn):
        return web.json_response(
            {"ok": False, "error": "status updater not bound (bot not ready)"},
            status=503,
        )

    # Build a lightweight "by" label for the embed (no real discord.User needed)
    by_label = f"<@{admin['sub']}>" if admin.get("sub") else "Admin panel"

    try:
        err = await update_fn(
            status,
            note=note,
            by=by_label,
            announce=True,
        )
    except Exception as e:
        print("[api/admin/status]", e)
        return web.json_response({"ok": False, "error": str(e)}, status=500)

    if err:
        # Still may have partially applied (persisted + presence); report it
        return web.json_response({"ok": False, "error": err, "status": status}, status=502)

    return web.json_response({"ok": True, "status": status, "note": note})


async def api_admin_post_changelog(request: web.Request) -> web.Response:
    """Post a changelog embed to the Discord changelog channel + Supabase."""
    admin = await require_admin(request)
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)

    title = str(body.get("title") or "").strip()
    notes = str(body.get("notes") or "").strip()
    version = str(body.get("version") or "").strip()
    if not title:
        return web.json_response({"ok": False, "error": "title required"}, status=400)

    post_fn = getattr(deps, "post_changelog", None)
    if not callable(post_fn):
        return web.json_response(
            {"ok": False, "error": "changelog poster not bound (bot not ready)"},
            status=503,
        )

    by_label = f"<@{admin['sub']}>" if admin.get("sub") else "Admin panel"

    try:
        err = await post_fn(
            title=title,
            notes=notes,
            version=version,
            by=by_label,
            automatic=False,
        )
    except Exception as e:
        print("[api/admin/changelog]", e)
        return web.json_response({"ok": False, "error": str(e)}, status=500)

    if err:
        return web.json_response({"ok": False, "error": err}, status=502)

    return web.json_response({"ok": True, "title": title})


# ── Stripe ───────────────────────────────────────────────────────────
async def api_create_checkout_session(request: web.Request) -> web.Response:
    payload = await require_user(request)
    if not STRIPE_SECRET_KEY:
        return web.json_response(
            {"ok": False, "error": "Stripe not configured (STRIPE_SECRET_KEY)"}, status=503
        )
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)
    plan = str(body.get("plan") or "").strip().lower()
    price_id = STRIPE_PRICE_PREMIUM if plan == "premium" else STRIPE_PRICE_BYPASS if plan == "bypass" else ""
    if not price_id:
        return web.json_response(
            {"ok": False, "error": f"No Stripe Price ID configured for plan '{plan}'"}, status=400
        )
    discord_id = str(payload["sub"])
    success_url = f"{PUBLIC_URL}/dashboard?success=1" if PUBLIC_URL else "https://example.com/?success=1"
    cancel_url = f"{PUBLIC_URL}/dashboard" if PUBLIC_URL else "https://example.com/"
    form = {
        "mode": "subscription",
        "payment_method_types[0]": "card",
        "line_items[0][price]": price_id,
        "line_items[0][quantity]": "1",
        "success_url": success_url,
        "cancel_url": cancel_url,
        "client_reference_id": discord_id,
        "metadata[discord_id]": discord_id,
        "metadata[plan]": plan,
        "metadata[price_id]": price_id,
        "subscription_data[metadata][discord_id]": discord_id,
        "subscription_data[metadata][plan]": plan,
        "subscription_data[metadata][price_id]": price_id,
    }
    headers = {
        "Authorization": f"Bearer {STRIPE_SECRET_KEY}",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    try:
        async with ClientSession() as session:
            async with session.post(
                "https://api.stripe.com/v1/checkout/sessions",
                data=form,
                headers=headers,
                timeout=20,
            ) as resp:
                data = await resp.json()
                if resp.status >= 400:
                    err = (data.get("error") or {}).get("message") or str(data)
                    return web.json_response({"ok": False, "error": err}, status=400)
                return web.json_response({"ok": True, "url": data.get("url"), "id": data.get("id")})
    except Exception as e:
        print("[stripe checkout]", e)
        return web.json_response({"ok": False, "error": str(e)}, status=500)


def _plan_from_price_id(price_id: str) -> str:
    """Map Stripe Price ID → internal plan. Never default to a paid tier on unknown."""
    price_id = (price_id or "").strip()
    if price_id and STRIPE_PRICE_BYPASS and price_id == STRIPE_PRICE_BYPASS:
        return "bypass"
    if price_id and STRIPE_PRICE_PREMIUM and price_id == STRIPE_PRICE_PREMIUM:
        return "premium"
    return ""


def _already_processed_event(event_id: str) -> bool:
    if not event_id or not deps.supabase:
        return False
    try:
        res = (
            deps.supabase.table("stripe_events")
            .select("event_id")
            .eq("event_id", event_id)
            .limit(1)
            .execute()
        )
        return bool(res.data)
    except Exception as e:
        print(f"[stripe_events] lookup failed: {e}")
        return False


def _mark_event_processed(event_id: str, event_type: str) -> None:
    if not event_id or not deps.supabase:
        return
    try:
        deps.supabase.table("stripe_events").upsert(
            {"event_id": event_id, "event_type": event_type or ""},
            on_conflict="event_id",
        ).execute()
    except Exception as e:
        print(f"[stripe_events] insert failed: {e}")


async def api_stripe_webhook(request: web.Request) -> web.Response:
    """Verify Stripe signature, process checkout (and optional lifecycle) events once."""
    raw = await request.read()
    sig = request.headers.get("Stripe-Signature", "")

    if not STRIPE_WEBHOOK_SECRET:
        print("[stripe webhook] STRIPE_WEBHOOK_SECRET not set — rejecting")
        return web.json_response({"ok": False, "error": "webhook not configured"}, status=503)

    # Official verification (signature + timestamp anti-replay)
    try:
        import stripe as _stripe

        event = _stripe.Webhook.construct_event(raw, sig, STRIPE_WEBHOOK_SECRET)
        # construct_event returns a StripeObject; normalize to dict
        if hasattr(event, "to_dict"):
            event = event.to_dict()
    except Exception as e:
        # Fallback minimal verify if stripe package missing
        try:
            parts = dict(p.split("=", 1) for p in sig.split(",") if "=" in p)
            ts = parts.get("t", "")
            v1 = parts.get("v1", "")
            if not ts or not v1:
                raise ValueError("missing signature parts")
            # Reject timestamps older than 5 minutes
            if abs(int(time.time()) - int(ts)) > 300:
                raise ValueError("timestamp outside tolerance")
            signed = f"{ts}.{raw.decode('utf-8')}"
            expected = hmac.new(
                STRIPE_WEBHOOK_SECRET.encode(), signed.encode(), hashlib.sha256
            ).hexdigest()
            if not hmac.compare_digest(expected, v1):
                raise ValueError("signature mismatch")
            event = json.loads(raw.decode("utf-8"))
        except Exception as e2:
            print(f"[stripe webhook] verify failed: {e} / {e2}")
            return web.json_response({"ok": False, "error": "invalid signature"}, status=400)

    event_id = str(event.get("id") or "")
    etype = str(event.get("type") or "")
    obj = (event.get("data") or {}).get("object") or {}

    if event_id and _already_processed_event(event_id):
        return web.json_response({"ok": True, "duplicate": True})

    if etype == "checkout.session.completed":
        meta = obj.get("metadata") or {}
        discord_id = str(
            meta.get("discord_id") or obj.get("client_reference_id") or ""
        ).strip()

        # Prefer Price ID over free-form metadata so a forged/wrong plan cannot upgrade
        plan = ""
        line_items = obj.get("line_items")  # usually expanded only on retrieve
        # Checkout Session stores price on the line items; metadata.plan is secondary
        price_id = str(meta.get("price_id") or "").strip()
        if not price_id:
            # Some sessions put price in metadata from create-checkout; otherwise try amount fallback is unsafe
            mode = str(obj.get("mode") or "")
            # If create-checkout set metadata.plan we still map only after price confirmation when possible
            plan = str(meta.get("plan") or "").strip().lower()
        else:
            plan = _plan_from_price_id(price_id)

        if not plan:
            plan = str(meta.get("plan") or "").strip().lower()
        if plan not in ("premium", "bypass"):
            print(f"[stripe webhook] unknown plan for session {obj.get('id')}; ignoring")
            _mark_event_processed(event_id, etype)
            return web.json_response({"ok": True, "ignored": True})

        if discord_id:
            try:
                cfg = deps.get_user_cfg(discord_id)
                cfg["rank"] = plan
                cfg["stripe_customer_id"] = obj.get("customer") or cfg.get("stripe_customer_id")
                cfg["stripe_subscription_id"] = obj.get("subscription") or cfg.get(
                    "stripe_subscription_id"
                )
                deps.set_user_cfg(discord_id, cfg)
                print(f"[stripe webhook] set plan={plan} for discord_id={discord_id}")
            except Exception as e:
                print(f"[stripe webhook] update failed: {e}")
                return web.json_response({"ok": False, "error": str(e)}, status=500)

    elif etype in (
        "customer.subscription.deleted",
        "customer.subscription.updated",
        "charge.refunded",
        "charge.dispute.created",
    ):
        # Best-effort downgrade / revoke on cancel, refund, dispute
        meta = obj.get("metadata") or {}
        discord_id = str(meta.get("discord_id") or "").strip()
        customer = str(obj.get("customer") or "")
        if not discord_id and customer and deps.supabase:
            try:
                # Find user by stored stripe_customer_id inside config jsonb (best-effort)
                res = (
                    deps.supabase.table("stand_configs")
                    .select("discord_id, config")
                    .limit(500)
                    .execute()
                )
                for row in res.data or []:
                    cfg = row.get("config") or {}
                    if str(cfg.get("stripe_customer_id") or "") == customer:
                        discord_id = str(row.get("discord_id") or "")
                        break
            except Exception as e:
                print(f"[stripe webhook] customer lookup: {e}")

        if discord_id and etype in (
            "customer.subscription.deleted",
            "charge.refunded",
            "charge.dispute.created",
        ):
            try:
                cfg = deps.get_user_cfg(discord_id)
                cfg["rank"] = "free"
                deps.set_user_cfg(discord_id, cfg)
                print(f"[stripe webhook] revoked plan for discord_id={discord_id} ({etype})")
            except Exception as e:
                print(f"[stripe webhook] revoke failed: {e}")
                return web.json_response({"ok": False, "error": str(e)}, status=500)

    _mark_event_processed(event_id, etype)
    return web.json_response({"ok": True})


# ── Tickets (website → Discord channels, stored in Supabase) ─────────
TICKETS_TABLE = "stand_tickets"


def _ticket_bot_headers() -> dict:
    return {
        "Authorization": f"Bot {DISCORD_BOT_TOKEN}",
        "Content-Type": "application/json",
        "User-Agent": "ExecutiveStand-WebTickets (https://discord.com)",
    }


def _tickets_client():
    return getattr(deps, "supabase", None)


def _row_to_ticket(row: dict) -> dict:
    return {
        "channel_id": int(row["channel_id"]) if str(row.get("channel_id", "")).isdigit() else row.get("channel_id"),
        "opener_id": int(row["opener_id"]) if str(row.get("opener_id", "")).isdigit() else row.get("opener_id"),
        "category": row.get("category") or "general",
        "number": int(row.get("number") or 0),
        "opened_at": row.get("opened_at") or "",
        "claimed_by": int(row["claimed_by"]) if row.get("claimed_by") and str(row["claimed_by"]).isdigit() else row.get("claimed_by"),
        "claimed_at": row.get("claimed_at"),
        "closed": bool(row.get("closed")),
        "closed_by": row.get("closed_by"),
        "closed_at": row.get("closed_at"),
        "guild_id": int(row["guild_id"]) if row.get("guild_id") and str(row["guild_id"]).isdigit() else row.get("guild_id"),
        "subject": row.get("subject") or "",
        "priority": row.get("priority") or "medium",
        "source": row.get("source") or "discord",
        "body": row.get("body") or "",
    }


def _load_tickets() -> dict:
    """Compatibility shape: {tickets: {channel_id: dict}, counters: {category: n}}."""
    sb = _tickets_client()
    out = {"tickets": {}, "counters": {}}
    if not sb:
        return out
    try:
        res = sb.table(TICKETS_TABLE).select("*").execute()
        for row in res.data or []:
            t = _row_to_ticket(row)
            out["tickets"][str(t["channel_id"])] = t
            cat = t.get("category") or "general"
            out["counters"][cat] = max(int(out["counters"].get(cat, 0)), int(t.get("number") or 0))
    except Exception as e:
        print("[tickets] load error:", e)
    return out


def _next_ticket_number(category: str) -> int:
    sb = _tickets_client()
    if not sb:
        return 1
    try:
        res = (
            sb.table(TICKETS_TABLE)
            .select("number")
            .eq("category", category)
            .order("number", desc=True)
            .limit(1)
            .execute()
        )
        if res.data:
            return int(res.data[0].get("number") or 0) + 1
    except Exception as e:
        print("[tickets] next number error:", e)
    return 1


def _upsert_ticket(ticket: dict) -> None:
    sb = _tickets_client()
    if not sb:
        print("[tickets] upsert skipped — no supabase")
        return
    row = {
        "channel_id": str(ticket["channel_id"]),
        "opener_id": str(ticket["opener_id"]),
        "category": ticket.get("category") or "general",
        "number": int(ticket.get("number") or 0),
        "subject": ticket.get("subject") or "",
        "priority": ticket.get("priority") or "medium",
        "body": (ticket.get("body") or "")[:2000],
        "source": ticket.get("source") or "discord",
        "claimed_by": str(ticket["claimed_by"]) if ticket.get("claimed_by") else None,
        "claimed_at": ticket.get("claimed_at"),
        "closed": bool(ticket.get("closed")),
        "closed_by": str(ticket["closed_by"]) if ticket.get("closed_by") else None,
        "closed_at": ticket.get("closed_at"),
        "guild_id": str(ticket["guild_id"]) if ticket.get("guild_id") else None,
        "opened_at": ticket.get("opened_at") or datetime.now(timezone.utc).isoformat(),
    }
    try:
        sb.table(TICKETS_TABLE).upsert(row).execute()
    except Exception as e:
        print("[tickets] upsert error:", e)
        raise


async def api_list_tickets(request: web.Request) -> web.Response:
    """List the current user's tickets (open + closed) from Supabase."""
    payload = await require_user(request)
    discord_id = str(payload["sub"])
    sb = _tickets_client()
    mine = []
    if sb:
        try:
            res = (
                sb.table(TICKETS_TABLE)
                .select("*")
                .eq("opener_id", discord_id)
                .order("opened_at", desc=True)
                .execute()
            )
            for row in res.data or []:
                t = _row_to_ticket(row)
                mine.append(
                    {
                        "id": t.get("number") or t.get("channel_id"),
                        "channel_id": str(t.get("channel_id")),
                        "subject": t.get("subject") or t.get("category") or "Ticket",
                        "category": t.get("category") or "",
                        "priority": t.get("priority") or "medium",
                        "status": "closed"
                        if t.get("closed")
                        else ("claimed" if t.get("claimed_by") else "open"),
                        "opened_at": t.get("opened_at") or "",
                        "source": t.get("source") or "discord",
                        "guild_id": str(t.get("guild_id") or GUILD_ID or ""),
                    }
                )
        except Exception as e:
            print("[tickets] list error:", e)
            return web.json_response({"ok": False, "error": str(e)}, status=500)
    return web.json_response({"ok": True, "tickets": mine})



async def api_create_ticket(request: web.Request) -> web.Response:
    """
    Create a real Discord ticket channel from the website form.
    Body: { subject, body, category, priority }
    Requires: GUILD_ID, STAFF_DISCORD_TOKEN (or DISCORD_TOKEN), preferably TICKET_CATEGORY_ID.
    """
    payload = await require_user(request)
    discord_id = str(payload["sub"])
    username = payload.get("username") or payload.get("global_name") or discord_id

    if not GUILD_ID or not DISCORD_BOT_TOKEN:
        return web.json_response(
            {
                "ok": False,
                "error": "Ticket system not configured. Set GUILD_ID and STAFF_DISCORD_TOKEN.",
            },
            status=503,
        )

    try:
        body = await request.json()
    except Exception:
        return web.json_response({"ok": False, "error": "invalid json"}, status=400)

    subject = str(body.get("subject") or "").strip()
    details = str(body.get("body") or body.get("details") or "").strip()
    category_key = str(body.get("category") or "general").strip().lower()
    priority = str(body.get("priority") or "medium").strip().lower()
    if priority not in ("low", "medium", "high"):
        priority = "medium"
    if not subject:
        return web.json_response({"ok": False, "error": "subject is required"}, status=400)
    if len(subject) > 200:
        subject = subject[:200]
    if len(details) > 4000:
        details = details[:4000]

    meta = WEB_TICKET_CATEGORIES.get(category_key) or WEB_TICKET_CATEGORIES["general"]
    category_key = category_key if category_key in WEB_TICKET_CATEGORIES else "general"

    sb = _tickets_client()
    if not sb:
        return web.json_response(
            {"ok": False, "error": "Supabase not configured — cannot store tickets."},
            status=503,
        )

    # Prevent multiple open tickets of same category for this user
    try:
        existing = (
            sb.table(TICKETS_TABLE)
            .select("channel_id")
            .eq("opener_id", discord_id)
            .eq("category", category_key)
            .eq("closed", False)
            .limit(1)
            .execute()
        )
        if existing.data:
            return web.json_response(
                {
                    "ok": False,
                    "error": f"You already have an open {meta['label']} ticket in Discord.",
                    "channel_id": existing.data[0].get("channel_id"),
                },
                status=409,
            )
    except Exception as e:
        print("[tickets] duplicate check error:", e)

    num = _next_ticket_number(category_key)
    slug = (meta.get("slug") or meta["label"].lower().replace(" ", "-"))[:12]
    channel_name = f"{slug}-{num:04d}"

    # Permission overwrites (REST format)
    # type 0 = role, type 1 = member
    overwrites = [
        {
            "id": GUILD_ID,  # @everyone
            "type": 0,
            "deny": str(0x400 | 0x4000),  # VIEW_CHANNEL | READ_MESSAGE_HISTORY simplified via bits
            "allow": "0",
        },
    ]
    # Deny view for @everyone more cleanly: VIEW_CHANNEL = 1 << 10 = 1024
    overwrites[0] = {
        "id": GUILD_ID,
        "type": 0,
        "deny": "1024",
        "allow": "0",
    }
    # Opener
    overwrites.append(
        {
            "id": discord_id,
            "type": 1,
            "allow": str(1024 | 2048 | 65536 | 16384 | 32768),  # view, send, history, attach, embeds
            "deny": "0",
        }
    )
    # Staff role
    if STAFF_ROLE_ID:
        overwrites.append(
            {
                "id": STAFF_ROLE_ID,
                "type": 0,
                "allow": str(1024 | 2048 | 65536 | 8192 | 16384 | 32768),  # + manage messages
                "deny": "0",
            }
        )

    create_payload: dict[str, Any] = {
        "name": channel_name,
        "type": 0,
        "topic": f"Ticket #{num} | {meta['label']} | opener:{discord_id} | web",
        "permission_overwrites": overwrites,
    }
    if TICKET_CATEGORY_ID:
        create_payload["parent_id"] = TICKET_CATEGORY_ID

    headers = _ticket_bot_headers()
    channel = None
    async with ClientSession() as session:
        async with session.post(
            f"https://discord.com/api/v10/guilds/{GUILD_ID}/channels",
            headers=headers,
            json=create_payload,
            timeout=20,
        ) as resp:
            raw = await resp.text()
            if resp.status not in (200, 201):
                print(f"[tickets] create channel failed {resp.status}: {raw[:500]}")
                return web.json_response(
                    {
                        "ok": False,
                        "error": f"Discord failed to create channel ({resp.status}). Check bot permissions and TICKET_CATEGORY_ID.",
                    },
                    status=502,
                )
            try:
                channel = json.loads(raw)
            except Exception:
                return web.json_response({"ok": False, "error": "invalid Discord response"}, status=502)

        channel_id = str(channel.get("id") or "")
        if not channel_id:
            return web.json_response({"ok": False, "error": "no channel id returned"}, status=502)

        # Initial embed + user message
        priority_label = {"low": "Low", "medium": "Medium", "high": "High ⚠️"}.get(priority, priority)
        embed = {
            "title": f"{meta['emoji']} {meta['label']} Ticket",
            "description": (
                f"Thanks for contacting support, <@{discord_id}>.\n\n"
                f"**Category:** {meta['label']}\n"
                f"**Priority:** {priority_label}\n"
                f"**Subject:** {subject}\n\n"
                f"**Details:**\n{details or '_No details provided._'}\n\n"
                f"_Opened from the website by `{username}`._\n"
                "Staff: reply here. Use the Discord ticket panel buttons to Claim / Close."
            ),
            "color": meta.get("color", 0x5865F2),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "footer": {"text": f"Ticket #{num:04d} • Executive Stand • Web"},
        }
        content = f"<@{discord_id}>"
        if STAFF_ROLE_ID:
            content += f" | <@&{STAFF_ROLE_ID}>"

        components = [
            {
                "type": 1,
                "components": [
                    {
                        "type": 2,
                        "style": 4,
                        "label": "Close",
                        "emoji": {"name": "🔒"},
                        "custom_id": "ticket:close",
                    },
                    {
                        "type": 2,
                        "style": 1,
                        "label": "Claim",
                        "emoji": {"name": "✋"},
                        "custom_id": "ticket:claim",
                    },
                    {
                        "type": 2,
                        "style": 2,
                        "label": "Transcript",
                        "emoji": {"name": "📄"},
                        "custom_id": "ticket:transcript",
                    },
                ],
            }
        ]
        async with session.post(
            f"https://discord.com/api/v10/channels/{channel_id}/messages",
            headers=headers,
            json={"content": content, "embeds": [embed], "components": components},
            timeout=15,
        ) as msg_resp:
            if msg_resp.status not in (200, 201):
                msg_err = await msg_resp.text()
                print(f"[tickets] post message failed {msg_resp.status}: {msg_err[:300]}")
                # Channel exists; still record ticket

    ticket_row = {
        "channel_id": int(channel_id),
        "opener_id": int(discord_id),
        "category": category_key,
        "number": num,
        "opened_at": datetime.now(timezone.utc).isoformat(),
        "claimed_by": None,
        "closed": False,
        "guild_id": int(GUILD_ID) if str(GUILD_ID).isdigit() else GUILD_ID,
        "subject": subject,
        "priority": priority,
        "source": "web",
        "body": details[:500],
    }
    try:
        _upsert_ticket(ticket_row)
    except Exception as e:
        return web.json_response(
            {"ok": False, "error": f"Ticket channel created but failed to save to Supabase: {e}"},
            status=500,
        )

    invite_hint = f"https://discord.com/channels/{GUILD_ID}/{channel_id}"
    return web.json_response(
        {
            "ok": True,
            "ticket": {
                "id": num,
                "channel_id": channel_id,
                "subject": subject,
                "category": category_key,
                "priority": priority,
                "status": "open",
                "url": invite_hint,
            },
            "message": f"Ticket #{num:04d} created in Discord. Staff will reply there.",
        }
    )


def register_routes(app: web.Application) -> None:
    """Attach all web dashboard routes to the aiohttp app."""
    app.router.add_get("/auth/discord", auth_discord)
    app.router.add_get("/auth/callback", auth_callback)
    app.router.add_get("/api/me", api_me)
    app.router.add_post("/api/logout", api_logout)
    app.router.add_post("/api/delete-account", api_delete_account)
    app.router.add_delete("/api/account", api_delete_account)
    app.router.add_get("/api/config", api_get_config)
    app.router.add_post("/api/config", api_save_config)
    app.router.add_put("/api/config", api_save_config)
    app.router.add_get("/api/loader", api_loader)
    app.router.add_get("/api/loader/preview", api_loader_preview)
    app.router.add_get("/api/changelog", api_changelog)
    app.router.add_get("/api/v1/me", api_me)
    # Tickets
    app.router.add_get("/api/tickets", api_list_tickets)
    app.router.add_post("/api/tickets", api_create_ticket)
    # Admin
    app.router.add_get("/api/admin/users", api_admin_users)
    app.router.add_post("/api/admin/set-plan", api_admin_set_plan)
    app.router.add_get("/api/admin/blacklist", api_admin_blacklist_list)
    app.router.add_post("/api/admin/blacklist", api_admin_blacklist)
    app.router.add_get("/api/admin/analytics", api_admin_analytics)
    app.router.add_get("/api/admin/keys", api_admin_keys_list)
    app.router.add_post("/api/admin/keys", api_admin_keys_add)
    app.router.add_delete("/api/admin/keys", api_admin_keys_delete)
    app.router.add_post("/api/admin/keys/delete", api_admin_keys_delete)
    app.router.add_post("/api/admin/status", api_admin_set_status)
    app.router.add_post("/api/admin/changelog", api_admin_post_changelog)
    # Stripe
    app.router.add_post("/api/create-checkout-session", api_create_checkout_session)
    app.router.add_post("/api/stripe-webhook", api_stripe_webhook)

    print(
        f"[web] OAuth={'ON' if oauth_configured() else 'OFF'} "
        f"admin_ids={len(ADMIN_DISCORD_IDS)} admin_roles={len(ADMIN_ROLE_IDS)} "
        f"guild={GUILD_ID or '(unset)'} stripe={'ON' if STRIPE_SECRET_KEY else 'OFF'} "
        f"tickets={'ON' if (GUILD_ID and DISCORD_BOT_TOKEN) else 'OFF'} "
        f"redirect={DISCORD_REDIRECT_URI or '(unset)'}"
    )
