-- Fase 7 · Reportes · ID07; RF-07 (resumen de casos, CU-11), RF-08 (reportes estadísticos, CU-12) e informe médico V2.
-- PROPUESTA para revisión: no se ha aplicado en Supabase y requiere aprobación expresa. Contrato: docs/contratos/reportes.md.
-- Se aplica sobre TODAS las migraciones de supabase/migrations/ (CUIDARED-008 a -011, backoffice y visitas).
-- Sin tablas ni índices nuevos: las agregaciones llegan a cada hecho por los índices existentes por adulto.
-- Validación local: node scripts/validar-propuestas-local.js --solo=reportes (pruebas-7-*.sql).
-- Reutilizable: todas las funciones usan `create or replace`. © 2026 Equipo CuidaRed – INTEC.
begin;

/* ───────────── 1. Comprobaciones y filtros comunes ───────────── */

-- Permisos adicionales y funcionalidades del plan, después de `exigir` (sesión, membresía, permiso y acceso
-- operativo). Una funcionalidad ausente responde 42501, igual que las series de visitas (`visitas_recurrentes`).
create or replace function cuidared_interno.reporte_exigir_extra(p_cuenta_id bigint, p_usuario_id uuid,
  p_permisos text[], p_funcionalidades text[]) returns void
language plpgsql stable set search_path = '' as $$
declare v_item text;
begin
  foreach v_item in array coalesce(p_permisos, array[]::text[]) loop
    if not cuidared_interno.tiene_permiso(p_cuenta_id, p_usuario_id, v_item) then raise insufficient_privilege; end if;
  end loop;
  foreach v_item in array coalesce(p_funcionalidades, array[]::text[]) loop
    if not cuidared_interno.cuenta_tiene_funcionalidad(p_cuenta_id, v_item) then raise insufficient_privilege; end if;
  end loop;
end;
$$;

-- Código de una lista cerrada; ausente o null = sin filtro.
create or replace function cuidared_interno.reporte_codigo(p_valor jsonb, p_permitidos text[]) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then return null; end if;
  if jsonb_typeof(p_valor) <> 'string' or not ((p_valor #>> '{}') = any (p_permitidos)) then
    raise invalid_parameter_value;
  end if;
  return p_valor #>> '{}';
end;
$$;

-- Filtros de los reportes normalizados con todas sus claves (null = sin filtro). Las fechas son días de
-- calendario de Santo Domingo, inclusivos. `p_claves` limita las claves admitidas según el tipo.
create or replace function cuidared_interno.reporte_filtros(p_filtros jsonb, p_claves text[]) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_f jsonb := coalesce(p_filtros, '{}'::jsonb);
  v_desde date;
  v_hasta date;
  v_municipio text;
begin
  if jsonb_typeof(v_f) <> 'object' then raise invalid_parameter_value; end if;
  -- Una clave con valor null equivale a omitirla: los filtros normalizados de una respuesta pueden reenviarse.
  v_f := jsonb_strip_nulls(v_f);
  if v_f - p_claves <> '{}'::jsonb then raise invalid_parameter_value; end if;
  v_desde := cuidared_interno.v_fecha(v_f->'desde', false);
  v_hasta := cuidared_interno.v_fecha(v_f->'hasta', false);
  if v_desde > v_hasta or v_desde < date '1900-01-01' or v_hasta > date '2999-12-31' then
    raise invalid_parameter_value;
  end if;
  if v_f ? 'municipio_cod' and jsonb_typeof(v_f->'municipio_cod') <> 'null' then
    if jsonb_typeof(v_f->'municipio_cod') <> 'string' or (v_f->>'municipio_cod') !~ '^[0-9]{4,6}$' then
      raise invalid_parameter_value;
    end if;
    v_municipio := v_f->>'municipio_cod';
  end if;
  return jsonb_build_object(
    'desde', v_desde,
    'hasta', v_hasta,
    'municipio_cod', v_municipio,
    'zona', cuidared_interno.v_texto(v_f->'zona', 1, 60, false),
    'riesgo', cuidared_interno.reporte_codigo(v_f->'riesgo', array['alto', 'medio', 'bajo', 'sin_evaluacion']),
    'tipo_necesidad_id', cuidared_interno.seg_entero_campo(v_f->'tipo_necesidad_id', 1, 32767));
end;
$$;

-- El seguimiento por visitas solo aplica a Organización. Las dos consultas reutilizan el mismo umbral.
create or replace function cuidared_interno.umbral_seguimiento_visitas(p_cuenta_id bigint) returns integer
language sql stable set search_path = '' as $$
  select case when cuidared_interno.valor_parametro_valido('entero', x.valor) then x.valor::integer else 15 end
  from cuidared.cuenta c join cuidared.tipo_cuenta t using (tipo_cuenta_id)
  cross join lateral (select cuidared_interno.alerta_parametro(c.cuenta_id, 'dias_sin_visita_alerta') as valor) x
  where c.cuenta_id = p_cuenta_id and t.codigo = 'organizacion'
$$;

-- La reconciliación existente cierra las alertas de sistema cuya fuente deja de estar vigente y conserva su historial.
create or replace function cuidared_interno.alerta_ventana_sin_visita(p_adulto uuid, p_cuenta bigint, p_hoy date)
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
    select cuidared_interno.umbral_seguimiento_visitas(p_cuenta) as umbral
  )
  select u.visita_id, coalesce(u.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date),
    p_hoy - coalesce(u.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date), c.umbral
  from cuidared.envejeciente e cross join configuracion c left join ultima_visita u on true
  where e.envejeciente_id = p_adulto and e.cuenta_id = p_cuenta and c.umbral is not null
$$;

-- Meses `YYYY-MM` de un periodo, también los vacíos; como máximo los 24 últimos.
create or replace function cuidared_interno.reporte_meses(p_desde date, p_hasta date, p_primero date, p_hoy date)
returns table (clave text, inicio date, fin date)
language sql immutable set search_path = '' as $$
  with limites as (
    select coalesce(p_hasta, p_hoy) as hasta
  ), periodo as (
    select least(coalesce(p_desde, p_primero, l.hasta), l.hasta) as desde, l.hasta from limites l
  )
  select to_char(m, 'YYYY-MM'), m::date, (m + interval '1 month' - interval '1 day')::date
  from periodo p, generate_series(
    greatest(date_trunc('month', p.desde::timestamp), date_trunc('month', p.hasta::timestamp) - interval '23 months'),
    date_trunc('month', p.hasta::timestamp), interval '1 month') m
  order by m
$$;

-- Serie de un gráfico: agrega a cada `{clave, etiqueta, valor}` su porcentaje entero sobre la suma de la serie.
create or replace function cuidared_interno.reporte_serie(p_items jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(i.item || jsonb_build_object('porcentaje',
      case when t.total > 0 then round((i.item->>'valor')::numeric * 100 / t.total)::integer else 0 end)
    order by i.n), '[]'::jsonb)
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as i(item, n)
  cross join (select coalesce(sum((e->>'valor')::numeric), 0) as total
              from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e) t
$$;

-- Personal asignado de toda la cuenta con acceso real a cada adulto: cuidadores con perfil vigente y voluntarios,
-- con vínculo no revocado y membresía activa con ese rol. Los familiares no cuentan como cobertura. Conjunto: una
-- consulta de membresía por miembro de la cuenta, no por vínculo.
create or replace function cuidared_interno.reporte_asignaciones(p_cuenta_id bigint)
returns table (envejeciente_id uuid, tipo text, usuario_id uuid, nombres text, apellidos text)
language sql stable set search_path = '' as $$
  with personal as materialized (
    select m.usuario_id, ma.rol
    from (select distinct mb.usuario_id from cuidared.membresia mb where mb.cuenta_id = p_cuenta_id) m
    cross join lateral cuidared_interno.membresia_activa(p_cuenta_id, m.usuario_id) ma
    where ma.rol = 'voluntario'
       or (ma.rol = 'cuidador'
           and exists (select 1 from cuidared.cuidador c where c.usuario_id = m.usuario_id and c.fecha_fin is null))
  )
  select v.envejeciente_id, tv.codigo::text, u.usuario_id, u.nombres::text, u.apellidos::text
  from cuidared.vinculo v
  join cuidared.tipo_vinculo tv on tv.tipo_vinculo_id = v.tipo_vinculo_id
  join personal p on p.usuario_id = v.usuario_id
    and p.rol = case tv.codigo when 'cuidador_asignado' then 'cuidador' when 'voluntario_asignado' then 'voluntario' end
  join cuidared.usuario u on u.usuario_id = v.usuario_id
  join cuidared.envejeciente e on e.envejeciente_id = v.envejeciente_id and e.cuenta_id = p_cuenta_id
  where v.fecha_revocacion is null
$$;

-- Adultos de la cuenta al alcance del actor, con consentimiento vigente. Para Administrador y Coordinador equivale a
-- cuidared_interno.alcanza_envejeciente sin evaluarla fila por fila; para los demás roles se evalúa por adulto.
create or replace function cuidared_interno.reporte_alcance(p_cuenta_id bigint, p_usuario_id uuid)
returns table (envejeciente_id uuid)
language sql stable set search_path = '' as $$
  select e.envejeciente_id
  from cuidared.envejeciente e
  cross join (select cuidared_interno.es_gestor(p_cuenta_id, p_usuario_id) as gestor) g
  where e.cuenta_id = p_cuenta_id and e.consentimiento_retirado_en is null
    and case when g.gestor then true
             else cuidared_interno.alcanza_envejeciente(p_cuenta_id, e.envejeciente_id, p_usuario_id) end
$$;

-- Riesgo vigente de los adultos de la cuenta: máximo nivel de los factores activos (misma regla que
-- cuidared_interno.nivel_riesgo_vigente), calculado en conjunto.
create or replace function cuidared_interno.reporte_riesgos(p_cuenta_id bigint)
returns table (envejeciente_id uuid, riesgo text)
language sql stable set search_path = '' as $$
  select distinct on (er.envejeciente_id) er.envejeciente_id, nr.codigo::text
  from cuidared.envejeciente_riesgo er
  join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
  join cuidared.envejeciente e on e.envejeciente_id = er.envejeciente_id and e.cuenta_id = p_cuenta_id
  where er.estado = 'activo'
  order by er.envejeciente_id, nr.orden desc
$$;

-- Opciones de filtro distintas del universo autorizado. No dependen de la página, del orden ni del tope del detalle.
create or replace function cuidared_api.api_reporte_opciones(p_cuenta_id bigint, p_ambito text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_resumen boolean := p_ambito = 'resumen';
  v_opciones jsonb;
begin
  if p_ambito is null or p_ambito not in ('resumen', 'reportes') then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id,
    case when v_resumen then 'resumen:ver' else 'reportes:ver' end)->>'usuario_id')::uuid;
  if not v_resumen then
    perform cuidared_interno.reporte_exigir_extra(p_cuenta_id, v_uid, array[]::text[], array['dashboard_metricas']);
  end if;
  with alcance as materialized (
    select e.envejeciente_id, e.municipio_cod, e.zona::text as zona
    from cuidared_interno.reporte_alcance(p_cuenta_id, v_uid) a
    join cuidared.envejeciente e using (envejeciente_id)
    where not v_resumen or e.estado = 'activo'
  ), municipios as (
    select distinct m.municipio_cod as codigo, m.nombre
    from alcance a join cuidared.municipio m on m.municipio_cod = a.municipio_cod
  ), sectores as (
    select distinct a.zona from alcance a where nullif(btrim(a.zona), '') is not null
  ), asignados as (
    select distinct p.usuario_id, p.nombres, p.apellidos,
      case p.tipo when 'cuidador_asignado' then 'cuidador' else 'voluntario' end as rol
    from cuidared_interno.reporte_asignaciones(p_cuenta_id) p
    join alcance a using (envejeciente_id)
    where v_resumen
  )
  select jsonb_build_object(
    'municipios', coalesce((select jsonb_agg(m order by m.nombre, m.codigo) from municipios m), '[]'::jsonb),
    'sectores', coalesce((select jsonb_agg(s.zona order by s.zona) from sectores s), '[]'::jsonb),
    'asignados', coalesce((select jsonb_agg(a order by a.apellidos, a.nombres, a.usuario_id) from asignados a), '[]'::jsonb))
  into v_opciones;
  return v_opciones;
