-- ============================================================
-- Executive Stand — Roblox + License Hub key stock
-- Run in Supabase SQL Editor
-- ============================================================

-- Keys pre-generated on License Hub, waiting to be sold in Roblox
create table if not exists key_stock (
  id            bigserial primary key,
  key           text not null unique,
  product       text not null,              -- 'stand' | 'premium' | 'shield'
  reserved      boolean not null default false,
  reserved_at   timestamptz,
  assigned_to_roblox_user_id bigint,
  assigned_to_roblox_username text,
  assigned_at   timestamptz,
  claimed_by_discord_id text,
  claimed_at    timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists key_stock_product_available_idx
  on key_stock (product)
  where reserved = false;

create index if not exists key_stock_key_idx on key_stock (key);

-- Assigned / claimed history (same as before, kept for lookup)
create table if not exists roblox_keys (
  id            bigserial primary key,
  key           text not null unique,
  product       text not null,
  roblox_user_id bigint not null,
  roblox_username text not null default '',
  claimed_by_discord_id text,
  claimed_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index if not exists roblox_keys_key_idx on roblox_keys (key);
create index if not exists roblox_keys_roblox_user_id_idx on roblox_keys (roblox_user_id);

create or replace function set_roblox_keys_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists roblox_keys_set_updated_at on roblox_keys;
create trigger roblox_keys_set_updated_at
before update on roblox_keys
for each row execute function set_roblox_keys_updated_at();
