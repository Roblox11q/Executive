# Stand Discord Config Bot (Render + Supabase)

## 1. Supabase

1. Create a project at https://supabase.com
2. SQL Editor -> run `supabase_schema.sql`
3. Project Settings -> API:
   - `SUPABASE_URL`
   - `SUPABASE_KEY` = **service_role** key (recommended for bots; bypasses RLS)

## 2. Render

1. New -> **Web Service** (not Web Service)
2. Connect your GitHub repo containing this folder
3. Build: `pip install -r requirements.txt`
4. Start: `python bot.py`
5. Environment variables:

| Key | Value |
|-----|--------|
| `DISCORD_TOKEN` | Bot token |
| `BUYER_ROLE_ID` | Discord role ID for buyers |
| `MAIN_SCRIPT_URL` | Raw GitHub URL to StandMain.lua |
| `SUPABASE_URL` | https://xxxx.supabase.co |
| `SUPABASE_KEY` | service_role key |

## 3. Discord

- Enable **Server Members Intent** in the developer portal (role checks)
- Invite with scopes: `bot`, `applications.commands`

## Commands

- `/setuploader` - set owner username
- `/addalt` / `/removealt` - link alts
- `/config` - gun, prefix, toggles
- `/mylinks` - list links
- `/unlink` - wipe config
- `/loader` - download personal StandLoader.lua (inject on **alts only**)

Only users with `BUYER_ROLE_ID` can use commands (set `0` to allow all while testing).

**In-game:** inject the loader on alt accounts only. The owner does **not** need the script — type commands in public chat (default prefix `.`). Alts listen by the owner username from `/setuploader`.


## Render free tier note

Use a **Web Service** (not Background Worker). The bot starts a tiny HTTP server on `PORT` so Render keeps the process alive. Open the service URL in a browser — you should see `Stand Discord bot online`.