end;
$$;

/* ───────────── 2. Resumen de casos (RF-07) ───────────── */

-- Un caso por adulto activo, con consentimiento vigente y al alcance del actor, calculado con la fecha de hoy.
-- Cada hecho se agrega una sola vez por cuenta, desde las tablas e índices por cuenta (sin subconsultas por fila
-- ni sondeos por adulto), y se une al final con los adultos al alcance.
create or replace function cuidared_interno.reporte_casos(p_cuenta_id bigint, p_usuario_id uuid)
returns table (
  envejeciente_id uuid, nombres text, apellidos text, municipio_cod text, municipio_nombre text, zona text,
  fecha_alta timestamptz, riesgo_vigente text, peso_riesgo integer,
  alertas_abiertas integer, alertas_pendientes integer, alertas_en_proceso integer,
  alertas_prioritarias_abiertas integer, alertas_seguimiento_abiertas integer, alertas_otras_abiertas integer,
  necesidades_activas integer, ultima_visita_id uuid, ultima_visita_fecha date, fecha_referencia date,
  dias_sin_visita integer, umbral_dias integer, seguimiento_vencido boolean,
  cuidadores jsonb, voluntarios jsonb, asignados uuid[],
  prioridad text, peso_prioridad integer, estado_atencion text, peso_estado integer, motivos text[])
language sql stable set search_path = '' as $$
  with parametros as (
    select cuidared_interno.hoy() as hoy, cuidared_interno.umbral_seguimiento_visitas(p_cuenta_id) as umbral
  ), adultos as materialized (
    select e.* from cuidared.envejeciente e
    join cuidared_interno.reporte_alcance(p_cuenta_id, p_usuario_id) s on s.envejeciente_id = e.envejeciente_id
    where e.estado = 'activo'
  ), riesgos as (
    select r.* from cuidared_interno.reporte_riesgos(p_cuenta_id) r
  ), alertas as (
    select x.envejeciente_id, count(*)::integer as abiertas,
      count(*) filter (where x.estado = 'pendiente')::integer as pendientes,
      count(*) filter (where x.estado = 'en_proceso')::integer as en_proceso,
      count(*) filter (where x.prioritaria)::integer as prioritarias,
      count(*) filter (where not x.prioritaria and x.codigo = 'ausencia_visitas')::integer as seguimiento,
      count(*) filter (where not x.prioritaria and x.codigo <> 'ausencia_visitas')::integer as otras
    from (
      select ae.envejeciente_id, ae.estado, t.codigo::text as codigo,
        cuidared_interno.alerta_es_prioritaria(t.codigo) and num_nonnulls(ae.fuente_riesgo_id,
          ae.fuente_necesidad_id, ae.fuente_visita_id, ae.fuente_perfil_id) = 1 as prioritaria
      from cuidared.alerta_envejeciente ae
      join cuidared.envejeciente e on e.envejeciente_id = ae.envejeciente_id and e.cuenta_id = p_cuenta_id
      join cuidared.tipo_alerta t on t.tipo_alerta_id = ae.tipo_alerta_id
      cross join parametros p
      where ae.estado in ('pendiente', 'en_proceso') and (p.umbral is not null or t.codigo <> 'ausencia_visitas')
    ) x
    group by x.envejeciente_id
  ), necesidades as (
    select en.envejeciente_id, count(*)::integer as activas
    from cuidared.envejeciente_necesidad en
    join cuidared.envejeciente e on e.envejeciente_id = en.envejeciente_id and e.cuenta_id = p_cuenta_id
    where en.estado in ('pendiente', 'en_proceso')
    group by en.envejeciente_id
  ), visitas as (
    -- Misma referencia que cuidared_interno.alerta_ventana_sin_visita (fase 6).
    select distinct on (d.envejeciente_id) d.envejeciente_id, v.visita_id, v.fecha
    from cuidared.visita v
    join cuidared.detalle_visita d on d.visita_id = v.visita_id
    cross join parametros p
    where p.umbral is not null and v.cuenta_id = p_cuenta_id and v.estado = 'completada' and v.fecha <= p.hoy
    order by d.envejeciente_id, v.fecha desc, coalesce(v.hora_fin, v.hora_inicio) desc nulls last,
      v.fecha_creacion desc, v.visita_id
  ), asignados as (
    select s.envejeciente_id,
      coalesce(jsonb_agg(jsonb_build_object('usuario_id', s.usuario_id, 'nombres', s.nombres,
        'apellidos', s.apellidos) order by s.apellidos, s.nombres, s.usuario_id)
        filter (where s.tipo = 'cuidador_asignado'), '[]'::jsonb) as cuidadores,
      coalesce(jsonb_agg(jsonb_build_object('usuario_id', s.usuario_id, 'nombres', s.nombres,
        'apellidos', s.apellidos) order by s.apellidos, s.nombres, s.usuario_id)
        filter (where s.tipo = 'voluntario_asignado'), '[]'::jsonb) as voluntarios,
      array_agg(s.usuario_id order by s.usuario_id) as ids
    from cuidared_interno.reporte_asignaciones(p_cuenta_id) s
    group by s.envejeciente_id
  ), base as (
    select a.envejeciente_id, a.nombres::text as nombres, a.apellidos::text as apellidos,
      a.municipio_cod::text as municipio_cod, mu.nombre::text as municipio_nombre, a.zona::text as zona,
      a.fecha_creacion, r.riesgo,
      coalesce(al.abiertas, 0) as abiertas, coalesce(al.pendientes, 0) as pendientes,
      coalesce(al.en_proceso, 0) as en_proceso, coalesce(al.prioritarias, 0) as prioritarias,
      coalesce(al.seguimiento, 0) as seguimiento, coalesce(al.otras, 0) as otras,
      coalesce(ne.activas, 0) as activas, uv.visita_id, uv.fecha as ultima_fecha,
      case when p.umbral is not null
        then coalesce(uv.fecha, (a.fecha_creacion at time zone 'America/Santo_Domingo')::date) end as referencia,
      p.hoy, p.umbral, coalesce(asg.cuidadores, '[]'::jsonb) as cuidadores,
      coalesce(asg.voluntarios, '[]'::jsonb) as voluntarios, coalesce(asg.ids, array[]::uuid[]) as ids
    from adultos a
    cross join parametros p
    left join cuidared.municipio mu on mu.municipio_cod = a.municipio_cod
    left join riesgos r on r.envejeciente_id = a.envejeciente_id
    left join alertas al on al.envejeciente_id = a.envejeciente_id
    left join necesidades ne on ne.envejeciente_id = a.envejeciente_id
    left join visitas uv on uv.envejeciente_id = a.envejeciente_id
    left join asignados asg on asg.envejeciente_id = a.envejeciente_id
  )
  select b.envejeciente_id, b.nombres, b.apellidos, b.municipio_cod, b.municipio_nombre, b.zona, b.fecha_creacion,
    b.riesgo, case b.riesgo when 'alto' then 0 when 'medio' then 1 when 'bajo' then 2 else 3 end,
    b.abiertas, b.pendientes, b.en_proceso, b.prioritarias, b.seguimiento, b.otras, b.activas,
    b.visita_id, b.ultima_fecha, b.referencia, b.hoy - b.referencia, b.umbral, s.vencido,
    b.cuidadores, b.voluntarios, b.ids,
    pr.prioridad, case pr.prioridad when 'alta' then 0 when 'media' then 1 else 2 end,
    ea.estado, case ea.estado when 'alerta_pendiente' then 0 when 'alerta_en_proceso' then 1
      when 'seguimiento_vencido' then 2 when 'necesidades_activas' then 3 else 4 end,
    array_remove(array[
      case when b.prioritarias > 0 then 'alerta_prioritaria_abierta' end,
      case when b.riesgo = 'alto' then 'riesgo_alto' end,
      case when b.seguimiento > 0 then 'alerta_seguimiento_abierta' end,
      case when b.otras > 0 then 'alerta_abierta' end,
      case when s.vencido then 'seguimiento_vencido' end,
      case when b.activas > 0 then 'necesidades_activas' end,
      case when b.riesgo = 'medio' then 'riesgo_medio' end,
      case when b.riesgo is null then 'sin_evaluacion_vigente' end,
      case when cardinality(b.ids) = 0 then 'sin_personal_asignado' end], null)
  from base b
  cross join lateral (select coalesce((b.hoy - b.referencia) > b.umbral, false) as vencido) s
  cross join lateral (
    select case
      when b.prioritarias > 0 or b.riesgo = 'alto' then 'alta'
      when b.seguimiento > 0 or b.otras > 0 or s.vencido or b.activas > 0 or b.riesgo = 'medio' then 'media'
      else 'baja' end as prioridad
  ) pr
  cross join lateral (
    select case
      when b.pendientes > 0 then 'alerta_pendiente'
      when b.abiertas > 0 then 'alerta_en_proceso'
      when s.vencido then 'seguimiento_vencido'
      when b.activas > 0 then 'necesidades_activas'
      else 'al_dia' end as estado
  ) ea
$$;

