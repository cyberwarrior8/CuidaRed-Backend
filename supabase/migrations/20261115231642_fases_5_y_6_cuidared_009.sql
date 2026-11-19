-- CUIDARED-009. Propuestas de Necesidades y Alertas aplicadas en una transacción.
begin;

-- ID05/RF-03. Base de necesidades por expediente. Propuesta para revisión, posterior a CUIDARED-008.

alter table cuidared.tipo_necesidad
  add column codigo text unique check (codigo ~ '^[a-z]+(_[a-z]+)*$');

insert into cuidared.tipo_necesidad(nombre,codigo) values
  ('Medicamentos','medicamentos'),
  ('Alimentación','alimentacion'),
  ('Transporte','transporte'),
  ('Compañía','compania'),
  ('Otros apoyos','otros_apoyos')
on conflict (nombre) do update set codigo = excluded.codigo;

insert into cuidared.necesidad(nombre,tipo_necesidad_id)
select t.nombre || ' (general)', t.tipo_necesidad_id
from cuidared.tipo_necesidad t
where t.codigo in ('medicamentos','alimentacion','transporte','compania','otros_apoyos')
on conflict (nombre) do nothing;

-- Una colisión con un ítem preexistente de otro tipo o inactivo se concilia de forma explícita.
do $$
begin
  if exists (
    select from cuidared.tipo_necesidad t
    where t.codigo in ('medicamentos','alimentacion','transporte','compania','otros_apoyos')
      and not exists (
        select from cuidared.necesidad n
        where n.nombre = t.nombre || ' (general)' and n.tipo_necesidad_id = t.tipo_necesidad_id and n.activo
      )
  ) then raise exception 'Revisar colisión en catálogo general de necesidades' using errcode = '23514'; end if;
end;
$$;

-- PostgreSQL exige retirar las dependencias directas antes de cambiar los tipos.
-- La vista de compatibilidad y el disparador anterior se restauran en esta transacción.
do $$
declare
  v_vista_oid regclass := to_regclass('cuidared.v_necesidades_activas');
  v_vista text;
  v_disparador text;
begin
  if v_vista_oid is not null then
    if exists (select from pg_catalog.pg_class c where c.oid = v_vista_oid
      and (c.relkind <> 'v' or pg_get_userbyid(c.relowner) <> current_user
        or c.relacl is not null or c.reloptions is distinct from array['security_invoker=true']
        or obj_description(c.oid,'pg_class') is not null))
      or exists (select from pg_catalog.pg_attribute a where a.attrelid = v_vista_oid
        and a.attnum > 0 and (a.attacl is not null or col_description(a.attrelid,a.attnum) is not null)) then
      raise exception 'Revisar los metadatos de cuidared.v_necesidades_activas antes de cambiar los tipos';
    end if;
    v_vista := pg_get_viewdef(v_vista_oid);
    drop view cuidared.v_necesidades_activas;
  end if;

  select pg_get_triggerdef(t.oid) into v_disparador from pg_catalog.pg_trigger t
    where t.tgrelid = 'cuidared.envejeciente_necesidad'::regclass
      and t.tgname = 'trg_envejeciente_necesidad_alerta' and t.tgenabled = 'O';
  if found then
    drop trigger trg_envejeciente_necesidad_alerta on cuidared.envejeciente_necesidad;
  end if;

  alter table cuidared.envejeciente_necesidad
    alter column cantidad type numeric,
    alter column unidad_medida type varchar(64);

  if v_disparador is not null then
    execute v_disparador;
  end if;
  if v_vista is not null then
    execute 'create view cuidared.v_necesidades_activas with (security_invoker = true) as ' || v_vista;
    if exists (select from pg_catalog.pg_class
      where oid = 'cuidared.v_necesidades_activas'::regclass and relacl is not null) then
      raise exception 'Revisar los permisos predeterminados de cuidared.v_necesidades_activas';
    end if;
  end if;
end;
$$;

alter table cuidared.envejeciente_necesidad
  add column registrado_por uuid references cuidared.usuario(usuario_id),
  add column resuelto_por uuid references cuidared.usuario(usuario_id);

create table cuidared.necesidad_evento (
  necesidad_evento_id uuid primary key default gen_random_uuid(),
  envejeciente_necesidad_id uuid not null references cuidared.envejeciente_necesidad(envejeciente_necesidad_id),
  usuario_id uuid references cuidared.usuario(usuario_id),
  fecha timestamptz not null,
  estado_anterior text check (estado_anterior in ('pendiente','en_proceso','resuelta','cancelada')),
  estado text not null check (estado in ('pendiente','en_proceso','resuelta','cancelada')),
  prioridad_anterior_id smallint references cuidared.prioridad(prioridad_id),
  prioridad_id smallint not null references cuidared.prioridad(prioridad_id),
  responsable_anterior_id uuid references cuidared.usuario(usuario_id),
  responsable_id uuid references cuidared.usuario(usuario_id),
  motivo text
);

create index ix_necesidades_expediente_fecha on cuidared.envejeciente_necesidad
  (envejeciente_id, fecha_necesidad desc, envejeciente_necesidad_id);
create index ix_necesidad_evento_ocurrencia_fecha on cuidared.necesidad_evento
  (envejeciente_necesidad_id, fecha desc, necesidad_evento_id);

alter table cuidared.envejeciente_necesidad enable row level security;
alter table cuidared.necesidad_evento enable row level security;
revoke all on cuidared.envejeciente_necesidad, cuidared.necesidad_evento from public, anon, authenticated;

-- En Supabase el trigger previo usaba la hora de inicio de la transacción (now()).
-- Una escritura que espere un bloqueo debe producir una versión posterior a la que acaba de leer.
create function cuidared_interno.necesidad_fijar_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.fecha_actualizacion := greatest(
    clock_timestamp(),
    date_trunc('milliseconds', old.fecha_actualizacion) + interval '1 millisecond'
  );
  return new;
end;
$$;

drop trigger if exists trg_envejeciente_necesidad_fecha_actualizacion on cuidared.envejeciente_necesidad;
create trigger trg_envejeciente_necesidad_fecha_actualizacion
  before update on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.necesidad_fijar_version();

create function cuidared_interno.necesidad_registrar_evento() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and
     (old.estado, old.prioridad_id, old.usuario_responsable_id)
       is not distinct from (new.estado, new.prioridad_id, new.usuario_responsable_id) then
    return new;
  end if;

  insert into cuidared.necesidad_evento (
    envejeciente_necesidad_id, usuario_id, fecha, estado_anterior, estado,
    prioridad_anterior_id, prioridad_id, responsable_anterior_id, responsable_id, motivo
  )
  values (
    new.envejeciente_necesidad_id, auth.uid(), new.fecha_actualizacion,
    case when tg_op = 'UPDATE' then old.estado end, new.estado,
    case when tg_op = 'UPDATE' then old.prioridad_id end, new.prioridad_id,
    case when tg_op = 'UPDATE' then old.usuario_responsable_id end, new.usuario_responsable_id,
    case when new.estado in ('resuelta','cancelada') and (tg_op = 'INSERT' or old.estado is distinct from new.estado)
      then new.motivo_resolucion end
  );
  return new;
end;
$$;

create trigger necesidad_registrar_evento
  after insert or update on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.necesidad_registrar_evento();

