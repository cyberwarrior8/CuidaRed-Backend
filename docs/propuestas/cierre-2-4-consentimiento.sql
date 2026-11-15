-- Retiro documentado y conservación manual del expediente.
-- Aplicar después de cierre-2-4-correcciones.sql.
begin;

alter table cuidared.envejeciente
  add column consentimiento_retirado_en timestamptz,
  add column consentimiento_retirado_por uuid references cuidared.usuario(usuario_id),
  add column consentimiento_retiro_motivo text,
  add constraint envejeciente_retiro_coherente_chk check (
    (consentimiento_retirado_en is null and consentimiento_retirado_por is null and consentimiento_retiro_motivo is null)
    or (consentimiento_retirado_en is not null and consentimiento_retirado_por is not null
        and estado in ('inactivo','fallecido') and (consentimiento_retiro_motivo is null
          or char_length(consentimiento_retiro_motivo) between 3 and 200))
  );
create index envejeciente_retiro_cuenta_idx on cuidared.envejeciente (cuenta_id, consentimiento_retirado_en desc, envejeciente_id)
  where consentimiento_retirado_en is not null;

create function cuidared_interno.visita_con_expediente_retirado(p_visita uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select from cuidared.detalle_visita d join cuidared.envejeciente e using (envejeciente_id)
    where d.visita_id = p_visita and e.consentimiento_retirado_en is not null)
$$;

create or replace function cuidared_interno.visita_visible(p_cuenta_id bigint, p_visita_id uuid, p_usuario_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select from cuidared.visita v
    join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where v.visita_id = p_visita_id and v.cuenta_id = p_cuenta_id
      and not cuidared_interno.visita_con_expediente_retirado(v.visita_id)
      and (m.rol in ('administrador', 'coordinador')
        or exists (select from cuidared.detalle_visita d where d.visita_id = v.visita_id
                   and cuidared_interno.alcanza_envejeciente(p_cuenta_id, d.envejeciente_id, p_usuario_id))))
$$;

create or replace function cuidared_interno.historial_eventos(
  p_envejeciente_id uuid, p_sensible boolean, p_indicaciones boolean, p_visitas boolean, p_necesidades boolean, p_alertas boolean)
