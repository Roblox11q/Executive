#!/usr/bin/env python3
"""
Executive Stand — Staff Bot
Moderation, tickets (Ticket-King style dropdown), verification, and staff Stand commands.
"""
from __future__ import annotations

import asyncio
import io
import json
import os
import re
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

import aiohttp

import discord
from discord import app_commands
from discord.ext import commands
from dotenv import load_dotenv
from supabase import create_client, Client

load_dotenv()

# ── Tokens / env ──────────────────────────────────────────────────────────────
TOKEN = os.getenv("STAFF_DISCORD_TOKEN") or os.getenv("DISCORD_TOKEN", "")
STAFF_ROLE_ID = int(os.getenv("STAFF_ROLE_ID", "0") or "0")
SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY = os.getenv("SUPABASE_KEY", "")

# Status (shared with user bot via Supabase)
STATUS_CHANNEL_ID = int(os.getenv("STATUS_CHANNEL_ID", "1554079705022595174") or "1554079705022595174")
CHANGELOG_CHANNEL_ID = int(os.getenv("CHANGELOG_CHANNEL_ID", "1553592489728933934") or "1553592489728933934")
STATUS_CHANNEL_LABEL = os.getenv("STATUS_CHANNEL_LABEL", "Executive Stand")
STATUS_TABLE = "stand_status"
# Notify user bot (website + presence) when staff changes status
PUBLIC_BOT_URL = (
    os.getenv("PUBLIC_BOT_URL")
    or os.getenv("RENDER_EXTERNAL_URL")
    or ""
).rstrip("/")
STATUS_SYNC_SECRET = (
    (os.getenv("STATUS_SYNC_SECRET") or "").strip()
    or (os.getenv("REGISTER_KEY_SECRET") or "").strip()
)
CHANGELOG_TABLE = "stand_changelog"
BLACKLIST_TABLE = "stand_blacklist"
TABLE = "stand_configs"
KEY_STOCK_TABLE = "key_stock"
ROBLOX_KEYS_TABLE = "roblox_keys"
MEMBERS_TABLE = "verified_members"

# Verification roles
VERIFY_ROLE_ID = int(os.getenv("VERIFY_ROLE_ID", "1554782511781908600") or "1554782511781908600")
UNVERIFIED_ROLE_ID = int(os.getenv("UNVERIFIED_ROLE_ID", "1554782544950726746") or "1554782544950726746")
MEMBER_ROLE_ID = int(os.getenv("MEMBER_ROLE_ID", "1553595287896072192") or "1553595287896072192")

# OAuth2 — needed for silent guild restore
# DISCORD_CLIENT_ID   : your bot's application ID
# DISCORD_CLIENT_SECRET: OAuth2 secret from Discord Developer Portal → OAuth2
# OAUTH_REDIRECT_URI  : must match exactly what you set in Discord Dev Portal
#                       e.g. https://your-render-service.onrender.com/callback
# GUILD_ID            : the server you want members restored to
DISCORD_CLIENT_ID     = os.getenv("DISCORD_CLIENT_ID", "")
DISCORD_CLIENT_SECRET = os.getenv("DISCORD_CLIENT_SECRET", "")
OAUTH_REDIRECT_URI    = os.getenv("OAUTH_REDIRECT_URI", "")
GUILD_ID              = int(os.getenv("GUILD_ID", "0") or "0")

# Tickets
TRANSCRIPT_CHANNEL_ID = int(os.getenv("TRANSCRIPT_CHANNEL_ID", "1554783241750188112") or "1554783241750188112")
TICKET_CATEGORY_ID = int(os.getenv("TICKET_CATEGORY_ID", "0") or "0")  # 0 = same category as panel
TICKET_DATA_FILE = Path(__file__).resolve().parent / "data" / "tickets.json"

# Status visuals (match user bot)
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
    "up": 0x2ECC71,
    "down": 0xE74C3C,
    "updating": 0x3498DB,
    "detected": 0xF1C40F,
}
MAINTENANCE_BLOCK_STATES = frozenset({"down", "updating"})
STATUS_FILE = Path(__file__).resolve().parent / "data" / "system_status.json"

_current_status: str = "up"
_status_note: str = ""

# ── Supabase ──────────────────────────────────────────────────────────────────
supabase: Optional[Client] = None
if SUPABASE_URL and SUPABASE_KEY:
    try:
        supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
        print("Staff bot: Supabase connected")
    except Exception as e:
        print("Staff bot: Supabase init error:", e)
else:
    print("Staff bot: Supabase not configured")


def _load_persisted_status() -> None:
    global _current_status, _status_note
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
                return
        except Exception as e:
            print("load status supabase error:", e)
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
    payload = {"status": _current_status, "note": _status_note}
    try:
        STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATUS_FILE.write_text(
            json.dumps(
                {
                    "status": _current_status,
                    "note": _status_note,
                    "updated_at": datetime.now(timezone.utc).isoformat(),
                },
                indent=2,
            ),
            encoding="utf-8",
        )
    except Exception as e:
        print("save status file error:", e)
    if supabase:
        try:
            supabase.table(STATUS_TABLE).upsert(
                {
                    "id": "current",
                    "status": _current_status,
                    "note": _status_note,
                }
            ).execute()
        except Exception as e:
            print("save status supabase error:", e)


_load_persisted_status()


def get_system_status() -> str:
    return _current_status if _current_status in STATUS_DOTS else "up"


# ── Blacklist helpers (shared table) ──────────────────────────────────────────
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


def clear_user(discord_id) -> None:
    if not supabase:
        return
    try:
        supabase.table(TABLE).delete().eq("discord_id", str(discord_id)).execute()
    except Exception as e:
        print("clear_user error:", e)


def get_user_cfg(discord_id) -> dict:
    if not supabase:
        return {}
    try:
        res = (
            supabase.table(TABLE)
            .select("config")
            .eq("discord_id", str(discord_id))
            .limit(1)
            .execute()
        )
        if res.data:
            cfg = res.data[0].get("config") or {}
            if isinstance(cfg, str):
                cfg = json.loads(cfg)
            return dict(cfg)
    except Exception as e:
        print("get_user_cfg error:", e)
    return {}


def set_user_cfg(discord_id, cfg: dict) -> None:
    if not supabase:
        return
    try:
        supabase.table(TABLE).upsert(
            {"discord_id": str(discord_id), "config": cfg}
        ).execute()
    except Exception as e:
        print("set_user_cfg error:", e)


# ── Verified member registry ──────────────────────────────────────────────────
# Supabase table: verified_members
# Run this SQL once in Supabase → SQL Editor:
#
#   create table if not exists verified_members (
#     id              bigint primary key,   -- Discord user ID
#     username        text,
#     display_name    text,
#     guild_id        bigint,
#     verified_at     timestamptz,
#     left_at         timestamptz,
#     in_server       boolean default true,
#     access_token    text,                 -- OAuth2 token for silent rejoin
#     refresh_token   text,
#     token_expires_at timestamptz
#   );

def log_verified_member(
    member: discord.Member,
    *,
    access_token: str = "",
    refresh_token: str = "",
    token_expires_at: str = "",
) -> None:
    """
    Upsert a verified member. On first verify (no OAuth yet) just logs identity.
    After OAuth callback, called again with tokens to update the row.
    """
    if not supabase:
        return
    payload: dict = {
        "id": member.id,
        "username": str(member),
        "display_name": member.display_name,
        "guild_id": member.guild.id,
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "left_at": None,
        "in_server": True,
    }
    if access_token:
        payload["access_token"] = access_token
    if refresh_token:
        payload["refresh_token"] = refresh_token
    if token_expires_at:
        payload["token_expires_at"] = token_expires_at
    try:
        supabase.table(MEMBERS_TABLE).upsert(payload, on_conflict="id").execute()
    except Exception as e:
        print(f"log_verified_member error for {member.id}:", e)


def save_oauth_tokens(
    user_id: int,
    access_token: str,
    refresh_token: str,
    expires_in: int,
) -> None:
    """Persist OAuth2 tokens for a user after the callback."""
    if not supabase:
        return
    expires_at = (
        datetime.now(timezone.utc) + timedelta(seconds=expires_in)
    ).isoformat()
    try:
        supabase.table(MEMBERS_TABLE).update(
            {
                "access_token": access_token,
                "refresh_token": refresh_token,
                "token_expires_at": expires_at,
            }
        ).eq("id", user_id).execute()
    except Exception as e:
        print(f"save_oauth_tokens error for {user_id}:", e)


def mark_member_left(member: discord.Member) -> None:
    """Mark a verified member as no longer in the server when they leave."""
    if not supabase:
        return
    try:
        supabase.table(MEMBERS_TABLE).update(
            {
                "in_server": False,
                "left_at": datetime.now(timezone.utc).isoformat(),
            }
        ).eq("id", member.id).execute()
    except Exception as e:
        print(f"mark_member_left error for {member.id}:", e)


