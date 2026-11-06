-- supabase-stub.sql — Simulación MÍNIMA de lo que Supabase aporta (esquema auth, roles y funciones) para validar
-- las propuestas SQL en un PostgreSQL local. Solo para pruebas locales: nunca ejecutar en el proyecto real.
-- © 2026 Equipo CuidaRed – INTEC.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator nologin; end if;
end $$;
create extension if not exists pgcrypto;
create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  invited_at timestamptz,
  email_confirmed_at timestamptz,
  deleted_at timestamptz,
  banned_until timestamptz,
  is_anonymous boolean not null default false,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  not_after timestamptz
);
-- PostgREST publica los claims del JWT en request.jwt.claims; auth.uid() lee el sub.
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt()->>'sub', '')::uuid $$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.jwt(), auth.uid() to authenticated, anon;
create schema storage;