returns table (tipo text, fecha timestamp with time zone, titulo text, detalle text, referencia_id text, orden smallint)
language sql stable set search_path = '' as $$
  select 'riesgo'::text, er.fecha_riesgo,
         format('Factor de riesgo registrado: %s (nivel %s)', r.nombre, coalesce(nr.codigo, lower(nr.nombre::text))),
         nullif(concat_ws(' · ', er.motivo, case when er.observacion is not null then 'Observación: ' || er.observacion end), ''),
         er.envejeciente_riesgo_id::text, 1::smallint
  from cuidared.envejeciente_riesgo er
  join cuidared.riesgo r on r.riesgo_id = er.riesgo_id
  join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
  -- El factor que genera un cuestionario se muestra como «evaluacion», no dos veces.
  where p_sensible and er.envejeciente_id = p_envejeciente_id and r.codigo::text is distinct from 'evaluacion'
  union all
  select 'riesgo'::text, er.fecha_resolucion, format('Factor de riesgo resuelto: %s', r.nombre), null::text,
         er.envejeciente_riesgo_id::text, 2::smallint
  from cuidared.envejeciente_riesgo er
  join cuidared.riesgo r on r.riesgo_id = er.riesgo_id
  where p_sensible and er.envejeciente_id = p_envejeciente_id and er.fecha_resolucion is not null
  union all
  select 'evaluacion'::text, ev.fecha,
         format('Evaluación de riesgo: %s de 100 puntos (nivel %s)', ev.puntaje, nr.codigo), null::text,
         ev.evaluacion_riesgo_id::text, 1::smallint
  from cuidared.evaluacion_riesgo ev
  join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = ev.nivel_riesgo_id
  where p_sensible and ev.envejeciente_id = p_envejeciente_id
  union all
  select 'indicacion'::text, i.fecha_creacion, format('Indicación médica registrada: %s', i.titulo), i.descripcion,
         i.indicacion_medica_id::text, 1::smallint
  from cuidared.indicacion_medica i
  where p_indicaciones and i.envejeciente_id = p_envejeciente_id
  union all
  select 'indicacion'::text, i.fecha_actualizacion, format('Indicación médica actualizada: %s (%s)', i.titulo, i.estado),
         null::text, i.indicacion_medica_id::text, 2::smallint
  from cuidared.indicacion_medica i
  where p_indicaciones and i.envejeciente_id = p_envejeciente_id
    and i.fecha_actualizacion > i.fecha_creacion + interval '1 second'
  union all
  select 'visita'::text,
         (v.fecha::timestamp + coalesce(v.hora_inicio, time '00:00')) at time zone 'America/Santo_Domingo',
         case v.estado::text when 'completada' then 'Visita realizada' else 'Visita cancelada' end
           || coalesce(': ' || v.razon, ''),
         -- La observación y el estado general son datos sensibles.
         nullif(concat_ws(' · ',
           case when v.estado::text = 'completada' and responsable.usuario_id is not null
             then 'Responsable: ' || concat_ws(' ', responsable.nombres, responsable.apellidos) end,
           case when p_sensible and d.estado_general is not null
             then 'Estado general: ' || replace(d.estado_general::text, '_', ' ') end,
           case when p_sensible then d.observacion end), ''),
         v.visita_id::text, 1::smallint
  from cuidared.detalle_visita d
  join cuidared.visita v on v.visita_id = d.visita_id
  left join cuidared.usuario responsable on responsable.usuario_id = d.registrado_por
  join cuidared.envejeciente adulto on adulto.envejeciente_id = d.envejeciente_id
  where p_visitas and d.envejeciente_id = p_envejeciente_id and v.estado::text in ('completada', 'cancelada')
    and not cuidared_interno.visita_con_expediente_retirado(v.visita_id)
    -- Antes de 4a, comprobar todos los adultos. Después, excluir visitas que quedaron sin cuenta conciliada.
    and case when to_jsonb(v) ? 'cuenta_id' then (to_jsonb(v)->>'cuenta_id')::bigint = adulto.cuenta_id
        else not exists (select 1 from cuidared.detalle_visita otro
          join cuidared.envejeciente e on e.envejeciente_id = otro.envejeciente_id
          where otro.visita_id = v.visita_id and e.cuenta_id is distinct from adulto.cuenta_id) end
  union all
  select 'necesidad'::text, en.fecha_necesidad, format('Necesidad registrada: %s', n.nombre), en.descripcion,
         en.envejeciente_necesidad_id::text, 1::smallint
  from cuidared.envejeciente_necesidad en
  join cuidared.necesidad n on n.necesidad_id = en.necesidad_id
  where p_necesidades and en.envejeciente_id = p_envejeciente_id
  union all
  select 'necesidad'::text, en.fecha_resolucion, format('Necesidad %s: %s', en.estado, n.nombre), en.motivo_resolucion,
         en.envejeciente_necesidad_id::text, 2::smallint
  from cuidared.envejeciente_necesidad en
  join cuidared.necesidad n on n.necesidad_id = en.necesidad_id
  where p_necesidades and en.envejeciente_id = p_envejeciente_id and en.fecha_resolucion is not null
  union all
  select 'alerta'::text, a.fecha_alerta, format('Alerta generada: %s', ta.nombre), a.descripcion,
         a.alerta_envejeciente_id::text, 1::smallint
  from cuidared.alerta_envejeciente a
  join cuidared.tipo_alerta ta on ta.tipo_alerta_id = a.tipo_alerta_id
  where p_alertas and a.envejeciente_id = p_envejeciente_id
  union all
  select 'alerta'::text, a.fecha_atencion, format('Alerta atendida (%s): %s', replace(a.estado::text, '_', ' '), ta.nombre),
         a.accion_tomada, a.alerta_envejeciente_id::text, 2::smallint
  from cuidared.alerta_envejeciente a
  join cuidared.tipo_alerta ta on ta.tipo_alerta_id = a.tipo_alerta_id
  where p_alertas and a.envejeciente_id = p_envejeciente_id and a.fecha_atencion is not null
