-- Local DB-only verification support.
--
-- The Supabase Postgres image contains the platform roles, auth schema, pgcrypto,
-- and pg_cron, but Auth/Storage service migrations are not applied when only the
-- database container is started.  Historical application migrations depend on
-- the objects below, so reproduce only that required database contract locally.

set role supabase_auth_admin;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    jsonb_strip_nulls(jsonb_build_object(
      'sub', nullif(current_setting('request.jwt.claim.sub', true), ''),
      'role', nullif(current_setting('request.jwt.claim.role', true), ''),
      'email', nullif(current_setting('request.jwt.claim.email', true), '')
    ))
  );
$$;

grant execute on function auth.jwt() to anon, authenticated, service_role;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(auth.jwt()->>'sub', '')::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select nullif(auth.jwt()->>'role', '');
$$;

grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;

reset role;

-- Application migrations run as the local `postgres` administrator.  Supabase
-- keeps Storage objects owned by `supabase_storage_admin`, while its migration
-- administrator must still be able to seed buckets and manage Storage RLS
-- policies.  Inherit only this dedicated owner role; do not transfer ownership
-- of service-managed objects to the application migration role.
grant supabase_storage_admin to postgres with inherit true, set false;

set role supabase_storage_admin;

-- Match the Storage service contract for objects created by its owner role.
-- The explicit grants below cover these compatibility tables; the defaults
-- keep the same contract if a later local compatibility object is added.
grant usage on schema storage to postgres;
alter default privileges in schema storage
  grant all on tables to postgres;
alter default privileges in schema storage
  grant all on functions to postgres;
alter default privileges in schema storage
  grant all on sequences to postgres;

create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  public boolean not null default false,
  avif_autodetection boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_accessed_at timestamptz not null default now(),
  metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  version text,
  owner_id text,
  user_metadata jsonb,
  unique (bucket_id, name)
);

alter table storage.objects enable row level security;

grant all on storage.buckets, storage.objects to postgres;
grant usage on schema storage to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;

reset role;