def build_oauth_url(state: str = "") -> str:
    """Build the Discord OAuth2 authorization URL."""
    params = {
        "client_id": DISCORD_CLIENT_ID,
        "redirect_uri": OAUTH_REDIRECT_URI,
        "response_type": "code",
        "scope": "identify guilds.join",
    }
    if state:
        params["state"] = state
    return "https://discord.com/oauth2/authorize?" + urllib.parse.urlencode(params)


async def exchange_code(code: str) -> Optional[dict]:
    """Exchange an OAuth2 authorization code for tokens."""
    async with aiohttp.ClientSession() as session:
        resp = await session.post(
            "https://discord.com/api/v10/oauth2/token",
            data={
                "client_id": DISCORD_CLIENT_ID,
                "client_secret": DISCORD_CLIENT_SECRET,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": OAUTH_REDIRECT_URI,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if resp.status != 200:
            print(f"exchange_code HTTP {resp.status}:", await resp.text())
            return None
        return await resp.json()


async def refresh_access_token(refresh_token: str) -> Optional[dict]:
    """Refresh an expired OAuth2 access token."""
    async with aiohttp.ClientSession() as session:
        resp = await session.post(
            "https://discord.com/api/v10/oauth2/token",
            data={
                "client_id": DISCORD_CLIENT_ID,
                "client_secret": DISCORD_CLIENT_SECRET,
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if resp.status != 200:
            print(f"refresh_access_token HTTP {resp.status}:", await resp.text())
            return None
        return await resp.json()


async def get_oauth_user(access_token: str) -> Optional[dict]:
    """Fetch the Discord user object for the given access token."""
    async with aiohttp.ClientSession() as session:
        resp = await session.get(
            "https://discord.com/api/v10/users/@me",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        if resp.status != 200:
            return None
        return await resp.json()


async def add_member_to_guild(user_id: int, access_token: str) -> tuple[bool, str]:
    """
    Use the bot token + user's OAuth2 token to silently add them to the guild.
    Returns (success, message).
    Discord returns 201 = added, 204 = already a member.
    """
    if not GUILD_ID or not TOKEN:
        return False, "GUILD_ID or bot TOKEN not configured"
    async with aiohttp.ClientSession() as session:
        resp = await session.put(
            f"https://discord.com/api/v10/guilds/{GUILD_ID}/members/{user_id}",
            json={"access_token": access_token},
            headers={
                "Authorization": f"Bot {TOKEN}",
                "Content-Type": "application/json",
            },
        )
        status = resp.status
        if status in (201, 204):
            return True, "added" if status == 201 else "already_member"
        body = await resp.text()
        return False, f"HTTP {status}: {body}"


# ── Bot setup ─────────────────────────────────────────────────────────────────
intents = discord.Intents.default()
intents.members = True
intents.message_content = True
intents.guilds = True

bot = commands.Bot(command_prefix="!", intents=intents)


def has_staff_role(interaction: discord.Interaction) -> bool:
    if STAFF_ROLE_ID == 0:
        if isinstance(interaction.user, discord.Member):
            return interaction.user.guild_permissions.administrator
        return False
    if not isinstance(interaction.user, discord.Member):
        return False
    return any(r.id == STAFF_ROLE_ID for r in interaction.user.roles)


def member_is_staff(member: discord.Member) -> bool:
    if STAFF_ROLE_ID == 0:
        return member.guild_permissions.administrator
    return any(r.id == STAFF_ROLE_ID for r in member.roles)


async def staff_check(interaction: discord.Interaction) -> bool:
    if has_staff_role(interaction):
        return True
    await interaction.response.send_message(
        "You need the **staff** role to use this command.",
        ephemeral=True,
    )
    return False


def _status_channel_name(status: str) -> str:
    dot = STATUS_DOTS.get(status, "🟢")
    label = (STATUS_CHANNEL_LABEL or "Executive Stand").strip() or "Executive Stand"
    return f"{dot}｜{label}"


async def _update_bot_presence(status: str | None = None) -> None:
    """Set the bot's activity/presence to reflect the current system status."""
    if status is None:
        status = _current_status if _current_status in STATUS_DOTS else "up"
    else:
        status = str(status).lower().strip()
    if status not in STATUS_DOTS:
        status = "up"
    dot = STATUS_DOTS.get(status, "🟢")
    label = STATUS_LABELS.get(status, status)
    activity = discord.Activity(
        type=discord.ActivityType.watching,
        name=f"{dot} {label}",
    )
    if bot is None or not getattr(bot, "is_ready", lambda: False)():
        print(f"[Staff] presence skip (bot not ready) → {dot} {label}")
        return
    try:
        await bot.change_presence(
            status=discord.Status.online,
            activity=activity,
        )
        print(f"[Staff] presence updated → watching {dot} {label}")
    except Exception as e:
        print("[Staff] presence update error:", e)


async def _notify_user_bot_status(
    status: str,
    *,
    note: str = "",
    by: Any = None,
    announce: bool = False,
) -> None:
    """
    Tell the user bot (website host) to reload status, update its presence,
    and rename the status channel. Works in combined service via localhost.
    """
    targets = []
    port = (os.getenv("PORT") or "10000").strip()
    targets.append(f"http://127.0.0.1:{port}/api/internal/status-sync")
    if PUBLIC_BOT_URL:
        targets.append(f"{PUBLIC_BOT_URL}/api/internal/status-sync")

    payload = {
        "status": status,
        "note": note or "",
        "by": str(by) if by else "staff bot",
        "announce": bool(announce),
    }
    if STATUS_SYNC_SECRET:
        payload["secret"] = STATUS_SYNC_SECRET

    headers = {"Content-Type": "application/json"}
    if STATUS_SYNC_SECRET:
        headers["X-Status-Sync-Secret"] = STATUS_SYNC_SECRET

    for url in targets:
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    url,
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=8),
                ) as resp:
                    text = await resp.text()
                    if resp.status < 400:
                        print(f"[Staff] notified user bot status-sync OK ({url}) {text[:120]}")
                        return
                    print(f"[Staff] status-sync {url} → HTTP {resp.status}: {text[:200]}")
        except Exception as e:
            print(f"[Staff] status-sync notify failed ({url}): {e}")


async def update_status_channel(
    status: str,
    *,
    note: str = "",
    by: Any = None,
    announce: bool = True,
    rename_channel: bool = True,
    notify_user_bot: bool = True,
) -> Optional[str]:
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

    # Staff bot presence
    await _update_bot_presence(status)

    channel = None
    rename_err = None
    if rename_channel and STATUS_CHANNEL_ID:
        channel = bot.get_channel(STATUS_CHANNEL_ID)
        if channel is None:
            try:
                channel = await bot.fetch_channel(STATUS_CHANNEL_ID)
            except Exception as e:
                rename_err = f"Cannot fetch status channel: {e}"
                print("[Staff]", rename_err)

        if channel is not None:
            new_name = _status_channel_name(status)
            try:
                if getattr(channel, "name", None) != new_name and hasattr(channel, "edit"):
                    await channel.edit(name=new_name, reason=f"Status → {status}")
                    print(f"[Staff] status channel renamed → {new_name}")
            except Exception as e:
                rename_err = f"status channel rename error: {e}"
                print("[Staff]", rename_err)

    label = STATUS_LABELS.get(status, status)
    color = STATUS_COLORS.get(status, 0x95A5A6)
    dot = STATUS_DOTS.get(status, "⚪")
    blocked = status in MAINTENANCE_BLOCK_STATES

    if announce and channel is not None and isinstance(channel, discord.TextChannel):
        desc = note.strip() if note and str(note).strip() else None
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
            print("[Staff] status channel message error:", e)
            # Still notify user bot so website/presence update
            if notify_user_bot:
                await _notify_user_bot_status(status, note=_status_note, by=by, announce=False)
            return f"Saved status but failed to post: {e}"

    # Push to user bot so website /api/status + user-bot presence stay in sync
    if notify_user_bot:
        await _notify_user_bot_status(status, note=_status_note, by=by, announce=False)

    return rename_err


async def status_watch_loop() -> None:
    """Pick up status changes made from the website admin panel (user bot)."""
    global _current_status, _status_note
    await bot.wait_until_ready()
    while not bot.is_closed():
        try:
            if not supabase:
                await asyncio.sleep(20)
                continue
            prev = _current_status
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
                note = str(rows[0].get("note") or "")
                if st in STATUS_DOTS and (st != _current_status or note != _status_note):
                    _current_status = st
                    _status_note = note
                    print(f"[Staff status-watch] {prev} → {st}")
                    await _update_bot_presence(st)
        except Exception as e:
            print("[Staff status-watch]", e)
        await asyncio.sleep(15)


async def post_changelog(
    title: str,
    notes: str,
    version: str = "",
    by: Optional[discord.abc.User] = None,
    automatic: bool = False,
) -> Optional[str]:
    channel = bot.get_channel(CHANGELOG_CHANNEL_ID)
    if channel is None:
        try:
            channel = await bot.fetch_channel(CHANGELOG_CHANNEL_ID)
        except Exception as e:
            return f"Cannot fetch changelog channel: {e}"
    if not isinstance(channel, discord.TextChannel):
        return "Changelog channel is not a text channel"

    embed = discord.Embed(
        title=title or "Update",
        description=notes or "_No notes_",
        color=0x5865F2,
        timestamp=datetime.now(timezone.utc),
    )
    if version:
        embed.add_field(name="Version", value=f"`{version}`", inline=True)
    who = str(by) if by else ("System" if automatic else "Staff")
    embed.add_field(name="By", value=who, inline=True)
    embed.set_footer(text="Executive Stand")
    try:
        await channel.send(embed=embed)
    except Exception as e:
        return f"Failed to post changelog: {e}"

    if supabase:
        try:
            supabase.table(CHANGELOG_TABLE).insert(
                {
                    "title": title or "Update",
                    "notes": notes or "",
                    "version": version or "",
                    "by": who,
                    "automatic": automatic,
                }
            ).execute()
        except Exception as e:
            print("changelog supabase error:", e)
    return None


# ── Ticket data persistence (Supabase stand_tickets, JSON file fallback) ─────
TICKETS_TABLE = "stand_tickets"


def _ticket_row_from_db(row: dict) -> dict:
    def _int(v):
        if v is None or v == "":
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return v

    return {
        "channel_id": _int(row.get("channel_id")),
        "opener_id": _int(row.get("opener_id")),
        "category": row.get("category") or "general",
        "number": int(row.get("number") or 0),
        "opened_at": row.get("opened_at") or "",
        "claimed_by": _int(row.get("claimed_by")),
        "claimed_at": row.get("claimed_at"),
        "closed": bool(row.get("closed")),
        "closed_by": _int(row.get("closed_by")),
        "closed_at": row.get("closed_at"),
        "guild_id": _int(row.get("guild_id")),
        "subject": row.get("subject") or "",
        "priority": row.get("priority") or "medium",
        "source": row.get("source") or "discord",
        "body": row.get("body") or "",
    }


def _load_tickets() -> dict:
    """Return {tickets: {channel_id: dict}, counters: {category: max_number}}."""
    out: dict = {"tickets": {}, "counters": {}}
    if supabase:
        try:
            res = supabase.table(TICKETS_TABLE).select("*").execute()
            for row in res.data or []:
                t = _ticket_row_from_db(row)
                out["tickets"][str(t["channel_id"])] = t
                cat = t.get("category") or "general"
                out["counters"][cat] = max(
                    int(out["counters"].get(cat, 0)), int(t.get("number") or 0)
                )
            return out
        except Exception as e:
            print("load tickets supabase error:", e)
    try:
        if TICKET_DATA_FILE.is_file():
            return json.loads(TICKET_DATA_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        print("load tickets file error:", e)
    return out


def _upsert_ticket_row(t: dict) -> None:
    if not supabase:
        return
    row = {
        "channel_id": str(t["channel_id"]),
        "opener_id": str(t["opener_id"]),
        "category": t.get("category") or "general",
        "number": int(t.get("number") or 0),
        "subject": t.get("subject") or "",
        "priority": t.get("priority") or "medium",
        "body": (t.get("body") or "")[:2000],
        "source": t.get("source") or "discord",
        "claimed_by": str(t["claimed_by"]) if t.get("claimed_by") else None,
        "claimed_at": t.get("claimed_at"),
        "closed": bool(t.get("closed")),
        "closed_by": str(t["closed_by"]) if t.get("closed_by") else None,
        "closed_at": t.get("closed_at"),
        "guild_id": str(t["guild_id"]) if t.get("guild_id") else None,
        "opened_at": t.get("opened_at") or datetime.now(timezone.utc).isoformat(),
    }
    supabase.table(TICKETS_TABLE).upsert(row).execute()


def _save_tickets(data: dict) -> None:
    """Persist full ticket map to Supabase (and JSON fallback)."""
    tickets = data.get("tickets") or {}
    if supabase:
        try:
            for t in tickets.values():
                _upsert_ticket_row(t)
        except Exception as e:
            print("save tickets supabase error:", e)
    try:
        TICKET_DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
        TICKET_DATA_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")
    except Exception as e:
        print("save tickets file error:", e)


TICKET_CATEGORIES = {
    "development": {
        "label": "Development",
        "description": "Report a bug",
        "emoji": "❓",
        "color": 0x5865F2,
    },
    "billing": {
        "label": "Billing",
        "description": "Report a billing issue, not receiving perks",
        "emoji": "💰",
        "color": 0xF1C40F,
    },
    "partnership": {
        "label": "Partnership",
        "description": "Apply to become an affiliate of Executive Stand",
        "emoji": "🔧",
        "color": 0x2ECC71,
    },
}


# ── Ticket UI ─────────────────────────────────────────────────────────────────
class TicketCloseView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(
        label="Close",
        style=discord.ButtonStyle.danger,
        emoji="🔒",
        custom_id="ticket:close",
    )
    async def close_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await close_ticket(interaction)

    @discord.ui.button(
        label="Claim",
        style=discord.ButtonStyle.primary,
        emoji="✋",
        custom_id="ticket:claim",
    )
    async def claim_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        if not isinstance(interaction.user, discord.Member) or not member_is_staff(interaction.user):
            await interaction.response.send_message("Only staff can claim tickets.", ephemeral=True)
            return
        data = _load_tickets()
        t = data.get("tickets", {}).get(str(interaction.channel_id))
        if not t:
            await interaction.response.send_message("This is not a tracked ticket.", ephemeral=True)
            return
        if t.get("claimed_by"):
            await interaction.response.send_message(
                f"Already claimed by <@{t['claimed_by']}>.", ephemeral=True
            )
            return
        t["claimed_by"] = interaction.user.id
        t["claimed_at"] = datetime.now(timezone.utc).isoformat()
        data["tickets"][str(interaction.channel_id)] = t
        _save_tickets(data)
        await interaction.response.send_message(
            f"✋ {interaction.user.mention} claimed this ticket."
        )
        try:
            await interaction.channel.send(
                embed=discord.Embed(
                    description=f"Ticket claimed by {interaction.user.mention}",
                    color=0x3498DB,
                )
            )
        except Exception:
            pass

    @discord.ui.button(
        label="Transcript",
        style=discord.ButtonStyle.secondary,
        emoji="📄",
        custom_id="ticket:transcript",
    )
    async def transcript_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        if not isinstance(interaction.user, discord.Member) or not member_is_staff(interaction.user):
            await interaction.response.send_message("Only staff can generate transcripts.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True)
        path_or_err = await generate_and_send_transcript(interaction.channel, interaction.user)
        if isinstance(path_or_err, str) and path_or_err.startswith("Error"):
            await interaction.followup.send(path_or_err, ephemeral=True)
        else:
            await interaction.followup.send("Transcript sent to the transcripts channel.", ephemeral=True)


class TicketSelect(discord.ui.Select):
    def __init__(self):
        options = []
        for key, meta in TICKET_CATEGORIES.items():
            options.append(
                discord.SelectOption(
                    label=meta["label"],
                    description=meta["description"][:100],
                    emoji=meta["emoji"],
                    value=key,
                )
            )
        super().__init__(
            placeholder="Select issue type...",
            min_values=1,
            max_values=1,
            options=options,
            custom_id="ticket:select",
        )

    async def callback(self, interaction: discord.Interaction):
        choice = self.values[0]
        meta = TICKET_CATEGORIES.get(choice)
        if not meta:
            await interaction.response.send_message("Invalid category.", ephemeral=True)
            return
        await create_ticket(interaction, choice, meta)


class TicketPanelView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)
        self.add_item(TicketSelect())


async def create_ticket(
    interaction: discord.Interaction,
    category_key: str,
    meta: dict,
):
    guild = interaction.guild
    if guild is None or not isinstance(interaction.user, discord.Member):
        await interaction.response.send_message("Guild only.", ephemeral=True)
        return

    data = _load_tickets()
    # Prevent multiple open tickets of same type per user
    for ch_id, t in list(data.get("tickets", {}).items()):
        if (
            t.get("opener_id") == interaction.user.id
            and t.get("category") == category_key
            and not t.get("closed")
        ):
            existing = guild.get_channel(int(ch_id))
            if existing:
                await interaction.response.send_message(
                    f"You already have an open **{meta['label']}** ticket: {existing.mention}",
                    ephemeral=True,
                )
                return

    await interaction.response.defer(ephemeral=True)

    counters = data.setdefault("counters", {})
    num = int(counters.get(category_key, 0)) + 1
    counters[category_key] = num
    slug = meta["label"].lower().replace(" ", "-")[:12]
    channel_name = f"{slug}-{num:04d}"

    overwrites = {
        guild.default_role: discord.PermissionOverwrite(view_channel=False),
        interaction.user: discord.PermissionOverwrite(
            view_channel=True,
            send_messages=True,
            read_message_history=True,
            attach_files=True,
            embed_links=True,
        ),
        guild.me: discord.PermissionOverwrite(
            view_channel=True,
            send_messages=True,
            manage_channels=True,
            manage_messages=True,
            read_message_history=True,
        ),
    }
    # Staff role can see
    if STAFF_ROLE_ID:
        role = guild.get_role(STAFF_ROLE_ID)
        if role:
            overwrites[role] = discord.PermissionOverwrite(
                view_channel=True,
                send_messages=True,
                read_message_history=True,
                manage_messages=True,
                attach_files=True,
            )

    category = None
    if TICKET_CATEGORY_ID:
        category = guild.get_channel(TICKET_CATEGORY_ID)
    if category is None and interaction.channel and isinstance(interaction.channel, discord.TextChannel):
        category = interaction.channel.category

    try:
        channel = await guild.create_text_channel(
            name=channel_name,
            overwrites=overwrites,
            category=category if isinstance(category, discord.CategoryChannel) else None,
            topic=f"Ticket #{num} | {meta['label']} | opener:{interaction.user.id}",
            reason=f"Ticket opened by {interaction.user}",
        )
    except Exception as e:
        await interaction.followup.send(f"Failed to create ticket: {e}", ephemeral=True)
        return

    data.setdefault("tickets", {})[str(channel.id)] = {
        "channel_id": channel.id,
        "opener_id": interaction.user.id,
        "category": category_key,
        "number": num,
        "opened_at": datetime.now(timezone.utc).isoformat(),
        "claimed_by": None,
        "closed": False,
        "guild_id": guild.id,
    }
    _save_tickets(data)

    embed = discord.Embed(
        title=f"{meta['emoji']} {meta['label']} Ticket",
        description=(
            f"Thanks for contacting support, {interaction.user.mention}.\n\n"
            f"**Category:** {meta['label']}\n"
            f"**Issue:** {meta['description']}\n\n"
            "Please describe your issue in detail. A staff member will assist you shortly.\n"
            "Use the buttons below to **Close**, **Claim**, or generate a **Transcript**."
        ),
        color=meta.get("color", 0x5865F2),
        timestamp=datetime.now(timezone.utc),
    )
    embed.set_footer(text=f"Ticket #{num:04d} • Executive Stand")
    await channel.send(
        content=f"{interaction.user.mention}"
        + (f" | <@&{STAFF_ROLE_ID}>" if STAFF_ROLE_ID else ""),
        embed=embed,
        view=TicketCloseView(),
    )
    await interaction.followup.send(
        f"Your ticket has been created: {channel.mention}",
        ephemeral=True,
    )


async def generate_and_send_transcript(
    channel: discord.abc.Messageable,
    requester: discord.abc.User,
) -> str:
    if not isinstance(channel, discord.TextChannel):
        return "Error: not a text channel"

    lines: list[str] = []
    lines.append(f"Transcript of #{channel.name} ({channel.id})")
    lines.append(f"Generated by {requester} ({requester.id}) at {datetime.now(timezone.utc).isoformat()}")
    lines.append("=" * 60)

    try:
        async for msg in channel.history(limit=500, oldest_first=True):
            ts = msg.created_at.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            author = f"{msg.author} ({msg.author.id})"
            content = msg.content or ""
            if msg.embeds:
                content += " [embed]"
            if msg.attachments:
                content += " " + " ".join(a.url for a in msg.attachments)
            lines.append(f"[{ts}] {author}: {content}")
    except Exception as e:
        return f"Error reading history: {e}"

    text = "\n".join(lines)
    file = discord.File(
        io.BytesIO(text.encode("utf-8")),
        filename=f"transcript-{channel.name}-{channel.id}.txt",
    )

    dest = bot.get_channel(TRANSCRIPT_CHANNEL_ID)
    if dest is None:
        try:
            dest = await bot.fetch_channel(TRANSCRIPT_CHANNEL_ID)
        except Exception as e:
            return f"Error fetching transcript channel: {e}"

    data = _load_tickets()
    t = data.get("tickets", {}).get(str(channel.id), {})
    embed = discord.Embed(
        title="📄 Ticket Transcript",
        color=0x95A5A6,
        timestamp=datetime.now(timezone.utc),
    )
    embed.add_field(name="Channel", value=f"#{channel.name} (`{channel.id}`)", inline=False)
    if t:
        embed.add_field(name="Opener", value=f"<@{t.get('opener_id')}>", inline=True)
        embed.add_field(name="Category", value=str(t.get("category", "—")), inline=True)
        if t.get("claimed_by"):
            embed.add_field(name="Claimed by", value=f"<@{t['claimed_by']}>", inline=True)
    embed.add_field(name="Requested by", value=str(requester), inline=True)
    embed.set_footer(text="Executive Stand")

    try:
        await dest.send(embed=embed, file=file)
    except Exception as e:
        return f"Error sending transcript: {e}"
    return "ok"


async def close_ticket(interaction: discord.Interaction):
    channel = interaction.channel
    if not isinstance(channel, discord.TextChannel):
        await interaction.response.send_message("Not a ticket channel.", ephemeral=True)
        return

    data = _load_tickets()
    t = data.get("tickets", {}).get(str(channel.id))
    is_opener = t and t.get("opener_id") == interaction.user.id
    is_staff = isinstance(interaction.user, discord.Member) and member_is_staff(interaction.user)
    if not is_opener and not is_staff:
        await interaction.response.send_message(
            "Only the ticket opener or staff can close this.",
            ephemeral=True,
        )
        return

    await interaction.response.send_message("Closing ticket in 5 seconds… generating transcript.")

    # Transcript first
    await generate_and_send_transcript(channel, interaction.user)

    if t:
        t["closed"] = True
        t["closed_by"] = interaction.user.id
        t["closed_at"] = datetime.now(timezone.utc).isoformat()
        data["tickets"][str(channel.id)] = t
        _save_tickets(data)

    await asyncio.sleep(5)
    try:
        await channel.delete(reason=f"Ticket closed by {interaction.user}")
    except Exception as e:
        try:
            await channel.send(f"Failed to delete channel: {e}")
        except Exception:
            pass


# ── Verification ──────────────────────────────────────────────────────────────
class VerifyView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(
        label="Verify",
        style=discord.ButtonStyle.success,
        emoji="✅",
        custom_id="verify:button",
    )
    async def verify_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        if not isinstance(interaction.user, discord.Member):
            await interaction.response.send_message("Members only.", ephemeral=True)
            return
        member = interaction.user
        guild = interaction.guild
        if guild is None:
            await interaction.response.send_message("Guild only.", ephemeral=True)
            return

        verified = guild.get_role(VERIFY_ROLE_ID)
        member_role = guild.get_role(MEMBER_ROLE_ID)
        unverified = guild.get_role(UNVERIFIED_ROLE_ID)

        to_add = [r for r in (verified, member_role) if r and r not in member.roles]
        to_remove = [unverified] if unverified and unverified in member.roles else []

        try:
            if to_add:
                await member.add_roles(*to_add, reason="User verified")
            if to_remove:
                await member.remove_roles(*to_remove, reason="User verified")
        except Exception as e:
            await interaction.response.send_message(f"Failed to update roles: {e}", ephemeral=True)
            return

        # Log identity to Supabase immediately (tokens come after OAuth)
        log_verified_member(member)

        # Build the OAuth2 URL so we can silently restore them if the server is raided
        oauth_configured = bool(DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET and OAUTH_REDIRECT_URI)
        if oauth_configured:
            oauth_url = build_oauth_url(state=str(member.id))
            await interaction.response.send_message(
                "✅ **Verified!** Welcome to Executive Stand.\n\n"
                "**One more step — click below to enable auto-restore:**\n"
                f"{oauth_url}\n\n"
                "This lets the bot silently add you back if the server is ever raided or wiped. "
                "It only requests `identify` and `guilds.join` — nothing else.",
                ephemeral=True,
            )
        else:
            await interaction.response.send_message(
                "You have been **verified**! Welcome to the server.",
                ephemeral=True,
            )


# ── Events ────────────────────────────────────────────────────────────────────
@bot.event
async def on_ready():
    bot.add_view(TicketPanelView())
    bot.add_view(TicketCloseView())
    bot.add_view(VerifyView())
    try:
        synced = await bot.tree.sync()
        print(f"[Staff] Synced {len(synced)} commands")
    except Exception as e:
        print("[Staff] Sync error:", e)
    print(f"[Staff] Logged in as {bot.user}")
    print(f"[Staff] Status channel: {STATUS_CHANNEL_ID} | label: {STATUS_CHANNEL_LABEL}")
    print(f"[Staff] Transcripts: {TRANSCRIPT_CHANNEL_ID}")
    print(f"[Staff] Verify={VERIFY_ROLE_ID} Unverified={UNVERIFIED_ROLE_ID} Member={MEMBER_ROLE_ID}")
    # Refresh status channel name from persisted state (don't re-notify user bot on boot)
    try:
        await update_status_channel(
            get_system_status(),
            note=_status_note or f"Staff bot online — status `{get_system_status()}`",
            announce=False,
            notify_user_bot=False,
        )
    except Exception as e:
        print("[Staff] on_ready status error:", e)
    # Set bot activity to reflect current system status
    await _update_bot_presence()
    try:
        bot.loop.create_task(status_watch_loop())
    except Exception as e:
        print("[Staff] status_watch_loop start error:", e)


@bot.event
async def on_member_join(member: discord.Member):
    """Auto-assign unverified role to new members."""
    if member.bot:
        return
    role = member.guild.get_role(UNVERIFIED_ROLE_ID)
    if role is None:
        return
    try:
        await member.add_roles(role, reason="Auto-role: unverified on join")
    except Exception as e:
        print(f"on_member_join role error for {member.id}:", e)


@bot.event
async def on_member_remove(member: discord.Member):
    """Mark verified members as left so restore knows who is missing."""
    if member.bot:
        return
    mark_member_left(member)


# ── Staff: Stand commands ─────────────────────────────────────────────────────
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
    embed = discord.Embed(title=f"Config — {user}", color=0x5865F2)
    embed.add_field(name="Owner", value=f"`{cfg.get('owner') or '—'}`", inline=True)
    embed.add_field(name="Rank", value=f"`{cfg.get('rank') or 'free'}`", inline=True)
    embed.add_field(name="Blacklisted", value=str(is_blacklisted(user.id)), inline=True)
    alts = cfg.get("alts") or {}
    if isinstance(alts, dict) and alts:
        lines = [f"`{name}` → slot {slot}" for name, slot in alts.items()]
        embed.add_field(name="Alts", value="\n".join(lines)[:1024], inline=False)
    else:
        embed.add_field(name="Alts", value="_none_", inline=False)
    controllers = cfg.get("controllers") or []
    embed.add_field(
        name="Controllers",
        value=", ".join(f"`{c}`" for c in controllers) if controllers else "_none_",
        inline=False,
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


@bot.tree.command(name="setrank", description="[Staff] Set buyer rank: free / premium / bypass")
@app_commands.describe(user="Discord user", rank="Rank to set")
@app_commands.choices(
    rank=[
        app_commands.Choice(name="free", value="free"),
        app_commands.Choice(name="premium", value="premium"),
        app_commands.Choice(name="bypass", value="bypass"),
    ]
)
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
        f"Set rank of **{user}** to `{rank.value}`.",
        ephemeral=True,
    )


@bot.tree.command(name="addstock", description="[Staff] Add License Hub keys to Roblox shop stock")
@app_commands.describe(
    product="Which product these keys belong to",
    keys="Keys separated by commas, spaces, or new lines (paste from License Hub)",
)
@app_commands.choices(product=[
    app_commands.Choice(name="Executive Stand", value="stand"),
    app_commands.Choice(name="Premium Commands", value="premium"),
    app_commands.Choice(name="Shield Bypass", value="shield"),
])
async def addstock(
    interaction: discord.Interaction,
    product: app_commands.Choice[str],
    keys: str,
):
    """Bulk-load keys generated on License Hub into the Roblox shop stock."""
    if not await staff_check(interaction):
        return
    if not supabase:
        return await interaction.response.send_message("Database unavailable.", ephemeral=True)

    raw = re.split(r"[\s,;]+", keys.strip())
    cleaned = [k.strip().upper() for k in raw if k.strip()]
    seen = set()
    unique = []
    for k in cleaned:
        if k not in seen:
            seen.add(k)
            unique.append(k)

    if not unique:
        return await interaction.response.send_message("No keys found in input.", ephemeral=True)

    await interaction.response.defer(ephemeral=True)
    prod = product.value
    added = 0
    skipped = 0
    for k in unique:
        try:
            supabase.table(KEY_STOCK_TABLE).upsert(
                {"key": k, "product": prod, "reserved": False},
                on_conflict="key",
            ).execute()
            added += 1
        except Exception as e:
            print(f"[addstock] skip {k}: {e}")
            skipped += 1

    label = {
        "stand": "Executive Stand",
        "premium": "Premium Commands",
        "shield": "Shield Bypass",
    }.get(prod, prod)

    await interaction.followup.send(
        f"Stocked **{added}** `{label}` key(s) from License Hub"
        + (f" ({skipped} skipped)" if skipped else "")
        + ".\nPlayers who buy the GamePass will receive these automatically.\n"
        + "In-game shop shows counts only — keys appear after purchase.",
        ephemeral=True,
    )


@bot.tree.command(name="stock", description="[Staff] Check how many License Hub keys are left in Roblox shop stock")
async def stock_cmd(interaction: discord.Interaction):
    if not await staff_check(interaction):
        return
    if not supabase:
        return await interaction.response.send_message("Database unavailable.", ephemeral=True)
    await interaction.response.defer(ephemeral=True)
    labels = {
        "stand": "Executive Stand",
        "premium": "Premium Commands",
        "shield": "Shield Bypass",
    }
    lines = []
    for p, label in labels.items():
        try:
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
            lines.append(f"**{label}**: `{count}` available")
        except Exception as e:
            lines.append(f"**{label}**: error `{e}`")
    await interaction.followup.send(
        "**Roblox key stock**\n" + "\n".join(lines)
        + "\n\nAdd more with `/addstock`.",
        ephemeral=True,
    )


@bot.tree.command(
    name="status",
    description="[Staff] Set maintenance / system status (updates status channel dot)",
)
@app_commands.describe(
    state="up | down | updating | detected",
    note="Optional message posted in the status channel",
)
@app_commands.choices(
    state=[
        app_commands.Choice(name="🟢 Online (up)", value="up"),
        app_commands.Choice(name="🔴 Down / Maintenance", value="down"),
        app_commands.Choice(name="🔵 Updating", value="updating"),
        app_commands.Choice(name="🟡 Detected", value="detected"),
    ]
)
async def status_cmd(
    interaction: discord.Interaction,
    state: app_commands.Choice[str],
    note: Optional[str] = None,
):
    if not await staff_check(interaction):
        return
    await interaction.response.defer(ephemeral=True)
    err = await update_status_channel(
        state.value,
        note=note or "",
        by=interaction.user,
        announce=True,
    )
    if err:
        await interaction.followup.send(f"Status update issue: {err}", ephemeral=True)
    else:
        await interaction.followup.send(
            f"Status set to **{STATUS_DOTS.get(state.value)} {STATUS_LABELS.get(state.value)}** "
            f"(channel → `{_status_channel_name(state.value)}`).",
            ephemeral=True,
        )


@bot.tree.command(
    name="changelog",
    description="[Staff] Post a changelog entry",
)
@app_commands.describe(
    title="Changelog title",
    notes="What changed",
    version="Optional version tag",
    set_updating="If true, set status to 🔵 Updating first",
    set_up_after="If true, set status to 🟢 Up after posting",
)
async def changelog_cmd(
    interaction: discord.Interaction,
    title: str,
    notes: str,
    version: Optional[str] = None,
    set_updating: Optional[bool] = False,
    set_up_after: Optional[bool] = True,
):
    if not await staff_check(interaction):
        return
    await interaction.response.defer(ephemeral=True)

    if set_updating:
        await update_status_channel(
            "updating",
            note=f"Deploying: {title}",
            by=interaction.user,
            announce=True,
        )

    err = await post_changelog(
        title=title,
        notes=notes,
        version=version or "",
        by=interaction.user,
    )
    if err:
        await interaction.followup.send(f"Changelog failed: {err}", ephemeral=True)
        return

    if set_up_after:
        await update_status_channel(
            "up",
            note=f"Update live: {title}",
            by=interaction.user,
            announce=True,
        )

    await interaction.followup.send(
        f"Changelog posted in <#{CHANGELOG_CHANNEL_ID}>.\n"
        f"Title: **{title}**"
        + (f" (`{version}`)" if version else ""),
        ephemeral=True,
    )


# ── Moderation commands ───────────────────────────────────────────────────────
@bot.tree.command(name="ban", description="[Staff] Ban a member")
@app_commands.describe(member="Member to ban", reason="Reason", delete_days="Delete message history (0-7 days)")
async def ban_cmd(
    interaction: discord.Interaction,
    member: discord.Member,
    reason: str = "No reason provided",
    delete_days: app_commands.Range[int, 0, 7] = 0,
):
    if not await staff_check(interaction):
        return
    if member.id == interaction.user.id:
        await interaction.response.send_message("You can't ban yourself.", ephemeral=True)
        return
    if member.top_role >= interaction.user.top_role and interaction.guild.owner_id != interaction.user.id:
        await interaction.response.send_message("You can't ban someone with equal/higher role.", ephemeral=True)
        return
    try:
        await member.ban(reason=f"{interaction.user}: {reason}", delete_message_days=delete_days)
        await interaction.response.send_message(
            f"🔨 Banned **{member}** (`{member.id}`)\nReason: {reason}",
            ephemeral=True,
        )
    except Exception as e:
        await interaction.response.send_message(f"Ban failed: {e}", ephemeral=True)


@bot.tree.command(name="unban", description="[Staff] Unban a user by ID")
@app_commands.describe(user_id="Discord user ID to unban", reason="Reason")
async def unban_cmd(
    interaction: discord.Interaction,
    user_id: str,
    reason: str = "No reason provided",
):
    if not await staff_check(interaction):
        return
    try:
        uid = int(user_id.strip())
        user = await bot.fetch_user(uid)
        await interaction.guild.unban(user, reason=f"{interaction.user}: {reason}")
        await interaction.response.send_message(
            f"Unbanned **{user}** (`{uid}`).",
            ephemeral=True,
        )
    except Exception as e:
        await interaction.response.send_message(f"Unban failed: {e}", ephemeral=True)


@bot.tree.command(name="kick", description="[Staff] Kick a member")
@app_commands.describe(member="Member to kick", reason="Reason")
async def kick_cmd(
    interaction: discord.Interaction,
    member: discord.Member,
    reason: str = "No reason provided",
):
    if not await staff_check(interaction):
        return
    if member.id == interaction.user.id:
        await interaction.response.send_message("You can't kick yourself.", ephemeral=True)
        return
    try:
        await member.kick(reason=f"{interaction.user}: {reason}")
        await interaction.response.send_message(
            f"👢 Kicked **{member}** (`{member.id}`)\nReason: {reason}",
            ephemeral=True,
        )
    except Exception as e:
        await interaction.response.send_message(f"Kick failed: {e}", ephemeral=True)


@bot.tree.command(name="timeout", description="[Staff] Timeout (mute) a member")
@app_commands.describe(
    member="Member to timeout",
    minutes="Duration in minutes (1–40320)",
    reason="Reason",
)
async def timeout_cmd(
    interaction: discord.Interaction,
    member: discord.Member,
    minutes: app_commands.Range[int, 1, 40320],
    reason: str = "No reason provided",
):
    if not await staff_check(interaction):
        return
    until = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    try:
        await member.timeout(until, reason=f"{interaction.user}: {reason}")
        await interaction.response.send_message(
            f"⏱️ Timed out **{member}** for **{minutes}** minute(s).\nReason: {reason}",
            ephemeral=True,
        )
    except Exception as e:
        await interaction.response.send_message(f"Timeout failed: {e}", ephemeral=True)


@bot.tree.command(name="untimeout", description="[Staff] Remove timeout from a member")
@app_commands.describe(member="Member to remove timeout from")
async def untimeout_cmd(interaction: discord.Interaction, member: discord.Member):
    if not await staff_check(interaction):
        return
    try:
        await member.timeout(None, reason=f"Timeout removed by {interaction.user}")
        await interaction.response.send_message(
            f"Removed timeout from **{member}**.",
            ephemeral=True,
        )
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


@bot.tree.command(name="purge", description="[Staff] Bulk delete messages")
@app_commands.describe(amount="Number of messages to delete (1–100)", user="Optional: only delete from this user")
async def purge_cmd(
    interaction: discord.Interaction,
    amount: app_commands.Range[int, 1, 100],
    user: Optional[discord.User] = None,
):
    if not await staff_check(interaction):
        return
    await interaction.response.defer(ephemeral=True)

    def check(m: discord.Message) -> bool:
        if user is None:
            return True
        return m.author.id == user.id

    try:
        deleted = await interaction.channel.purge(limit=amount, check=check)
        await interaction.followup.send(
            f"🗑️ Deleted **{len(deleted)}** message(s)."
            + (f" (from {user})" if user else ""),
            ephemeral=True,
        )
    except Exception as e:
        await interaction.followup.send(f"Purge failed: {e}", ephemeral=True)


@bot.tree.command(name="lock", description="[Staff] Lock a channel (deny @everyone send)")
@app_commands.describe(channel="Channel to lock (defaults to current)")
async def lock_cmd(
    interaction: discord.Interaction,
    channel: Optional[discord.TextChannel] = None,
):
    if not await staff_check(interaction):
        return
    ch = channel or interaction.channel
    if not isinstance(ch, discord.TextChannel):
        await interaction.response.send_message("Text channels only.", ephemeral=True)
        return
    overwrite = ch.overwrites_for(interaction.guild.default_role)
    overwrite.send_messages = False
    try:
        await ch.set_permissions(interaction.guild.default_role, overwrite=overwrite, reason=f"Locked by {interaction.user}")
        await interaction.response.send_message(f"🔒 Locked {ch.mention}.", ephemeral=True)
    except Exception as e:
        await interaction.response.send_message(f"Lock failed: {e}", ephemeral=True)


@bot.tree.command(name="unlock", description="[Staff] Unlock a channel")
@app_commands.describe(channel="Channel to unlock (defaults to current)")
async def unlock_cmd(
    interaction: discord.Interaction,
    channel: Optional[discord.TextChannel] = None,
):
    if not await staff_check(interaction):
        return
    ch = channel or interaction.channel
    if not isinstance(ch, discord.TextChannel):
        await interaction.response.send_message("Text channels only.", ephemeral=True)
        return
    overwrite = ch.overwrites_for(interaction.guild.default_role)
    overwrite.send_messages = None
    try:
        await ch.set_permissions(interaction.guild.default_role, overwrite=overwrite, reason=f"Unlocked by {interaction.user}")
        await interaction.response.send_message(f"🔓 Unlocked {ch.mention}.", ephemeral=True)
    except Exception as e:
        await interaction.response.send_message(f"Unlock failed: {e}", ephemeral=True)


@bot.tree.command(name="slowmode", description="[Staff] Set channel slowmode")
@app_commands.describe(seconds="Slowmode delay in seconds (0 to disable)", channel="Channel (defaults to current)")
async def slowmode_cmd(
    interaction: discord.Interaction,
    seconds: app_commands.Range[int, 0, 21600],
    channel: Optional[discord.TextChannel] = None,
):
    if not await staff_check(interaction):
        return
    ch = channel or interaction.channel
    if not isinstance(ch, discord.TextChannel):
        await interaction.response.send_message("Text channels only.", ephemeral=True)
        return
    try:
        await ch.edit(slowmode_delay=seconds, reason=f"Slowmode by {interaction.user}")
        msg = "Slowmode disabled." if seconds == 0 else f"Slowmode set to **{seconds}s**."
        await interaction.response.send_message(f"🐢 {msg} ({ch.mention})", ephemeral=True)
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


@bot.tree.command(name="nick", description="[Staff] Change a member's nickname")
@app_commands.describe(member="Member", nickname="New nickname (empty to reset)")
async def nick_cmd(
    interaction: discord.Interaction,
    member: discord.Member,
    nickname: Optional[str] = None,
):
    if not await staff_check(interaction):
        return
    try:
        await member.edit(nick=nickname or None, reason=f"Nickname by {interaction.user}")
        await interaction.response.send_message(
            f"Nickname for **{member}** set to `{nickname or '(reset)'}`.",
            ephemeral=True,
        )
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


@bot.tree.command(name="role", description="[Staff] Add or remove a role from a member")
@app_commands.describe(member="Member", role="Role", action="add or remove")
@app_commands.choices(
    action=[
        app_commands.Choice(name="add", value="add"),
        app_commands.Choice(name="remove", value="remove"),
    ]
)
async def role_cmd(
    interaction: discord.Interaction,
    member: discord.Member,
    role: discord.Role,
    action: app_commands.Choice[str],
):
    if not await staff_check(interaction):
        return
    try:
        if action.value == "add":
            await member.add_roles(role, reason=f"Role add by {interaction.user}")
            await interaction.response.send_message(
                f"Added {role.mention} to **{member}**.", ephemeral=True
            )
        else:
            await member.remove_roles(role, reason=f"Role remove by {interaction.user}")
            await interaction.response.send_message(
                f"Removed {role.mention} from **{member}**.", ephemeral=True
            )
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


# ── Ticket commands ───────────────────────────────────────────────────────────
@bot.tree.command(name="ticketpanel", description="[Staff] Post the ticket panel (dropdown menu)")
async def ticketpanel_cmd(interaction: discord.Interaction):
    if not await staff_check(interaction):
        return
    embed = discord.Embed(
        title="🎫 Support Tickets",
        description=(
            "Need help? Select an issue type from the dropdown below to open a private ticket.\n\n"
            "**Categories**\n"
            "❓ **Development** — Report a bug\n"
            "💰 **Billing** — Report a billing issue, not receiving perks\n"
            "🔧 **Partnership** — Apply to become an affiliate of Executive Stand\n\n"
            "A staff member will respond as soon as possible."
        ),
        color=0x2B2D31,
    )
    embed.set_footer(text="Executive Stand • Select an option below")
    await interaction.response.send_message("Panel posted.", ephemeral=True)
    await interaction.channel.send(embed=embed, view=TicketPanelView())


@bot.tree.command(name="ticketadd", description="[Staff] Add a user to this ticket")
@app_commands.describe(user="User to add")
async def ticketadd_cmd(interaction: discord.Interaction, user: discord.Member):
    if not await staff_check(interaction):
        return
    data = _load_tickets()
    if str(interaction.channel_id) not in data.get("tickets", {}):
        await interaction.response.send_message("This is not a tracked ticket channel.", ephemeral=True)
        return
    ch = interaction.channel
    if not isinstance(ch, discord.TextChannel):
        await interaction.response.send_message("Text channel only.", ephemeral=True)
        return
    try:
        await ch.set_permissions(
            user,
            view_channel=True,
            send_messages=True,
            read_message_history=True,
            attach_files=True,
            reason=f"Added to ticket by {interaction.user}",
        )
        await interaction.response.send_message(f"Added {user.mention} to this ticket.")
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


@bot.tree.command(name="ticketremove", description="[Staff] Remove a user from this ticket")
@app_commands.describe(user="User to remove")
async def ticketremove_cmd(interaction: discord.Interaction, user: discord.Member):
    if not await staff_check(interaction):
        return
    data = _load_tickets()
    if str(interaction.channel_id) not in data.get("tickets", {}):
        await interaction.response.send_message("This is not a tracked ticket channel.", ephemeral=True)
        return
    ch = interaction.channel
    if not isinstance(ch, discord.TextChannel):
        await interaction.response.send_message("Text channel only.", ephemeral=True)
        return
    try:
        await ch.set_permissions(user, overwrite=None, reason=f"Removed from ticket by {interaction.user}")
        await interaction.response.send_message(f"Removed {user.mention} from this ticket.")
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


@bot.tree.command(name="ticketclose", description="[Staff] Close this ticket")
async def ticketclose_cmd(interaction: discord.Interaction):
    if not await staff_check(interaction):
        return
    await close_ticket(interaction)


@bot.tree.command(name="ticketrename", description="[Staff] Rename this ticket channel")
@app_commands.describe(name="New channel name")
async def ticketrename_cmd(interaction: discord.Interaction, name: str):
    if not await staff_check(interaction):
        return
    data = _load_tickets()
    if str(interaction.channel_id) not in data.get("tickets", {}):
        await interaction.response.send_message("This is not a tracked ticket channel.", ephemeral=True)
        return
    ch = interaction.channel
    if not isinstance(ch, discord.TextChannel):
        await interaction.response.send_message("Text channel only.", ephemeral=True)
        return
    clean = re.sub(r"[^a-z0-9\-]", "", name.lower().replace(" ", "-"))[:90]
    if not clean:
        await interaction.response.send_message("Invalid name.", ephemeral=True)
        return
    try:
        await ch.edit(name=clean, reason=f"Renamed by {interaction.user}")
        await interaction.response.send_message(f"Renamed to `{clean}`.", ephemeral=True)
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)


# ── Verification setup ────────────────────────────────────────────────────────
@bot.tree.command(name="verifypanel", description="[Staff] Post the verification panel")
async def verifypanel_cmd(interaction: discord.Interaction):
    if not await staff_check(interaction):
        return
    embed = discord.Embed(
        title="Verification",
        description=(
            "Welcome to **Executive Stand**!\n\n"
            "Click the **Verify** button below to unlock the server.\n"
            "You will receive the verified and member roles."
        ),
        color=0x2ECC71,
    )
    embed.set_footer(text="Executive Stand")
    await interaction.response.send_message("Verification panel posted.", ephemeral=True)
    await interaction.channel.send(embed=embed, view=VerifyView())


@bot.tree.command(name="rules", description="[Staff] Post the server rules panel")
@app_commands.describe(channel="Channel to post rules in (defaults to current)")
async def rules_cmd(
    interaction: discord.Interaction,
    channel: Optional[discord.TextChannel] = None,
):
    if not await staff_check(interaction):
        return
    target = channel or interaction.channel
    if not isinstance(target, discord.TextChannel):
        await interaction.response.send_message("Text channels only.", ephemeral=True)
        return

    embed = discord.Embed(
        title="📜 Executive Stand — Server Rules",
        description=(
            "Welcome to **Executive Stand**. By staying in this server you agree to these rules.\n\n"
            "**Community**\n"
            "• Be respectful — no harassment, hate, or toxicity\n"
            "• No spam, mass pings, or unsolicited ads\n"
            "• Keep chat clean — no NSFW or illegal content\n\n"
            "**Product & support**\n"
            "• Do not leak, resell, or share loaders, keys, or configs\n"
            "• No scams or abusive chargebacks\n"
            "• Use the ticket panel for bugs, billing, and partnerships\n\n"
            "**Access**\n"
            "• Verify to unlock channels\n"
            "• Don't mini-mod; contact staff instead\n\n"
            "**Enforcement**\n"
            "• Staff decisions are final\n"
            "• Punishments: warn → timeout → kick → ban / blacklist\n"
            "• Follow Discord ToS at all times"
        ),
        color=0x5865F2,
    )
    embed.add_field(
        name="Support tickets",
        value=(
            "❓ **Development** — Report a bug\n"
            "💰 **Billing** — Payments / missing perks\n"
            "🔧 **Partnership** — Affiliate applications"
        ),
        inline=False,
    )
    embed.set_footer(text="Executive Stand • Breaking rules may result in a product blacklist")
    await interaction.response.send_message(
        f"Rules posted in {target.mention}.",
        ephemeral=True,
    )
    await target.send(embed=embed)


@bot.tree.command(name="announce", description="[Staff] Send an announcement embed to a channel")
@app_commands.describe(
    channel="Channel to send the announcement in",
    message="Announcement text",
    title="Optional embed title",
    ping="Optional role to ping",
    image_url="Optional image URL for the embed",
)
async def announce_cmd(
    interaction: discord.Interaction,
    channel: discord.TextChannel,
    message: str,
    title: Optional[str] = None,
    ping: Optional[discord.Role] = None,
    image_url: Optional[str] = None,
):
    if not await staff_check(interaction):
        return

    member = interaction.user
    is_admin = isinstance(member, discord.Member) and member.guild_permissions.administrator
    lowered = message.lower()
    if not is_admin and ("@everyone" in lowered or "@here" in lowered):
        await interaction.response.send_message(
            "Only administrators can include @everyone / @here in announcements.",
            ephemeral=True,
        )
        return

    embed = discord.Embed(
        title=title or "📢 Announcement",
        description=message,
        color=0x5865F2,
        timestamp=datetime.now(timezone.utc),
    )
    embed.set_footer(text=f"Executive Stand • Posted by {interaction.user}")
    if image_url:
        try:
            embed.set_image(url=image_url)
        except Exception:
            pass

    content = ping.mention if ping else None
    try:
        await channel.send(content=content, embed=embed)
    except Exception as e:
        await interaction.response.send_message(f"Failed to send: {e}", ephemeral=True)
        return

    await interaction.response.send_message(
        f"Announcement sent to {channel.mention}.",
        ephemeral=True,
    )


@bot.tree.command(name="say", description="[Staff] Send a plain message (no embed) to a channel")
@app_commands.describe(
    channel="Channel to send in",
    message="Message text",
)
async def say_cmd(
    interaction: discord.Interaction,
    channel: discord.TextChannel,
    message: str,
):
    if not await staff_check(interaction):
        return
    if not isinstance(interaction.user, discord.Member) or not interaction.user.guild_permissions.administrator:
        if "@everyone" in message.lower() or "@here" in message.lower():
            await interaction.response.send_message(
                "Only administrators can include @everyone / @here.",
                ephemeral=True,
            )
            return
    try:
        await channel.send(message)
    except Exception as e:
        await interaction.response.send_message(f"Failed: {e}", ephemeral=True)
        return
    await interaction.response.send_message(
        f"Message sent to {channel.mention}.",
        ephemeral=True,
    )


# ── Restore command ───────────────────────────────────────────────────────────
@bot.tree.command(
    name="restoremembers",
    description="[Staff] Silently re-add all verified members who left (requires OAuth2 setup)",
)
async def restoremembers_cmd(interaction: discord.Interaction):
    if not await staff_check(interaction):
        return
    if not supabase:
        await interaction.response.send_message("Database unavailable.", ephemeral=True)
        return
    if not GUILD_ID:
        await interaction.response.send_message(
            "GUILD_ID env var is not set.", ephemeral=True
        )
        return

    await interaction.response.defer(ephemeral=True)

    # Fetch all members who left and have an OAuth token
    try:
        res = (
            supabase.table(MEMBERS_TABLE)
            .select("id, username, access_token, refresh_token, token_expires_at")
            .eq("in_server", False)
            .eq("guild_id", GUILD_ID)
            .execute()
        )
        rows = res.data or []
    except Exception as e:
        await interaction.followup.send(f"DB error: {e}", ephemeral=True)
        return

    if not rows:
        await interaction.followup.send(
            "No missing members found in the database.", ephemeral=True
        )
        return

    added = 0
    already = 0
    refreshed = 0
    no_token = 0
    failed: list[str] = []

    for row in rows:
        user_id = int(row["id"])
        username = row.get("username") or str(user_id)
        access_token = row.get("access_token") or ""
        refresh_token = row.get("refresh_token") or ""
        token_expires_at = row.get("token_expires_at") or ""

        if not access_token:
            no_token += 1
            continue

        # Refresh token if expired or expiring within 60 seconds
        if token_expires_at:
            try:
                exp = datetime.fromisoformat(token_expires_at.replace("Z", "+00:00"))
                if exp <= datetime.now(timezone.utc) + timedelta(seconds=60):
                    if refresh_token:
                        new_tokens = await refresh_access_token(refresh_token)
                        if new_tokens:
                            access_token = new_tokens["access_token"]
                            save_oauth_tokens(
                                user_id,
                                access_token,
                                new_tokens.get("refresh_token", refresh_token),
                                int(new_tokens.get("expires_in", 604800)),
                            )
                            refreshed += 1
                        else:
                            failed.append(f"`{username}` (token refresh failed)")
                            continue
            except Exception as e:
                print(f"token expiry check error for {user_id}:", e)

        ok, msg = await add_member_to_guild(user_id, access_token)
        if ok:
            if msg == "already_member":
                already += 1
                # They're back in — mark them in_server
                try:
                    supabase.table(MEMBERS_TABLE).update(
                        {"in_server": True, "left_at": None}
                    ).eq("id", user_id).execute()
                except Exception:
                    pass
            else:
                added += 1
                try:
                    supabase.table(MEMBERS_TABLE).update(
                        {"in_server": True, "left_at": None}
                    ).eq("id", user_id).execute()
                except Exception:
                    pass
        else:
            failed.append(f"`{username}` ({msg})")

        # Small delay to avoid hitting the Discord rate limit
        await asyncio.sleep(0.5)

    lines = [
        f"**Restore complete** — {len(rows)} member(s) processed",
        f"✅ Silently re-added: **{added}**",
        f"🔁 Already in server: **{already}**",
        f"🔑 Token refreshed mid-restore: **{refreshed}**",
        f"⚠️ No OAuth token (never authorized): **{no_token}**",
    ]
    if failed:
        lines.append(f"❌ Failed ({len(failed)}): " + ", ".join(failed[:10]))
        if len(failed) > 10:
            lines.append(f"  _… and {len(failed) - 10} more_")
    if no_token:
        lines.append(
            f"\n_{no_token} member(s) never completed the OAuth step — "
            "they will need to re-verify to register their token._"
        )

    await interaction.followup.send("\n".join(lines), ephemeral=True)


# ── OAuth2 + HTTP server ───────────────────────────────────────────────────────
async def _start_http():
    from aiohttp import web

    # ── HTML helpers ──────────────────────────────────────────────────────────
    def _page(title: str, body: str, color: str = "#57F287") -> web.Response:
        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{title} — Executive Stand</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{background:#1e1f22;color:#e3e5e8;font-family:'Segoe UI',sans-serif;
         display:flex;align-items:center;justify-content:center;min-height:100vh;padding:1rem}}
    .card{{background:#2b2d31;border-radius:12px;padding:2.5rem 2rem;max-width:420px;
           width:100%;text-align:center;box-shadow:0 4px 24px #0006}}
    h1{{font-size:1.5rem;margin-bottom:.75rem;color:{color}}}
    p{{color:#b5bac1;line-height:1.6;margin-bottom:1rem}}
    .tag{{background:#313338;border-radius:6px;padding:.25rem .6rem;
          font-size:.8rem;color:#949ba4;display:inline-block;margin-top:.5rem}}
  </style>
</head>
<body>
  <div class="card">
    <h1>{title}</h1>
    {body}
  </div>
</body>
</html>"""
        return web.Response(text=html, content_type="text/html")

    # ── Routes ────────────────────────────────────────────────────────────────
    async def health(_request: web.Request) -> web.Response:
        return web.Response(text="Executive Stand staff bot online")

    async def authorize(_request: web.Request) -> web.Response:
        """
        GET /authorize
        Redirect the user to Discord OAuth2. The verify button sends them here
        automatically via the ephemeral link, but staff can also link directly
        to <PUBLIC_BOT_URL>/authorize for a clean entry point.
        """
        if not DISCORD_CLIENT_ID or not OAUTH_REDIRECT_URI:
            return _page(
                "Not Configured",
                "<p>OAuth2 is not set up on this server yet.</p>",
                color="#ED4245",
            )
        state = _request.rel_url.query.get("state", "")
        return web.HTTPFound(build_oauth_url(state=state))

    async def callback(request: web.Request) -> web.Response:
        """
        GET /callback
        Discord redirects here after the user authorises.
        Exchange code → tokens → fetch user → add to guild → update Supabase.
        """
        code  = request.rel_url.query.get("code", "")
        state = request.rel_url.query.get("state", "")  # discord user id passed as state
        error = request.rel_url.query.get("error", "")

        if error:
            return _page(
                "Authorization Cancelled",
                "<p>You cancelled the authorization. You can close this tab.</p>"
                "<p>You are still verified, but the bot cannot restore you automatically.</p>",
                color="#FEE75C",
            )

        if not code:
            return _page(
                "Bad Request",
                "<p>No authorization code received.</p>",
                color="#ED4245",
            )

        # Exchange code for tokens
        tokens = await exchange_code(code)
        if not tokens:
            return _page(
                "Authorization Failed",
                "<p>Could not exchange your authorization code. Please try verifying again.</p>",
                color="#ED4245",
            )

        access_token  = tokens.get("access_token", "")
        refresh_token = tokens.get("refresh_token", "")
        expires_in    = int(tokens.get("expires_in", 604800))

        # Fetch the Discord user behind the token
        user_data = await get_oauth_user(access_token)
        if not user_data:
            return _page(
                "Authorization Failed",
                "<p>Could not fetch your Discord profile. Please try again.</p>",
                color="#ED4245",
            )

        user_id       = int(user_data["id"])
        username      = user_data.get("username", str(user_id))
        discriminator = user_data.get("discriminator", "0")
        display       = f"{username}#{discriminator}" if discriminator != "0" else username

        # Persist tokens
        save_oauth_tokens(user_id, access_token, refresh_token, expires_in)

        # Silently add to guild right now in case they already left
        guild_result = ""
        if GUILD_ID:
            ok, msg = await add_member_to_guild(user_id, access_token)
            if ok and msg == "added":
                guild_result = "<p>You have been added back to the server.</p>"
            # If already_member or failed — either way they're in or they'll be restored later

        return _page(
            "✅ All Set!",
            f"<p>Hey <strong>{display}</strong>, you're registered for auto-restore.</p>"
            f"{guild_result}"
            "<p>If the server is ever raided or wiped, staff can silently add you back "
            "without any action needed from you.</p>"
            "<p>You can close this tab.</p>"
            f'<span class="tag">guilds.join · identify</span>',
        )

    app = web.Application()
    app.router.add_get("/",          health)
    app.router.add_get("/health",    health)
    app.router.add_get("/authorize", authorize)
    app.router.add_get("/callback",  callback)

    runner = web.AppRunner(app)
    await runner.setup()
    port = int(os.getenv("PORT", "10000") or "10000")
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    print(
        f"[Staff] HTTP on 0.0.0.0:{port} | "
        f"OAuth={'on' if DISCORD_CLIENT_ID else 'NOT CONFIGURED'}"
    )


async def main():
    token_source = (
        "STAFF_DISCORD_TOKEN"
        if os.getenv("STAFF_DISCORD_TOKEN")
        else ("DISCORD_TOKEN" if os.getenv("DISCORD_TOKEN") else None)
    )
    if not TOKEN:
        print("=" * 60)
        print("FATAL: No bot token found.")
        print("Set STAFF_DISCORD_TOKEN in the staff bot Render service env vars.")
        print("You need a *second* Discord application (separate bot) for staff.")
        print("Do NOT reuse the user bot token — both clients will fight over the gateway.")
        print("=" * 60)
        raise SystemExit("STAFF_DISCORD_TOKEN or DISCORD_TOKEN is required")

    print(f"[Staff] Token source: {token_source}")
    print(f"[Staff] Token length: {len(TOKEN)} (should be ~70 chars)")
    print(f"[Staff] STAFF_ROLE_ID={STAFF_ROLE_ID}")
    print(f"[Staff] Supabase={'yes' if supabase else 'NO'}")

    # When launched via main.py (same Render service), user bot owns PORT
    if os.getenv("COMBINED_SERVICE", "").strip() in ("1", "true", "yes", "on"):
        print("[Staff] COMBINED_SERVICE=1 — skipping HTTP (user bot binds PORT)")
    else:
        await _start_http()
    try:
        async with bot:
            await bot.start(TOKEN)
    except discord.LoginFailure:
        print("=" * 60)
        print("FATAL: Login failed — invalid token.")
        print("Regenerate the token in Discord Developer Portal for the STAFF bot app.")
        print("=" * 60)
        raise
    except discord.PrivilegedIntentsRequired as e:
        print("=" * 60)
        print("FATAL: Privileged intents not enabled for the staff bot application.")
        print("Discord Developer Portal → Bot → enable:")
        print("  - SERVER MEMBERS INTENT")
        print("  - MESSAGE CONTENT INTENT")
        print("=" * 60)
        raise
    except Exception as e:
        print(f"[Staff] Crash on start: {type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