$$;

create function cuidared_interno.trg_expediente_retirado_proteger() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.consentimiento_retirado_en is not null then raise no_data_found; end if;
  return new;
end;
$$;
create trigger envejeciente_retiro_inmutable before update on cuidared.envejeciente
  for each row execute function cuidared_interno.trg_expediente_retirado_proteger();

-- Bloquea nuevas tareas si el retiro ganó el bloqueo de fila. Solo se aplica a inserciones
-- nuevas para conservar los estados y registros históricos.
create function cuidared_interno.trg_tarea_requiere_consentimiento() returns trigger
language plpgsql set search_path = '' as $$
declare v_retirado timestamptz;
begin
  select e.consentimiento_retirado_en into v_retirado from cuidared.envejeciente e
    where e.envejeciente_id = new.envejeciente_id for share;
  if v_retirado is not null then raise no_data_found; end if;
  return new;
end;
$$;
create trigger tarea_requiere_consentimiento before insert on cuidared.tarea_agenda
  for each row execute function cuidared_interno.trg_tarea_requiere_consentimiento();

create or replace function cuidared_interno.tarea_cargar(p_cuenta_id bigint, p_tarea_id uuid) returns cuidared.tarea_agenda
language plpgsql set search_path = '' as $$
declare v_t cuidared.tarea_agenda;
begin
  select t.* into v_t from cuidared.tarea_agenda t
  join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
  where t.tarea_agenda_id = p_tarea_id and e.cuenta_id = p_cuenta_id and e.consentimiento_retirado_en is null
  for update of t;
  if not found then raise no_data_found; end if;
  if v_t.es_historica then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  return v_t;
end;
$$;

create or replace function cuidared_interno.alcanza_envejeciente(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1
    from cuidared.envejeciente e
    join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id and e.consentimiento_retirado_en is null
      and (m.rol <> 'cuidador' or exists (
        select 1 from cuidared.cuidador c where c.usuario_id = p_usuario_id and c.fecha_fin is null
      ))
      and (m.rol in ('administrador', 'coordinador')
        or exists (
          select 1 from cuidared.vinculo v join cuidared.tipo_vinculo tv on tv.tipo_vinculo_id = v.tipo_vinculo_id
          where v.envejeciente_id = e.envejeciente_id and v.usuario_id = p_usuario_id
            and v.fecha_revocacion is null
            and (m.rol <> 'familiar' or v.autorizado_por_usuario_id is not null)
            and tv.codigo::text = case m.rol when 'cuidador' then 'cuidador_asignado'
                                             when 'voluntario' then 'voluntario_asignado'
                                             when 'familiar' then 'familiar_responsable' end)))
$$;

create or replace function cuidared_api.api_listar_envejecientes(
  p_cuenta_id bigint,
  p_estado text default null,
  p_municipio_cod text default null,
  p_orden jsonb default '["apellidos","nombres","fecha_creacion","envejeciente_id"]'::jsonb,
  p_limite integer default 20,
  p_desplazamiento integer default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'adultos:ver');
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_gestor boolean := v_ctx->>'rol' in ('administrador', 'coordinador');
  v_nivel text := cuidared_interno.env_nivel(p_cuenta_id, v_uid);
  v_orden text := '';
  v_token text;
  v_expr text;
  v_res jsonb;