-- Orden del resumen desde los tokens de `sort` (1 o 2 campos distintos), con el desempate fijo del contrato.
create or replace function cuidared_interno.reporte_orden_casos(p_orden text[]) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v_token text;
  v_campo text;
  v_desc boolean;
  v_vistos text[] := array[]::text[];
  v_partes text[] := array[]::text[];
  v_dir text;
begin
  if p_orden is null or cardinality(p_orden) not between 1 and 2 then raise invalid_parameter_value; end if;
  foreach v_token in array p_orden loop
    v_desc := left(v_token, 1) = '-';
    v_campo := case when v_desc then substr(v_token, 2) else v_token end;
    if v_campo is null or v_campo = any (v_vistos)
       or v_campo not in ('prioridad', 'estado_atencion', 'ultima_visita', 'riesgo', 'nombre') then
      raise invalid_parameter_value;
    end if;
    v_vistos := array_append(v_vistos, v_campo);
    v_dir := case when v_desc then 'desc' else 'asc' end;
    v_partes := array_append(v_partes, case v_campo
      when 'prioridad' then format('peso_prioridad %s', v_dir)
      when 'estado_atencion' then format('peso_estado %s', v_dir)
      when 'riesgo' then format('peso_riesgo %s', v_dir)
      when 'nombre' then format('apellidos %1$s, nombres %1$s', v_dir)
      when 'ultima_visita' then case when v_desc
        then 'ultima_visita_fecha desc nulls last, fecha_alta desc'
        else 'ultima_visita_fecha asc nulls first, fecha_alta asc' end
    end);
  end loop;
  return array_to_string(v_partes, ', ')
    || ', peso_prioridad, peso_estado, alertas_abiertas desc, peso_riesgo, dias_sin_visita desc,'
    || ' apellidos, nombres, envejeciente_id';
end;
$$;

create or replace function cuidared_api.api_resumen_casos_listar(p_cuenta_id bigint, p_filtros jsonb,
  p_orden text[], p_limite integer, p_desplazamiento bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'resumen:ver')->>'usuario_id')::uuid;
  v_f jsonb := coalesce(p_filtros, '{}'::jsonb);
  v_orden text;
  v_estado text;
  v_prioridad text;
  v_riesgo text;
  v_municipio text;
  v_zona text;
  v_asignado text;
  v_asignado_id uuid;
  v_q text;
  v_resultado jsonb;
begin
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(v_f) <> 'object'
     or v_f - array['estado_atencion', 'prioridad', 'riesgo', 'municipio_cod', 'zona', 'asignado', 'q'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_orden := cuidared_interno.reporte_orden_casos(p_orden);
  v_estado := cuidared_interno.reporte_codigo(v_f->'estado_atencion',
    array['alerta_pendiente', 'alerta_en_proceso', 'seguimiento_vencido', 'necesidades_activas', 'al_dia']);
  v_prioridad := cuidared_interno.reporte_codigo(v_f->'prioridad', array['alta', 'media', 'baja']);
  v_riesgo := cuidared_interno.reporte_codigo(v_f->'riesgo', array['alto', 'medio', 'bajo', 'sin_evaluacion']);
  if v_f ? 'municipio_cod' and jsonb_typeof(v_f->'municipio_cod') <> 'null' then
    if jsonb_typeof(v_f->'municipio_cod') <> 'string' or (v_f->>'municipio_cod') !~ '^[0-9]{4,6}$' then
      raise invalid_parameter_value;
    end if;
    v_municipio := v_f->>'municipio_cod';
  end if;
  v_zona := cuidared_interno.v_texto(v_f->'zona', 1, 60, false);
  v_q := cuidared_interno.v_texto(v_f->'q', 2, 60, false);
  if v_f ? 'asignado' and jsonb_typeof(v_f->'asignado') <> 'null' then
    if jsonb_typeof(v_f->'asignado') = 'string' and (v_f->>'asignado') in ('sin', 'con') then
      v_asignado := v_f->>'asignado';
    else
      v_asignado_id := cuidared_interno.v_uuid(v_f->'asignado');
      v_asignado := 'usuario';
    end if;
  end if;

  execute format($q$
    with casos as materialized (
      select c.* from cuidared_interno.reporte_casos($1, $2) c
      where ($3::text is null or c.estado_atencion = $3)
        and ($4::text is null or c.prioridad = $4)
        and ($5::text is null or ($5 = 'sin_evaluacion' and c.riesgo_vigente is null) or c.riesgo_vigente = $5)
        and ($6::text is null or c.municipio_cod = $6)
        and ($7::text is null or c.zona = $7)
        and ($8::text is null
             or ($8 = 'sin' and cardinality(c.asignados) = 0)
             or ($8 = 'con' and cardinality(c.asignados) > 0)
             or ($8 = 'usuario' and $9 = any (c.asignados)))
        and ($10::text is null or position(lower($10) in
             lower(concat_ws(' ', c.nombres, c.apellidos, c.zona, c.municipio_nombre))) > 0)
    ), pagina as (
      select c.*, row_number() over (order by %1$s) as posicion
      from casos c order by %1$s limit $11 offset $12
    )
    select jsonb_build_object('total', (select count(*) from casos), 'items', coalesce(jsonb_agg(
      jsonb_build_object(
        'envejeciente_id', p.envejeciente_id, 'nombres', p.nombres, 'apellidos', p.apellidos,
        'municipio', jsonb_build_object('codigo', p.municipio_cod, 'nombre', p.municipio_nombre),
        'zona', p.zona, 'fecha_alta', p.fecha_alta, 'riesgo_vigente', p.riesgo_vigente,
        'prioridad', p.prioridad, 'estado_atencion', p.estado_atencion, 'motivos', to_jsonb(p.motivos),
        'alertas', jsonb_build_object('abiertas', p.alertas_abiertas, 'pendientes', p.alertas_pendientes,
          'en_proceso', p.alertas_en_proceso, 'prioritarias_abiertas', p.alertas_prioritarias_abiertas),
        'necesidades_activas', p.necesidades_activas,
        'seguimiento', case when p.umbral_dias is not null then jsonb_build_object('ultima_visita_id', p.ultima_visita_id,
          'ultima_visita_fecha', p.ultima_visita_fecha, 'fecha_referencia', p.fecha_referencia,
          'dias_sin_visita', p.dias_sin_visita, 'umbral_dias', p.umbral_dias, 'vencido', p.seguimiento_vencido) end,
        'asignados', jsonb_build_object('total', cardinality(p.asignados),
          'cuidadores', p.cuidadores, 'voluntarios', p.voluntarios)
      ) order by p.posicion), '[]'::jsonb))
    from pagina p
  $q$, v_orden)
  into v_resultado
  using p_cuenta_id, v_uid, v_estado, v_prioridad, v_riesgo, v_municipio, v_zona, v_asignado, v_asignado_id,
    v_q, p_limite, p_desplazamiento;
  return v_resultado;
end;
$$;

create or replace function cuidared_api.api_resumen_casos_indicadores(p_cuenta_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'resumen:ver')->>'usuario_id')::uuid;
  v_resultado jsonb;
begin
  with c as materialized (select * from cuidared_interno.reporte_casos(p_cuenta_id, v_uid))
  select jsonb_build_object(
    'fecha_calculo', cuidared_interno.hoy(),
    'umbral_dias_sin_visita', cuidared_interno.umbral_seguimiento_visitas(p_cuenta_id),
    'casos_activos', count(*),
    'por_prioridad', jsonb_build_object(
      'alta', count(*) filter (where c.prioridad = 'alta'),
      'media', count(*) filter (where c.prioridad = 'media'),
      'baja', count(*) filter (where c.prioridad = 'baja')),
    'por_estado_atencion', jsonb_build_object(
      'alerta_pendiente', count(*) filter (where c.estado_atencion = 'alerta_pendiente'),
      'alerta_en_proceso', count(*) filter (where c.estado_atencion = 'alerta_en_proceso'),
      'seguimiento_vencido', count(*) filter (where c.estado_atencion = 'seguimiento_vencido'),
      'necesidades_activas', count(*) filter (where c.estado_atencion = 'necesidades_activas'),
      'al_dia', count(*) filter (where c.estado_atencion = 'al_dia')),
    'adultos_prioritarios', count(*) filter (where c.alertas_prioritarias_abiertas > 0),
    'alertas_prioritarias_abiertas', coalesce(sum(c.alertas_prioritarias_abiertas), 0),
    'alertas_abiertas', coalesce(sum(c.alertas_abiertas), 0),
    'alertas_pendientes', coalesce(sum(c.alertas_pendientes), 0),
    'alertas_en_proceso', coalesce(sum(c.alertas_en_proceso), 0),
    'seguimiento_vencido', count(*) filter (where c.seguimiento_vencido),
    'necesidades_activas', coalesce(sum(c.necesidades_activas), 0),
    'adultos_con_necesidades_activas', count(*) filter (where c.necesidades_activas > 0),
    'sin_personal_asignado', count(*) filter (where cardinality(c.asignados) = 0))
  into v_resultado
  from c;
  return v_resultado;
end;
$$;

/* ───────────── 3. Reportes estadísticos (RF-08) ───────────── */

-- Adultos de la cuenta, en cualquier estado, con consentimiento vigente, al alcance del actor y que cumplen
-- los filtros de municipio, sector y riesgo vigente actuales.
create or replace function cuidared_interno.reporte_poblacion(p_cuenta_id bigint, p_usuario_id uuid, p_f jsonb)
returns table (envejeciente_id uuid, nombres text, apellidos text, municipio_cod text, municipio_nombre text,
  zona text, estado text, sexo text, fecha_nacimiento date, fecha_alta timestamptz, dia_alta date,
  riesgo_vigente text)
language sql stable set search_path = '' as $$
  select e.envejeciente_id, e.nombres::text, e.apellidos::text, e.municipio_cod::text, mu.nombre::text,
    e.zona::text, e.estado::text, e.sexo::text, e.fecha_nacimiento, e.fecha_creacion,
    (e.fecha_creacion at time zone 'America/Santo_Domingo')::date, r.riesgo
  from cuidared.envejeciente e
  join cuidared_interno.reporte_alcance(p_cuenta_id, p_usuario_id) s on s.envejeciente_id = e.envejeciente_id
  left join cuidared.municipio mu on mu.municipio_cod = e.municipio_cod
  left join cuidared_interno.reporte_riesgos(p_cuenta_id) r on r.envejeciente_id = e.envejeciente_id
  where (p_f->>'municipio_cod' is null or e.municipio_cod = p_f->>'municipio_cod')
    and (p_f->>'zona' is null or e.zona = p_f->>'zona')
    and (p_f->>'riesgo' is null
         or (p_f->>'riesgo' = 'sin_evaluacion' and r.riesgo is null)
         or r.riesgo = p_f->>'riesgo')
