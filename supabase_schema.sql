-- Run this in Supabase SQL Editor once

create table if not exists stand_configs (
  discord_id text primary key,
  config jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create index if not exists stand_configs_updated_at_idx
  on stand_configs (updated_at desc);

-- Staff blacklist (blocks buyer commands + wiped on blacklist)
create table if not exists stand_blacklist (
  discord_id text primary key,
  reason text not null default '',
  by text not null default '',
  created_at timestamptz not null default now()
);

-- Prefer service_role key for the bot (bypasses RLS).