begin
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or (p_estado is not null and p_estado not in ('activo', 'inactivo', 'fallecido'))
     or (p_municipio_cod is not null and p_municipio_cod !~ '^[0-9]{4,6}$')
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) not between 1 and 8 then
    raise invalid_parameter_value;
  end if;
  for v_token in select jsonb_array_elements_text(p_orden) loop
    v_expr := case case when left(v_token, 1) = '-' then substr(v_token, 2) else v_token end
      when 'apellidos' then 'lower(e.apellidos)'
      when 'nombres' then 'lower(e.nombres)'
      when 'fecha_creacion' then 'e.fecha_creacion'
      when 'envejeciente_id' then 'e.envejeciente_id'
    end;
    if v_expr is null then raise invalid_parameter_value; end if;
    v_orden := v_orden || case when v_orden = '' then '' else ', ' end || v_expr
               || case when left(v_token, 1) = '-' then ' desc' else ' asc' end;
  end loop;

  -- Las expresiones de orden salen de la lista cerrada de arriba; los valores del cliente van como parámetros.
  execute format($q$
    with base as (
      select e.* from cuidared.envejeciente e
      where e.cuenta_id = $1 and e.consentimiento_retirado_en is null
        and ($2::text is null or e.estado = $2)
        and ($3::text is null or e.municipio_cod = $3)
        and ($4 or cuidared_interno.alcanza_envejeciente($1, e.envejeciente_id, $5))
    )
    select jsonb_build_object(
      'total', (select count(*) from base),
      'items', coalesce((
        select jsonb_agg(
          jsonb_build_object('envejeciente_id', e.envejeciente_id, 'estado', e.estado, 'nombres', e.nombres,
                             'apellidos', e.apellidos, 'municipio_cod', e.municipio_cod, 'zona', e.zona,
                             'fecha_creacion', cuidared_interno.env_ts(e.fecha_creacion))
          || case when $8 in ('basico', 'completo') then jsonb_build_object(
               'fecha_nacimiento', e.fecha_nacimiento, 'sexo', e.sexo) else '{}'::jsonb end
          || case when $8 = 'completo' then jsonb_build_object('autonomia', e.autonomia) else '{}'::jsonb end
          order by %1$s)
        from (select e.* from base e order by %1$s limit $6 offset $7) e), '[]'::jsonb))
  $q$, v_orden)
  into v_res
  using p_cuenta_id, p_estado, p_municipio_cod, v_gestor, v_uid, p_limite, p_desplazamiento, v_nivel;
  return v_res;
end;
$$;

create or replace function cuidared_api.api_listar_visitas(
  p_cuenta_id bigint,
  p_filtros jsonb default '{}'::jsonb,
  p_orden jsonb default '[]'::jsonb,
  p_limite integer default 20,
  p_desplazamiento integer default 0
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_gestor boolean;
  v_estado text;
  v_env uuid;
  v_desde date;
  v_hasta date;
  v_orden text := '';
  v_usados text[] := '{}';
  v_elem jsonb;
  v_campo text;
  v_dir text;
  v_res jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:ver');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  v_gestor := (v_ctx->>'rol') in ('administrador', 'coordinador');
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(p_filtros) is distinct from 'object'
     or p_filtros - array['estado', 'envejeciente_id', 'desde', 'hasta'] <> '{}'::jsonb
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) > 5 then
    raise invalid_parameter_value;
  end if;
  v_estado := cuidared_interno.v_texto(p_filtros->'estado', 1, 20, false);
  if v_estado is not null and v_estado not in ('programada', 'en_curso', 'completada', 'cancelada') then
    raise invalid_parameter_value;
  end if;
  v_env := cuidared_interno.v_uuid(p_filtros->'envejeciente_id', false);
  v_desde := cuidared_interno.v_fecha(p_filtros->'desde', false);
  v_hasta := cuidared_interno.v_fecha(p_filtros->'hasta', false);
  if v_desde is not null and v_hasta is not null and v_desde > v_hasta then raise invalid_parameter_value; end if;
  -- Filtrar por un adulto fuera del alcance (otra cuenta o inexistente) = adulto inexistente.
  if v_env is not null and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_uid) then
    raise no_data_found;
  end if;
  for v_elem in select e.value from jsonb_array_elements(p_orden) as e loop
    if jsonb_typeof(v_elem) is distinct from 'object' or v_elem - array['campo', 'direccion'] <> '{}'::jsonb
       or jsonb_typeof(v_elem->'campo') is distinct from 'string' or jsonb_typeof(v_elem->'direccion') is distinct from 'string' then
      raise invalid_parameter_value;
    end if;
    v_campo := v_elem->>'campo';
    v_dir := v_elem->>'direccion';
    if not (v_campo = any (array['fecha', 'hora_programada', 'estado', 'fecha_creacion', 'visita_id']))
       or v_dir not in ('asc', 'desc') or v_campo = any (v_usados) then
      raise invalid_parameter_value;
    end if;
    v_usados := array_append(v_usados, v_campo);
    -- Solo identificadores de la lista cerrada y direcciones asc/desc llegan al SQL dinámico.
    v_orden := v_orden || format('f.%I %s nulls last, ', v_campo, v_dir);
  end loop;
  if v_orden = '' then v_orden := 'f.fecha desc nulls last, f.hora_programada desc nulls last, '; end if;
  if not ('visita_id' = any (v_usados)) then v_orden := v_orden || 'f.visita_id asc'; else v_orden := left(v_orden, length(v_orden) - 2); end if;

  execute format($q$
    with f as (
      select v.visita_id, v.fecha, v.hora_programada, v.estado, v.fecha_creacion
      from cuidared.visita v
      where v.cuenta_id = $1 and not cuidared_interno.visita_con_expediente_retirado(v.visita_id)
        and ($4::text is null or v.estado::text = $4)
        and ($5::uuid is null or exists (
              select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id and d.envejeciente_id = $5))
        and ($6::date is null or v.fecha >= $6)
        and ($7::date is null or v.fecha <= $7)
        and ($3
             or exists (select 1 from cuidared.registro_visita r where r.visita_id = v.visita_id and r.usuario_id = $2)
             or exists (select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id
                        and cuidared_interno.alcanza_envejeciente($1, d.envejeciente_id, $2)))
    ), p as (
      select f.visita_id, row_number() over (order by %s) as rn from f
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'items', coalesce((select jsonb_agg(cuidared_interno.visita_json(p.visita_id, $2, false) order by p.rn)
                         from p where p.rn > $8 and p.rn <= $8 + $9), '[]'::jsonb))
  $q$, v_orden)
  into v_res
  using p_cuenta_id, v_uid, v_gestor, v_estado, v_env, v_desde, v_hasta, p_desplazamiento, p_limite;
  return v_res;
