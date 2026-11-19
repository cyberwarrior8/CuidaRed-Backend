-- CUIDARED-010 · Suscripciones y entregas Web Push.
begin;

-- CUIDARED-010 · Registro de dispositivos Web Push · RF-18.
-- Propuesta sin aplicar. © 2026 Equipo CuidaRed – INTEC.

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

-- CUIDARED-010 · Cola y entrega de avisos Web Push · RF-18/RF-21.
-- Aplicar después de web-push-suscripciones.sql. © 2026 Equipo CuidaRed – INTEC.

create table cuidared.push_entrega (
  entrega_id uuid primary key default gen_random_uuid(),
  notificacion_id uuid not null references cuidared.notificacion(notificacion_id) on delete cascade,
  endpoint_hash bytea not null references cuidared.push_suscripcion(endpoint_hash) on delete cascade,
  estado text not null default 'pendiente' check (estado in ('pendiente','enviada','omitida','fallida')),
  intentos smallint not null default 0 check (intentos between 0 and 6),
  reserva_id uuid,
  version_suscripcion timestamptz,
  disponible_en timestamptz not null default now(),
  creada_en timestamptz not null default now(),
  terminada_en timestamptz,
  unique (notificacion_id, endpoint_hash)
);
create index push_entrega_lista_idx on cuidared.push_entrega (disponible_en,entrega_id) where estado='pendiente';
create index push_entrega_dispositivo_idx on cuidared.push_entrega (endpoint_hash);
alter table cuidared.push_entrega enable row level security;
revoke all on cuidared.push_entrega from public, anon, authenticated, service_role;

create function cuidared_interno.push_encolar_aviso()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into cuidared.push_entrega(notificacion_id,endpoint_hash)
  select new.notificacion_id,s.endpoint_hash from cuidared.push_suscripcion s
  where s.usuario_id=new.usuario_id
  on conflict (notificacion_id,endpoint_hash) do nothing;
  return new;
end;
$$;
revoke all on function cuidared_interno.push_encolar_aviso() from public, anon, authenticated;
create trigger push_encolar_al_notificar after insert on cuidared.notificacion
  for each row when (new.alerta_envejeciente_id is not null and new.cuenta_id is not null and new.estado = 'no_leida')
  execute function cuidared_interno.push_encolar_aviso();

