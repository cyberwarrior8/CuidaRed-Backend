-- Fase 6a · Consulta de alertas, casos prioritarios y lectura de avisos personales.
-- Depende del cierre de fases 2 a 4. Propuesta local para revisión.
begin;

alter table cuidared.alerta_envejeciente
  add column cierre_automatico boolean not null default false,
  add column fuente_riesgo_id bigint references cuidared.envejeciente_riesgo(envejeciente_riesgo_id),
  add column fuente_necesidad_id uuid references cuidared.envejeciente_necesidad(envejeciente_necesidad_id),
  add column fuente_visita_id uuid,
  add column fuente_perfil_id uuid references cuidared.envejeciente(envejeciente_id),
  add constraint alerta_fuente_visita_adulto_fk foreign key (fuente_visita_id, envejeciente_id)
    references cuidared.detalle_visita(visita_id, envejeciente_id),
  add constraint alerta_fuente_coherente_chk check (
    num_nonnulls(fuente_riesgo_id, fuente_necesidad_id, fuente_visita_id, fuente_perfil_id) <= 1
    and (fuente_perfil_id is null or fuente_perfil_id = envejeciente_id)
  );
alter table cuidared.alerta_envejeciente enable row level security;
alter table cuidared.notificacion enable row level security;
revoke all on cuidared.alerta_envejeciente, cuidared.notificacion from public, anon, authenticated;

create index alerta_adulto_fecha_idx
  on cuidared.alerta_envejeciente (envejeciente_id, fecha_alerta desc, alerta_envejeciente_id);
create index notificacion_alerta_destinatario_fecha_idx
  on cuidared.notificacion (usuario_id, fecha_notificacion desc, notificacion_id)
  where alerta_envejeciente_id is not null;

create function cuidared_interno.alerta_es_prioritaria(p_tipo text) returns boolean
language sql immutable set search_path = '' as $$
  select p_tipo in ('riesgo_alto', 'medicamento_pendiente')
$$;

-- Los campos del orden se comparan con una lista fija por RPC y se citan como identificadores.
create function cuidared_interno.alerta_orden(p_orden text[], p_fecha text, p_id text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v_campo text;
  v_token text;
  v_vistos text[] := array[]::text[];
  v_orden text := '';
begin
  if p_orden is null or cardinality(p_orden) not between 1 and 2 then raise invalid_parameter_value; end if;
  foreach v_token in array p_orden loop
    v_campo := case when left(v_token, 1) = '-' then substr(v_token, 2) else v_token end;
    if v_campo is null or v_campo not in (p_fecha, p_id) or v_campo = any(v_vistos) then
      raise invalid_parameter_value;
    end if;
    v_vistos := array_append(v_vistos, v_campo);
    v_orden := concat_ws(', ', nullif(v_orden, ''),
      format('%I %s', v_campo, case when left(v_token, 1) = '-' then 'desc' else 'asc' end));
  end loop;
  if not (p_id = any(v_vistos)) then v_orden := v_orden || format(', %I asc', p_id); end if;
  return v_orden;
end;
$$;

create function cuidared_interno.alerta_json(p_alerta cuidared.alerta_envejeciente, p_adulto cuidared.envejeciente,
  p_tipo cuidared.tipo_alerta, p_prioridad cuidared.prioridad)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'alerta_envejeciente_id', p_alerta.alerta_envejeciente_id,
    'envejeciente_id', p_adulto.envejeciente_id, 'nombres', p_adulto.nombres, 'apellidos', p_adulto.apellidos,
    'tipo', jsonb_build_object('codigo', p_tipo.codigo, 'nombre', p_tipo.nombre),
    'prioridad', jsonb_build_object('nombre', p_prioridad.nombre, 'orden', p_prioridad.orden),
    'descripcion', p_alerta.descripcion, 'origen', p_alerta.origen, 'estado', p_alerta.estado,
    'fecha_alerta', p_alerta.fecha_alerta, 'fecha_atencion', p_alerta.fecha_atencion,
    'atendida_por', (
      select nullif(concat_ws(' ',u.nombres,u.apellidos),'')
      from cuidared.usuario u where u.usuario_id = p_alerta.usuario_atendio_id
        and exists (select from cuidared.membresia m
          where m.cuenta_id = p_adulto.cuenta_id and m.usuario_id = u.usuario_id)
    ),
    'cierre_automatico', p_alerta.cierre_automatico,
    'accion_tomada', p_alerta.accion_tomada,
    'es_prioritaria', cuidared_interno.alerta_es_prioritaria(p_tipo.codigo)
      and num_nonnulls(p_alerta.fuente_riesgo_id, p_alerta.fuente_necesidad_id,
        p_alerta.fuente_visita_id, p_alerta.fuente_perfil_id) = 1,
    'fuente', case
      when p_alerta.fuente_riesgo_id is not null then jsonb_build_object('tipo', 'riesgo', 'referencia_id', p_alerta.fuente_riesgo_id::text)
      when p_alerta.fuente_necesidad_id is not null then jsonb_build_object('tipo', 'necesidad', 'referencia_id', p_alerta.fuente_necesidad_id)
      when p_alerta.fuente_visita_id is not null then jsonb_build_object('tipo', 'visita', 'referencia_id', p_alerta.fuente_visita_id)
      when p_alerta.fuente_perfil_id is not null then jsonb_build_object('tipo', 'perfil', 'referencia_id', p_alerta.fuente_perfil_id)
    end
  )