end $$;

create or replace function cuidared_api.api_programar_visita(p_cuenta_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_hoy date := cuidared_interno.hoy();
  v_fecha date;
  v_hora time;
  v_razon text;
  v_notas text;
  v_adultos uuid[];
  v_parts uuid[];
  v_id uuid := gen_random_uuid();
  v_a uuid;
  v_p uuid;
  v_m record;
  v_estado text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  -- Programar equivale a autorizar: solo programa un usuario principal.
  if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'visitas:autorizar') then raise insufficient_privilege; end if;
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['fecha', 'hora_programada', 'razon', 'notas', 'envejeciente_ids', 'participante_ids'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hora := cuidared_interno.v_hora(p_datos->'hora_programada');
  if v_fecha < v_hoy or (v_fecha = v_hoy and v_hora < cuidared_interno.hora_local()) then
    raise invalid_parameter_value;
  end if;
  v_razon := cuidared_interno.v_texto(p_datos->'razon', 3, 120);
  v_notas := cuidared_interno.v_texto(p_datos->'notas', 1, 300, false);
  v_adultos := cuidared_interno.v_uuids(p_datos->'envejeciente_ids', 1, 4);
  v_parts := cuidared_interno.v_uuids(p_datos->'participante_ids', 1, 3);

  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  -- Adultos: de la cuenta y al alcance de quien programa. Otra cuenta e inexistente responden igual (42501).
  foreach v_a in array v_adultos loop
    perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:programar', v_a);
    select e.estado into v_estado from cuidared.envejeciente e where e.envejeciente_id = v_a;
    if v_estado <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  end loop;
  -- Participantes: miembros activos con rol permitido y sin otra visita a esa hora.
  foreach v_p in array v_parts loop
    select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_p);
    if not found or v_m.rol not in ('cuidador', 'voluntario', 'coordinador')
       or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
      raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
    end if;
    if exists (
      select 1 from cuidared.visita vv join cuidared.registro_visita rr on rr.visita_id = vv.visita_id
      where vv.cuenta_id = p_cuenta_id and rr.usuario_id = v_p and vv.fecha = v_fecha and vv.hora_programada = v_hora
        and vv.estado::text in ('programada', 'en_curso')) then
      raise exception 'CR_PARTICIPANTE_OCUPADO' using errcode = 'P0001';
    end if;
  end loop;

  insert into cuidared.visita (visita_id, cuenta_id, fecha, hora_programada, razon, estado, origen, creada_por, notas)
    values (v_id, p_cuenta_id, v_fecha, v_hora, v_razon, 'programada', 'interna', v_uid, v_notas);
  foreach v_p in array v_parts loop
    insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id) values (v_id, v_p, v_uid);
    select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_p);
    if v_m.rol in ('cuidador', 'voluntario') then
      foreach v_a in array v_adultos loop
        -- Si falta un vínculo vigente, 3b abre un nuevo periodo y registra a quien programa como autorizador (RF-12/RF-13).
        if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_a, v_p) then
          if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar') then
            raise insufficient_privilege;
          end if;
          perform cuidared_interno.seg_vincular(p_cuenta_id, v_a, v_p,
            case v_m.rol when 'cuidador' then 'cuidador_asignado' else 'voluntario_asignado' end, v_uid);
        end if;
      end loop;
    end if;
  end loop;
  insert into cuidared.detalle_visita (visita_id, envejeciente_id) select v_id, a from unnest(v_adultos) as a;
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $$;

