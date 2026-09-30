# Executive Stand — Discord Bots (Render + Supabase)

**In-game support:** Da Hood (`2788229376`) · DERS HOOD (`96247461091106`) · Des Hood (`128413479081937`) · Hood Customs (`9825515356`)

Two bots:

| Process | File | Purpose |
|---------|------|---------|
| **User bot** | `bot.py` | Buyer commands (`/loader`, `/config`, alts, etc.) |
| **Staff bot** | `staff_bot.py` | Moderation, tickets, verification, staff Stand commands |

---

## 1. Supabase

1. Create a project at https://supabase.com  
2. SQL Editor → run `supabase_schema.sql`  
3. Project Settings → API:
   - `SUPABASE_URL`
   - `SUPABASE_KEY` = **service_role** key (recommended; bypasses RLS)

---

## 2. Discord applications

Create **two** Discord applications (or reuse one token only if you run a single process — not recommended).

### User bot (`bot.py`)
- Enable **Server Members Intent**
- Invite: `bot`, `applications.commands`

### Staff bot (`staff_bot.py`)
- Enable **Server Members Intent** and **Message Content Intent** (transcripts)
- Invite with: `bot`, `applications.commands`
- Permissions: Manage Channels, Manage Roles, Ban, Kick, Moderate Members, Manage Messages, View Channels, Send Messages, Attach Files

---

## 3. Render

Deploy **two** Web Services (or one service + a second service for the staff bot).

### User bot service
- Build: `pip install -r requirements.txt`
- Start: `python bot.py`
- Env:

| Key | Value |
|-----|--------|
| `DISCORD_TOKEN` | User bot token |
| `BUYER_ROLE_ID` | Buyer role ID |
| `STAFF_ROLE_ID` | Staff role ID (optional; for maintenance bypass) |
| `MAIN_SCRIPT_URL` | Raw GitHub URL to StandMain.lua |
| `SUPABASE_URL` | https://xxxx.supabase.co |
| `SUPABASE_KEY` | service_role key |
| `STATUS_CHANNEL_ID` | `1554079705022595174` |
| `STATUS_CHANNEL_LABEL` | `Executive Stand` |
| `CHANGELOG_CHANNEL_ID` | Changelog channel ID |
| `PUBLIC_BOT_URL` | Public URL of this service (auto on Render) |

### Staff bot service
- Build: `pip install -r requirements.txt`
- Start: `python staff_bot.py`
- Env:

| Key | Value |
|-----|--------|
| `STAFF_DISCORD_TOKEN` | Staff bot token (falls back to `DISCORD_TOKEN`) |
| `STAFF_ROLE_ID` | Staff role ID |
| `SUPABASE_URL` / `SUPABASE_KEY` | Same as user bot |
| `STATUS_CHANNEL_ID` | `1554079705022595174` |
| `STATUS_CHANNEL_LABEL` | `Executive Stand` |
| `CHANGELOG_CHANNEL_ID` | Changelog channel ID |
| `TRANSCRIPT_CHANNEL_ID` | `1554783241750188112` |
| `VERIFY_ROLE_ID` | `1554782511781908600` |
| `UNVERIFIED_ROLE_ID` | `1554782544950726746` |
| `MEMBER_ROLE_ID` | `1553595287896072192` |
| `TICKET_CATEGORY_ID` | Optional category for new tickets |

---

## 4. User bot commands (`bot.py`)

- `/setuploader` — set owner username + key  
- `/addalt` / `/removealt` — link alts  
- `/config` — gun, prefix, toggles  
- `/mylinks` — list links  
- `/unlink` — wipe config  
- `/loader` — download personal StandLoader.lua (inject on **alts only**)  
- `/addcontroller` / `/removecontroller` — extra Roblox users who can command alts  
- `/setkey` — update license key  

Only users with `BUYER_ROLE_ID` can use buyer commands (set `0` to allow all while testing).

**In-game:** inject on alts only. Owner (and controllers) type commands in public chat.

---

## 5. Staff bot commands (`staff_bot.py`)

### Stand / system
- `/status` — set 🟢 up / 🔴 down / 🔵 updating / 🟡 detected (renames status channel `🟢｜Executive Stand`)
- `/changelog` — post changelog (optional auto status flip)
- `/blacklist` `/unblacklist` `/checkblacklist`
- `/forceunlink` `/staffview` `/setrank`

### Moderation
- `/ban` `/unban` `/kick`
- `/timeout` `/untimeout`
- `/purge` `/lock` `/unlock` `/slowmode`
- `/nick` `/role`

### Tickets (Ticket-King style)
- `/ticketpanel` — post panel with **dropdown**:
  - ❓ Development — Report a bug  
  - 💰 Billing — Report a billing issue, not receiving perks  
  - 🔧 Partnership — Apply to become an affiliate of NodeRoblox  
- Ticket channel buttons: **Close** · **Claim** · **Transcript**
- `/ticketadd` `/ticketremove` `/ticketclose` `/ticketrename`
- Transcripts are posted to channel `1554783241750188112`

### Verification
- New members automatically receive the **unverified** role (`1554782544950726746`)
- `/verifypanel` — post a **Verify** button
- On verify: remove unverified → add **verified** (`1554782511781908600`) + **member** (`1553595287896072192`)

---

## Render free tier note

Use a **Web Service** (not Background Worker). Each bot starts a tiny HTTP server on `PORT` so Render keeps the process alive.

---

## Troubleshooting: staff bot not online

### 1. Separate Discord bot application (most common)
You need **two** bots:
1. User bot application → token in user service as `DISCORD_TOKEN`
2. **New** Discord application for staff → token in staff service as `STAFF_DISCORD_TOKEN`

Using the **same token** on both services makes them disconnect each other (only one gateway session per token).

Create a second app: https://discord.com/developers/applications → New Application → Bot → Reset Token → copy into Render.

### 2. Set env on the **staff** Render service
On the `stand-staff-bot` service (not the user one):

| Key | Required |
|-----|----------|
| `STAFF_DISCORD_TOKEN` | **Yes** — staff bot token |
| `STAFF_ROLE_ID` | Recommended |
| `SUPABASE_URL` / `SUPABASE_KEY` | Same as user bot |

If `STAFF_DISCORD_TOKEN` is empty, the process exits immediately with:
`STAFF_DISCORD_TOKEN or DISCORD_TOKEN is required`

### 3. Privileged intents (staff bot app)
Developer Portal → your **staff** application → Bot → enable:
- **SERVER MEMBERS INTENT** (auto-role + verification)
- **MESSAGE CONTENT INTENT** (transcripts)

### 4. Invite the staff bot
Invite the **staff** bot (not the user bot) with scopes `bot` + `applications.commands` and permissions: Manage Channels, Manage Roles, Ban Members, Kick Members, Moderate Members, Manage Messages, View Channels, Send Messages, Attach Files, Read Message History.

### 5. Two Render services
`render.yaml` defines two services. Confirm both exist and the staff one start command is:
```
python staff_bot.py
```
Open **Logs** on `stand-staff-bot`. You should see:
```
[Staff] Token source: STAFF_DISCORD_TOKEN
[Staff] Logged in as YourStaffBot#1234
```
If you only see the user bot logs, the staff service was never deployed or crashed before login.

### 6. Free tier / root directory
- If the repo root is the parent folder, set Render **Root Directory** to `Executive-main` (wherever `staff_bot.py` lives).
- Free web services sleep; open the staff service URL once after deploy so it wakes.