$$;

-- Serie `por_mes` a partir de los días de los registros (jsonb array de fechas `YYYY-MM-DD`).
create or replace function cuidared_interno.reporte_por_mes(p_dias date[], p_f jsonb, p_hoy date) returns jsonb
language sql immutable set search_path = '' as $$
  select cuidared_interno.reporte_serie(coalesce(jsonb_agg(jsonb_build_object('clave', m.clave,
      'etiqueta', m.clave,
      'valor', (select count(*) from unnest(coalesce(p_dias, array[]::date[])) d where d between m.inicio and m.fin))
    order by m.inicio), '[]'::jsonb))
  from cuidared_interno.reporte_meses((p_f->>'desde')::date, (p_f->>'hasta')::date,
    (select min(d) from unnest(coalesce(p_dias, array[]::date[])) d), p_hoy) m
$$;

create or replace function cuidared_interno.reporte_adultos(p_cuenta_id bigint, p_usuario_id uuid, p_f jsonb,
  p_hoy date) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_desde date := (p_f->>'desde')::date;
  v_hasta date := (p_f->>'hasta')::date;
  v jsonb;
begin
  with p as materialized (
    select b.*, extract(year from age(p_hoy, b.fecha_nacimiento))::integer as edad,
      coalesce(pa.n, 0)::integer as personal
    from cuidared_interno.reporte_poblacion(p_cuenta_id, p_usuario_id, p_f) b
    left join (select s.envejeciente_id, count(*) as n from cuidared_interno.reporte_asignaciones(p_cuenta_id) s
               group by s.envejeciente_id) pa on pa.envejeciente_id = b.envejeciente_id
    where (v_desde is null or b.dia_alta >= v_desde) and (v_hasta is null or b.dia_alta <= v_hasta)
  ), act as materialized (select * from p where p.estado = 'activo')
  select jsonb_build_object(
    'vacio', (select count(*) from p) = 0,
    'indicadores', jsonb_build_object(
      'registrados', (select count(*) from p),
      'activos', (select count(*) from act),
      'inactivos', (select count(*) from p where p.estado = 'inactivo'),
      'fallecidos', (select count(*) from p where p.estado = 'fallecido'),
      'riesgo_alto', (select count(*) from act where act.riesgo_vigente = 'alto'),
      'riesgo_medio', (select count(*) from act where act.riesgo_vigente = 'medio'),
      'riesgo_bajo', (select count(*) from act where act.riesgo_vigente = 'bajo'),
      'sin_evaluacion', (select count(*) from act where act.riesgo_vigente is null),
      'edad_promedio', (select round(avg(p.edad), 1) from p),
      'sin_personal_asignado', (select count(*) from act where act.personal = 0)),
    'series', jsonb_build_object(
      'por_riesgo', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', n.clave, 'etiqueta', n.etiqueta, 'valor',
          (select count(*) from act where coalesce(act.riesgo_vigente, 'sin_evaluacion') = n.clave)) order by n.orden)
        from (values ('alto', 'Alto', 1), ('medio', 'Medio', 2), ('bajo', 'Bajo', 3),
                     ('sin_evaluacion', 'Sin evaluación vigente', 4)) n(clave, etiqueta, orden))),
      'por_municipio', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', g.municipio_cod, 'etiqueta', g.etiqueta, 'valor', g.n)
          order by g.n desc, g.etiqueta, g.municipio_cod)
        from (select act.municipio_cod, coalesce(act.municipio_nombre, act.municipio_cod) as etiqueta, count(*) as n
              from act group by 1, 2) g)),
      'por_zona', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', g.clave, 'etiqueta', g.etiqueta, 'valor', g.n)
          order by g.n desc, g.etiqueta)
        from (select coalesce(act.zona, 'sin_zona') as clave, coalesce(act.zona, 'Sin sector') as etiqueta,
                count(*) as n from act group by 1, 2) g)),
      'por_estado', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', s.clave, 'etiqueta', s.etiqueta, 'valor',
          (select count(*) from p where p.estado = s.clave)) order by s.orden)
        from (values ('activo', 'Activo', 1), ('inactivo', 'Inactivo', 2), ('fallecido', 'Fallecido', 3))
          s(clave, etiqueta, orden))),
      'por_mes', cuidared_interno.reporte_por_mes((select array_agg(p.dia_alta) from p), p_f, p_hoy)),
    'detalle', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'envejeciente_id', d.envejeciente_id, 'nombres', d.nombres, 'apellidos', d.apellidos,
        'municipio', jsonb_build_object('codigo', d.municipio_cod, 'nombre', d.municipio_nombre),
        'zona', d.zona, 'edad', d.edad, 'sexo', d.sexo, 'riesgo_vigente', d.riesgo_vigente, 'estado', d.estado,
        'fecha_alta', d.fecha_alta, 'personal_asignado', d.personal)
        order by d.apellidos, d.nombres, d.envejeciente_id), '[]'::jsonb)
      from (select * from p order by p.apellidos, p.nombres, p.envejeciente_id limit 5000) d),
    'detalle_total', (select count(*) from p),
    'detalle_truncado', (select count(*) from p) > 5000)
  into v;
  return v;
end;
$$;

-- Una actividad institucional sin expediente solo puede coincidir con filtros de la visita, como el período.
create or replace function cuidared_interno.reporte_visitas_institucionales(p_cuenta_id bigint, p_f jsonb)
returns table (visita_id uuid, fecha date)
language sql stable set search_path = '' as $$
  select v.visita_id, v.fecha
  from cuidared.visita v
  join cuidared.solicitud_visita s on s.solicitud_visita_id = v.solicitud_visita_id and s.cuenta_id = v.cuenta_id
  where v.cuenta_id = p_cuenta_id and v.estado = 'completada' and s.tipo_visita = 'institucional'
    and p_f->>'municipio_cod' is null and p_f->>'zona' is null and p_f->>'riesgo' is null
    and (p_f->>'desde' is null or v.fecha >= (p_f->>'desde')::date)
    and (p_f->>'hasta' is null or v.fecha <= (p_f->>'hasta')::date)
    and not exists (select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id)
$$;

create or replace function cuidared_interno.reporte_visitas(p_cuenta_id bigint, p_usuario_id uuid, p_f jsonb,
  p_hoy date) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_desde date := (p_f->>'desde')::date;
  v_hasta date := (p_f->>'hasta')::date;
  v jsonb;
begin
  with pob as materialized (
    select * from cuidared_interno.reporte_poblacion(p_cuenta_id, p_usuario_id, p_f)
  ), atenciones_cuenta as materialized (
    select v.visita_id, v.fecha, d.envejeciente_id, d.estado_general::text as estado_general
    from cuidared.visita v
    join cuidared.detalle_visita d on d.visita_id = v.visita_id
    where v.cuenta_id = p_cuenta_id and v.estado = 'completada'
      and (v_desde is null or v.fecha >= v_desde) and (v_hasta is null or v.fecha <= v_hasta)
  ), atenciones as materialized (
    select ac.visita_id, ac.fecha, ac.envejeciente_id, ac.estado_general, pob.nombres, pob.apellidos
    from atenciones_cuenta ac join pob on pob.envejeciente_id = ac.envejeciente_id
  ), visitas_incluidas as (
    select distinct a.visita_id, 'personal'::text as tipo_visita from atenciones a
    union all
    select i.visita_id, 'institucional' from cuidared_interno.reporte_visitas_institucionales(p_cuenta_id, p_f) i
  ), visitas as materialized (
    -- adultos_total cuenta todos los adultos registrados en la visita, también los que quedan fuera del filtro.
    select v.visita_id, v.fecha, v.hora_inicio, v.hora_fin, v.razon::text as razon, v.origen::text as origen,
      v.fecha_creacion, ids.tipo_visita, coalesce(t.adultos_total, 0) as adultos_total
    from visitas_incluidas ids
    join cuidared.visita v on v.visita_id = ids.visita_id
    left join (select ac.visita_id, count(*) as adultos_total from atenciones_cuenta ac group by ac.visita_id) t
      on t.visita_id = v.visita_id
  ), pagina as materialized (
    select * from visitas
    order by visitas.fecha desc, visitas.hora_inicio desc nulls last, visitas.fecha_creacion desc, visitas.visita_id
    limit 5000
  ), adultos_visita as (
    select a.visita_id, jsonb_agg(jsonb_build_object('envejeciente_id', a.envejeciente_id, 'nombres', a.nombres,
        'apellidos', a.apellidos, 'estado_general', a.estado_general)
        order by a.apellidos, a.nombres, a.envejeciente_id) as adultos
    from atenciones a join pagina p on p.visita_id = a.visita_id
    group by a.visita_id
  ), responsables as (
    select r.visita_id, jsonb_agg(jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres,
        'apellidos', u.apellidos) order by u.apellidos, u.nombres, u.usuario_id) as responsables
    from cuidared.registro_visita r
    join pagina p on p.visita_id = r.visita_id
    join cuidared.usuario u on u.usuario_id = r.usuario_id
    group by r.visita_id
  )
  select jsonb_build_object(
    'vacio', (select count(*) from visitas) = 0,
    'indicadores', jsonb_build_object(
      'visitas_realizadas', (select count(*) from visitas),
      'visitas_personales', (select count(*) from visitas where tipo_visita = 'personal'),
      'visitas_institucionales', (select count(*) from visitas where tipo_visita = 'institucional'),
      'atenciones', (select count(*) from atenciones),
      'adultos_visitados', (select count(distinct a.envejeciente_id) from atenciones a),
      'adultos_activos', (select count(*) from pob where pob.estado = 'activo'),
      'promedio_por_adulto', (select round(count(*)::numeric / nullif(count(distinct a.envejeciente_id), 0), 2)
                              from atenciones a),
      'requirieron_atencion', (select count(*) from atenciones a
                               where a.estado_general in ('requiere_atencion', 'situacion_critica')),
      'situaciones_criticas', (select count(*) from atenciones a where a.estado_general = 'situacion_critica'),
      'visitas_compartidas', (select count(*) from visitas where visitas.adultos_total > 1)),
    'series', jsonb_build_object(
      'por_mes', cuidared_interno.reporte_por_mes((select array_agg(visitas.fecha) from visitas), p_f, p_hoy),
      'por_tipo_visita', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', s.clave, 'etiqueta', s.etiqueta,
          'valor', (select count(*) from visitas where tipo_visita = s.clave)) order by s.orden)
        from (values ('personal', 'Con expediente', 1), ('institucional', 'Institucional sin expediente', 2))
          s(clave, etiqueta, orden))),
      'por_estado_general', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', s.clave, 'etiqueta', s.etiqueta, 'valor',
          (select count(*) from atenciones a where coalesce(a.estado_general, 'sin_registro') = s.clave))
          order by s.orden)
        from (values ('estable', 'Estable', 1), ('requiere_atencion', 'Requiere atención', 2),
                     ('situacion_critica', 'Situación crítica', 3), ('sin_registro', 'Sin registro', 4))
          s(clave, etiqueta, orden)))),
    'detalle', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'visita_id', d.visita_id, 'fecha', d.fecha, 'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
        'hora_fin', to_char(d.hora_fin, 'HH24:MI'), 'razon', d.razon, 'origen', d.origen, 'tipo_visita', d.tipo_visita,
        'responsables', coalesce(r.responsables, '[]'::jsonb), 'adultos', coalesce(av.adultos, '[]'::jsonb))
        order by d.fecha desc, d.hora_inicio desc nulls last, d.fecha_creacion desc, d.visita_id), '[]'::jsonb)
      from pagina d
      left join adultos_visita av on av.visita_id = d.visita_id
      left join responsables r on r.visita_id = d.visita_id),
    'detalle_total', (select count(*) from visitas),
    'detalle_truncado', (select count(*) from visitas) > 5000)
  into v;
  return v;