create function cuidared_interno.necesidad_json(p_necesidad_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'envejeciente_necesidad_id', en.envejeciente_necesidad_id,
    'envejeciente_id', en.envejeciente_id,
    'envejeciente_nombre', concat_ws(' ', e.nombres, e.apellidos),
    'envejeciente_estado', e.estado,
    'necesidad_id', en.necesidad_id,
    'necesidad_nombre', n.nombre,
    'tipo_necesidad_id', t.tipo_necesidad_id,
    'tipo_necesidad_nombre', t.nombre,
    'prioridad_id', en.prioridad_id,
    'prioridad', p.nombre,
    'estado', en.estado,
    'descripcion', en.descripcion,
    'cantidad', en.cantidad,
    'unidad_medida', en.unidad_medida,
    'fecha_necesidad', en.fecha_necesidad,
    'fecha_actualizacion', en.fecha_actualizacion,
    'usuario_responsable_id', u.usuario_id,
    'responsable', case when u.usuario_id is not null then concat_ws(' ',u.nombres,u.apellidos) end,
    'indicacion_medica_id', i.indicacion_medica_id,
    'fecha_resolucion', en.fecha_resolucion,
    'motivo_resolucion', en.motivo_resolucion,
    'registrado_por', autor.usuario_id,
    'resuelto_por', cierre.usuario_id,
    'es_recurrente', en.es_recurrente
  )
  from cuidared.envejeciente_necesidad en
  join cuidared.envejeciente e using (envejeciente_id)
  join cuidared.necesidad n using (necesidad_id)
  join cuidared.tipo_necesidad t using (tipo_necesidad_id)
  join cuidared.prioridad p using (prioridad_id)
  left join cuidared.indicacion_medica i on i.indicacion_medica_id = en.indicacion_medica_id
    and i.envejeciente_id = en.envejeciente_id
    and cuidared_interno.tiene_permiso(e.cuenta_id, auth.uid(), 'indicaciones:ver')
  left join cuidared.usuario u on u.usuario_id = en.usuario_responsable_id and exists (
    select from cuidared.membresia m where m.usuario_id = u.usuario_id and m.cuenta_id = e.cuenta_id
  )
  left join cuidared.usuario autor on autor.usuario_id = en.registrado_por and exists (
    select from cuidared.membresia m where m.usuario_id = autor.usuario_id and m.cuenta_id = e.cuenta_id
  )
  left join cuidared.usuario cierre on cierre.usuario_id = en.resuelto_por and exists (
    select from cuidared.membresia m where m.usuario_id = cierre.usuario_id and m.cuenta_id = e.cuenta_id
  )
  where en.envejeciente_necesidad_id = p_necesidad_id
$$;

create function cuidared_interno.necesidad_exigir(
  p_cuenta_id bigint, p_necesidad_id uuid, p_accion text
) returns uuid
language plpgsql set search_path = '' as $$
declare
  v_usuario uuid := (cuidared_interno.exigir(p_cuenta_id, p_accion)->>'usuario_id')::uuid;
begin
  if not exists (
    select from cuidared.envejeciente_necesidad en
    where en.envejeciente_necesidad_id = p_necesidad_id
      and cuidared_interno.alcanza_envejeciente(p_cuenta_id, en.envejeciente_id, v_usuario)
  ) then raise no_data_found; end if;
  return v_usuario;
end;
$$;

create function cuidared_api.api_necesidad_obtener(p_cuenta_id bigint, p_necesidad_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.necesidad_exigir(p_cuenta_id, p_necesidad_id, 'necesidades:ver');
  return cuidared_interno.necesidad_json(p_necesidad_id);
end;
$$;

create function cuidared_api.api_necesidades_listar(
  p_cuenta_id bigint, p_filtros jsonb, p_orden jsonb, p_limite integer, p_desplazamiento bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'necesidades:ver')->>'usuario_id')::uuid;
  v_adulto uuid;
  v_estado text;
  v_prioridad smallint;
  v_tipo smallint;
  v_activas boolean;
  v_token text;
  v_campo text;
  v_cols text[] := '{}';
  v_orden text[] := '{}';
  v_resultado jsonb;
begin
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(p_filtros) is distinct from 'object'
     or p_filtros - array['envejeciente_id','estado','activas','prioridad_id','tipo_necesidad_id'] <> '{}'::jsonb
     or jsonb_typeof(p_orden) is distinct from 'array'
     or jsonb_array_length(p_orden) not between 1 and 4
     or (p_filtros ? 'activas' and p_filtros->'activas' is distinct from 'true'::jsonb) then
    raise invalid_parameter_value;
  end if;
  v_adulto := cuidared_interno.v_uuid(p_filtros->'envejeciente_id', false);
  v_estado := cuidared_interno.v_texto(p_filtros->'estado', 1, 12, false);
  v_prioridad := cuidared_interno.seg_entero_campo(p_filtros->'prioridad_id', 1, 32767);
  v_tipo := cuidared_interno.seg_entero_campo(p_filtros->'tipo_necesidad_id', 1, 32767);
  v_activas := p_filtros ? 'activas';
  if (v_estado is not null and v_estado not in ('pendiente','en_proceso','resuelta','cancelada'))
     or (p_filtros ? 'estado' and v_estado is null)
     or (p_filtros ? 'envejeciente_id' and v_adulto is null)
     or (p_filtros ? 'prioridad_id' and v_prioridad is null)
     or (p_filtros ? 'tipo_necesidad_id' and v_tipo is null) then raise invalid_parameter_value; end if;
  if v_adulto is not null and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_adulto, v_uid) then
    raise no_data_found;
  end if;

  for v_token in select jsonb_array_elements_text(p_orden) loop
    v_campo := case regexp_replace(v_token, '^-', '')
      when 'fecha_necesidad' then 'fecha_necesidad'
      when 'prioridad' then 'prioridad_orden'
      when 'estado' then 'estado'
      when 'envejeciente_necesidad_id' then 'envejeciente_necesidad_id'
    end;
    if v_campo is null or v_campo = any (v_cols) then raise invalid_parameter_value; end if;
    v_cols := array_append(v_cols, v_campo);
    v_orden := array_append(v_orden, 'n.' || v_campo || case when left(v_token,1) = '-' then ' desc' else ' asc' end);
  end loop;
  if not ('envejeciente_necesidad_id' = any(v_cols)) then
    v_orden := array_append(v_orden, 'n.envejeciente_necesidad_id asc');
  end if;

  execute format($sql$
    with autorizadas as materialized (
      select e.envejeciente_id from cuidared.envejeciente e
      where e.cuenta_id = $1 and ($3 is null or e.envejeciente_id = $3)
        and cuidared_interno.alcanza_envejeciente($1, e.envejeciente_id, $2)
    ), necesidades as materialized (
      select en.envejeciente_necesidad_id, en.fecha_necesidad, en.estado, p.orden prioridad_orden
      from autorizadas a
      join cuidared.envejeciente_necesidad en using (envejeciente_id)
      join cuidared.necesidad c using (necesidad_id)
      join cuidared.prioridad p using (prioridad_id)
      where ($4 is null or en.estado = $4) and (not $5 or en.estado in ('pendiente','en_proceso'))
        and ($6 is null or en.prioridad_id = $6) and ($7 is null or c.tipo_necesidad_id = $7)
    ), pagina as (
      select n.envejeciente_necesidad_id, row_number() over (order by %1$s) posicion
      from necesidades n order by posicion limit $8 offset $9
    )
    select jsonb_build_object(
      'items', coalesce(jsonb_agg(cuidared_interno.necesidad_json(p.envejeciente_necesidad_id) order by p.posicion), '[]'::jsonb),
      'total', (select count(*) from necesidades)
    ) from pagina p
  $sql$, array_to_string(v_orden, ', '))
  into v_resultado using p_cuenta_id, v_uid, v_adulto, v_estado, v_activas, v_prioridad, v_tipo, p_limite, p_desplazamiento;
  return v_resultado;
end;
$$;

