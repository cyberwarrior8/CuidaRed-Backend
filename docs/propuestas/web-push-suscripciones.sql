-- CUIDARED-010 · Registro de dispositivos Web Push · RF-18.
-- Propuesta sin aplicar. © 2026 Equipo CuidaRed – INTEC.
begin;

create function cuidared_interno.push_endpoint_valido(p_endpoint text) returns boolean
language sql immutable strict set search_path = '' as $$
  select length(p_endpoint) <= 4096 and p_endpoint collate "C" ~
    '^https://(fcm[.]googleapis[.]com/(fcm/send|wp)/|updates[.]push[.]services[.]mozilla[.]com/wpush/v2/|web[.]push[.]apple[.]com/)[A-Za-z0-9_-][A-Za-z0-9_~.:-]*$'
$$;
revoke all on function cuidared_interno.push_endpoint_valido(text) from public, anon, authenticated;

create table cuidared.push_suscripcion (
  endpoint text not null check (cuidared_interno.push_endpoint_valido(endpoint)),
  -- Una URL válida puede superar el tamaño de una entrada B-tree.
  endpoint_hash bytea generated always as (sha256(endpoint::bytea)) stored primary key,
  usuario_id uuid not null references cuidared.usuario(usuario_id) on delete cascade,
  sesion_id uuid not null,
  p256dh text not null check (p256dh collate "C" ~ '^B[A-P][A-Za-z0-9_-]{84}[AEIMQUYcgkosw048]$'),
  auth text not null check (auth collate "C" ~ '^[A-Za-z0-9_-]{21}[AQgw]$'),
  creada_en timestamptz not null default now(),
  actualizada_en timestamptz not null default now()
);
create index push_suscripcion_usuario_idx on cuidared.push_suscripcion (usuario_id);
create index push_suscripcion_sesion_idx on cuidared.push_suscripcion (sesion_id);
alter table cuidared.push_suscripcion enable row level security;
revoke all on cuidared.push_suscripcion from public, anon, authenticated, service_role;

create function cuidared_api.api_push_registrar_suscripcion(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := cuidared_interno.exigir_sesion();
begin
  if cuidared_interno.push_endpoint_valido(p_endpoint) is distinct from true
    or p_p256dh is null or p_p256dh collate "C" !~ '^B[A-P][A-Za-z0-9_-]{84}[AEIMQUYcgkosw048]$'
    or p_auth is null or p_auth collate "C" !~ '^[A-Za-z0-9_-]{21}[AQgw]$' then
    raise invalid_parameter_value;
  end if;

  insert into cuidared.push_suscripcion as s (endpoint, usuario_id, sesion_id, p256dh, auth)
  values (p_endpoint, v_usuario, (auth.jwt()->>'session_id')::uuid, p_p256dh, p_auth)
  on conflict (endpoint_hash) do update
    set sesion_id = excluded.sesion_id, p256dh = excluded.p256dh, auth = excluded.auth,
      actualizada_en = clock_timestamp()
    where s.usuario_id = v_usuario and s.endpoint = excluded.endpoint;
  if not found then raise unique_violation; end if;
end;
$$;

create function cuidared_api.api_push_estado_suscripcion(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := cuidared_interno.exigir_sesion();
begin
  if cuidared_interno.push_endpoint_valido(p_endpoint) is distinct from true then
    raise invalid_parameter_value;
  end if;
  return jsonb_build_object('activa', exists (
    select from cuidared.push_suscripcion s where s.endpoint_hash = sha256(p_endpoint::bytea)
      and s.endpoint = p_endpoint and s.usuario_id = v_usuario
  ));
end;
$$;

create function cuidared_api.api_push_revocar_suscripcion(p_endpoint text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := cuidared_interno.exigir_sesion();
begin
  if cuidared_interno.push_endpoint_valido(p_endpoint) is distinct from true then
    raise invalid_parameter_value;
  end if;
  delete from cuidared.push_suscripcion s where s.endpoint_hash = sha256(p_endpoint::bytea)
    and s.endpoint = p_endpoint and s.usuario_id = v_usuario;
end;
$$;

-- El vencimiento por inactividad no modifica revocada_en. Cerrar desde CuidaRed sí lo hace.
create function cuidared_interno.push_revocar_dispositivos_sesion()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from cuidared.push_suscripcion where sesion_id = new.sesion_id;
  return new;
end;
$$;
revoke all on function cuidared_interno.push_revocar_dispositivos_sesion() from public, anon, authenticated;
create trigger push_retirar_suscripciones_al_cerrar
  after insert or update of revocada_en on cuidared.sesion_acceso
  for each row when (new.revocada_en is not null)
  execute function cuidared_interno.push_revocar_dispositivos_sesion();

revoke all on function cuidared_api.api_push_registrar_suscripcion(text,text,text),
  cuidared_api.api_push_estado_suscripcion(text), cuidared_api.api_push_revocar_suscripcion(text)
  from public, anon, authenticated;
grant execute on function cuidared_api.api_push_registrar_suscripcion(text,text,text),
  cuidared_api.api_push_estado_suscripcion(text), cuidared_api.api_push_revocar_suscripcion(text)
  to authenticated;

commit;
