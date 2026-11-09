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
import time
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
SESSION_SECRET = (
    os.getenv("SESSION_SECRET")
    or os.getenv("DISCORD_CLIENT_SECRET")
    or "dev-insecure-change-me"
).strip()
# Comma-separated Discord user IDs that get is_admin on the site
ADMIN_DISCORD_IDS = {
    x.strip()
    for x in (os.getenv("ADMIN_DISCORD_IDS") or "").split(",")
    if x.strip()
}
TOKEN_TTL_SEC = int(os.getenv("SESSION_TTL_SEC", "604800"))  # 7 days
OAUTH_SCOPES = "identify"


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


def is_admin_id(discord_id: str) -> bool:
    return str(discord_id) in ADMIN_DISCORD_IDS


def user_public(payload: dict, cfg: dict) -> dict:
    did = str(payload["sub"])
    rank = str(cfg.get("rank") or "free").lower()
    if rank not in ("free", "premium", "bypass"):
        rank = "free"
    avatar = payload.get("avatar") or ""
    avatar_url = ""
    if avatar:
        ext = "gif" if str(avatar).startswith("a_") else "png"
        avatar_url = f"https://cdn.discordapp.com/avatars/{did}/{avatar}.{ext}?size=128"
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
        "is_admin": is_admin_id(did),
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
    return web.json_response({"ok": True, "user": user_public(payload, cfg)})


async def api_logout(_request: web.Request) -> web.Response:
    resp = web.json_response({"ok": True})
    resp.del_cookie("es_token", path="/")
    return resp


async def api_get_config(request: web.Request) -> web.Response:
    payload = await require_user(request)
    cfg = deps.get_user_cfg(payload["sub"])
    # Never expose nothing sensitive beyond what the user owns
    safe = dict(cfg)
    return web.json_response({"ok": True, "config": safe, "user": user_public(payload, cfg)})


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
    return web.json_response({"ok": True, "config": cfg, "user": user_public(payload, cfg)})


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
    if not is_admin_id(str(payload["sub"])):
        raise web.HTTPForbidden(text=json.dumps({"ok": False, "error": "admin only"}), content_type="application/json")
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


def register_routes(app: web.Application) -> None:
    """Attach all web dashboard routes to the aiohttp app."""
    app.router.add_get("/auth/discord", auth_discord)
    app.router.add_get("/auth/callback", auth_callback)
    app.router.add_get("/api/me", api_me)
    app.router.add_post("/api/logout", api_logout)
    app.router.add_get("/api/config", api_get_config)
    app.router.add_post("/api/config", api_save_config)
    app.router.add_put("/api/config", api_save_config)
    app.router.add_get("/api/loader", api_loader)
    app.router.add_get("/api/loader/preview", api_loader_preview)
    app.router.add_get("/api/changelog", api_changelog)
    app.router.add_get("/api/v1/me", api_me)
    # Admin
    app.router.add_get("/api/admin/users", api_admin_users)
    app.router.add_post("/api/admin/set-plan", api_admin_set_plan)
    app.router.add_get("/api/admin/blacklist", api_admin_blacklist_list)
    app.router.add_post("/api/admin/blacklist", api_admin_blacklist)
    app.router.add_get("/api/admin/analytics", api_admin_analytics)

    print(
        f"[web] OAuth={'ON' if oauth_configured() else 'OFF'} "
        f"admins={len(ADMIN_DISCORD_IDS)} redirect={DISCORD_REDIRECT_URI or '(unset)'}"
    )