create function cuidared_api.api_necesidad_historial(
  p_cuenta_id bigint, p_necesidad_id uuid, p_orden jsonb, p_limite integer, p_desplazamiento bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_campo text;
  v_cols text[] := '{}';
  v_orden text[] := '{}';
  v_resultado jsonb;
begin
  perform cuidared_interno.necesidad_exigir(p_cuenta_id, p_necesidad_id, 'necesidades:ver');
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) not between 1 and 2 then
    raise invalid_parameter_value;
  end if;
  for v_token in select jsonb_array_elements_text(p_orden) loop
    v_campo := regexp_replace(v_token, '^-', '');
    if v_campo is null or v_campo not in ('fecha','necesidad_evento_id')
       or v_campo = any(v_cols) then raise invalid_parameter_value; end if;
    v_cols := array_append(v_cols, v_campo);
    v_orden := array_append(v_orden, 'h.' || v_campo || case when left(v_token,1) = '-' then ' desc' else ' asc' end);
  end loop;
  if not ('necesidad_evento_id' = any(v_cols)) then v_orden := array_append(v_orden, 'h.necesidad_evento_id asc'); end if;

  execute format($sql$
    with pagina as (
      select h.*, row_number() over (order by %1$s) posicion
      from cuidared.necesidad_evento h where h.envejeciente_necesidad_id = $1
      order by posicion limit $2 offset $3
    )
    select jsonb_build_object(
      'items', coalesce(jsonb_agg(jsonb_build_object(
        'necesidad_evento_id', h.necesidad_evento_id, 'fecha', h.fecha,
        'actor', case when u.usuario_id is not null then concat_ws(' ',u.nombres,u.apellidos) end,
        'estado_anterior', h.estado_anterior, 'estado', h.estado,
        'prioridad_id', p.prioridad_id, 'prioridad', p.nombre, 'prioridad_anterior', pa.nombre,
        'responsable_anterior', case when anterior.usuario_id is not null then concat_ws(' ',anterior.nombres,anterior.apellidos) end,
        'responsable', case when actual.usuario_id is not null then concat_ws(' ',actual.nombres,actual.apellidos) end,
        'motivo', h.motivo
      ) order by h.posicion), '[]'::jsonb),
      'total', (select count(*) from cuidared.necesidad_evento h2 where h2.envejeciente_necesidad_id = $1)
    ) from pagina h join cuidared.prioridad p using (prioridad_id)
    left join cuidared.prioridad pa on pa.prioridad_id = h.prioridad_anterior_id
    left join cuidared.usuario u on u.usuario_id = h.usuario_id and exists (
      select from cuidared.membresia m where m.usuario_id = u.usuario_id and m.cuenta_id = $4
    )
    left join cuidared.usuario anterior on anterior.usuario_id = h.responsable_anterior_id and exists (
      select from cuidared.membresia m where m.usuario_id = anterior.usuario_id and m.cuenta_id = $4
    )
    left join cuidared.usuario actual on actual.usuario_id = h.responsable_id and exists (
      select from cuidared.membresia m where m.usuario_id = actual.usuario_id and m.cuenta_id = $4
    )
  $sql$, array_to_string(v_orden, ', '))
  into v_resultado using p_necesidad_id,p_limite,p_desplazamiento,p_cuenta_id;
  return v_resultado;
end;
$$;

create function cuidared_interno.necesidad_responsable_valido(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_responsable_id uuid
) returns boolean language sql stable set search_path = '' as $$
  select cuidared_interno.tiene_permiso(p_cuenta_id, p_responsable_id, 'necesidades:actualizar')
    and cuidared_interno.alcanza_envejeciente(p_cuenta_id, p_envejeciente_id, p_responsable_id)
$$;

create function cuidared_interno.necesidad_adulto_activo(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_uid uuid
) returns void language plpgsql set search_path = '' as $$
declare v_estado text;
begin
  select e.estado into v_estado from cuidared.envejeciente e
  where e.cuenta_id = p_cuenta_id and e.envejeciente_id = p_envejeciente_id for share;
  if not found or not cuidared_interno.alcanza_envejeciente(p_cuenta_id,p_envejeciente_id,p_uid) then
    raise no_data_found;
  end if;
  if v_estado is distinct from 'activo' then
    raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001';
  end if;
end;
$$;

create function cuidared_interno.necesidad_para_actualizar(
  p_cuenta_id bigint, p_necesidad_id uuid
) returns cuidared.envejeciente_necesidad language plpgsql set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id,'necesidades:actualizar')->>'usuario_id')::uuid;
  v_ocurrencia cuidared.envejeciente_necesidad;
begin
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  v_uid := (cuidared_interno.exigir(p_cuenta_id,'necesidades:actualizar')->>'usuario_id')::uuid;
  select en.* into v_ocurrencia
    from cuidared.envejeciente_necesidad en join cuidared.envejeciente e using (envejeciente_id)
    where en.envejeciente_necesidad_id = p_necesidad_id and e.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  perform cuidared_interno.necesidad_adulto_activo(p_cuenta_id,v_ocurrencia.envejeciente_id,v_uid);
  select en.* into v_ocurrencia from cuidared.envejeciente_necesidad en
    where en.envejeciente_necesidad_id = p_necesidad_id for update;
  if not found then raise no_data_found; end if;
  if v_ocurrencia.estado not in ('pendiente','en_proceso') then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  return v_ocurrencia;
end;
$$;

create function cuidared_interno.necesidad_crear(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_necesidad_id uuid, p_datos jsonb
) returns jsonb language plpgsql set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id,'necesidades:registrar')->>'usuario_id')::uuid;
  v_catalogo smallint;
  v_prioridad smallint;
  v_descripcion text;
  v_cantidad numeric;
  v_unidad text;
  v_indicacion uuid;
  v_responsable uuid;
  v_recurrente boolean := false;
  v_fecha timestamptz;