$$;

create function cuidared_interno.alertas_visibles(p_cuenta_id bigint, p_usuario_id uuid)
returns table (alerta_envejeciente_id uuid, envejeciente_id uuid, nombres text, apellidos text, fecha_alerta timestamptz,
  estado text, tipo text, es_prioritaria boolean, datos jsonb)
language sql stable set search_path = '' as $$
  with adultos as materialized (
    select e.* from cuidared.envejeciente e
    where e.cuenta_id = p_cuenta_id and e.estado = 'activo'
      and cuidared_interno.alcanza_envejeciente(p_cuenta_id, e.envejeciente_id, p_usuario_id)
  )
  select a.alerta_envejeciente_id, e.envejeciente_id, e.nombres::text, e.apellidos::text, a.fecha_alerta,
    a.estado::text, t.codigo::text,
    cuidared_interno.alerta_es_prioritaria(t.codigo) and
      num_nonnulls(a.fuente_riesgo_id, a.fuente_necesidad_id, a.fuente_visita_id, a.fuente_perfil_id) = 1,
    cuidared_interno.alerta_json(a, e, t, p)
  from adultos e
  join cuidared.alerta_envejeciente a on a.envejeciente_id = e.envejeciente_id
  join cuidared.tipo_alerta t on t.tipo_alerta_id = a.tipo_alerta_id
  join cuidared.prioridad p on p.prioridad_id = a.prioridad_id
$$;

create function cuidared_api.api_alertas_listar(p_cuenta_id bigint, p_filtros jsonb, p_orden text[],
  p_limite integer, p_desplazamiento bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'alertas:ver')->>'usuario_id')::uuid;
  v_orden text := cuidared_interno.alerta_orden(p_orden, 'fecha_alerta', 'alerta_envejeciente_id');
  v_resultado jsonb;
  v_estado text := p_filtros->>'estado';
  v_tipo text := p_filtros->>'tipo';
  v_adulto uuid;
begin
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
    or jsonb_typeof(p_filtros) is distinct from 'object'
    or p_filtros - array['estado', 'envejeciente_id', 'tipo'] <> '{}'::jsonb
    or (p_filtros ? 'estado' and (jsonb_typeof(p_filtros->'estado') is distinct from 'string'
      or v_estado not in ('pendiente', 'en_proceso', 'resuelta')))
    or (p_filtros ? 'tipo' and (jsonb_typeof(p_filtros->'tipo') is distinct from 'string'
      or v_tipo !~ '^[a-z][a-z0-9_]{0,79}$')) then raise invalid_parameter_value; end if;
  v_adulto := cuidared_interno.v_uuid(p_filtros->'envejeciente_id', false);

  execute format($q$
    with base as materialized (
      select a.* from cuidared_interno.alertas_visibles($1, $2) a
      where ($3::text is null or a.estado = $3)
        and ($4::text is null or a.tipo = $4)
        and ($5::uuid is null or a.envejeciente_id = $5)
    ), pagina as (
      select b.datos, row_number() over (order by %1$s) as posicion
      from base b order by %1$s limit $6 offset $7
    )
    select jsonb_build_object('total', (select count(*) from base),
      'items', coalesce(jsonb_agg(datos order by posicion), '[]'::jsonb)) from pagina
  $q$, v_orden) into v_resultado using p_cuenta_id, v_uid, v_estado, v_tipo, v_adulto, p_limite, p_desplazamiento;
  return v_resultado;