create or replace function cuidared_api.api_autorizar_solicitud_visita(p_cuenta_id bigint, p_solicitud_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_s record;
  v_env uuid;
  v_participante uuid;
  v_id uuid;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_solicitud_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  select * into v_s from cuidared.solicitud_visita where solicitud_visita_id = p_solicitud_id and cuenta_id = p_cuenta_id for update;
  if not found then raise no_data_found; end if;
  if v_s.estado::text <> 'pendiente' then raise exception 'CR_SOLICITUD_REVISADA' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['envejeciente_id', 'fecha', 'hora', 'participante_id'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_env := cuidared_interno.v_uuid(p_datos->'envejeciente_id');
  v_participante := coalesce(cuidared_interno.v_uuid(p_datos->'participante_id', false), v_uid);
  v_id := (cuidared_api.api_programar_visita(p_cuenta_id, jsonb_build_object(
    'fecha', p_datos->'fecha', 'hora_programada', p_datos->'hora', 'razon', btrim(left(v_s.motivo, 120)),
    'envejeciente_ids', jsonb_build_array(v_env), 'participante_ids', jsonb_build_array(v_participante)
  ))->>'visita_id')::uuid;
  update cuidared.visita v set origen = 'solicitud', solicitud_visita_id = p_solicitud_id where v.visita_id = v_id;
  update cuidared.solicitud_visita
    set estado = 'autorizada', envejeciente_id = v_env, revisada_por = v_uid, revisada_en = now(), visita_id = v_id
    where solicitud_visita_id = p_solicitud_id;
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $$;

create function cuidared_api.api_retirar_consentimiento(p_cuenta_id bigint,p_envejeciente_id uuid,p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'adultos:desactivar')->>'usuario_id')::uuid;
  v_motivo text := cuidared_interno.v_texto(to_jsonb(p_motivo), 3, 200, false);
  v_fecha timestamptz := now();
  v_texto constant text := 'Cancelada por retiro del consentimiento.';
  v_v cuidared.visita;
  v_visita uuid;
begin
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  perform cuidared_interno.env_exigir(p_cuenta_id, 'adultos:desactivar', p_envejeciente_id);
  update cuidared.envejeciente as e set
    consentimiento_retirado_en = v_fecha, consentimiento_retirado_por = v_uid, consentimiento_retiro_motivo = v_motivo,
    estado = case when e.estado = 'fallecido' then e.estado else 'inactivo' end,
    motivo_estado = case when e.estado = 'fallecido' then e.motivo_estado else 'Retiro del consentimiento' end,
    fecha_estado = case when e.estado = 'fallecido' then e.fecha_estado else v_fecha end,
    fecha_actualizacion = v_fecha
    where e.cuenta_id = p_cuenta_id and e.envejeciente_id = p_envejeciente_id
      and e.consentimiento_retirado_en is null;
  if not found then raise no_data_found; end if;

  update cuidared.tarea_agenda set estado = 'cancelada', motivo_cancelacion = v_texto,
    cancelada_por = v_uid, actualizado_por = v_uid, fecha_actualizacion = v_fecha
    where envejeciente_id = p_envejeciente_id and estado in ('pendiente','en_progreso') and not es_historica;
  update cuidared.alerta_envejeciente set estado = 'resuelta', fecha_atencion = v_fecha, usuario_atendio_id = v_uid,
    fecha_actualizacion = v_fecha, accion_tomada = 'Cerrada por retiro del consentimiento.'
    where envejeciente_id = p_envejeciente_id and estado in ('pendiente','en_proceso');

  -- Usa el mismo orden de bloqueo que la cancelación normal de visitas ligadas a solicitudes.
  for v_visita in select v.visita_id from cuidared.visita v join cuidared.detalle_visita d using (visita_id)
    where d.envejeciente_id = p_envejeciente_id and v.cuenta_id = p_cuenta_id
      and v.hora_programada is not null and v.estado in ('programada','en_curso')
    order by v.visita_id loop
    v_v := cuidared_interno.bloquear_visita(v_visita);
    if v_v.estado in ('programada','en_curso') then
      update cuidared.visita set estado = 'cancelada', motivo_cancelacion = v_texto,
        cancelada_por = v_uid, fecha_cancelacion = v_fecha, fecha_actualizacion = v_fecha
        where visita_id = v_visita;
    end if;
  end loop;

  return jsonb_build_object('envejeciente_id', p_envejeciente_id, 'fecha', v_fecha);
end;
$$;

create function cuidared_api.api_consentimientos_retirados(p_cuenta_id bigint,p_limite integer,p_offset integer,p_desc boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_total bigint; v_items jsonb;
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'adultos:desactivar');
  if p_limite is null or p_limite not between 1 and 100 or p_offset is null or p_offset < 0 or p_desc is null then
    raise invalid_parameter_value;
  end if;
  with propios as (
    select e.envejeciente_id, e.nombres, e.apellidos, e.consentimiento_retirado_en fecha,
      e.consentimiento_retirado_por, e.consentimiento_retiro_motivo
    from cuidared.envejeciente e where e.cuenta_id = p_cuenta_id and e.consentimiento_retirado_en is not null
  ), pagina as (
    select p.*, row_number() over (order by case when p_desc then p.fecha end desc,
        case when not p_desc then p.fecha end, p.envejeciente_id) as posicion
    from propios p order by posicion limit p_limite offset p_offset
  )
  select (select count(*) from propios), coalesce(jsonb_agg(jsonb_build_object(
    'envejeciente_id', p.envejeciente_id, 'nombre', concat_ws(' ', p.nombres, p.apellidos),
    'fecha', p.fecha, 'motivo', p.consentimiento_retiro_motivo,
    'actor', nullif(concat_ws(' ', u.nombres, u.apellidos), '')
  ) order by p.posicion), '[]'::jsonb) into v_total,v_items
  from pagina p left join cuidared.usuario u on u.usuario_id = p.consentimiento_retirado_por;
  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;

revoke all on function cuidared_interno.visita_con_expediente_retirado(uuid),
  cuidared_interno.trg_tarea_requiere_consentimiento(), cuidared_interno.trg_expediente_retirado_proteger()
  from public, anon, authenticated;
revoke all on function cuidared_api.api_retirar_consentimiento(bigint,uuid,text),
  cuidared_api.api_consentimientos_retirados(bigint,integer,integer,boolean) from public, anon;
grant execute on function cuidared_api.api_retirar_consentimiento(bigint,uuid,text),
  cuidared_api.api_consentimientos_retirados(bigint,integer,integer,boolean) to authenticated;
commit;