begin
  if p_necesidad_id is null or jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['necesidad_id','prioridad_id','descripcion','cantidad','unidad_medida','indicacion_medica_id','usuario_responsable_id','es_recurrente'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_catalogo := cuidared_interno.seg_entero_campo(p_datos->'necesidad_id',1,32767);
  v_prioridad := cuidared_interno.seg_entero_campo(p_datos->'prioridad_id',1,32767);
  v_descripcion := cuidared_interno.v_texto(p_datos->'descripcion',5,500);
  v_unidad := cuidared_interno.v_texto(p_datos->'unidad_medida',1,64,false);
  v_indicacion := cuidared_interno.v_uuid(p_datos->'indicacion_medica_id',false);
  v_responsable := cuidared_interno.v_uuid(p_datos->'usuario_responsable_id',false);
  if p_datos ? 'cantidad' and jsonb_typeof(p_datos->'cantidad') <> 'null' then
    if jsonb_typeof(p_datos->'cantidad') <> 'number' then raise invalid_parameter_value; end if;
    v_cantidad := (p_datos->>'cantidad')::numeric;
    if v_cantidad <= 0 or v_cantidad > 10000 then raise invalid_parameter_value; end if;
  end if;
  if (p_datos ? 'es_recurrente') then
    if jsonb_typeof(p_datos->'es_recurrente') <> 'boolean' then raise invalid_parameter_value; end if;
    v_recurrente := (p_datos->>'es_recurrente')::boolean;
  end if;
  if (v_cantidad is null) <> (v_unidad is null) or v_catalogo is null or v_prioridad is null then
    raise invalid_parameter_value;
  end if;

  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  v_uid := (cuidared_interno.exigir(p_cuenta_id,'necesidades:registrar')->>'usuario_id')::uuid;
  perform cuidared_interno.necesidad_adulto_activo(p_cuenta_id,p_envejeciente_id,v_uid);
  if not exists (select from cuidared.necesidad n where n.necesidad_id = v_catalogo and n.activo)
     or not exists (select from cuidared.prioridad p where p.prioridad_id = v_prioridad)
     or (v_indicacion is not null and (
       not cuidared_interno.tiene_permiso(p_cuenta_id,v_uid,'indicaciones:ver')
       or not exists (select from cuidared.indicacion_medica i
                      where i.indicacion_medica_id = v_indicacion and i.envejeciente_id = p_envejeciente_id))) then
    raise invalid_parameter_value;
  end if;
  if v_responsable is not null and not cuidared_interno.necesidad_responsable_valido(p_cuenta_id,p_envejeciente_id,v_responsable) then
    raise exception 'CR_RESPONSABLE_NECESIDAD_INVALIDO' using errcode = 'P0001';
  end if;

  v_fecha := clock_timestamp();
  insert into cuidared.envejeciente_necesidad(
    envejeciente_necesidad_id,envejeciente_id,necesidad_id,prioridad_id,descripcion,cantidad,unidad_medida,
    indicacion_medica_id,usuario_responsable_id,es_recurrente,registrado_por,fecha_necesidad,fecha_actualizacion
  ) values (
    p_necesidad_id,p_envejeciente_id,v_catalogo,v_prioridad,v_descripcion,v_cantidad,v_unidad,
    v_indicacion,v_responsable,v_recurrente,v_uid,v_fecha,v_fecha
  );
  return cuidared_interno.necesidad_json(p_necesidad_id);
end;
$$;

create function cuidared_interno.necesidad_actualizar(
  p_cuenta_id bigint, p_necesidad_id uuid, p_datos jsonb
) returns jsonb language plpgsql set search_path = '' as $$
declare
  v_ocurrencia cuidared.envejeciente_necesidad := cuidared_interno.necesidad_para_actualizar(p_cuenta_id,p_necesidad_id);
  v_prioridad smallint := v_ocurrencia.prioridad_id;
  v_responsable uuid := v_ocurrencia.usuario_responsable_id;
begin
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos = '{}'::jsonb
     or p_datos - array['prioridad_id','usuario_responsable_id'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  if p_datos ? 'prioridad_id' then
    v_prioridad := cuidared_interno.seg_entero_campo(p_datos->'prioridad_id',1,32767);
    if v_prioridad is null or not exists (select from cuidared.prioridad p where p.prioridad_id = v_prioridad) then
      raise invalid_parameter_value;
    end if;
  end if;
  if p_datos ? 'usuario_responsable_id' then
    v_responsable := cuidared_interno.v_uuid(p_datos->'usuario_responsable_id',false);
    if v_responsable is not null and not cuidared_interno.necesidad_responsable_valido(p_cuenta_id,v_ocurrencia.envejeciente_id,v_responsable) then
      raise exception 'CR_RESPONSABLE_NECESIDAD_INVALIDO' using errcode = 'P0001';
    end if;
  end if;
  if (v_prioridad,v_responsable) is distinct from (v_ocurrencia.prioridad_id,v_ocurrencia.usuario_responsable_id) then
    update cuidared.envejeciente_necesidad set prioridad_id = v_prioridad, usuario_responsable_id = v_responsable
      where envejeciente_necesidad_id = p_necesidad_id;
  end if;
  return cuidared_interno.necesidad_json(p_necesidad_id);
end;
$$;

create function cuidared_interno.necesidad_cambiar_estado(
  p_cuenta_id bigint, p_necesidad_id uuid, p_datos jsonb
) returns jsonb language plpgsql set search_path = '' as $$
declare
  v_ocurrencia cuidared.envejeciente_necesidad := cuidared_interno.necesidad_para_actualizar(p_cuenta_id,p_necesidad_id);
  v_estado text;
  v_motivo text;
  v_cerrada boolean;
  v_fecha timestamptz;
begin
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['estado','motivo'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_estado := cuidared_interno.v_texto(p_datos->'estado',1,12);
  if v_estado not in ('en_proceso','resuelta','cancelada') then raise invalid_parameter_value; end if;
  if v_ocurrencia.estado = v_estado then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  v_cerrada := v_estado in ('resuelta','cancelada');
  if v_cerrada then
    v_motivo := cuidared_interno.v_texto(p_datos->'motivo',3,500);
  elsif p_datos ? 'motivo' then
    raise invalid_parameter_value;
  end if;
  v_fecha := clock_timestamp();
  update cuidared.envejeciente_necesidad set estado = v_estado,
    fecha_resolucion = case when v_cerrada then v_fecha end,
    resuelto_por = case when v_cerrada then auth.uid() end,
    motivo_resolucion = v_motivo
    where envejeciente_necesidad_id = p_necesidad_id;
  return cuidared_interno.necesidad_json(p_necesidad_id);
end;
$$;

create function cuidared_api.api_necesidad_crear(p_cuenta_id bigint,p_envejeciente_id uuid,p_datos jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  select cuidared_interno.necesidad_crear(p_cuenta_id,p_envejeciente_id,gen_random_uuid(),p_datos)
$$;
create function cuidared_api.api_necesidad_actualizar(p_cuenta_id bigint,p_necesidad_id uuid,p_datos jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  select cuidared_interno.necesidad_actualizar(p_cuenta_id,p_necesidad_id,p_datos)
$$;
create function cuidared_api.api_necesidad_estado(p_cuenta_id bigint,p_necesidad_id uuid,p_datos jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  select cuidared_interno.necesidad_cambiar_estado(p_cuenta_id,p_necesidad_id,p_datos)
$$;

create function cuidared_api.api_necesidad_candidatos(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_orden jsonb, p_limite integer, p_desplazamiento bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_accion text;
  v_token text;
  v_campo text;
  v_cols text[] := '{}';
  v_orden text[] := '{}';
  v_resultado jsonb;
begin
  v_accion := case when cuidared_interno.tiene_permiso(p_cuenta_id,v_uid,'necesidades:registrar')
    then 'necesidades:registrar' else 'necesidades:actualizar' end;
  perform cuidared_interno.exigir(p_cuenta_id,v_accion);
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id,p_envejeciente_id,v_uid) then raise no_data_found; end if;
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) not between 1 and 2 then
    raise invalid_parameter_value;
  end if;
  for v_token in select jsonb_array_elements_text(p_orden) loop
    v_campo := regexp_replace(v_token, '^-', '');
    if v_campo is null or v_campo not in ('nombre','usuario_id')
       or v_campo = any(v_cols) then raise invalid_parameter_value; end if;
    v_cols := array_append(v_cols, v_campo);
    v_orden := array_append(v_orden, 'c.' || v_campo || case when left(v_token,1) = '-' then ' desc' else ' asc' end);
  end loop;
  if not ('usuario_id' = any(v_cols)) then v_orden := array_append(v_orden,'c.usuario_id asc'); end if;
  execute format($sql$
    with candidatos as materialized (
      select distinct u.usuario_id, concat_ws(' ',u.nombres,u.apellidos) as nombre
      from cuidared.membresia m join cuidared.usuario u using (usuario_id)
      where m.cuenta_id = $1 and m.estado = 'activa'
        and cuidared_interno.necesidad_responsable_valido($1,$2,u.usuario_id)
    ), pagina as (
      select c.*, row_number() over (order by %1$s) posicion
      from candidatos c order by posicion limit $3 offset $4
    )
    select jsonb_build_object(
      'items',coalesce(jsonb_agg(jsonb_build_object('usuario_id',p.usuario_id,'nombre',p.nombre)
        order by p.posicion),'[]'::jsonb),
      'total',(select count(*) from candidatos)
    ) from pagina p
  $sql$,array_to_string(v_orden,', '))
  into v_resultado using p_cuenta_id,p_envejeciente_id,p_limite,p_desplazamiento;
  return v_resultado;
end;
$$;

revoke all on function cuidared_interno.necesidad_fijar_version(), cuidared_interno.necesidad_registrar_evento(),
  cuidared_interno.necesidad_json(uuid),
  cuidared_interno.necesidad_exigir(bigint,uuid,text),
  cuidared_interno.necesidad_responsable_valido(bigint,uuid,uuid),
  cuidared_interno.necesidad_adulto_activo(bigint,uuid,uuid),
  cuidared_interno.necesidad_para_actualizar(bigint,uuid),
  cuidared_interno.necesidad_crear(bigint,uuid,uuid,jsonb),
  cuidared_interno.necesidad_actualizar(bigint,uuid,jsonb),
  cuidared_interno.necesidad_cambiar_estado(bigint,uuid,jsonb) from public, anon, authenticated;

revoke all on function cuidared_api.api_necesidad_obtener(bigint,uuid),
  cuidared_api.api_necesidades_listar(bigint,jsonb,jsonb,integer,bigint),
  cuidared_api.api_necesidad_historial(bigint,uuid,jsonb,integer,bigint),
  cuidared_api.api_necesidad_crear(bigint,uuid,jsonb),
  cuidared_api.api_necesidad_actualizar(bigint,uuid,jsonb),
  cuidared_api.api_necesidad_estado(bigint,uuid,jsonb),
  cuidared_api.api_necesidad_candidatos(bigint,uuid,jsonb,integer,bigint) from public, anon;
grant execute on function cuidared_api.api_necesidad_obtener(bigint,uuid),
  cuidared_api.api_necesidades_listar(bigint,jsonb,jsonb,integer,bigint),
  cuidared_api.api_necesidad_historial(bigint,uuid,jsonb,integer,bigint),
  cuidared_api.api_necesidad_crear(bigint,uuid,jsonb),
  cuidared_api.api_necesidad_actualizar(bigint,uuid,jsonb),
  cuidared_api.api_necesidad_estado(bigint,uuid,jsonb),
  cuidared_api.api_necesidad_candidatos(bigint,uuid,jsonb,integer,bigint) to authenticated;

-- ID05/RF-10: extender el contrato de sincronización aplicado en 4c.
-- Propuesta local; ejecutar después de fase-5-necesidades.sql.

create function cuidared_interno.sync_necesidad(
  p_cuenta_id bigint, p_usuario_id uuid, p_id_cliente uuid, p_tipo text, p_registro_id uuid,
  p_datos jsonb, p_cliente timestamptz, p_base timestamptz,
  out o_resultado text, out o_motivo text, out o_gana text, out o_servidor timestamptz
) returns record
language plpgsql set search_path = '' as $$
declare
  v_adulto uuid;
  v_actual cuidared.envejeciente_necesidad;
  v_productor uuid;
  v_marca_productor timestamptz;
  v_marca_servidor timestamptz;
  v_base_cambio boolean;
  v_gana_local boolean := false;
begin
  -- Mismo orden de bloqueos que las escrituras en línea y los cambios de membresía.
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);

  if p_tipo = 'registrar' then
    if p_base is not null then raise invalid_parameter_value; end if;
    v_adulto := cuidared_interno.v_uuid(p_datos->'envejeciente_id');
    perform cuidared_interno.necesidad_crear(p_cuenta_id, v_adulto, p_registro_id, p_datos - 'envejeciente_id');
    o_resultado := 'aplicada';
    select n.fecha_actualizacion into o_servidor
      from cuidared.envejeciente_necesidad n where n.envejeciente_necesidad_id = p_registro_id;
    return;
  end if;

  perform cuidared_interno.necesidad_exigir(p_cuenta_id, p_registro_id, 'necesidades:actualizar');
  perform 1 from cuidared.envejeciente e join cuidared.envejeciente_necesidad n using (envejeciente_id)
    where n.envejeciente_necesidad_id = p_registro_id and e.cuenta_id = p_cuenta_id
      and e.estado = 'activo' and e.consentimiento_retirado_en is null for share of e;
  if not found then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;
  select * into strict v_actual from cuidared.envejeciente_necesidad n
    where n.envejeciente_necesidad_id = p_registro_id for update;
  o_servidor := v_actual.fecha_actualizacion;

  if exists (select from cuidared.operacion_sync o
    where o.cuenta_id = p_cuenta_id and o.usuario_id = p_usuario_id and o.entidad = 'necesidad'
      and o.tipo = p_tipo and o.registro_id = p_registro_id and o.actualizado_en_cliente = p_cliente
      and o.id_cliente <> p_id_cliente and o.resultado <> 'rechazada') then
    o_resultado := 'duplicada';
    return;
  end if;

  -- La versión producida por sync se compara con el instante original de la captura.
  select o.usuario_id, o.actualizado_en_cliente into v_productor, v_marca_productor
    from cuidared.operacion_sync o
    where o.cuenta_id = p_cuenta_id and o.entidad = 'necesidad' and o.registro_id = p_registro_id
      and (o.resultado = 'aplicada' or (o.resultado = 'conflicto' and o.gana = 'local'))
      and o.actualizado_en_servidor = v_actual.fecha_actualizacion
    order by o.procesada_en desc, o.id_cliente
    limit 1;
  v_marca_servidor := cuidared_interno.sync_ms(coalesce(v_marca_productor, v_actual.fecha_actualizacion));
  v_base_cambio := p_base is null or cuidared_interno.sync_ms(o_servidor) > cuidared_interno.sync_ms(p_base);

  if v_actual.estado in ('resuelta','cancelada') then
    if not v_base_cambio then raise exception 'CR_NECESIDAD_CERRADA' using errcode = 'P0001'; end if;
    o_resultado := 'conflicto'; o_gana := 'servidor'; o_motivo := 'NEED_CLOSED';
    return;
  end if;
  if v_base_cambio and not (v_productor is not distinct from p_usuario_id and v_marca_servidor <= cuidared_interno.sync_ms(p_cliente)) then
    if v_marca_servidor >= cuidared_interno.sync_ms(p_cliente) then
      o_resultado := 'conflicto'; o_gana := 'servidor'; o_motivo := 'SERVIDOR_MAS_RECIENTE';
      return;
    end if;
    v_gana_local := true;
  end if;

  perform cuidared_interno.necesidad_cambiar_estado(p_cuenta_id, p_registro_id, p_datos);
  o_resultado := case when v_gana_local then 'conflicto' else 'aplicada' end;
  o_gana := case when v_gana_local then 'local' end;
  select n.fecha_actualizacion into o_servidor
    from cuidared.envejeciente_necesidad n where n.envejeciente_necesidad_id = p_registro_id;
exception when unique_violation then
  -- Un registro ya existente con otro id_cliente no constituye un alta nueva.
  if p_tipo = 'registrar' then raise no_data_found; end if;
  raise;
end;
$$;
revoke all on function cuidared_interno.sync_necesidad(bigint,uuid,uuid,text,uuid,jsonb,timestamptz,timestamptz)
  from public, anon, authenticated;

create or replace function cuidared_api.api_sync_aplicar_operacion(p_cuenta_id bigint, p_operacion jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_id uuid;
  v_registro uuid;
  v_entidad text;
  v_tipo text;
  v_datos jsonb;
  v_cliente timestamp with time zone;
  v_base timestamp with time zone;
  v_ahora timestamp with time zone := pg_catalog.now();
  v_previa cuidared.operacion_sync;
  v_hay_previa boolean;
  v_res record;
  v_resultado text;
  v_motivo text;
  v_gana text;
  v_servidor timestamp with time zone;
  v_original text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or jsonb_typeof(p_operacion) is distinct from 'object'
     or length(p_operacion::text) > 65536
     or p_operacion - array['id_cliente', 'entidad', 'tipo', 'registro_id', 'datos', 'actualizado_en', 'base_actualizado_en']
        <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  -- Sin membresía activa o sin sync:usar no hay nada que registrar: 403 y no se guarda nada.
  if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'sync:usar') then
    raise insufficient_privilege;
  end if;

  v_id := cuidared_interno.v_uuid(p_operacion->'id_cliente');
  v_registro := cuidared_interno.v_uuid(p_operacion->'registro_id');
  v_entidad := cuidared_interno.v_texto(p_operacion->'entidad', 1, 30);
  v_tipo := cuidared_interno.v_texto(p_operacion->'tipo', 1, 30);
  if v_entidad !~ '^[a-z][a-z_]{0,29}$' or v_tipo !~ '^[a-z][a-z_]{0,29}$'
     or jsonb_typeof(p_operacion->'datos') is distinct from 'object' then
    raise invalid_parameter_value;
  end if;
  v_datos := p_operacion->'datos';
  v_cliente := cuidared_interno.v_marca(p_operacion->'actualizado_en');
  v_base := cuidared_interno.v_marca(p_operacion->'base_actualizado_en', false);

  -- Serializa los reintentos con la misma clave: el segundo espera y ve la fila ya escrita.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id::text, 1));
  select * into v_previa from cuidared.operacion_sync o where o.id_cliente = v_id;
  v_hay_previa := found;

  -- La clave es de una sola operación de una sola persona en una sola cuenta: cualquier otro uso se rechaza sin revelar nada
  -- de la fila existente ni modificarla.
  if v_hay_previa and (v_previa.usuario_id <> v_uid or v_previa.cuenta_id <> p_cuenta_id or v_previa.entidad::text <> v_entidad
                       or v_previa.tipo::text <> v_tipo or v_previa.registro_id <> v_registro) then
    return cuidared_interno.sync_item(v_id, v_registro, 'rechazada', 'ID_CLIENTE_EN_USO', null, null, null);
  end if;

  begin
    if not cuidared_interno.acceso_operativo(p_cuenta_id) then
      -- D07: sin escrituras operativas. Es transitorio: al renovar la cuenta el mismo reintento se resuelve.
      v_resultado := 'rechazada'; v_motivo := 'SUBSCRIPTION_INACTIVE';
    elsif v_hay_previa and v_previa.resultado::text <> 'rechazada' then
      -- Reintento de una operación ya resuelta: se devuelve lo resuelto, sin aplicar nada.
      if v_entidad = 'necesidad' then
        perform cuidared_interno.necesidad_exigir(p_cuenta_id, v_registro,
          case v_tipo when 'registrar' then 'necesidades:registrar' else 'necesidades:actualizar' end);
      else
        perform cuidared_interno.exigir_operar_visita(p_cuenta_id, v_registro, v_uid);
      end if;
      v_resultado := 'duplicada'; v_original := v_previa.resultado::text; v_motivo := v_previa.motivo::text;
      v_gana := v_previa.gana::text; v_servidor := v_previa.actualizado_en_servidor;
    elsif v_entidad not in ('visita', 'necesidad') then
      v_resultado := 'rechazada'; v_motivo := 'ENTIDAD_NO_SOPORTADA';
    elsif (v_entidad = 'visita' and v_tipo not in ('registrar', 'iniciar'))
       or (v_entidad = 'necesidad' and v_tipo not in ('registrar', 'cambiar_estado')) then
      v_resultado := 'rechazada'; v_motivo := 'TIPO_NO_SOPORTADO';
    elsif v_cliente > v_ahora + interval '5 minutes' or v_base > v_ahora + interval '5 minutes' then
      v_resultado := 'rechazada'; v_motivo := 'RELOJ_INVALIDO';
    else
      if v_entidad = 'necesidad' then
        select * into v_res from cuidared_interno.sync_necesidad(
          p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      else
        select * into v_res from cuidared_interno.sync_visita(
          p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      end if;
      v_resultado := v_res.o_resultado; v_motivo := v_res.o_motivo; v_gana := v_res.o_gana; v_servidor := v_res.o_servidor;
    end if;
  exception
    -- Las reglas incumplidas son el resultado de ESTA operación; la subtransacción deshace lo que haya escrito.
    when insufficient_privilege then
      v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN'; v_gana := null; v_servidor := null;
    when no_data_found then
      v_resultado := 'rechazada'; v_motivo := 'NOT_FOUND'; v_gana := null; v_servidor := null;
    when data_exception or check_violation then
      v_resultado := 'rechazada'; v_motivo := 'INVALID_INPUT'; v_gana := null; v_servidor := null;
    when raise_exception then
      v_gana := null; v_servidor := null;
      case sqlerrm
        when 'CR_CUENTA_SIN_ACCESO' then v_resultado := 'rechazada'; v_motivo := 'SUBSCRIPTION_INACTIVE';
        when 'CR_LIMITE_PLAN' then v_resultado := 'rechazada'; v_motivo := 'PLAN_LIMIT_REACHED';
        when 'CR_VISITA_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'VISIT_CLOSED';
        when 'CR_ESTADO_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_ADULTO_INACTIVO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_NECESIDAD_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'NEED_CLOSED';
        when 'CR_RESPONSABLE_NECESIDAD_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_NEED_ASSIGNEE';
        when 'CR_NO_PARTICIPA' then v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN';
        when 'CR_CONFLICTO' then v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN';
        else raise;
      end case;
  end;

  -- Un reintento de una operación ya resuelta no escribe nada (la fila original se conserva).
  if v_original is null then
    perform cuidared_interno.sync_registrar(v_id, v_uid, p_cuenta_id, v_entidad, v_tipo, v_registro, v_resultado, v_motivo,
                                            v_gana, v_cliente, v_base, v_servidor);
  end if;
  return cuidared_interno.sync_item(v_id, v_registro, v_resultado, v_motivo, v_gana, v_original, v_servidor);
end $$;

-- Resultado de una operación propia (para el cliente que reintenta después de perder la respuesta). Otra persona, otra cuenta o
-- una clave inexistente: P0002 (404), sin distinguir cuál. Como toda lectura operativa, se bloquea en una cuenta vencida.
create or replace function cuidared_api.api_sync_obtener_operacion(p_cuenta_id bigint, p_id_cliente uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid; v_o cuidared.operacion_sync; v_permiso text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_id_cliente is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'sync:usar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  select * into v_o from cuidared.operacion_sync o
    where o.id_cliente = p_id_cliente and o.usuario_id = v_uid and o.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if v_o.entidad = 'necesidad' then
    v_permiso := case v_o.tipo when 'registrar' then 'necesidades:registrar' else 'necesidades:actualizar' end;
    if v_o.resultado = 'rechazada' and v_o.actualizado_en_servidor is null then
      -- Un rechazo sin versión solo informa del intento propio, aunque el registro nunca se haya creado.
      perform cuidared_interno.exigir(p_cuenta_id, v_permiso);
    else
      perform cuidared_interno.necesidad_exigir(p_cuenta_id, v_o.registro_id, v_permiso);
    end if;
  end if;
  return cuidared_interno.sync_item(v_o.id_cliente, v_o.registro_id, v_o.resultado::text, v_o.motivo::text, v_o.gana::text, null,
                                    v_o.actualizado_en_servidor)
    || jsonb_build_object('entidad', v_o.entidad, 'tipo', v_o.tipo, 'procesada_en', cuidared_interno.sync_iso(v_o.procesada_en));
end $$;

-- Fase 6a · Consulta de alertas, casos prioritarios y lectura de avisos personales.
-- Depende del cierre de fases 2 a 4. Propuesta local para revisión.

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

-- Fase 6b · Fuentes, reconciliación idempotente y avisos internos.
-- Depende de fase 5 y 6a. Preparado para revisión, sin activación del proceso diario.

-- Estas definiciones proceden de la inspección de metadatos. En el modelo local de referencia no existen.
drop trigger if exists trg_envejeciente_riesgo_alerta on cuidared.envejeciente_riesgo;
drop trigger if exists trg_envejeciente_necesidad_alerta on cuidared.envejeciente_necesidad;
drop trigger if exists trg_detalle_visita_alerta on cuidared.detalle_visita;
drop trigger if exists trg_alerta_envejeciente_notificar on cuidared.alerta_envejeciente;
drop index if exists cuidared.ux_alerta_sistema_abierta;
do $$
declare
  v_firma text;
begin
  foreach v_firma in array array[
    'cuidared.fn_trg_alerta_por_visita()', 'cuidared.fn_trg_alerta_por_riesgo()', 'cuidared.fn_trg_alerta_por_necesidad()',
    'cuidared.fn_trg_alerta_notificar()', 'cuidared.fn_generar_alerta(uuid,text,smallint,text,text)',
    'cuidared.sp_generar_alertas_ausencia_visita()'
  ] loop
    if to_regprocedure(v_firma) is not null then
      execute format('revoke all on function %s from public, anon, authenticated', to_regprocedure(v_firma));
    end if;
  end loop;
end;
$$;

alter table cuidared.alerta_envejeciente
  add column sin_fuente_historica boolean not null default true;
-- Las migraciones no deducen la fuente de las alertas que ya existían.
alter table cuidared.alerta_envejeciente
  alter column sin_fuente_historica set default false,
  drop constraint if exists ck_alerta_env_resuelta,
  add constraint alerta_fuente_obligatoria_chk check (
    num_nonnulls(fuente_riesgo_id, fuente_necesidad_id, fuente_visita_id, fuente_perfil_id) = 1
    or (sin_fuente_historica and num_nonnulls(fuente_riesgo_id, fuente_necesidad_id, fuente_visita_id, fuente_perfil_id) = 0)
  ),
  add constraint alerta_resolucion_trazable_chk check (
    (not cierre_automatico and (estado <> 'resuelta' or usuario_atendio_id is not null)
      or cierre_automatico and estado = 'resuelta' and usuario_atendio_id is null and origen = 'sistema')
    and (estado <> 'resuelta' or (fecha_atencion is not null and nullif(btrim(accion_tomada), '') is not null))
  ) not valid;

create unique index alerta_fuente_riesgo_ux on cuidared.alerta_envejeciente (fuente_riesgo_id)
  where fuente_riesgo_id is not null;
create unique index alerta_fuente_necesidad_ux on cuidared.alerta_envejeciente (fuente_necesidad_id)
  where fuente_necesidad_id is not null;
create unique index alerta_fuente_visita_adulto_ux on cuidared.alerta_envejeciente (fuente_visita_id, envejeciente_id)
  where fuente_visita_id is not null;
create unique index alerta_fuente_perfil_ux on cuidared.alerta_envejeciente (fuente_perfil_id)
  where fuente_perfil_id is not null;

create function cuidared_interno.trg_alerta_fuente_consistente() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_tipo text;
begin
  if tg_op = 'INSERT' and new.sin_fuente_historica then raise check_violation; end if;
  if tg_op = 'UPDATE'
     and (new.envejeciente_id, new.tipo_alerta_id, new.fuente_riesgo_id, new.fuente_necesidad_id,
          new.fuente_visita_id, new.fuente_perfil_id, new.sin_fuente_historica) is distinct from
         (old.envejeciente_id, old.tipo_alerta_id, old.fuente_riesgo_id, old.fuente_necesidad_id,
          old.fuente_visita_id, old.fuente_perfil_id, old.sin_fuente_historica) then
    raise check_violation;
  end if;
  if new.sin_fuente_historica then return new; end if;
  select codigo into v_tipo from cuidared.tipo_alerta where tipo_alerta_id = new.tipo_alerta_id;
  if (new.fuente_riesgo_id is not null and (v_tipo <> 'riesgo_alto' or not exists (
       select from cuidared.envejeciente_riesgo r where r.envejeciente_riesgo_id = new.fuente_riesgo_id
         and r.envejeciente_id = new.envejeciente_id)))
    or (new.fuente_necesidad_id is not null and (v_tipo <> 'medicamento_pendiente' or not exists (
       select from cuidared.envejeciente_necesidad n where n.envejeciente_necesidad_id = new.fuente_necesidad_id
         and n.envejeciente_id = new.envejeciente_id)))
    or (new.fuente_visita_id is not null and (v_tipo <> 'ausencia_visitas' or not exists (
       select from cuidared.visita v join cuidared.envejeciente e on e.cuenta_id = v.cuenta_id
         where v.visita_id = new.fuente_visita_id and v.estado = 'completada'
           and e.envejeciente_id = new.envejeciente_id)))
    or (new.fuente_perfil_id is not null and v_tipo <> 'ausencia_visitas') then
    raise check_violation;
  end if;
  return new;
end;
$$;

create trigger alerta_fuente_consistente before insert or update of envejeciente_id,tipo_alerta_id,fuente_riesgo_id,
  fuente_necesidad_id,fuente_visita_id,fuente_perfil_id,sin_fuente_historica on cuidared.alerta_envejeciente
  for each row execute function cuidared_interno.trg_alerta_fuente_consistente();

insert into cuidared.tipo_alerta(codigo,nombre) values
  ('riesgo_alto','Riesgo alto'),
  ('medicamento_pendiente','Medicamento pendiente'),
  ('ausencia_visitas','Seguimiento familiar sin visita')
on conflict(codigo) do nothing;

create function cuidared_interno.alerta_parametro(p_cuenta bigint, p_parametro text) returns text
language sql stable set search_path = '' as $$
  select coalesce(c.valor,p.valor)
  from cuidared.parametro p
  left join cuidared.configuracion_cuenta c on c.parametro_id = p.parametro_id and c.cuenta_id = p_cuenta
  where p.nombre = p_parametro
$$;

-- Último contacto efectivo verificable de la cuenta. Una visita de varios adultos aporta
-- una referencia distinta por adulto. Programadas y canceladas se excluyen.
create function cuidared_interno.alerta_ventana_sin_visita(p_adulto uuid, p_cuenta bigint, p_hoy date)
returns table (visita_id uuid, referencia date, dias integer, umbral integer)
language sql stable set search_path = '' as $$
  with ultima_visita as (
    select v.visita_id, v.fecha
    from cuidared.detalle_visita d join cuidared.visita v using (visita_id)
    where d.envejeciente_id = p_adulto and v.cuenta_id = p_cuenta and v.estado = 'completada'
      and v.fecha <= p_hoy
    order by v.fecha desc, coalesce(v.hora_fin, v.hora_inicio) desc nulls last,
      v.fecha_creacion desc, v.visita_id
    limit 1
  ), configuracion as (
    select cuidared_interno.alerta_parametro(p_cuenta,'dias_sin_visita_alerta') as valor
  )
  select u.visita_id, coalesce(u.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date),
    p_hoy - coalesce(u.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date),
    case when cuidared_interno.valor_parametro_valido('entero',c.valor) then c.valor::integer else 15 end
  from cuidared.envejeciente e cross join configuracion c left join ultima_visita u on true
  where e.envejeciente_id = p_adulto and e.cuenta_id = p_cuenta
$$;

create function cuidared_interno.alertas_fuentes_vigentes(p_adulto uuid, p_cuenta bigint, p_hoy date, p_tipo text)
returns table (tipo text, prioridad text, descripcion text, riesgo_id bigint, necesidad_id uuid, visita_id uuid, perfil_id uuid)
language sql stable set search_path = '' as $$
  select 'riesgo_alto', 'alta', format('Factor de riesgo alto vigente: %s.',r.nombre),
    er.envejeciente_riesgo_id,null::uuid,null::uuid,null::uuid
  from cuidared.envejeciente_riesgo er join cuidared.nivel_riesgo nr using (nivel_riesgo_id)
  join cuidared.riesgo r using (riesgo_id)
  where (p_tipo is null or p_tipo = 'riesgo_alto') and er.envejeciente_id = p_adulto
    and er.estado = 'activo' and nr.codigo = 'alto'
  union all
  select 'medicamento_pendiente','alta',format('Necesidad de medicamentos pendiente: %s.',n.nombre),
    null, en.envejeciente_necesidad_id, null, null
  from cuidared.envejeciente_necesidad en join cuidared.necesidad n using (necesidad_id)
  join cuidared.tipo_necesidad t using (tipo_necesidad_id)
  where (p_tipo is null or p_tipo = 'medicamento_pendiente') and en.envejeciente_id = p_adulto
    and en.estado = 'pendiente' and t.codigo = 'medicamentos'
  union all
  select 'ausencia_visitas','media',format('Han pasado más de %s días calendario desde el último contacto efectivo.',v.umbral),
    null,null,v.visita_id,case when v.visita_id is null then p_adulto end
  from cuidared_interno.alerta_ventana_sin_visita(p_adulto,p_cuenta,p_hoy) v
  where (p_tipo is null or p_tipo = 'ausencia_visitas') and v.dias > v.umbral
$$;

-- El índice único por fuente protege entre sesiones. El bloqueo por expediente también serializa
-- el cierre de alertas y evita generarlas concurrentemente con un retiro de consentimiento.
create function cuidared_interno.alertas_reconciliar_adulto(p_adulto uuid, p_hoy date, p_tipo text default null) returns integer
language plpgsql set search_path = '' as $$
declare
  v_cuenta bigint;
  v_cantidad integer;
begin
  if p_hoy is null or (p_tipo is not null and p_tipo not in ('riesgo_alto','medicamento_pendiente','ausencia_visitas')) then
    raise invalid_parameter_value;
  end if;
  select e.cuenta_id into v_cuenta
    from cuidared.envejeciente e where e.envejeciente_id = p_adulto and e.estado = 'activo'
      and e.consentimiento_retirado_en is null
    for share;
  if not found or not cuidared_interno.acceso_operativo(v_cuenta) then return 0; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_adulto::text, 608144));
  with fuentes as materialized (
    select * from cuidared_interno.alertas_fuentes_vigentes(p_adulto,v_cuenta,p_hoy,p_tipo)
  ), cerrar as (
    update cuidared.alerta_envejeciente a set estado = 'resuelta',
      accion_tomada = 'Cierre automático: la condición dejó de estar vigente.',
      cierre_automatico = true, fecha_atencion = now(), usuario_atendio_id = null, fecha_actualizacion = now()
    from cuidared.tipo_alerta t
    where a.envejeciente_id = p_adulto and a.tipo_alerta_id = t.tipo_alerta_id and a.origen = 'sistema'
      and not a.sin_fuente_historica and a.estado in ('pendiente','en_proceso')
      and t.codigo in ('riesgo_alto','medicamento_pendiente','ausencia_visitas')
      and (p_tipo is null or t.codigo = p_tipo)
      and not exists (select from fuentes f where f.tipo = t.codigo
        and f.riesgo_id is not distinct from a.fuente_riesgo_id
        and f.necesidad_id is not distinct from a.fuente_necesidad_id
        and f.visita_id is not distinct from a.fuente_visita_id
        and f.perfil_id is not distinct from a.fuente_perfil_id)
  )
  insert into cuidared.alerta_envejeciente (envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,origen,
    fuente_riesgo_id,fuente_necesidad_id,fuente_visita_id,fuente_perfil_id)
  select p_adulto,t.tipo_alerta_id,p.prioridad_id,f.descripcion,'sistema',f.riesgo_id,f.necesidad_id,f.visita_id,f.perfil_id
  from fuentes f join cuidared.tipo_alerta t on t.codigo = f.tipo
  join cuidared.prioridad p on lower(p.nombre) = f.prioridad
  on conflict do nothing;
  get diagnostics v_cantidad = row_count;
  return v_cantidad;
end;
$$;

-- Los cambios del riesgo o de la necesidad alertan dentro de su propia transacción.
create function cuidared_interno.trg_alerta_reconciliar_fuente() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform cuidared_interno.alertas_reconciliar_adulto(new.envejeciente_id,cuidared_interno.hoy(),tg_argv[0]);
  return null;
end;
$$;

create trigger alertas_riesgo_vigente
  after insert or update of estado,nivel_riesgo_id on cuidared.envejeciente_riesgo
  for each row execute function cuidared_interno.trg_alerta_reconciliar_fuente('riesgo_alto');
create trigger alertas_medicamento_pendiente
  after insert or update of estado,necesidad_id on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.trg_alerta_reconciliar_fuente('medicamento_pendiente');

create function cuidared_interno.trg_alerta_avisar() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_cuenta bigint;
  v_tipo text;
begin
  if new.origen <> 'sistema' or new.sin_fuente_historica then return null; end if;
  select e.cuenta_id into v_cuenta from cuidared.envejeciente e
    where e.envejeciente_id = new.envejeciente_id and e.estado = 'activo'
      and e.consentimiento_retirado_en is null;
  if not found then return null; end if;
  select codigo into v_tipo from cuidared.tipo_alerta where tipo_alerta_id = new.tipo_alerta_id;
  if not cuidared_interno.acceso_operativo(v_cuenta)
    or (cuidared_interno.alerta_es_prioritaria(v_tipo) and cuidared_interno.alerta_parametro(v_cuenta,'notificar_casos_prioritarios') = 'false') then
    return null;
  end if;
  insert into cuidared.notificacion (usuario_id,cuenta_id,alerta_envejeciente_id,mensaje)
  select distinct m.usuario_id,v_cuenta,new.alerta_envejeciente_id,
    case when v_tipo = 'ausencia_visitas' then 'Hay una alerta de seguimiento por revisar.'
         else 'Hay una alerta de caso prioritario por revisar.' end
  from cuidared.membresia m
  join cuidared_interno.membresia_activa(v_cuenta,m.usuario_id) vigente on vigente.membresia_id = m.membresia_id
  where m.cuenta_id = v_cuenta
    and (vigente.rol = 'coordinador' or (vigente.tipo = 'organizacion' and vigente.rol = 'administrador'))
    and cuidared_interno.tiene_permiso(v_cuenta,m.usuario_id,'alertas:ver')
    and cuidared_interno.alcanza_envejeciente(v_cuenta,new.envejeciente_id,m.usuario_id);
  return null;
end;
$$;

create trigger alertas_avisos_personales after insert on cuidared.alerta_envejeciente
  for each row execute function cuidared_interno.trg_alerta_avisar();

-- Invocación de operador o del dueño del trabajo diario. Nunca expuesta por la Data API.
create function cuidared_interno.alertas_evaluar_diario() returns integer
language plpgsql set search_path = '' as $$
declare
  v_adulto uuid;
  v_cantidad integer := 0;
  v_hoy date := cuidared_interno.hoy();
begin
  for v_adulto in select e.envejeciente_id from cuidared.envejeciente e
    where e.estado = 'activo' and e.consentimiento_retirado_en is null
      and cuidared_interno.acceso_operativo(e.cuenta_id)
    order by e.envejeciente_id
  loop
    v_cantidad := v_cantidad + cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_hoy);
  end loop;
  return v_cantidad;
end;
$$;

revoke all on function cuidared_interno.alerta_parametro(bigint,text),
  cuidared_interno.alerta_ventana_sin_visita(uuid,bigint,date),
  cuidared_interno.alertas_fuentes_vigentes(uuid,bigint,date,text),
  cuidared_interno.alertas_reconciliar_adulto(uuid,date,text),
  cuidared_interno.trg_alerta_fuente_consistente(),
  cuidared_interno.trg_alerta_reconciliar_fuente(),
  cuidared_interno.trg_alerta_avisar(),
  cuidared_interno.alertas_evaluar_diario() from public, anon, authenticated;

-- RF-21: reutiliza la consulta por cuenta y limita los datos nuevos a referencias.
-- Propuesta 6z, posterior a los bloques de necesidades y alertas.

-- Reemplaza los disparadores históricos que grababan la fila completa.
create or replace trigger trg_envejeciente_necesidad_auditoria
  after insert or update or delete on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.trg_auditoria_referencia('envejeciente_necesidad_id','envejeciente_id');
create or replace trigger trg_alerta_envejeciente_auditoria
  after insert or update or delete on cuidared.alerta_envejeciente
  for each row execute function cuidared_interno.trg_auditoria_referencia('alerta_envejeciente_id','envejeciente_id');

create or replace function cuidared_api.api_auditoria_cuenta(
  p_cuenta_id bigint, p_limite integer, p_desplazamiento bigint, p_desc boolean
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_items jsonb;
  v_total bigint;
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'auditoria:ver');
  if p_limite is null or p_limite not between 1 and 100
     or p_desplazamiento is null or p_desplazamiento < 0 or p_desc is null then
    raise invalid_parameter_value;
  end if;

  with eventos as materialized (
    select a.auditoria_id, a.tabla, a.operacion, a.fecha, a.usuario_id,
           coalesce(a.datos_nuevos, a.datos_anteriores) as fila
    from cuidared.auditoria a
    where a.tabla in ('cuenta', 'configuracion_cuenta', 'membresia', 'envejeciente',
      'contacto_emergencia', 'vinculo', 'indicacion_medica', 'envejeciente_riesgo',
      'envejeciente_necesidad', 'alerta_envejeciente',
      'evaluacion_riesgo', 'visita', 'detalle_visita', 'registro_visita',
      'tarea_agenda', 'evidencia', 'evidencia_visita', 'evidencia_indicacion', 'solicitud_visita')
  ), propios as (
    select e.auditoria_id, e.tabla, e.operacion, e.fecha, e.usuario_id
    from eventos e
    where case
      when e.tabla in ('cuenta','configuracion_cuenta','membresia','envejeciente','visita','solicitud_visita')
        then (e.fila ->> 'cuenta_id') = p_cuenta_id::text
      when e.tabla in ('detalle_visita','registro_visita','evidencia_visita')
        then exists (select 1 from cuidared.visita v where v.visita_id::text = e.fila ->> 'visita_id'
                     and v.cuenta_id = p_cuenta_id)
      when e.tabla = 'evidencia'
        then exists (select 1 from cuidared.tarea_agenda t
                     join cuidared.envejeciente a on a.envejeciente_id = t.envejeciente_id
                     where t.tarea_agenda_id::text = e.fila ->> 'tarea_agenda_id' and a.cuenta_id = p_cuenta_id)
      when e.tabla = 'evidencia_indicacion'
        then exists (select 1 from cuidared.indicacion_medica i
                     join cuidared.envejeciente a using (envejeciente_id)
                     where i.indicacion_medica_id::text = e.fila ->> 'indicacion_medica_id' and a.cuenta_id = p_cuenta_id)
      else exists (select 1 from cuidared.envejeciente a where a.envejeciente_id::text = e.fila ->> 'envejeciente_id'
                   and a.cuenta_id = p_cuenta_id)
    end
  ), pagina as (
    select p.*, row_number() over (order by case when p_desc then fecha end desc,
      case when not p_desc then fecha end, auditoria_id desc) as posicion
    from propios p
    order by posicion limit p_limite offset p_desplazamiento
  )
  select (select count(*) from propios),
    coalesce(jsonb_agg(jsonb_build_object(
      'auditoria_id', p.auditoria_id::text,
      'actor', nullif(concat_ws(' ', u.nombres, u.apellidos), ''),
      'accion', case p.operacion when 'I' then 'alta' when 'U' then 'actualizacion' else 'baja' end,
      'entidad', p.tabla, 'fecha', p.fecha, 'resultado', 'confirmado'
    ) order by p.posicion), '[]'::jsonb)
  into v_total, v_items
  from pagina p left join cuidared.usuario u on u.usuario_id = p.usuario_id;

  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;
revoke all on function cuidared_api.api_auditoria_cuenta(bigint,integer,bigint,boolean) from public, anon;
grant execute on function cuidared_api.api_auditoria_cuenta(bigint,integer,bigint,boolean) to authenticated;

commit;
