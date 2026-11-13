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

-- ============================================================
-- Core stand configs + web dashboard tables
-- ============================================================

create table if not exists stand_configs (
  discord_id  text primary key,
  config      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create or replace function set_stand_configs_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists stand_configs_set_updated_at on stand_configs;
create trigger stand_configs_set_updated_at
before update on stand_configs
for each row execute function set_stand_configs_updated_at();

create table if not exists stand_blacklist (
  discord_id  text primary key,
  reason      text not null default '',
  "by"        text,
  created_at  timestamptz not null default now()
);

create table if not exists stand_status (
  id          int primary key default 1,
  status      text not null default 'up',
  note        text default '',
  updated_at  timestamptz not null default now()
);

insert into stand_status (id, status) values (1, 'up')
on conflict (id) do nothing;

create table if not exists stand_changelog (
  id          bigserial primary key,
  title       text not null default 'Update',
  notes       text not null default '',
  version     text not null default '',
  "by"        text not null default '',
  automatic   boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ============================================================
-- Support tickets (website + Discord staff bot)
-- ============================================================

create table if not exists stand_tickets (
  channel_id   text primary key,
  opener_id    text not null,
  category     text not null default 'general',
  number       int not null default 0,
  subject      text not null default '',
  priority     text not null default 'medium',
  body         text not null default '',
  source       text not null default 'discord',
  claimed_by   text,
  claimed_at   timestamptz,
  closed       boolean not null default false,
  closed_by    text,
  closed_at    timestamptz,
  guild_id     text,
  opened_at    timestamptz not null default now()
);

create index if not exists stand_tickets_opener_idx
  on stand_tickets (opener_id);

create index if not exists stand_tickets_open_idx
  on stand_tickets (closed, category);

create index if not exists stand_tickets_opened_at_idx
  on stand_tickets (opened_at desc);

-- ============================================================
-- Stripe webhook idempotency
-- ============================================================

create table if not exists stripe_events (
  event_id    text primary key,
  event_type  text not null default '',
  processed_at timestamptz not null default now()
);

-- ============================================================
-- Atomic key reservation (avoids double-dispense races)
-- ============================================================

create or replace function reserve_key_stock(
  p_product text,
  p_roblox_user_id bigint,
  p_roblox_username text default ''
)
returns table (
  out_id bigint,
  out_key text,
  out_reused boolean
)
language plpgsql
as $$
declare
  v_id bigint;
  v_key text;
begin
  -- Idempotent: already reserved for this Roblox user + product?
  select id, key into v_id, v_key
  from key_stock
  where product = p_product
    and assigned_to_roblox_user_id = p_roblox_user_id
    and reserved = true
  limit 1;

  if found then
    return query select v_id, v_key, true;
    return;
  end if;

  -- Atomically claim one available key (SKIP LOCKED avoids blocking / double-claim)
  update key_stock
  set
    reserved = true,
    reserved_at = now(),
    assigned_to_roblox_user_id = p_roblox_user_id,
    assigned_to_roblox_username = coalesce(p_roblox_username, ''),
    assigned_at = now()
  where id = (
    select id
    from key_stock
    where product = p_product
      and reserved = false
    order by id
    for update skip locked
    limit 1
  )
  returning id, key into v_id, v_key;

  if v_id is null then
    return;  -- out of stock → empty result set
  end if;

  return query select v_id, v_key, false;
end;
$$;