end;
$$;

create or replace function cuidared_interno.reporte_necesidades(p_cuenta_id bigint, p_usuario_id uuid, p_f jsonb,
  p_hoy date) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_desde date := (p_f->>'desde')::date;
  v_hasta date := (p_f->>'hasta')::date;
  v_tipo integer := (p_f->>'tipo_necesidad_id')::integer;
  v jsonb;
begin
  with pob as materialized (
    select * from cuidared_interno.reporte_poblacion(p_cuenta_id, p_usuario_id, p_f)
  ), nec as materialized (
    select en.envejeciente_necesidad_id, en.envejeciente_id, en.estado::text as estado, en.es_recurrente,
      n.tipo_necesidad_id, pr.prioridad_id, coalesce(pr.codigo::text, pr.prioridad_id::text) as prioridad,
      (en.fecha_necesidad at time zone 'America/Santo_Domingo')::date as dia
    from pob
    join cuidared.envejeciente_necesidad en on en.envejeciente_id = pob.envejeciente_id
    join cuidared.necesidad n on n.necesidad_id = en.necesidad_id
    join cuidared.prioridad pr on pr.prioridad_id = en.prioridad_id
    where (v_tipo is null or n.tipo_necesidad_id = v_tipo)
      and (v_desde is null or (en.fecha_necesidad at time zone 'America/Santo_Domingo')::date >= v_desde)
      and (v_hasta is null or (en.fecha_necesidad at time zone 'America/Santo_Domingo')::date <= v_hasta)
  ), tipos as materialized (
    select t.tipo_necesidad_id, t.nombre::text as nombre,
      count(nec.envejeciente_necesidad_id) as total,
      count(*) filter (where nec.estado = 'pendiente') as pendientes,
      count(*) filter (where nec.estado = 'en_proceso') as en_proceso,
      count(*) filter (where nec.estado = 'resuelta') as resueltas,
      count(*) filter (where nec.estado = 'cancelada') as canceladas,
      count(*) filter (where nec.prioridad = 'alta') as prioridad_alta,
      count(*) filter (where nec.es_recurrente) as recurrentes
    from cuidared.tipo_necesidad t
    left join nec on nec.tipo_necesidad_id = t.tipo_necesidad_id
    where v_tipo is null or t.tipo_necesidad_id = v_tipo
    group by t.tipo_necesidad_id, t.nombre
  ), totales as (
    select count(*) as registradas from nec
  )
  select jsonb_build_object(
    'vacio', (select registradas from totales) = 0,
    'indicadores', jsonb_build_object(
      'registradas', (select registradas from totales),
      'activas', (select count(*) from nec where nec.estado in ('pendiente', 'en_proceso')),
      'pendientes', (select count(*) from nec where nec.estado = 'pendiente'),
      'en_proceso', (select count(*) from nec where nec.estado = 'en_proceso'),
      'resueltas', (select count(*) from nec where nec.estado = 'resuelta'),
      'canceladas', (select count(*) from nec where nec.estado = 'cancelada'),
      'porcentaje_resueltas', (select case when count(*) = 0 then 0
        else round(count(*) filter (where nec.estado = 'resuelta') * 100.0 / count(*))::integer end from nec),
      'prioridad_alta_activas', (select count(*) from nec
                                 where nec.prioridad = 'alta' and nec.estado in ('pendiente', 'en_proceso')),
      'recurrentes', (select count(*) from nec where nec.es_recurrente),
      'adultos_con_necesidades', (select count(distinct nec.envejeciente_id) from nec),
      'mas_frecuente', (select jsonb_build_object('tipo_necesidad_id', t.tipo_necesidad_id, 'nombre', t.nombre,
                          'total', t.total)
                        from tipos t where t.total > 0 order by t.total desc, t.nombre, t.tipo_necesidad_id limit 1)),
    'series', jsonb_build_object(
      'por_tipo', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', t.tipo_necesidad_id::text, 'etiqueta', t.nombre,
          'valor', t.total) order by t.total desc, t.nombre, t.tipo_necesidad_id)
        from tipos t)),
      'por_estado', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', s.clave, 'etiqueta', s.etiqueta, 'valor',
          (select count(*) from nec where nec.estado = s.clave)) order by s.orden)
        from (values ('pendiente', 'Pendiente', 1), ('en_proceso', 'En proceso', 2), ('resuelta', 'Resuelta', 3),
                     ('cancelada', 'Cancelada', 4)) s(clave, etiqueta, orden))),
      'por_prioridad', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', coalesce(pr.codigo::text, pr.prioridad_id::text),
          'etiqueta', pr.nombre, 'valor', (select count(*) from nec where nec.prioridad_id = pr.prioridad_id))
          order by pr.orden, pr.prioridad_id)
        from cuidared.prioridad pr)),
      'recurrencia', cuidared_interno.reporte_serie(jsonb_build_array(
        jsonb_build_object('clave', 'recurrente', 'etiqueta', 'Recurrentes',
          'valor', (select count(*) from nec where nec.es_recurrente)),
        jsonb_build_object('clave', 'puntual', 'etiqueta', 'Puntuales',
          'valor', (select count(*) from nec where not nec.es_recurrente)))),
      'por_mes', cuidared_interno.reporte_por_mes((select array_agg(nec.dia) from nec), p_f, p_hoy)),
    'detalle', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tipo_necesidad_id', t.tipo_necesidad_id, 'nombre', t.nombre, 'total', t.total,
        'porcentaje', round(t.total * 100.0 / tot.registradas)::integer,
        'pendientes', t.pendientes, 'en_proceso', t.en_proceso, 'resueltas', t.resueltas,
        'canceladas', t.canceladas, 'prioridad_alta', t.prioridad_alta, 'recurrentes', t.recurrentes)
        order by t.total desc, t.nombre, t.tipo_necesidad_id), '[]'::jsonb)
      from tipos t cross join totales tot where t.total > 0),
    'detalle_total', (select count(*) from tipos where tipos.total > 0),
    'detalle_truncado', false)
  into v;
  return v;
end;
$$;

create or replace function cuidared_interno.reporte_casos_prioritarios(p_cuenta_id bigint, p_usuario_id uuid,
  p_f jsonb, p_hoy date) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_desde date := (p_f->>'desde')::date;
  v_hasta date := (p_f->>'hasta')::date;
  v jsonb;
begin
  with pob as materialized (
    select * from cuidared_interno.reporte_poblacion(p_cuenta_id, p_usuario_id, p_f)
  ), al as materialized (
    select ae.alerta_envejeciente_id, ae.envejeciente_id, ae.estado::text as estado, ae.fecha_alerta,
      ae.cierre_automatico, t.codigo::text as tipo, (ae.fecha_alerta at time zone 'America/Santo_Domingo')::date as dia
    from pob
    join cuidared.alerta_envejeciente ae on ae.envejeciente_id = pob.envejeciente_id
    join cuidared.tipo_alerta t on t.tipo_alerta_id = ae.tipo_alerta_id
    where cuidared_interno.alerta_es_prioritaria(t.codigo)
      and num_nonnulls(ae.fuente_riesgo_id, ae.fuente_necesidad_id, ae.fuente_visita_id, ae.fuente_perfil_id) = 1
      and (v_desde is null or (ae.fecha_alerta at time zone 'America/Santo_Domingo')::date >= v_desde)
      and (v_hasta is null or (ae.fecha_alerta at time zone 'America/Santo_Domingo')::date <= v_hasta)
  ), casos as materialized (
    select pob.envejeciente_id, pob.nombres, pob.apellidos, pob.municipio_cod, pob.municipio_nombre, pob.zona,
      pob.riesgo_vigente, count(*) as alertas,
      count(*) filter (where al.estado in ('pendiente', 'en_proceso')) as abiertas,
      array_agg(distinct al.tipo order by al.tipo) as tipos,
      case when bool_or(al.estado = 'pendiente') then 'pendiente'
           when bool_or(al.estado = 'en_proceso') then 'en_proceso' else 'resuelta' end as estado_actual,
      max(al.fecha_alerta) as ultima_alerta
    from al join pob on pob.envejeciente_id = al.envejeciente_id
    group by pob.envejeciente_id, pob.nombres, pob.apellidos, pob.municipio_cod, pob.municipio_nombre, pob.zona,
      pob.riesgo_vigente
  )
  select jsonb_build_object(
    'vacio', (select count(*) from al) = 0,
    'indicadores', jsonb_build_object(
      'alertas_prioritarias', (select count(*) from al),
      'adultos_prioritarios', (select count(*) from casos),
      'casos_abiertos', (select count(*) from casos where casos.abiertas > 0),
      'alertas_pendientes', (select count(*) from al where al.estado = 'pendiente'),
      'alertas_en_proceso', (select count(*) from al where al.estado = 'en_proceso'),
      'alertas_resueltas', (select count(*) from al where al.estado = 'resuelta'),
      'resueltas_automaticamente', (select count(*) from al where al.estado = 'resuelta' and al.cierre_automatico),
      'porcentaje_resueltas', (select case when count(*) = 0 then 0
        else round(count(*) filter (where al.estado = 'resuelta') * 100.0 / count(*))::integer end from al)),
    'series', jsonb_build_object(
      'por_estado', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', s.clave, 'etiqueta', s.etiqueta, 'valor',
          (select count(*) from al where al.estado = s.clave)) order by s.orden)
        from (values ('pendiente', 'Pendiente', 1), ('en_proceso', 'En proceso', 2), ('resuelta', 'Resuelta', 3))
          s(clave, etiqueta, orden))),
      'por_tipo', cuidared_interno.reporte_serie((
        select jsonb_agg(jsonb_build_object('clave', s.clave, 'etiqueta', s.etiqueta, 'valor',
          (select count(*) from al where al.tipo = s.clave)) order by s.orden)
        from (values ('riesgo_alto', 'Riesgo alto', 1), ('medicamento_pendiente', 'Medicamentos pendientes', 2),
                     ('necesidad_prioritaria', 'Necesidad prioritaria', 3)) s(clave, etiqueta, orden))),
      'por_mes', cuidared_interno.reporte_por_mes((select array_agg(al.dia) from al), p_f, p_hoy)),
    'detalle', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'envejeciente_id', c.envejeciente_id, 'nombres', c.nombres, 'apellidos', c.apellidos,
        'municipio', jsonb_build_object('codigo', c.municipio_cod, 'nombre', c.municipio_nombre),
        'zona', c.zona, 'riesgo_vigente', c.riesgo_vigente, 'alertas', c.alertas, 'alertas_abiertas', c.abiertas,
        'tipos', to_jsonb(c.tipos), 'estado_actual', c.estado_actual, 'ultima_alerta', c.ultima_alerta)
        order by (c.abiertas > 0) desc, c.apellidos, c.nombres, c.envejeciente_id), '[]'::jsonb)
      from (select * from casos
            order by (casos.abiertas > 0) desc, casos.apellidos, casos.nombres, casos.envejeciente_id
            limit 5000) c),
    'detalle_total', (select count(*) from casos),
    'detalle_truncado', (select count(*) from casos) > 5000)
  into v;
  return v;
