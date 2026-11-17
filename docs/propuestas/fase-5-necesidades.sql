-- ID05/RF-03. Base de necesidades por expediente. Propuesta para revisión, posterior a CUIDARED-008.
begin;

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
commit;
