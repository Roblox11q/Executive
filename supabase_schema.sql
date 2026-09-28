-- Run this in the Supabase SQL Editor once.
-- Prefer the service_role key in the bot so the app can write without RLS issues.

create table if not exists stand_configs (
  discord_id text primary key,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists stand_configs_updated_at_idx
  on stand_configs (updated_at desc);

create or replace function set_stand_configs_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists stand_configs_set_updated_at on stand_configs;
create trigger stand_configs_set_updated_at
before update on stand_configs
for each row
execute function set_stand_configs_updated_at();

-- Staff blacklist (blocks buyer commands + wiped on blacklist)
create table if not exists stand_blacklist (
  discord_id text primary key,
  reason text not null default '',
  by text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function set_blacklist_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists stand_blacklist_set_updated_at on stand_blacklist;
create trigger stand_blacklist_set_updated_at
before update on stand_blacklist
for each row
execute function set_blacklist_updated_at();

-- System status (persisted so maintenance locks survive Render restarts / multi-instance)
create table if not exists stand_status (
  id text primary key default 'current',
  status text not null default 'up',
  note text not null default '',
  updated_at timestamptz not null default now()
);

create index if not exists stand_status_updated_at_idx
  on stand_status (updated_at desc);

insert into stand_status (id, status, note)
values ('current', 'up', '')
on conflict (id) do nothing;

-- Changelog history (written whenever staff or auto-deploy posts a changelog)
create table if not exists stand_changelog (
  id bigserial primary key,
  title text not null default 'Update',
  notes text not null default '',
  version text not null default '',
  by text not null default 'System',
  automatic boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists stand_changelog_created_at_idx
  on stand_changelog (created_at desc);

-- If your project uses RLS, enable it and allow the service_role key full access.
-- Example (service role bypasses RLS in Supabase by default):
-- alter table stand_configs enable row level security;
-- alter table stand_blacklist enable row level security;
-- alter table stand_status enable row level security;
-- alter table stand_changelog enable row level security;