create function cuidared_interno.push_aviso_elegible(p_aviso cuidared.notificacion, p_usuario_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select p_aviso.usuario_id=p_usuario_id and p_aviso.estado='no_leida' and exists (
    select from cuidared.alerta_envejeciente a
    join cuidared.envejeciente e on e.envejeciente_id=a.envejeciente_id
    join cuidared.tipo_alerta t on t.tipo_alerta_id=a.tipo_alerta_id
    join cuidared.usuario u on u.usuario_id=p_usuario_id and u.estado='activo'
    join auth.users au on au.id=u.usuario_id
    join cuidared_interno.membresia_activa(p_aviso.cuenta_id,p_usuario_id) m on true
    where a.alerta_envejeciente_id=p_aviso.alerta_envejeciente_id
      and e.cuenta_id=p_aviso.cuenta_id and e.estado='activo' and e.consentimiento_retirado_en is null
      and au.email_confirmed_at is not null and au.deleted_at is null
      and (au.banned_until is null or au.banned_until <= now())
      and (m.rol='coordinador' or (m.tipo='organizacion' and m.rol='administrador'))
      and cuidared_interno.acceso_operativo(p_aviso.cuenta_id)
      and cuidared_interno.tiene_permiso(p_aviso.cuenta_id,p_usuario_id,'alertas:ver')
      and cuidared_interno.alcanza_envejeciente(p_aviso.cuenta_id,e.envejeciente_id,p_usuario_id)
      and (not cuidared_interno.alerta_es_prioritaria(t.codigo) or
        cuidared_interno.alerta_parametro(p_aviso.cuenta_id,'notificar_casos_prioritarios') is distinct from 'false')
  )
$$;
revoke all on function cuidared_interno.push_aviso_elegible(cuidared.notificacion,uuid) from public, anon, authenticated;

-- El bloqueo y la reserva permiten varias réplicas del emisor y recuperan un envío interrumpido.
create function cuidared_api.api_push_reservar_entregas(p_limite integer)
returns table (entrega_id uuid,reserva_id uuid,notificacion_id uuid,cuenta_id text,endpoint text,p256dh text,auth text,ttl integer)
language plpgsql security definer set search_path = '' as $$
begin
  if p_limite is null or p_limite not between 1 and 10 then raise invalid_parameter_value; end if;
  return query
  with tomadas as materialized (
    select q.entrega_id from cuidared.push_entrega q
    where q.estado='pendiente' and q.disponible_en <= now()
    order by q.disponible_en,q.entrega_id limit p_limite
    for update skip locked
  ), clasificacion as materialized (
    select q.entrega_id,n.cuenta_id,s.endpoint,s.p256dh,s.auth,s.actualizada_en,
      greatest(0,floor(extract(epoch from (q.creada_en + interval '1 day' - now()))))::integer as vigencia,
      case
        when q.creada_en + interval '1 day' <= now() or not cuidared_interno.push_aviso_elegible(n,s.usuario_id) then 'omitida'
        when q.intentos >= 6 then 'fallida'
        else 'pendiente'
      end as nuevo_estado
    from tomadas t
    join cuidared.push_entrega q on q.entrega_id=t.entrega_id
    join cuidared.push_suscripcion s on s.endpoint_hash=q.endpoint_hash
    join cuidared.notificacion n on n.notificacion_id=q.notificacion_id
  ), reservadas as (
    update cuidared.push_entrega q set estado=c.nuevo_estado,
      reserva_id=case when c.nuevo_estado='pendiente' then gen_random_uuid() end,
      version_suscripcion=case when c.nuevo_estado='pendiente' then c.actualizada_en end,
      intentos=q.intentos + case when c.nuevo_estado='pendiente' then 1 else 0 end,
      disponible_en=now()+interval '2 minutes',
      terminada_en=case when c.nuevo_estado<>'pendiente' then now() end
    from clasificacion c where c.entrega_id=q.entrega_id
    returning q.entrega_id,q.reserva_id,q.notificacion_id,c.cuenta_id,c.endpoint,c.p256dh,c.auth,c.vigencia
  )
  select r.entrega_id,r.reserva_id,r.notificacion_id,r.cuenta_id::text,r.endpoint,r.p256dh,r.auth,r.vigencia
  from reservadas r where r.reserva_id is not null;
end;
$$;

create function cuidared_api.api_push_finalizar_entrega(p_entrega_id uuid,p_reserva_id uuid,p_resultado text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_entrega cuidared.push_entrega;
begin
  if p_entrega_id is null or p_reserva_id is null or p_resultado is null
     or p_resultado not in ('enviada','reintentar','fallida','caducada') then raise invalid_parameter_value; end if;
  if p_resultado='caducada' then
    -- Mismo orden de bloqueos que una revocación: dispositivo y después su entrega.
    perform from cuidared.push_suscripcion s
    where s.endpoint_hash=(select q.endpoint_hash from cuidared.push_entrega q
      where q.entrega_id=p_entrega_id and q.reserva_id=p_reserva_id and q.estado='pendiente')
    for update;
  end if;
  select * into v_entrega from cuidared.push_entrega
    where entrega_id=p_entrega_id and reserva_id=p_reserva_id and estado='pendiente'
    for update;
  if not found then return; end if;

  if p_resultado='caducada' then
    -- Un navegador puede renovar sus claves mientras se procesa una entrega anterior.
    delete from cuidared.push_suscripcion
      where endpoint_hash=v_entrega.endpoint_hash and actualizada_en=v_entrega.version_suscripcion;
    if found then return; end if;
  end if;

  update cuidared.push_entrega set
    estado=case when p_resultado='enviada' then 'enviada'
      when p_resultado='reintentar' and v_entrega.intentos<6 then 'pendiente' else 'fallida' end,
    disponible_en=now()+make_interval(secs=>15 * (1 << (v_entrega.intentos - 1))),
    reserva_id=null,version_suscripcion=null,
    terminada_en=case when p_resultado<>'reintentar' or v_entrega.intentos>=6 then now() end
  where entrega_id=p_entrega_id;
end;
$$;

grant usage on schema cuidared_api to service_role;
revoke all on function cuidared_api.api_push_reservar_entregas(integer),
  cuidared_api.api_push_finalizar_entrega(uuid,uuid,text) from public, anon, authenticated, service_role;
grant execute on function cuidared_api.api_push_reservar_entregas(integer),
  cuidared_api.api_push_finalizar_entrega(uuid,uuid,text) to service_role;

commit;
