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
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

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
CHANGELOG_TABLE = "stand_changelog"
BLACKLIST_TABLE = "stand_blacklist"
TABLE = "stand_configs"
KEY_STOCK_TABLE = "key_stock"
ROBLOX_KEYS_TABLE = "roblox_keys"

# Verification roles
VERIFY_ROLE_ID = int(os.getenv("VERIFY_ROLE_ID", "1554782511781908600") or "1554782511781908600")
UNVERIFIED_ROLE_ID = int(os.getenv("UNVERIFIED_ROLE_ID", "1554782544950726746") or "1554782544950726746")
MEMBER_ROLE_ID = int(os.getenv("MEMBER_ROLE_ID", "1553595287896072192") or "1553595287896072192")

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


async def update_status_channel(
    status: str,
    *,
    note: str = "",
    by: Optional[discord.abc.User] = None,
    announce: bool = True,
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


# ── Ticket data persistence ───────────────────────────────────────────────────
def _load_tickets() -> dict:
    try:
        if TICKET_DATA_FILE.is_file():
            return json.loads(TICKET_DATA_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        print("load tickets error:", e)
    return {"tickets": {}, "counters": {}}


def _save_tickets(data: dict) -> None:
    try:
        TICKET_DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
        TICKET_DATA_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")
    except Exception as e:
        print("save tickets error:", e)


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
    # Refresh status channel name from persisted state
    try:
        await update_status_channel(
            get_system_status(),
            note=_status_note or f"Staff bot online — status `{get_system_status()}`",
            announce=False,
        )
    except Exception as e:
        print("[Staff] on_ready status error:", e)


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
            f"Nickname for **{member}** set to `{nickname or '(reset)'}`."
            ,
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


# ── Minimal HTTP for Render (optional second service) ─────────────────────────
async def _start_http():
    from aiohttp import web

    async def health(_request):
        return web.Response(text="Executive Stand staff bot online")

    app = web.Application()
    app.router.add_get("/", health)
    app.router.add_get("/health", health)
    runner = web.AppRunner(app)
    await runner.setup()
    port = int(os.getenv("PORT", "10000") or "10000")
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    print(f"[Staff] HTTP health on 0.0.0.0:{port}")


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
