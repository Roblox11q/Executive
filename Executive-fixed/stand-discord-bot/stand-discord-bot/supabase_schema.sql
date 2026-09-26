-- Run this in Supabase SQL Editor once

create table if not exists stand_configs (
  discord_id text primary key,
  config jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- optional index for maintenance
create index if not exists stand_configs_updated_at_idx
  on stand_configs (updated_at desc);

-- If using anon key from the bot, add a policy (prefer service_role key for bots):
-- alter table stand_configs enable row level security;
-- For service_role key, RLS is bypassed — recommended for this bot.