end;
$$;

-- Envoltura común del contrato: tipo, fecha que filtra, zona horaria, filtros normalizados y contenido.
create or replace function cuidared_interno.reporte_construir(p_cuenta_id bigint, p_usuario_id uuid, p_tipo text,
  p_f jsonb) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_hoy date := cuidared_interno.hoy();
  v_contenido jsonb;
begin
  v_contenido := case p_tipo
    when 'adultos' then cuidared_interno.reporte_adultos(p_cuenta_id, p_usuario_id, p_f, v_hoy)
    when 'visitas' then cuidared_interno.reporte_visitas(p_cuenta_id, p_usuario_id, p_f, v_hoy)
    when 'necesidades' then cuidared_interno.reporte_necesidades(p_cuenta_id, p_usuario_id, p_f, v_hoy)
    when 'casos_prioritarios' then cuidared_interno.reporte_casos_prioritarios(p_cuenta_id, p_usuario_id, p_f, v_hoy)
  end;
  if v_contenido is null then raise invalid_parameter_value; end if;
  return jsonb_build_object(
    'tipo', p_tipo,
    'campo_fecha', case p_tipo when 'adultos' then 'fecha_alta' when 'visitas' then 'fecha_visita'
      when 'necesidades' then 'fecha_registro' else 'fecha_alerta' end,
    'zona_horaria', 'America/Santo_Domingo',
    'generado_en', pg_catalog.now(),
    'filtros', p_f) || v_contenido;
end;
$$;

-- Requisitos de cada tipo: permiso adicional y claves de filtro admitidas.
create or replace function cuidared_interno.reporte_permisos_tipo(p_tipo text) returns text[]
language sql immutable set search_path = '' as $$
  select case when p_tipo = 'visitas' then array['visitas:ver'] else array[]::text[] end
$$;

create or replace function cuidared_interno.reporte_claves_tipo(p_tipo text) returns text[]
language sql immutable set search_path = '' as $$
  select array['desde', 'hasta', 'municipio_cod', 'zona', 'riesgo']
    || case when p_tipo = 'necesidades' then array['tipo_necesidad_id'] else array[]::text[] end
$$;

create or replace function cuidared_api.api_reporte(p_cuenta_id bigint, p_tipo text, p_filtros jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'reportes:ver')->>'usuario_id')::uuid;
begin
  perform cuidared_interno.reporte_exigir_extra(p_cuenta_id, v_uid, cuidared_interno.reporte_permisos_tipo(p_tipo),
    array['dashboard_metricas']);
  if p_tipo is null or p_tipo not in ('adultos', 'visitas', 'necesidades', 'casos_prioritarios') then
    raise invalid_parameter_value;
  end if;
  return cuidared_interno.reporte_construir(p_cuenta_id, v_uid, p_tipo,
    cuidared_interno.reporte_filtros(p_filtros, cuidared_interno.reporte_claves_tipo(p_tipo)));
end;
$$;

/* ───────────── 4. Análisis avanzado (reportes_avanzados) ───────────── */

-- Comparativos y tendencias. Sin `visitas:ver` (Familia) las métricas de visitas se publican como null.
create or replace function cuidared_interno.reporte_avanzado(p_cuenta_id bigint, p_usuario_id uuid, p_f jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_hoy date := cuidared_interno.hoy();
  v_desde date := (p_f->>'desde')::date;
  v_hasta date := (p_f->>'hasta')::date;
  v_fin date := coalesce(v_hasta, v_hoy);
  v_inicio date;
  v_corte_inicio date := v_desde;
  v_meses integer;
  v_visitas boolean := cuidared_interno.tiene_permiso(p_cuenta_id, p_usuario_id, 'visitas:ver');
  v jsonb;
begin
  -- Tendencias: el periodo pedido, con los meses de los extremos recortados a `desde` y `hasta`. Sin `desde`, los
  -- 12 meses que terminan en `hasta`; con menos de 3 meses, los 6 que terminan en `hasta`. Los meses agregados por
  -- esa ampliación son completos; el último se recorta siempre a `hasta`.
  v_inicio := coalesce(v_desde, (date_trunc('month', v_fin::timestamp) - interval '11 months')::date);
  select count(*) into v_meses from cuidared_interno.reporte_meses(v_inicio, v_fin, null, v_hoy);
  if v_desde is null or v_meses < 3 then
    v_corte_inicio := null;
  end if;
  if v_meses < 3 then
    v_inicio := (date_trunc('month', v_fin::timestamp) - interval '5 months')::date;
  end if;

  with pob as materialized (
    select * from cuidared_interno.reporte_poblacion(p_cuenta_id, p_usuario_id, p_f)
  ), activos as materialized (
    select c.* from cuidared_interno.reporte_casos(p_cuenta_id, p_usuario_id) c
    where c.envejeciente_id in (select pob.envejeciente_id from pob)
  ), visitas_pob as materialized (
    -- Atenciones de visitas completadas de la población (cualquier estado del adulto), solo con `visitas:ver`.
    select distinct x.visita_id, x.fecha, x.envejeciente_id
    from (select v.visita_id, v.fecha, d.envejeciente_id
          from cuidared.visita v join cuidared.detalle_visita d on d.visita_id = v.visita_id
          where v_visitas and v.cuenta_id = p_cuenta_id and v.estado = 'completada') x
    join pob on pob.envejeciente_id = x.envejeciente_id
  ), visitas_activos as materialized (
    select va.visita_id, a.municipio_cod, a.zona
    from visitas_pob va join activos a on a.envejeciente_id = va.envejeciente_id
    where (v_desde is null or va.fecha >= v_desde) and (v_hasta is null or va.fecha <= v_hasta)
  ), necesidades_activos as (
    select en.envejeciente_id, count(*) as n
    from activos a join cuidared.envejeciente_necesidad en on en.envejeciente_id = a.envejeciente_id
    where en.estado in ('pendiente', 'en_proceso')
      and (v_desde is null or (en.fecha_necesidad at time zone 'America/Santo_Domingo')::date >= v_desde)
      and (v_hasta is null or (en.fecha_necesidad at time zone 'America/Santo_Domingo')::date <= v_hasta)
    group by en.envejeciente_id
  ), por_adulto as materialized (
    select a.*, coalesce(n.n, 0) as necesidades from activos a
    left join necesidades_activos n on n.envejeciente_id = a.envejeciente_id
  ), zonas as (
    select a.municipio_cod, a.municipio_nombre, a.zona, count(*) as adultos_activos,
      count(*) filter (where a.riesgo_vigente = 'alto') as riesgo_alto,
      sum(a.necesidades) as necesidades_activas, sum(a.alertas_abiertas) as alertas_abiertas,
      round(avg(a.dias_sin_visita), 1) as dias_sin_visita_promedio,
      count(*) filter (where cardinality(a.asignados) = 0) as sin_personal_asignado
    from por_adulto a
    group by a.municipio_cod, a.municipio_nombre, a.zona
  ), zonas_visitas as (
    select va.municipio_cod, va.zona, count(distinct va.visita_id) as visitas
    from visitas_activos va group by va.municipio_cod, va.zona
  ), municipios as (
    select a.municipio_cod, a.municipio_nombre, count(*) as adultos_activos,
      count(*) filter (where a.riesgo_vigente = 'alto') as riesgo_alto,
      sum(a.necesidades) as necesidades_activas, sum(a.alertas_abiertas) as alertas_abiertas,
      round(avg(a.dias_sin_visita), 1) as dias_sin_visita_promedio,
      count(*) filter (where cardinality(a.asignados) = 0) as sin_personal_asignado
    from por_adulto a
    group by a.municipio_cod, a.municipio_nombre
  ), municipios_visitas as (
    select va.municipio_cod, count(distinct va.visita_id) as visitas
    from visitas_activos va group by va.municipio_cod
  ), meses as materialized (
    select m.clave, m.inicio, greatest(m.inicio, v_corte_inicio) as desde, least(m.fin, v_fin) as hasta
    from cuidared_interno.reporte_meses(v_inicio, v_fin, null, v_hoy) m
  ), hechos as materialized (
    -- Un hecho por registro con su día local: visita (distinta), necesidad, alerta prioritaria y alta.
    select 'visita' as clase, x.fecha as dia from (select distinct vp.visita_id, vp.fecha from visitas_pob vp) x
    union all
    select 'visita', i.fecha
    from cuidared_interno.reporte_visitas_institucionales(p_cuenta_id, p_f - array['desde', 'hasta']) i
    where v_visitas
    union all
    select 'necesidad', (en.fecha_necesidad at time zone 'America/Santo_Domingo')::date
    from pob join cuidared.envejeciente_necesidad en on en.envejeciente_id = pob.envejeciente_id
    union all
    select 'alerta', (ae.fecha_alerta at time zone 'America/Santo_Domingo')::date
    from pob join cuidared.alerta_envejeciente ae on ae.envejeciente_id = pob.envejeciente_id
    join cuidared.tipo_alerta t on t.tipo_alerta_id = ae.tipo_alerta_id
    where cuidared_interno.alerta_es_prioritaria(t.codigo)
      and num_nonnulls(ae.fuente_riesgo_id, ae.fuente_necesidad_id, ae.fuente_visita_id, ae.fuente_perfil_id) = 1
    union all
    select 'alta', pob.dia_alta from pob
  ), conteos as (
    select m.clave, m.inicio,
      count(h.dia) filter (where h.clase = 'visita') as visitas_realizadas,
      count(h.dia) filter (where h.clase = 'necesidad') as necesidades_registradas,
      count(h.dia) filter (where h.clase = 'alerta') as alertas_prioritarias,
      count(h.dia) filter (where h.clase = 'alta') as perfiles_nuevos
    from meses m left join hechos h on h.dia between m.desde and m.hasta
    group by m.clave, m.inicio
  ), tendencias as (
    select c.*, lag(c.visitas_realizadas) over (order by c.inicio) as previas from conteos c
  )
  select jsonb_build_object(
    'vacio', not exists (select from pob) and not exists (select from conteos c where c.visitas_realizadas > 0),
    'comparativo_zonas', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'municipio', jsonb_build_object('codigo', z.municipio_cod, 'nombre', z.municipio_nombre), 'zona', z.zona,
        'adultos_activos', z.adultos_activos, 'riesgo_alto', z.riesgo_alto,
        'visitas_realizadas', case when v_visitas then coalesce(zv.visitas, 0) end,
        'visitas_por_adulto', case when v_visitas
          then round(coalesce(zv.visitas, 0)::numeric / z.adultos_activos, 2) end,
        'necesidades_activas', z.necesidades_activas, 'alertas_abiertas', z.alertas_abiertas,
        'dias_sin_visita_promedio', z.dias_sin_visita_promedio, 'sin_personal_asignado', z.sin_personal_asignado)
        order by z.adultos_activos desc, z.municipio_nombre, z.municipio_cod, z.zona nulls last), '[]'::jsonb)
      from zonas z
      left join zonas_visitas zv on zv.municipio_cod = z.municipio_cod and zv.zona is not distinct from z.zona),
    'comparativo_municipios', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'municipio', jsonb_build_object('codigo', m.municipio_cod, 'nombre', m.municipio_nombre),
        'adultos_activos', m.adultos_activos, 'riesgo_alto', m.riesgo_alto,
        'visitas_realizadas', case when v_visitas then coalesce(mv.visitas, 0) end,
        'visitas_por_adulto', case when v_visitas
          then round(coalesce(mv.visitas, 0)::numeric / m.adultos_activos, 2) end,
        'necesidades_activas', m.necesidades_activas, 'alertas_abiertas', m.alertas_abiertas,
        'dias_sin_visita_promedio', m.dias_sin_visita_promedio, 'sin_personal_asignado', m.sin_personal_asignado)
        order by m.adultos_activos desc, m.municipio_nombre, m.municipio_cod), '[]'::jsonb)
      from municipios m left join municipios_visitas mv on mv.municipio_cod = m.municipio_cod),
    'tendencias', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'mes', t.clave, 'visitas_realizadas', case when v_visitas then t.visitas_realizadas end,
        'variacion_visitas', case when not v_visitas or t.previas is null or t.previas = 0 then null
          else round((t.visitas_realizadas - t.previas) * 100.0 / t.previas)::integer end,
        'necesidades_registradas', t.necesidades_registradas, 'alertas_prioritarias', t.alertas_prioritarias,
        'perfiles_nuevos', t.perfiles_nuevos) order by t.inicio), '[]'::jsonb)
      from tendencias t))
  into v;
  return jsonb_build_object('tipo', 'analisis_avanzado', 'zona_horaria', 'America/Santo_Domingo',
    'generado_en', pg_catalog.now(), 'filtros', p_f) || v;