end;
$$;

create function cuidared_api.api_alerta_obtener(p_cuenta_id bigint, p_alerta_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'alertas:ver')->>'usuario_id')::uuid;
  v_resultado jsonb;
begin
  select cuidared_interno.alerta_json(a, e, t, p) into v_resultado
  from cuidared.alerta_envejeciente a
  join cuidared.envejeciente e on e.envejeciente_id = a.envejeciente_id
  join cuidared.tipo_alerta t on t.tipo_alerta_id = a.tipo_alerta_id
  join cuidared.prioridad p on p.prioridad_id = a.prioridad_id
  where a.alerta_envejeciente_id = p_alerta_id and e.cuenta_id = p_cuenta_id and e.estado = 'activo'
    and cuidared_interno.alcanza_envejeciente(p_cuenta_id, e.envejeciente_id, v_uid);
  if not found then raise no_data_found; end if;
  return v_resultado;
end;
$$;

create function cuidared_interno.alerta_transicion(p_cuenta_id bigint, p_alerta_id uuid, p_estado text, p_accion text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_accion text;
  v_alerta cuidared.alerta_envejeciente;
begin
  if p_estado = 'en_proceso' or cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'alertas:gestionar') then
    perform cuidared_interno.exigir(p_cuenta_id, 'alertas:gestionar');
  else
    perform cuidared_interno.exigir(p_cuenta_id, 'alertas:cerrar');
  end if;
  -- Bloqueo adulto antes de alerta: el retiro del consentimiento trabaja en ese orden.
  perform 1 from cuidared.envejeciente e
    join cuidared.alerta_envejeciente a on a.envejeciente_id = e.envejeciente_id
    where a.alerta_envejeciente_id = p_alerta_id and e.cuenta_id = p_cuenta_id and e.estado = 'activo'
      and cuidared_interno.alcanza_envejeciente(p_cuenta_id, e.envejeciente_id, v_uid)
    for share of e;
  if not found then raise no_data_found; end if;
  select a.* into v_alerta from cuidared.alerta_envejeciente a
    where a.alerta_envejeciente_id = p_alerta_id for update;
  if not found then raise no_data_found; end if;
  if p_estado = 'en_proceso' then
    if v_alerta.estado = 'en_proceso' then
      return cuidared_api.api_alerta_obtener(p_cuenta_id, p_alerta_id);
    end if;
    if v_alerta.estado <> 'pendiente' then
      raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
    end if;
    update cuidared.alerta_envejeciente set estado = 'en_proceso', fecha_actualizacion = now()
      where alerta_envejeciente_id = p_alerta_id;
    return cuidared_api.api_alerta_obtener(p_cuenta_id, p_alerta_id);
  end if;
  if p_estado is distinct from 'resuelta' then raise invalid_parameter_value; end if;
  v_accion := cuidared_interno.v_texto(to_jsonb(p_accion), 1, 500);
  if v_alerta.estado = 'resuelta' and v_alerta.usuario_atendio_id = v_uid and v_alerta.accion_tomada = v_accion then
    return cuidared_api.api_alerta_obtener(p_cuenta_id, p_alerta_id);
  end if;
  if v_alerta.estado not in ('pendiente', 'en_proceso') then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  update cuidared.alerta_envejeciente set estado = 'resuelta', fecha_atencion = now(),
    usuario_atendio_id = v_uid, accion_tomada = v_accion, fecha_actualizacion = now()
    where alerta_envejeciente_id = p_alerta_id;
  return cuidared_api.api_alerta_obtener(p_cuenta_id, p_alerta_id);
