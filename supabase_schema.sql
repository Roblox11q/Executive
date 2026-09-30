-- ============================================================
-- Executive Stand — Roblox Key Registration (run in Supabase)
-- ============================================================
-- Adds a table for keys generated from Roblox GamePass purchases.
-- Players buy in-game → key lands here → they claim it in Discord
-- with /claimkey or staff can link it.

create table if not exists roblox_keys (
  id            bigserial primary key,
  key           text not null unique,
  product       text not null,                    -- 'stand' | 'premium' | 'shield'
  roblox_user_id bigint not null,
  roblox_username text not null default '',
  claimed_by_discord_id text,                     -- null until claimed
  claimed_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index if not exists roblox_keys_key_idx
  on roblox_keys (key);

create index if not exists roblox_keys_roblox_user_id_idx
  on roblox_keys (roblox_user_id);

create index if not exists roblox_keys_product_idx
  on roblox_keys (product);

create index if not exists roblox_keys_unclaimed_idx
  on roblox_keys (roblox_user_id)
  where claimed_by_discord_id is null;

create or replace function set_roblox_keys_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists roblox_keys_set_updated_at on roblox_keys;
create trigger roblox_keys_set_updated_at
before update on roblox_keys
for each row
execute function set_roblox_keys_updated_at();

-- Optional: allow service_role full access (default in Supabase)
-- alter table roblox_keys enable row level security;