end;
$$;

create or replace function cuidared_api.api_reporte_avanzado(p_cuenta_id bigint, p_filtros jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'reportes:ver')->>'usuario_id')::uuid;
begin
  perform cuidared_interno.reporte_exigir_extra(p_cuenta_id, v_uid, array[]::text[],
    array['dashboard_metricas', 'reportes_avanzados']);
  return cuidared_interno.reporte_avanzado(p_cuenta_id, v_uid,
    cuidared_interno.reporte_filtros(p_filtros, cuidared_interno.reporte_claves_tipo('analisis_avanzado')));
end;
$$;

/* ───────────── 5. Exportaciones auditadas ───────────── */

-- Registro en la auditoría de la cuenta (RF-21): solo referencias, tipo, formato y filtros; nunca filas.
create or replace function cuidared_interno.reporte_registrar_exportacion(p_cuenta_id bigint, p_usuario_id uuid,
  p_rol text, p_tipo text, p_formato text, p_f jsonb) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into cuidared.auditoria (tabla, operacion, registro_id, usuario_id, datos_nuevos)
  values ('exportacion_reporte', 'I', v_id::text, p_usuario_id,
    jsonb_build_object('cuenta_id', p_cuenta_id, 'tipo', p_tipo, 'formato', p_formato, 'filtros', p_f));
  return jsonb_build_object(
    'exportacion_id', v_id, 'tipo', p_tipo, 'formato', p_formato, 'filtros', p_f, 'fecha', pg_catalog.now(),
    'generado_por', (select jsonb_build_object('nombres', u.nombres, 'apellidos', u.apellidos, 'rol', p_rol)
                     from cuidared.usuario u where u.usuario_id = p_usuario_id),
    'cuenta', (select jsonb_build_object('nombre', c.nombre) from cuidared.cuenta c where c.cuenta_id = p_cuenta_id));
end;
$$;

create or replace function cuidared_api.api_exportar_reporte_csv(p_cuenta_id bigint, p_tipo text, p_filtros jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'reportes:ver');
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_f jsonb;
  v_reporte jsonb;
begin
  perform cuidared_interno.reporte_exigir_extra(p_cuenta_id, v_uid, cuidared_interno.reporte_permisos_tipo(p_tipo),
    array['dashboard_metricas']);
  if p_tipo is null or p_tipo not in ('adultos', 'visitas', 'necesidades', 'casos_prioritarios') then
    raise invalid_parameter_value;
  end if;
  v_f := cuidared_interno.reporte_filtros(p_filtros, cuidared_interno.reporte_claves_tipo(p_tipo));
  v_reporte := cuidared_interno.reporte_construir(p_cuenta_id, v_uid, p_tipo, v_f);
  return jsonb_build_object(
    'exportacion', cuidared_interno.reporte_registrar_exportacion(p_cuenta_id, v_uid, v_ctx->>'rol', p_tipo, 'csv', v_f),
    'reporte', v_reporte);
end;
$$;

-- Registro previo del PDF o el Excel que genera el frontend. Sin permiso o sin plan no se registra nada.
create or replace function cuidared_api.api_registrar_exportacion_reporte(p_cuenta_id bigint, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'reportes:ver');
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_tipo text;
  v_formato text;
  v_funcionalidades text[] := array['dashboard_metricas'];
  v_f jsonb;
begin
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['tipo', 'formato', 'filtros'] <> '{}'::jsonb
     or not (p_datos ?& array['tipo', 'formato']) then
    raise invalid_parameter_value;
  end if;
  v_tipo := cuidared_interno.reporte_codigo(p_datos->'tipo',
    array['adultos', 'visitas', 'necesidades', 'casos_prioritarios', 'analisis_avanzado']);
  v_formato := cuidared_interno.reporte_codigo(p_datos->'formato', array['pdf', 'xlsx']);
  if v_tipo is null or v_formato is null then raise invalid_parameter_value; end if;
  if v_formato = 'xlsx' or v_tipo = 'analisis_avanzado' then
    v_funcionalidades := v_funcionalidades || array['reportes_avanzados'];
  end if;
  perform cuidared_interno.reporte_exigir_extra(p_cuenta_id, v_uid, cuidared_interno.reporte_permisos_tipo(v_tipo),
    v_funcionalidades);
  v_f := cuidared_interno.reporte_filtros(case when jsonb_typeof(p_datos->'filtros') = 'null' then null
    else p_datos->'filtros' end, cuidared_interno.reporte_claves_tipo(v_tipo));
  return cuidared_interno.reporte_registrar_exportacion(p_cuenta_id, v_uid, v_ctx->>'rol', v_tipo, v_formato, v_f);
end;
$$;

/* ───────────── 6. Informe médico por adulto (informe:exportar) ───────────── */

create or replace function cuidared_api.api_informe_medico(p_cuenta_id bigint, p_envejeciente_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'informe:exportar');
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_hoy date := cuidared_interno.hoy();
  v_e cuidared.envejeciente;
  v_sensible boolean;
  v_indicaciones boolean;
  v_visitas boolean;
  v_omitidas text[];
  v_id uuid := gen_random_uuid();
  v_identificacion jsonb;
  v_riesgo jsonb;
  v_indicacion jsonb;
  v_visita jsonb;