end;
$$;

create function cuidared_api.api_alerta_resolver(p_cuenta_id bigint, p_alerta_id uuid, p_accion text) returns jsonb
language sql security definer set search_path = '' as $$
  select cuidared_interno.alerta_transicion(p_cuenta_id, p_alerta_id, 'resuelta', p_accion)
$$;

create function cuidared_api.api_alerta_en_atencion(p_cuenta_id bigint, p_alerta_id uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select cuidared_interno.alerta_transicion(p_cuenta_id, p_alerta_id, 'en_proceso', null)
$$;

create function cuidared_api.api_casos_prioritarios_listar(p_cuenta_id bigint, p_filtros jsonb, p_orden text[],
  p_limite integer, p_desplazamiento bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'alertas:ver')->>'usuario_id')::uuid;
  v_orden text := cuidared_interno.alerta_orden(p_orden, 'fecha_alerta', 'envejeciente_id');
  v_adulto uuid;
  v_resultado jsonb;
begin
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
    or jsonb_typeof(p_filtros) is distinct from 'object' or p_filtros - 'envejeciente_id' <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_adulto := cuidared_interno.v_uuid(p_filtros->'envejeciente_id', false);
  execute format($q$
    with base as materialized (
      select a.* from cuidared_interno.alertas_visibles($1, $2) a
      where a.es_prioritaria and a.estado in ('pendiente', 'en_proceso')
        and ($3::uuid is null or a.envejeciente_id = $3)
    ), casos as materialized (
      select envejeciente_id, nombres, apellidos, max(fecha_alerta) fecha_alerta, count(*) total_alertas
      from base group by envejeciente_id, nombres, apellidos
    ), pagina as (
      select c.*, row_number() over (order by %1$s) posicion from casos c
      order by %1$s limit $4 offset $5
    )
    select jsonb_build_object('total', (select count(*) from casos), 'items', coalesce(jsonb_agg(
      jsonb_build_object('envejeciente_id', p.envejeciente_id, 'nombres', p.nombres, 'apellidos', p.apellidos,
        'fecha_alerta', p.fecha_alerta, 'total_alertas', p.total_alertas, 'alertas',
        (select jsonb_agg(a.datos order by a.fecha_alerta desc, a.alerta_envejeciente_id)
         from base a where a.envejeciente_id = p.envejeciente_id)
      ) order by p.posicion), '[]'::jsonb)) from pagina p
  $q$, v_orden) into v_resultado using p_cuenta_id, v_uid, v_adulto, p_limite, p_desplazamiento;
  return v_resultado;
end;
$$;

create function cuidared_interno.aviso_alerta_json(p_aviso cuidared.notificacion) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('notificacion_id', p_aviso.notificacion_id,
    'alerta_envejeciente_id', p_aviso.alerta_envejeciente_id, 'mensaje', p_aviso.mensaje,
    'estado', p_aviso.estado, 'fecha_notificacion', p_aviso.fecha_notificacion, 'fecha_lectura', p_aviso.fecha_lectura)
$$;

create function cuidared_api.api_notificaciones_alerta_listar(p_cuenta_id bigint, p_filtros jsonb, p_orden text[],
  p_limite integer, p_desplazamiento bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'alertas:ver')->>'usuario_id')::uuid;
  v_orden text := cuidared_interno.alerta_orden(p_orden, 'fecha_notificacion', 'notificacion_id');
  v_estado text := p_filtros->>'estado';
  v_resultado jsonb;
