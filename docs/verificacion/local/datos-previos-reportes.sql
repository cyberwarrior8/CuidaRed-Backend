-- Metadatos simulados de Supabase Auth que el backoffice necesita y el stub general no trae.
-- Solo para validación local de la fase 7 sobre todas las migraciones aplicadas. © 2026 Equipo CuidaRed – INTEC.
alter table auth.users add column if not exists last_sign_in_at timestamptz;

create table if not exists auth.audit_log_entries (
  instance_id uuid,
  id uuid primary key default gen_random_uuid(),
  payload json,
  created_at timestamptz default now(),
  ip_address character varying(64) not null default ''
);