begin
  select e.* into v_e from cuidared.envejeciente e
  where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id;
  -- Otra cuenta, inexistente, fuera de alcance o con consentimiento retirado responden igual (P0002).
  if not found or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, p_envejeciente_id, v_uid) then
    raise no_data_found;
  end if;
  v_sensible := cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:ver-sensible');
  v_indicaciones := cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'indicaciones:ver');
  v_visitas := cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'visitas:ver');
  v_omitidas := array_remove(array[case when not v_indicaciones then 'indicaciones' end,
    case when not v_sensible then 'riesgo' end, case when not v_visitas then 'visitas' end], null);

  select jsonb_build_object(
    'envejeciente_id', v_e.envejeciente_id, 'nombres', v_e.nombres, 'apellidos', v_e.apellidos,
    'cedula', v_e.cedula::text, 'fecha_nacimiento', v_e.fecha_nacimiento,
    'edad', extract(year from age(v_hoy, v_e.fecha_nacimiento))::integer, 'sexo', v_e.sexo::text,
    'municipio', jsonb_build_object('codigo', v_e.municipio_cod, 'nombre', mu.nombre),
    'provincia', case when pv.provincia_cod is null then null
      else jsonb_build_object('codigo', pv.provincia_cod, 'nombre', pv.nombre) end,
    'estado', v_e.estado)
  into v_identificacion
  from (select 1) uno
  left join cuidared.municipio mu on mu.municipio_cod = v_e.municipio_cod
  left join cuidared.provincia pv on pv.provincia_cod = mu.provincia_cod;

  if v_sensible then
    select jsonb_build_object(
      'nivel_vigente', cuidared_interno.nivel_riesgo_vigente(v_e.envejeciente_id),
      'vigentes', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'envejeciente_riesgo_id', er.envejeciente_riesgo_id::text,
          'factor', jsonb_build_object('codigo', r.codigo, 'nombre', r.nombre),
          'nivel', jsonb_build_object('codigo', nr.codigo, 'nombre', nr.nombre),
          'motivo', er.motivo, 'observacion', er.observacion, 'fecha', er.fecha_riesgo)
          order by nr.orden desc, er.fecha_riesgo desc, er.envejeciente_riesgo_id desc), '[]'::jsonb)
        from cuidared.envejeciente_riesgo er
        join cuidared.riesgo r on r.riesgo_id = er.riesgo_id
        join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
        where er.envejeciente_id = v_e.envejeciente_id and er.estado = 'activo'),
      'historial', (
        select coalesce(jsonb_agg(h.fila order by h.fecha_riesgo desc, h.envejeciente_riesgo_id desc), '[]'::jsonb)
        from (
          select er.fecha_riesgo, er.envejeciente_riesgo_id, jsonb_build_object(
            'envejeciente_riesgo_id', er.envejeciente_riesgo_id::text,
            'factor', jsonb_build_object('codigo', r.codigo, 'nombre', r.nombre),
            'nivel', jsonb_build_object('codigo', nr.codigo, 'nombre', nr.nombre),
            'estado', er.estado, 'motivo', er.motivo, 'fecha', er.fecha_riesgo,
            'fecha_resolucion', er.fecha_resolucion) as fila
          from cuidared.envejeciente_riesgo er
          join cuidared.riesgo r on r.riesgo_id = er.riesgo_id
          join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
          where er.envejeciente_id = v_e.envejeciente_id
          order by er.fecha_riesgo desc, er.envejeciente_riesgo_id desc
          limit 15) h),
      'historial_total', (select count(*) from cuidared.envejeciente_riesgo er
                          where er.envejeciente_id = v_e.envejeciente_id))
    into v_riesgo;
  end if;

  if v_indicaciones then
    select jsonb_build_object(
      'vigentes', coalesce(jsonb_agg(jsonb_build_object(
        'indicacion_medica_id', i.indicacion_medica_id,
        'tipo', jsonb_build_object('tipo_indicacion_id', ti.tipo_indicacion_id, 'nombre', ti.nombre),
        'titulo', i.titulo, 'descripcion', i.descripcion, 'frecuencia_horario', i.frecuencia_horario,
        'fecha_inicio', i.fecha_inicio, 'fecha_fin', i.fecha_fin,
        'registrada_por', (
          select jsonb_build_object('nombres', u.nombres, 'apellidos', u.apellidos)
          from cuidared.usuario u where u.usuario_id = i.registrado_por
            and exists (select 1 from cuidared.membresia m where m.cuenta_id = p_cuenta_id and m.usuario_id = u.usuario_id)))
        order by i.fecha_inicio desc, i.fecha_creacion desc, i.indicacion_medica_id)
        filter (where i.estado = 'activa' and i.fecha_inicio <= v_hoy
          and (i.fecha_fin is null or i.fecha_fin >= v_hoy)), '[]'::jsonb),
      'no_vigentes', count(*) filter (where not (i.estado = 'activa' and i.fecha_inicio <= v_hoy
        and (i.fecha_fin is null or i.fecha_fin >= v_hoy))))
    into v_indicacion
    from cuidared.indicacion_medica i
    join cuidared.tipo_indicacion ti on ti.tipo_indicacion_id = i.tipo_indicacion_id
    where i.envejeciente_id = v_e.envejeciente_id;
  end if;

  if v_visitas then
    with realizadas as materialized (
      select v.visita_id, v.fecha, v.hora_inicio, v.hora_fin, v.origen::text as origen, v.fecha_creacion,
        d.estado_general::text as estado_general, d.observacion
      from cuidared.detalle_visita d join cuidared.visita v on v.visita_id = d.visita_id
      where d.envejeciente_id = v_e.envejeciente_id and v.cuenta_id = p_cuenta_id and v.estado = 'completada'
        and v.fecha <= v_hoy
    )
    select jsonb_build_object(
      'realizadas_total', (select count(*) from realizadas),
      'ultima_fecha', (select max(r.fecha) from realizadas r),
      'recientes', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'visita_id', r.visita_id, 'fecha', r.fecha, 'hora_inicio', to_char(r.hora_inicio, 'HH24:MI'),
          'hora_fin', to_char(r.hora_fin, 'HH24:MI'), 'origen', r.origen,
          'responsables', (
            select coalesce(jsonb_agg(jsonb_build_object('nombres', u.nombres, 'apellidos', u.apellidos)
              order by u.apellidos, u.nombres, u.usuario_id), '[]'::jsonb)
            from cuidared.registro_visita rv join cuidared.usuario u on u.usuario_id = rv.usuario_id
            where rv.visita_id = r.visita_id),
          'estado_general', case when v_sensible then r.estado_general end,
          'observacion', case when v_sensible then r.observacion end)
          order by r.fecha desc, coalesce(r.hora_fin, r.hora_inicio) desc nulls last, r.fecha_creacion desc,
            r.visita_id), '[]'::jsonb)
        from (select * from realizadas
              order by realizadas.fecha desc, coalesce(realizadas.hora_fin, realizadas.hora_inicio) desc nulls last,
                realizadas.fecha_creacion desc, realizadas.visita_id
              limit 10) r))
    into v_visita;
  end if;

  insert into cuidared.auditoria (tabla, operacion, registro_id, usuario_id, datos_nuevos)
  values ('informe_medico', 'I', v_id::text, v_uid, jsonb_build_object('cuenta_id', p_cuenta_id,
    'envejeciente_id', v_e.envejeciente_id, 'secciones_omitidas', to_jsonb(v_omitidas)));

  return jsonb_build_object(
    'informe_id', v_id,
    'generado_en', pg_catalog.now(),
    'generado_por', (select jsonb_build_object('nombres', u.nombres, 'apellidos', u.apellidos, 'rol', v_ctx->>'rol')
                     from cuidared.usuario u where u.usuario_id = v_uid),
    'cuenta', (select jsonb_build_object('nombre', c.nombre) from cuidared.cuenta c where c.cuenta_id = p_cuenta_id),
    'aviso', 'CuidaRed no diagnostica ni sustituye al médico tratante.',
    'secciones_omitidas', to_jsonb(v_omitidas),
    'identificacion', v_identificacion,
    'riesgo', v_riesgo,
    'indicaciones', v_indicacion,
    'visitas', v_visita);
end;
$$;

/* ───────────── 7. Auditoría de la cuenta con exportaciones e informes ───────────── */

-- Misma firma que la versión de CUIDARED-009 (6z); agrega las entidades de esta fase con la acción `exportacion`.
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
      'tarea_agenda', 'evidencia', 'evidencia_visita', 'evidencia_indicacion', 'solicitud_visita',
      'exportacion_reporte', 'informe_medico')
  ), propios as (
    select e.auditoria_id, e.tabla, e.operacion, e.fecha, e.usuario_id
    from eventos e
    where case
      when e.tabla in ('cuenta','configuracion_cuenta','membresia','envejeciente','visita','solicitud_visita',
                       'exportacion_reporte','informe_medico')
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
      'accion', case when p.tabla in ('exportacion_reporte', 'informe_medico') then 'exportacion'
        when p.operacion = 'I' then 'alta' when p.operacion = 'U' then 'actualizacion' else 'baja' end,
      'entidad', p.tabla, 'fecha', p.fecha, 'resultado', 'confirmado'
    ) order by p.posicion), '[]'::jsonb)
  into v_total, v_items
  from pagina p left join cuidared.usuario u on u.usuario_id = p.usuario_id;

  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;

/* ───────────── 8. Privilegios ───────────── */

-- Las funciones internas no se exponen: solo las RPC de cuidared_api, y únicamente para `authenticated`.
revoke all on function cuidared_interno.reporte_exigir_extra(bigint, uuid, text[], text[]) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_codigo(jsonb, text[]) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_filtros(jsonb, text[]) from public, anon, authenticated;
revoke all on function cuidared_interno.umbral_seguimiento_visitas(bigint) from public, anon, authenticated;
revoke all on function cuidared_interno.alerta_ventana_sin_visita(uuid, bigint, date) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_meses(date, date, date, date) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_serie(jsonb) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_asignaciones(bigint) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_alcance(bigint, uuid) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_riesgos(bigint) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_casos(bigint, uuid) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_orden_casos(text[]) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_poblacion(bigint, uuid, jsonb) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_por_mes(date[], jsonb, date) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_adultos(bigint, uuid, jsonb, date) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_visitas(bigint, uuid, jsonb, date) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_visitas_institucionales(bigint, jsonb) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_necesidades(bigint, uuid, jsonb, date) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_casos_prioritarios(bigint, uuid, jsonb, date)
  from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_construir(bigint, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_permisos_tipo(text) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_claves_tipo(text) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_avanzado(bigint, uuid, jsonb) from public, anon, authenticated;
revoke all on function cuidared_interno.reporte_registrar_exportacion(bigint, uuid, text, text, text, jsonb)
  from public, anon, authenticated;

revoke all on function cuidared_api.api_resumen_casos_listar(bigint, jsonb, text[], integer, bigint) from public, anon;
revoke all on function cuidared_api.api_resumen_casos_indicadores(bigint) from public, anon;
revoke all on function cuidared_api.api_reporte_opciones(bigint, text) from public, anon;
revoke all on function cuidared_api.api_reporte(bigint, text, jsonb) from public, anon;
revoke all on function cuidared_api.api_reporte_avanzado(bigint, jsonb) from public, anon;
revoke all on function cuidared_api.api_exportar_reporte_csv(bigint, text, jsonb) from public, anon;
revoke all on function cuidared_api.api_registrar_exportacion_reporte(bigint, jsonb) from public, anon;
revoke all on function cuidared_api.api_informe_medico(bigint, uuid) from public, anon;
revoke all on function cuidared_api.api_auditoria_cuenta(bigint, integer, bigint, boolean) from public, anon;
grant execute on function cuidared_api.api_resumen_casos_listar(bigint, jsonb, text[], integer, bigint) to authenticated;
grant execute on function cuidared_api.api_resumen_casos_indicadores(bigint) to authenticated;
grant execute on function cuidared_api.api_reporte_opciones(bigint, text) to authenticated;
grant execute on function cuidared_api.api_reporte(bigint, text, jsonb) to authenticated;
grant execute on function cuidared_api.api_reporte_avanzado(bigint, jsonb) to authenticated;
grant execute on function cuidared_api.api_exportar_reporte_csv(bigint, text, jsonb) to authenticated;
grant execute on function cuidared_api.api_registrar_exportacion_reporte(bigint, jsonb) to authenticated;
grant execute on function cuidared_api.api_informe_medico(bigint, uuid) to authenticated;
grant execute on function cuidared_api.api_auditoria_cuenta(bigint, integer, bigint, boolean) to authenticated;

commit;