begin
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
    or jsonb_typeof(p_filtros) is distinct from 'object' or p_filtros - 'estado' <> '{}'::jsonb
    or (p_filtros ? 'estado' and (jsonb_typeof(p_filtros->'estado') is distinct from 'string'
      or v_estado not in ('no_leida', 'leida', 'archivada'))) then raise invalid_parameter_value; end if;
  execute format($q$
    with base as materialized (
      select n.notificacion_id, n.fecha_notificacion, cuidared_interno.aviso_alerta_json(n) datos
      from cuidared.notificacion n
      join cuidared.alerta_envejeciente a on a.alerta_envejeciente_id = n.alerta_envejeciente_id
      join cuidared.envejeciente e on e.envejeciente_id = a.envejeciente_id
      where n.usuario_id = $2 and e.cuenta_id = $1 and e.estado = 'activo'
        and (n.cuenta_id is null or n.cuenta_id = $1)
        and ($3::text is null or n.estado = $3)
        and cuidared_interno.alcanza_envejeciente($1, e.envejeciente_id, $2)
    ), pagina as (
      select b.datos, row_number() over (order by %1$s) posicion from base b
      order by %1$s limit $4 offset $5
    )
    select jsonb_build_object('total', (select count(*) from base),
      'items', coalesce(jsonb_agg(datos order by posicion), '[]'::jsonb)) from pagina
  $q$, v_orden) into v_resultado using p_cuenta_id, v_uid, v_estado, p_limite, p_desplazamiento;
  return v_resultado;
end;
$$;

create function cuidared_api.api_notificacion_alerta_leer(p_cuenta_id bigint, p_notificacion_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'alertas:ver')->>'usuario_id')::uuid;
  v_aviso cuidared.notificacion;
begin
  select n.* into v_aviso
  from cuidared.notificacion n
  join cuidared.alerta_envejeciente a on a.alerta_envejeciente_id = n.alerta_envejeciente_id
  join cuidared.envejeciente e on e.envejeciente_id = a.envejeciente_id
  where n.notificacion_id = p_notificacion_id and n.usuario_id = v_uid and e.cuenta_id = p_cuenta_id
    and e.estado = 'activo'
    and (n.cuenta_id is null or n.cuenta_id = p_cuenta_id)
    and cuidared_interno.alcanza_envejeciente(p_cuenta_id, e.envejeciente_id, v_uid)
  for update of n;
  if not found then raise no_data_found; end if;
  if v_aviso.estado = 'no_leida' then
    update cuidared.notificacion n set estado = 'leida', fecha_lectura = coalesce(n.fecha_lectura, now())
      where n.notificacion_id = p_notificacion_id returning n.* into v_aviso;
  end if;
  return cuidared_interno.aviso_alerta_json(v_aviso);
end;
$$;

revoke all on function cuidared_interno.alerta_es_prioritaria(text), cuidared_interno.alerta_orden(text[],text,text),
  cuidared_interno.alerta_json(cuidared.alerta_envejeciente,cuidared.envejeciente,cuidared.tipo_alerta,cuidared.prioridad),
  cuidared_interno.alerta_transicion(bigint,uuid,text,text),
  cuidared_interno.alertas_visibles(bigint,uuid), cuidared_interno.aviso_alerta_json(cuidared.notificacion)
  from public, anon, authenticated;
revoke all on function cuidared_api.api_alertas_listar(bigint,jsonb,text[],integer,bigint),
  cuidared_api.api_alerta_obtener(bigint,uuid), cuidared_api.api_alerta_resolver(bigint,uuid,text),
  cuidared_api.api_alerta_en_atencion(bigint,uuid),
  cuidared_api.api_casos_prioritarios_listar(bigint,jsonb,text[],integer,bigint),
  cuidared_api.api_notificaciones_alerta_listar(bigint,jsonb,text[],integer,bigint),
  cuidared_api.api_notificacion_alerta_leer(bigint,uuid) from public, anon;
grant execute on function cuidared_api.api_alertas_listar(bigint,jsonb,text[],integer,bigint),
  cuidared_api.api_alerta_obtener(bigint,uuid), cuidared_api.api_alerta_resolver(bigint,uuid,text),
  cuidared_api.api_alerta_en_atencion(bigint,uuid),
  cuidared_api.api_casos_prioritarios_listar(bigint,jsonb,text[],integer,bigint),
  cuidared_api.api_notificaciones_alerta_listar(bigint,jsonb,text[],integer,bigint),
  cuidared_api.api_notificacion_alerta_leer(bigint,uuid) to authenticated;

commit;
