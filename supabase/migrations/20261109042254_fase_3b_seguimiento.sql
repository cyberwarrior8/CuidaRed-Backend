-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 3 · Envejecientes, bloque 3b — asignaciones y permiso familiar explícito, evaluación y factores de riesgo,
-- indicaciones médicas e historial consolidado. ID03 · RF-12, RF-13, RF-14, RF-15, RF-3.4 (CU-06) · Reglas de Negocio V2.
-- Basada en docs/DB.sql, la migración 20261025041944_fase_1_acceso y docs/propuestas/fase-2a-base.sql (autorización
-- cuidared_interno.exigir / exigir_envejeciente, membresia_activa y matriz de permisos). Validada en un PostgreSQL local con
-- `node scripts/validar-propuestas-local.js --solo=3b` (esquema auth simulado; no certifica RLS ni Auth de Supabase).
-- Contrato HTTP: docs/contratos/seguimiento.md. © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (las abiertas se marcan «Propuesta técnica (Dxx)» y esperan confirmación del usuario):
--   · V2 / RF-13 — el vínculo NO concede acceso por sí solo: el permiso del familiar es explícito, lo registra quien lo autoriza
--     (autorizado_por_usuario_id, fecha_autorizacion) y es revocable con fecha y motivo. alcanza_envejeciente exige
--     fecha_revocacion is null para todos los tipos de vínculo (cuidador, voluntario y familiar).
--   · D11 (confirmada) — cuestionario de 100 puntos (30/40/30), umbrales 0–29 / 30–54 / 55–100, nivel agregado = máximo de los
--     factores vigentes y «Sin evaluación vigente» cuando no hay ninguno. El servidor calcula puntaje, desglose y nivel.
--   · Propuesta técnica (D11): respuestas incompletas se rechazan (CR_EVALUACION_INCOMPLETA); el cuestionario se versiona
--     (version_cuestionario = 'v1') y se guarda el desglose para que un cambio futuro de pesos no reescriba el historial.
--   · Propuesta técnica (D10): transiciones. Factor de riesgo: activo → resuelto | reemplazado (terminales). Indicación:
--     activa ⇄ suspendida, activa | suspendida → finalizada; «finalizada» es terminal y no se edita.
--   · Propuesta técnica (D04): historial — los eventos de riesgo/evaluación y las observaciones de visita exigen
--     adultos:ver-sensible; indicaciones, visitas, necesidades y alertas exigen su permiso de consulta.
--   · Propuesta técnica (D14): catálogos mínimos — nivel_riesgo (bajo, medio, alto) y el factor «Evaluación de riesgo» con un
--     `codigo` estable; el resto de catálogos (riesgo, tipo_indicacion) los define el catálogo aprobado.
--   · Un adulto de otra cuenta, inexistente o fuera del alcance del usuario produce la misma respuesta (42501 en rutas de
--     adulto; P0002 en rutas por id de factor o indicación).
begin;

/* ───────────── 1. Catálogos mínimos con código estable (D14, propuesta) ───────────── */

alter table cuidared.nivel_riesgo
  add column if not exists codigo character varying check (codigo::text ~ '^[a-z_]+$');
create unique index if not exists uq_nivel_riesgo_codigo on cuidared.nivel_riesgo (codigo);
insert into cuidared.nivel_riesgo (nombre, orden)
select v.nombre, v.orden
from (values ('Bajo', 1), ('Medio', 2), ('Alto', 3)) as v(nombre, orden)
where not exists (select 1 from cuidared.nivel_riesgo n where lower(n.nombre::text) = lower(v.nombre));
update cuidared.nivel_riesgo set codigo = lower(nombre::text)
where codigo is null and lower(nombre::text) in ('bajo', 'medio', 'alto');

alter table cuidared.riesgo
  add column if not exists codigo character varying check (codigo::text ~ '^[a-z_]+$');
create unique index if not exists uq_riesgo_codigo on cuidared.riesgo (codigo);
-- Factor que genera el cuestionario de evaluación; no se registra a mano.
insert into cuidared.riesgo (nombre, descripcion, codigo)
values ('Evaluación de riesgo', 'Resultado del cuestionario de evaluación de riesgo social (100 puntos).', 'evaluacion')
on conflict (nombre) do update set codigo = coalesce(cuidared.riesgo.codigo, excluded.codigo);

-- El bloque 2a incorpora la identidad, autorización y revocación de vínculos para que 2c conserve el historial.

/* ───────────── 3. Riesgo: evaluaciones, autoría de factores y un factor vigente por tipo ───────────── */

alter table cuidared.envejeciente_riesgo
  add column if not exists registrado_por uuid references cuidared.usuario(usuario_id),
  add column if not exists fecha_resolucion timestamp with time zone,
  add column if not exists resuelto_por uuid references cuidared.usuario(usuario_id);
-- Un solo factor activo por adulto y tipo de factor: el máximo de los vigentes no puede duplicarse ni siquiera ante
-- peticiones concurrentes (las RPC además serializan por adulto).
create unique index uq_env_riesgo_activo on cuidared.envejeciente_riesgo (envejeciente_id, riesgo_id)
  where estado::text = 'activo';
create index ix_env_riesgo_envejeciente on cuidared.envejeciente_riesgo (envejeciente_id, fecha_riesgo desc);

create table cuidared.evaluacion_riesgo (
  evaluacion_riesgo_id bigint generated always as identity,
  envejeciente_id uuid not null,
  respuestas jsonb not null check (jsonb_typeof(respuestas) = 'object'),
  puntaje smallint not null check (puntaje between 0 and 100),
  desglose jsonb not null check (jsonb_typeof(desglose) = 'array'),
  nivel_riesgo_id smallint not null,
  version_cuestionario character varying not null check (version_cuestionario::text ~ '^v[0-9]+$'),
  -- Factor de envejeciente_riesgo que generó esta evaluación (trazabilidad; el factor puede pasar a reemplazado).
  envejeciente_riesgo_id bigint,
  usuario_id uuid not null,
  fecha timestamp with time zone not null default now(),
  constraint evaluacion_riesgo_pkey primary key (evaluacion_riesgo_id),
  constraint fk_evaluacion_riesgo_envejeciente foreign key (envejeciente_id) references cuidared.envejeciente(envejeciente_id),
  constraint fk_evaluacion_riesgo_nivel foreign key (nivel_riesgo_id) references cuidared.nivel_riesgo(nivel_riesgo_id),
  constraint fk_evaluacion_riesgo_factor foreign key (envejeciente_riesgo_id) references cuidared.envejeciente_riesgo(envejeciente_riesgo_id),
  constraint fk_evaluacion_riesgo_usuario foreign key (usuario_id) references cuidared.usuario(usuario_id)
);
create index ix_evaluacion_riesgo_envejeciente on cuidared.evaluacion_riesgo (envejeciente_id, fecha desc);
-- Tabla nueva: sin acceso directo (solo a través de las RPC).
alter table cuidared.evaluacion_riesgo enable row level security;
revoke all on cuidared.evaluacion_riesgo from public, anon, authenticated;

/* ───────────── 4. Indicaciones médicas: autoría (RF-15) ───────────── */

insert into cuidared.tipo_indicacion(nombre)
values ('Medicamento'), ('Cuidado'), ('Consulta'), ('Terapia')
on conflict (nombre) do nothing;

alter table cuidared.indicacion_medica
  add column if not exists registrado_por uuid references cuidared.usuario(usuario_id),
  add column if not exists actualizado_por uuid references cuidared.usuario(usuario_id);
create index ix_indicacion_medica_envejeciente on cuidared.indicacion_medica (envejeciente_id, estado);

/* ───────────── 5. Alcance sobre el adulto: exige vínculo NO revocado ───────────── */

/* ───────────── 6. Ayudas internas (esquema NO expuesto) ───────────── */

-- Marca temporal en UTC con sufijo Z (contrato de la API).
create function cuidared_interno.seg_iso_utc(p_fecha timestamp with time zone) returns text
language sql immutable set search_path = '' as $$
  select to_char(p_fecha at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;

-- ¿El usuario tiene la acción en su membresía activa de la cuenta?
create function cuidared_interno.seg_tiene_permiso(p_cuenta_id bigint, p_usuario_id uuid, p_accion text) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m
    where p_accion = any (cuidared_interno.permisos(m.rol_id, m.tipo_cuenta_id)))
$$;

-- Lectura validada de campos de un objeto JSON (22023 ante tipos, formatos o rangos inválidos).
create function cuidared_interno.seg_texto_campo(p_valor jsonb, p_min integer, p_max integer) returns text
language plpgsql immutable set search_path = '' as $$
declare v_texto text;
begin
  if p_valor is null or p_valor = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := pg_catalog.btrim(p_valor #>> '{}');
  if v_texto = '' then return null; end if;
  if pg_catalog.char_length(v_texto) not between p_min and p_max then raise invalid_parameter_value; end if;
  return v_texto;
end;
$$;

create function cuidared_interno.seg_entero_campo(p_valor jsonb, p_min integer, p_max integer) returns integer
language plpgsql immutable set search_path = '' as $$
declare v_numero numeric;
begin
  if p_valor is null or p_valor = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_valor) <> 'number' then raise invalid_parameter_value; end if;
  v_numero := (p_valor #>> '{}')::numeric;
  if v_numero <> trunc(v_numero) or v_numero not between p_min and p_max then raise invalid_parameter_value; end if;
  return v_numero::integer;
end;
$$;

create function cuidared_interno.seg_fecha_campo(p_valor jsonb) returns date
language plpgsql stable set search_path = '' as $$
declare v_texto text; v_fecha date;
begin
  if p_valor is null or p_valor = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := p_valor #>> '{}';
  if v_texto !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise invalid_parameter_value; end if;
  begin
    v_fecha := v_texto::date;
  exception when others then
    raise invalid_parameter_value; -- fecha de calendario inexistente (p. ej. 2026-02-30)
  end;
  if v_fecha not between date '1900-01-01' and date '2100-12-31' then raise invalid_parameter_value; end if;
  return v_fecha;
end;
$$;

/* ── Cuestionario de riesgo (D11) — portado de features/gestion/lib/riesgo.ts del frontend ── */

-- Definición versionada: secciones, preguntas y puntos por respuesta. Socioeconómica máx. 30, salud 40, apoyo 30.
create function cuidared_interno.cuestionario_riesgo_v1() returns jsonb
language sql immutable set search_path = '' as $$
  select '[
    {"id": "socio", "preguntas": [
      {"clave": "ingresos_fijos", "tipo": "switch", "si": 0, "no": 10},
      {"clave": "vivienda", "tipo": "select", "opciones": {"propia": 0, "alquilada": 4, "cedida": 6, "precaria": 10}},
      {"clave": "vive_solo", "tipo": "switch", "si": 10, "no": 0}]},
    {"id": "salud", "preguntas": [
      {"clave": "cronica", "tipo": "switch", "si": 12, "no": 0},
      {"clave": "movilidad", "tipo": "select", "opciones": {"independiente": 0, "apoyo": 5, "reducida": 10, "encamado": 16}},
      {"clave": "medicamentos", "tipo": "switch", "si": 12, "no": 0}]},
    {"id": "apoyo", "preguntas": [
      {"clave": "familiares", "tipo": "switch", "si": 0, "no": 10},
      {"clave": "frecuencia", "tipo": "select", "opciones": {"diaria": 0, "semanal": 3, "mensual": 6, "ocasional": 8, "nunca": 10}},
      {"clave": "cuidador", "tipo": "switch", "si": 0, "no": 10}]}
  ]'::jsonb
$$;

-- Umbrales confirmados: 0–29 bajo, 30–54 medio, 55–100 alto.
create function cuidared_interno.nivel_desde_puntaje(p_puntaje integer) returns text
language sql immutable set search_path = '' as $$
  select case when p_puntaje >= 55 then 'alto' when p_puntaje >= 30 then 'medio' else 'bajo' end
$$;

/*
 * Calcula puntaje, nivel y desglose a partir de las respuestas (el cliente nunca aporta el resultado).
 *   22023                       claves desconocidas, tipos o valores fuera del cuestionario
 *   CR_EVALUACION_INCOMPLETA    falta alguna pregunta (ausente, null o cadena vacía en las de selección)
 */
create function cuidared_interno.calcular_riesgo_v1(p_respuestas jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_def jsonb := cuidared_interno.cuestionario_riesgo_v1();
  v_conocidas text[];
  v_seccion jsonb;
  v_pregunta jsonb;
  v_valor jsonb;
  v_clave text;
  v_puntos integer;
  v_detalle jsonb;
  v_desglose jsonb := '[]'::jsonb;
  v_sec_puntos integer;
  v_sec_max integer;
  v_total integer := 0;
  v_incompleta boolean := false;
begin
  if p_respuestas is null or jsonb_typeof(p_respuestas) <> 'object' then raise invalid_parameter_value; end if;
  select array_agg(p ->> 'clave') into v_conocidas
  from jsonb_array_elements(v_def) s, jsonb_array_elements(s -> 'preguntas') p;
  if exists (select 1 from jsonb_object_keys(p_respuestas) k where k <> all (v_conocidas)) then
    raise invalid_parameter_value;
  end if;

  for v_seccion in select s from jsonb_array_elements(v_def) s loop
    v_detalle := '[]'::jsonb;
    v_sec_puntos := 0;
    v_sec_max := 0;
    for v_pregunta in select p from jsonb_array_elements(v_seccion -> 'preguntas') p loop
      v_clave := v_pregunta ->> 'clave';
      v_valor := p_respuestas -> v_clave;
      if v_pregunta ->> 'tipo' = 'switch' then
        v_sec_max := v_sec_max + greatest((v_pregunta ->> 'si')::integer, (v_pregunta ->> 'no')::integer);
        if v_valor is null or v_valor = 'null'::jsonb then v_incompleta := true; continue; end if;
        if jsonb_typeof(v_valor) <> 'boolean' then raise invalid_parameter_value; end if;
        v_puntos := case when v_valor = 'true'::jsonb then (v_pregunta ->> 'si')::integer else (v_pregunta ->> 'no')::integer end;
      else
        v_sec_max := v_sec_max + (select max(o.value::integer) from jsonb_each_text(v_pregunta -> 'opciones') o);
        if v_valor is null or v_valor = 'null'::jsonb or v_valor = '""'::jsonb then v_incompleta := true; continue; end if;
        if jsonb_typeof(v_valor) <> 'string' or not ((v_pregunta -> 'opciones') ? (v_valor #>> '{}')) then
          raise invalid_parameter_value;
        end if;
        v_puntos := (v_pregunta -> 'opciones' ->> (v_valor #>> '{}'))::integer;
      end if;
      v_sec_puntos := v_sec_puntos + v_puntos;
      v_detalle := v_detalle || jsonb_build_array(jsonb_build_object('clave', v_clave, 'respuesta', v_valor, 'puntos', v_puntos));
    end loop;
    v_desglose := v_desglose || jsonb_build_array(jsonb_build_object(
      'id', v_seccion ->> 'id', 'puntos', v_sec_puntos, 'max', v_sec_max, 'detalle', v_detalle));
    v_total := v_total + v_sec_puntos;
  end loop;

  if v_incompleta then raise exception 'CR_EVALUACION_INCOMPLETA' using errcode = 'P0001'; end if;
  return jsonb_build_object('version', 'v1', 'puntaje', v_total,
                            'nivel', cuidared_interno.nivel_desde_puntaje(v_total), 'desglose', v_desglose);
end;
$$;

-- Nivel agregado del adulto: el MÁXIMO de los factores vigentes (estado activo). null si no hay ninguno
-- («Sin evaluación vigente»): no se conserva el último nivel ni se asume «bajo». Lo reutilizan las alertas de fase 6.
create function cuidared_interno.nivel_riesgo_vigente(p_envejeciente_id uuid) returns text
language sql stable set search_path = '' as $$
  select nr.codigo::text
  from cuidared.envejeciente_riesgo er
  join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
  where er.envejeciente_id = p_envejeciente_id and er.estado::text = 'activo'
  order by nr.orden desc
  limit 1
$$;

-- Representaciones JSON (snake_case, fechas UTC) que devuelven las RPC.
create function cuidared_interno.seg_factor_json(p_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'envejeciente_riesgo_id', er.envejeciente_riesgo_id::text,
    'envejeciente_id', er.envejeciente_id,
    'riesgo_id', er.riesgo_id,
    'riesgo', r.nombre,
    'es_evaluacion', r.codigo::text is not distinct from 'evaluacion',
    'nivel', nr.codigo,
    'estado', er.estado,
    'motivo', er.motivo,
    'observacion', er.observacion,
    'fecha_riesgo', cuidared_interno.seg_iso_utc(er.fecha_riesgo),
    'registrado_por', er.registrado_por,
    'fecha_resolucion', cuidared_interno.seg_iso_utc(er.fecha_resolucion),
    'resuelto_por', er.resuelto_por)
  from cuidared.envejeciente_riesgo er
  join cuidared.riesgo r on r.riesgo_id = er.riesgo_id
  join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
  where er.envejeciente_riesgo_id = p_id
$$;

create function cuidared_interno.seg_indicacion_json(p_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'indicacion_medica_id', i.indicacion_medica_id,
    'envejeciente_id', i.envejeciente_id,
    'tipo_indicacion_id', i.tipo_indicacion_id,
    'tipo', ti.nombre,
    'titulo', i.titulo,
    'descripcion', i.descripcion,
    'frecuencia_horario', i.frecuencia_horario,
    'fecha_inicio', i.fecha_inicio,
    'fecha_fin', i.fecha_fin,
    'estado', i.estado,
    'registrado_por', i.registrado_por,
    'actualizado_por', i.actualizado_por,
    'fecha_creacion', cuidared_interno.seg_iso_utc(i.fecha_creacion),
    'fecha_actualizacion', cuidared_interno.seg_iso_utc(i.fecha_actualizacion))
  from cuidared.indicacion_medica i
  join cuidared.tipo_indicacion ti on ti.tipo_indicacion_id = i.tipo_indicacion_id
  where i.indicacion_medica_id = p_id
$$;

create function cuidared_interno.seg_asignacion_json(p_envejeciente_id uuid, p_usuario_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'envejeciente_id', v.envejeciente_id,
    'usuario_id', v.usuario_id,
    'tipo', tv.codigo,
    'nombres', u.nombres,
    'apellidos', u.apellidos,
    'autorizado_por_usuario_id', v.autorizado_por_usuario_id,
    'fecha_autorizacion', cuidared_interno.seg_iso_utc(v.fecha_autorizacion))
  from cuidared.vinculo v
  join cuidared.tipo_vinculo tv on tv.tipo_vinculo_id = v.tipo_vinculo_id
  join cuidared.usuario u on u.usuario_id = v.usuario_id
  where v.envejeciente_id = p_envejeciente_id and v.usuario_id = p_usuario_id and v.fecha_revocacion is null
$$;

-- Vigentes de un tipo de vínculo cuyo titular conserva su membresía activa con el rol esperado. Con p_detalle (gestores)
-- incluye el id y la autorización; sin él, solo nombres (minimización para el resto de roles).
create function cuidared_interno.seg_asignados(p_cuenta_id bigint, p_envejeciente_id uuid, p_tipo text, p_rol text, p_detalle boolean)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(
           case when p_detalle then cuidared_interno.seg_asignacion_json(v.envejeciente_id, v.usuario_id)
                else jsonb_build_object('nombres', u.nombres, 'apellidos', u.apellidos) end
           order by u.apellidos, u.nombres, u.usuario_id), '[]'::jsonb)
  from cuidared.vinculo v
  join cuidared.tipo_vinculo tv on tv.tipo_vinculo_id = v.tipo_vinculo_id and tv.codigo::text = p_tipo
  join cuidared.usuario u on u.usuario_id = v.usuario_id
  where v.envejeciente_id = p_envejeciente_id and v.fecha_revocacion is null
    and (p_rol <> 'familiar' or v.autorizado_por_usuario_id is not null)
    and exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, v.usuario_id) m where m.rol = p_rol)
$$;

/*
 * Crea un periodo de asignación o autorización. Si ya existe uno explícito vigente del mismo tipo se conserva.
 * Usa el bloqueo de miembros de la cuenta antes del adulto para serializar con cambios de rol y otras asignaciones.
 */
create function cuidared_interno.seg_vincular(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid, p_tipo text, p_actor uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_rol text := case p_tipo when 'cuidador_asignado' then 'cuidador' when 'voluntario_asignado' then 'voluntario'
                            when 'familiar_responsable' then 'familiar' end;
  v_estado text;
  v_rol_actual text;
  v_tipo_id smallint;
  v_fecha timestamptz;
begin
  if v_rol is null or p_actor is null then raise invalid_parameter_value; end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id,
    case when v_rol = 'familiar' then 'familiares:autorizar' else 'adultos:asignar' end, p_envejeciente_id);
  select m.rol into v_rol_actual from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m;
  if not found or v_rol_actual <> v_rol then raise exception 'CR_ROL_NO_COMPATIBLE' using errcode = 'P0001'; end if;
  select e.estado::text into v_estado from cuidared.envejeciente e
   where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id
   for no key update;
  if not found then raise insufficient_privilege; end if;
  if v_estado <> 'activo' then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;
  select tv.tipo_vinculo_id into v_tipo_id from cuidared.tipo_vinculo tv where tv.codigo::text = p_tipo;
  if v_tipo_id is null then raise exception 'catalogo tipo_vinculo sin configurar' using errcode = '55000'; end if;

  v_fecha := clock_timestamp();
  update cuidared.vinculo v set fecha_revocacion = v_fecha, motivo_revocacion = 'Sustituido por nueva autorización'
   where v.envejeciente_id = p_envejeciente_id and v.usuario_id = p_usuario_id and v.fecha_revocacion is null
     and (v.tipo_vinculo_id <> v_tipo_id or v.autorizado_por_usuario_id is null);
  insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id, autorizado_por_usuario_id, fecha_autorizacion)
  values (p_envejeciente_id, p_usuario_id, v_tipo_id, p_actor, v_fecha)
  on conflict (envejeciente_id, usuario_id) where fecha_revocacion is null do nothing;
  return cuidared_interno.seg_asignacion_json(p_envejeciente_id, p_usuario_id);
end;
$$;

-- Revoca un vínculo vigente de los tipos indicados (P0002 si no existe, ya está revocado o es de otro tipo).
create function cuidared_interno.seg_revocar(p_envejeciente_id uuid, p_usuario_id uuid, p_tipos text[], p_motivo text)
returns void language plpgsql set search_path = '' as $$
begin
  update cuidared.vinculo v
     set fecha_revocacion = clock_timestamp(), motivo_revocacion = p_motivo
    from cuidared.tipo_vinculo tv
   where tv.tipo_vinculo_id = v.tipo_vinculo_id and tv.codigo::text = any (p_tipos)
     and v.envejeciente_id = p_envejeciente_id and v.usuario_id = p_usuario_id and v.fecha_revocacion is null;
  if not found then raise no_data_found; end if;
end;
$$;

/* ── Eventos del historial consolidado (RF-3.4 / CU-06) ── */

-- Una fila por evento. Solo se calculan los tipos permitidos: sin permiso no se lee ni una fila. Usa únicamente
-- columnas de DB.sql en visitas, necesidades y alertas (otras fases pueden ampliarlas). Visitas: solo realizadas y
-- canceladas; las programadas o en curso pertenecen a la agenda.
create function cuidared_interno.historial_eventos(
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
         case when p_sensible then nullif(concat_ws(' · ',
           case when d.estado_general is not null then 'Estado general: ' || replace(d.estado_general::text, '_', ' ') end,
           d.observacion), '') end,
         v.visita_id::text, 1::smallint
  from cuidared.detalle_visita d
  join cuidared.visita v on v.visita_id = d.visita_id
  join cuidared.envejeciente adulto on adulto.envejeciente_id = d.envejeciente_id
  where p_visitas and d.envejeciente_id = p_envejeciente_id and v.estado::text in ('completada', 'cancelada')
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

revoke all on all functions in schema cuidared_interno from public, anon, authenticated;

/* ───────────── 7. RPC expuestas: asignaciones y permiso familiar (RF-12, RF-13) ───────────── */

-- Consulta (alcance). Gestores (asignar o autorizar): cuidadores, voluntarios y familiares autorizados con su id y
-- autorización. Resto: solo nombres de cuidadores y voluntarios.
create function cuidared_api.api_asignaciones_listar(p_cuenta_id bigint, p_envejeciente_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_gestor boolean;
  v_resultado jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:ver', p_envejeciente_id);
  v_uid := (v_ctx ->> 'usuario_id')::uuid;
  v_gestor := cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar')
    or cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'familiares:autorizar');
  v_resultado := jsonb_build_object(
    'cuidadores', cuidared_interno.seg_asignados(p_cuenta_id, p_envejeciente_id, 'cuidador_asignado', 'cuidador', v_gestor),
    'voluntarios', cuidared_interno.seg_asignados(p_cuenta_id, p_envejeciente_id, 'voluntario_asignado', 'voluntario', v_gestor));
  if v_gestor then
    v_resultado := v_resultado || jsonb_build_object(
      'familiares', cuidared_interno.seg_asignados(p_cuenta_id, p_envejeciente_id, 'familiar_responsable', 'familiar', true));
  end if;
  return v_resultado;
end;
$$;

-- Asigna un cuidador o voluntario (adultos:asignar). El voluntario solo existe en Organización. El usuario debe tener
-- una membresía activa con el rol correspondiente en la cuenta (CR_ROL_NO_COMPATIBLE); no se distingue "no existe".
create function cuidared_api.api_asignar(p_cuenta_id bigint, p_envejeciente_id uuid, p_tipo text, p_usuario_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null or p_usuario_id is null
     or p_tipo is null or p_tipo not in ('cuidador_asignado', 'voluntario_asignado') then
    raise invalid_parameter_value;
  end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:asignar', p_envejeciente_id);
  if p_tipo = 'voluntario_asignado' and v_ctx ->> 'tipo' <> 'organizacion' then
    raise exception 'CR_ROL_NO_PERMITIDO' using errcode = 'P0001';
  end if;
  return cuidared_interno.seg_vincular(p_cuenta_id, p_envejeciente_id, p_usuario_id, p_tipo, (v_ctx ->> 'usuario_id')::uuid);
end;
$$;

create function cuidared_api.api_asignacion_revocar(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_motivo text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null or p_usuario_id is null then
    raise invalid_parameter_value;
  end if;
  v_motivo := cuidared_interno.seg_texto_campo(to_jsonb(p_motivo), 1, 300);
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:asignar', p_envejeciente_id);
  perform cuidared_interno.seg_revocar(p_envejeciente_id, p_usuario_id, array['cuidador_asignado', 'voluntario_asignado'], v_motivo);
end;
$$;

-- Autoriza a un familiar (familiares:autorizar: Coordinador en Familia, solo Administrador en Organización). Debe ser un
-- miembro activo con rol familiar. El permiso es por adulto (V2) y revocable.
create function cuidared_api.api_familiar_autorizar(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null or p_usuario_id is null then
    raise invalid_parameter_value;
  end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'familiares:autorizar', p_envejeciente_id);
  return cuidared_interno.seg_vincular(p_cuenta_id, p_envejeciente_id, p_usuario_id, 'familiar_responsable', (v_ctx ->> 'usuario_id')::uuid);
end;
$$;

create function cuidared_api.api_familiar_revocar(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_motivo text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null or p_usuario_id is null then
    raise invalid_parameter_value;
  end if;
  v_motivo := cuidared_interno.seg_texto_campo(to_jsonb(p_motivo), 1, 300);
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'familiares:autorizar', p_envejeciente_id);
  perform cuidared_interno.seg_revocar(p_envejeciente_id, p_usuario_id, array['familiar_responsable'], v_motivo);
end;
$$;

/* ───────────── 8. RPC expuestas: riesgo (RF-14) ───────────── */

-- Consulta (adultos:ver-sensible + alcance). El cuidador consulta pero no modifica.
create function cuidared_api.api_riesgo_consultar(p_cuenta_id bigint, p_envejeciente_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_nivel text;
  v_ultima jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null then raise invalid_parameter_value; end if;
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:ver-sensible', p_envejeciente_id);
  v_nivel := cuidared_interno.nivel_riesgo_vigente(p_envejeciente_id);
  select jsonb_build_object(
           'evaluacion_riesgo_id', ev.evaluacion_riesgo_id, 'puntaje', ev.puntaje, 'nivel', nr.codigo,
           'version_cuestionario', ev.version_cuestionario, 'desglose', ev.desglose, 'respuestas', ev.respuestas,
           'fecha', cuidared_interno.seg_iso_utc(ev.fecha), 'usuario_id', ev.usuario_id,
           -- Una evaluación es vigente mientras su factor siga activo; si no, es historia y no una clasificación actual.
           'vigente', coalesce(er.estado::text = 'activo', false))
    into v_ultima
    from cuidared.evaluacion_riesgo ev
    join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = ev.nivel_riesgo_id
    left join cuidared.envejeciente_riesgo er on er.envejeciente_riesgo_id = ev.envejeciente_riesgo_id
   where ev.envejeciente_id = p_envejeciente_id
   order by ev.fecha desc, ev.evaluacion_riesgo_id desc
   limit 1;
  return jsonb_build_object(
    'nivel_vigente', v_nivel,
    'texto', case when v_nivel is null then 'Sin evaluación vigente' else 'Riesgo ' || v_nivel end,
    'factores_vigentes', coalesce((
      select jsonb_agg(cuidared_interno.seg_factor_json(t.id) order by t.orden desc, t.fecha_riesgo desc, t.id desc)
      from (select er.envejeciente_riesgo_id as id, nr.orden, er.fecha_riesgo
              from cuidared.envejeciente_riesgo er
              join cuidared.nivel_riesgo nr on nr.nivel_riesgo_id = er.nivel_riesgo_id
             where er.envejeciente_id = p_envejeciente_id and er.estado::text = 'activo') t), '[]'::jsonb),
    -- Factores resueltos o reemplazados, del más reciente al más antiguo (máximo 50; el resto, en /historial).
    'historial', coalesce((
      select jsonb_agg(cuidared_interno.seg_factor_json(t.id) order by t.fecha_riesgo desc, t.id desc)
      from (select er.envejeciente_riesgo_id as id, er.fecha_riesgo
              from cuidared.envejeciente_riesgo er
             where er.envejeciente_id = p_envejeciente_id and er.estado::text <> 'activo'
             order by er.fecha_riesgo desc, er.envejeciente_riesgo_id desc
             limit 50) t), '[]'::jsonb),
    'ultima_evaluacion', v_ultima);
end;
$$;

-- Evalúa con el cuestionario (adultos:evaluar): calcula en el servidor, guarda la evaluación y el factor «Evaluación de
-- riesgo»; el factor anterior del mismo tipo pasa a reemplazado.
create function cuidared_api.api_riesgo_evaluar(p_cuenta_id bigint, p_envejeciente_id uuid, p_respuestas jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_estado text;
  v_calculo jsonb;
  v_nivel_id smallint;
  v_riesgo_id smallint;
  v_factor bigint;
  v_evaluacion bigint;
  v_fecha timestamp with time zone := clock_timestamp();
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:evaluar', p_envejeciente_id);
  v_actor := (v_ctx ->> 'usuario_id')::uuid;
  v_calculo := cuidared_interno.calcular_riesgo_v1(p_respuestas);

  select e.estado::text into v_estado from cuidared.envejeciente e
   where e.envejeciente_id = p_envejeciente_id for no key update;
  if v_estado is distinct from 'activo' then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;
  select nr.nivel_riesgo_id into v_nivel_id from cuidared.nivel_riesgo nr where nr.codigo::text = v_calculo ->> 'nivel';
  select r.riesgo_id into v_riesgo_id from cuidared.riesgo r where r.codigo::text = 'evaluacion';
  if v_nivel_id is null or v_riesgo_id is null then
    raise exception 'catalogos de riesgo sin configurar' using errcode = '55000';
  end if;

  update cuidared.envejeciente_riesgo set estado = 'reemplazado'
   where envejeciente_id = p_envejeciente_id and riesgo_id = v_riesgo_id and estado::text = 'activo';
  insert into cuidared.envejeciente_riesgo (envejeciente_id, riesgo_id, nivel_riesgo_id, fecha_riesgo, estado, motivo, registrado_por)
  values (p_envejeciente_id, v_riesgo_id, v_nivel_id, v_fecha, 'activo',
          format('Evaluación de riesgo: %s de 100 puntos.', v_calculo ->> 'puntaje'), v_actor)
  returning envejeciente_riesgo_id into v_factor;
  insert into cuidared.evaluacion_riesgo (envejeciente_id, respuestas, puntaje, desglose, nivel_riesgo_id, version_cuestionario,
                                          envejeciente_riesgo_id, usuario_id, fecha)
  values (p_envejeciente_id, p_respuestas, (v_calculo ->> 'puntaje')::smallint, v_calculo -> 'desglose', v_nivel_id,
          v_calculo ->> 'version', v_factor, v_actor, v_fecha)
  returning evaluacion_riesgo_id into v_evaluacion;

  return jsonb_build_object(
    'evaluacion_riesgo_id', v_evaluacion, 'envejeciente_id', p_envejeciente_id,
    'puntaje', (v_calculo ->> 'puntaje')::integer, 'nivel', v_calculo ->> 'nivel',
    'version_cuestionario', v_calculo ->> 'version', 'desglose', v_calculo -> 'desglose', 'respuestas', p_respuestas,
    'fecha', cuidared_interno.seg_iso_utc(v_fecha), 'usuario_id', v_actor,
    'factor', cuidared_interno.seg_factor_json(v_factor),
    'nivel_vigente', cuidared_interno.nivel_riesgo_vigente(p_envejeciente_id));
end;
$$;

-- Registra un factor (adultos:evaluar) y reemplaza el activo del mismo riesgo_id. El factor «Evaluación de riesgo» solo
-- lo genera el cuestionario.
create function cuidared_api.api_riesgo_registrar(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_riesgo_id integer, p_nivel text, p_motivo text, p_observacion text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_estado text;
  v_motivo text;
  v_observacion text;
  v_nivel_id smallint;
  v_codigo text;
  v_factor bigint;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null
     or p_riesgo_id is null or p_riesgo_id not between 1 and 32767
     or p_nivel is null or p_nivel not in ('bajo', 'medio', 'alto') then
    raise invalid_parameter_value;
  end if;
  v_motivo := cuidared_interno.seg_texto_campo(to_jsonb(p_motivo), 5, 200);
  v_observacion := cuidared_interno.seg_texto_campo(to_jsonb(p_observacion), 1, 300);
  if v_motivo is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:evaluar', p_envejeciente_id);
  v_actor := (v_ctx ->> 'usuario_id')::uuid;

  select e.estado::text into v_estado from cuidared.envejeciente e
   where e.envejeciente_id = p_envejeciente_id for no key update;
  if v_estado is distinct from 'activo' then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;
  select r.codigo::text into v_codigo from cuidared.riesgo r where r.riesgo_id = p_riesgo_id;
  if not found or v_codigo is not distinct from 'evaluacion' then raise invalid_parameter_value; end if;
  select nr.nivel_riesgo_id into v_nivel_id from cuidared.nivel_riesgo nr where nr.codigo::text = p_nivel;
  if v_nivel_id is null then raise exception 'catalogos de riesgo sin configurar' using errcode = '55000'; end if;

  update cuidared.envejeciente_riesgo set estado = 'reemplazado'
   where envejeciente_id = p_envejeciente_id and riesgo_id = p_riesgo_id and estado::text = 'activo';
  insert into cuidared.envejeciente_riesgo (envejeciente_id, riesgo_id, nivel_riesgo_id, fecha_riesgo, estado, motivo, observacion, registrado_por)
  values (p_envejeciente_id, p_riesgo_id, v_nivel_id, clock_timestamp(), 'activo', v_motivo, v_observacion, v_actor)
  returning envejeciente_riesgo_id into v_factor;
  return jsonb_build_object('factor', cuidared_interno.seg_factor_json(v_factor),
                            'nivel_vigente', cuidared_interno.nivel_riesgo_vigente(p_envejeciente_id));
end;
$$;

-- Resuelve un factor activo (adultos:evaluar). Tras resolver el último queda «Sin evaluación vigente».
create function cuidared_api.api_riesgo_resolver(p_cuenta_id bigint, p_envejeciente_riesgo_id bigint, p_observacion text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_env uuid;
  v_estado text;
  v_observacion text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_riesgo_id is null or p_envejeciente_riesgo_id <= 0 then
    raise invalid_parameter_value;
  end if;
  v_observacion := cuidared_interno.seg_texto_campo(to_jsonb(p_observacion), 1, 300);
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'adultos:evaluar');
  v_actor := (v_ctx ->> 'usuario_id')::uuid;
  -- Un factor de otra cuenta, inexistente o fuera de alcance responde igual (P0002).
  select er.envejeciente_id into v_env
    from cuidared.envejeciente_riesgo er
    join cuidared.envejeciente e on e.envejeciente_id = er.envejeciente_id and e.cuenta_id = p_cuenta_id
   where er.envejeciente_riesgo_id = p_envejeciente_riesgo_id;
  if not found or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_actor) then raise no_data_found; end if;
  -- Mismo orden de bloqueo que evaluar/registrar (primero el adulto) para evitar interbloqueos.
  perform 1 from cuidared.envejeciente e where e.envejeciente_id = v_env for no key update;
  select er.estado::text into v_estado from cuidared.envejeciente_riesgo er
   where er.envejeciente_riesgo_id = p_envejeciente_riesgo_id for update;
  if v_estado <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  update cuidared.envejeciente_riesgo
     set estado = 'resuelto', fecha_resolucion = clock_timestamp(), resuelto_por = v_actor,
         observacion = case when v_observacion is null then observacion
                            else concat_ws(E'\n', observacion, 'Resolución: ' || v_observacion) end
   where envejeciente_riesgo_id = p_envejeciente_riesgo_id;
  return jsonb_build_object('factor', cuidared_interno.seg_factor_json(p_envejeciente_riesgo_id),
                            'nivel_vigente', cuidared_interno.nivel_riesgo_vigente(v_env));
end;
$$;

/* ───────────── 9. RPC expuestas: indicaciones médicas (RF-15) ───────────── */

-- Listado paginado (indicaciones:ver + alcance). El familiar autorizado consulta; el voluntario no tiene el permiso.
create function cuidared_api.api_indicaciones_listar(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_estado text default null, p_orden text default 'fecha_inicio',
  p_desc boolean default true, p_limite integer default 20, p_desplazamiento bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_total bigint;
  v_items jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null
     or (p_estado is not null and p_estado not in ('activa', 'suspendida', 'finalizada'))
     or p_orden is null or p_orden not in ('fecha_inicio', 'fecha_creacion', 'indicacion_medica_id') or p_desc is null
     or p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0 then
    raise invalid_parameter_value;
  end if;
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'indicaciones:ver', p_envejeciente_id);
  select count(*) into v_total from cuidared.indicacion_medica i
   where i.envejeciente_id = p_envejeciente_id and (p_estado is null or i.estado::text = p_estado);
  select coalesce(jsonb_agg(cuidared_interno.seg_indicacion_json(t.id) order by t.n), '[]'::jsonb) into v_items
  from (select i.indicacion_medica_id as id,
               row_number() over (order by
                 case when p_orden = 'fecha_inicio' and p_desc then i.fecha_inicio end desc,
                 case when p_orden = 'fecha_inicio' and not p_desc then i.fecha_inicio end asc,
                 case when p_orden = 'fecha_creacion' and p_desc then i.fecha_creacion end desc,
                 case when p_orden = 'fecha_creacion' and not p_desc then i.fecha_creacion end asc,
                 case when p_orden = 'indicacion_medica_id' and p_desc then i.indicacion_medica_id end desc,
                 i.indicacion_medica_id) as n
          from cuidared.indicacion_medica i
         where i.envejeciente_id = p_envejeciente_id and (p_estado is null or i.estado::text = p_estado)
         order by n
         limit p_limite offset p_desplazamiento) t;
  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;

-- Crea (indicaciones:gestionar + alcance: Coordinador/Administrador y cuidador asignado). La plataforma solo transcribe lo
-- indicado por personal de salud; no determina tratamientos.
create function cuidared_api.api_indicacion_crear(p_cuenta_id bigint, p_envejeciente_id uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_estado text;
  v_tipo integer;
  v_titulo text;
  v_descripcion text;
  v_frecuencia text;
  v_inicio date;
  v_fin date;
  v_id uuid;
  v_ahora timestamp with time zone := clock_timestamp();
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null
     or jsonb_typeof(p_datos) is distinct from 'object' then
    raise invalid_parameter_value;
  end if;
  if exists (select 1 from jsonb_object_keys(p_datos) k where k <> all (array[
       'tipo_indicacion_id', 'titulo', 'descripcion', 'frecuencia_horario', 'fecha_inicio', 'fecha_fin'])) then
    raise invalid_parameter_value;
  end if;
  v_tipo := cuidared_interno.seg_entero_campo(p_datos -> 'tipo_indicacion_id', 1, 32767);
  v_titulo := cuidared_interno.seg_texto_campo(p_datos -> 'titulo', 3, 80);
  v_descripcion := cuidared_interno.seg_texto_campo(p_datos -> 'descripcion', 1, 300);
  v_frecuencia := cuidared_interno.seg_texto_campo(p_datos -> 'frecuencia_horario', 1, 60);
  v_inicio := cuidared_interno.seg_fecha_campo(p_datos -> 'fecha_inicio');
  v_fin := cuidared_interno.seg_fecha_campo(p_datos -> 'fecha_fin');
  if v_tipo is null or v_titulo is null or v_inicio is null or (v_fin is not null and v_fin < v_inicio)
     or not exists (select 1 from cuidared.tipo_indicacion t where t.tipo_indicacion_id = v_tipo) then
    raise invalid_parameter_value;
  end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'indicaciones:gestionar', p_envejeciente_id);
  v_actor := (v_ctx ->> 'usuario_id')::uuid;
  select e.estado::text into v_estado from cuidared.envejeciente e
   where e.envejeciente_id = p_envejeciente_id for no key update;
  if v_estado is distinct from 'activo' then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;

  insert into cuidared.indicacion_medica (envejeciente_id, tipo_indicacion_id, titulo, descripcion, frecuencia_horario,
                                          fecha_inicio, fecha_fin, estado, registrado_por, actualizado_por,
                                          fecha_creacion, fecha_actualizacion)
  values (p_envejeciente_id, v_tipo, v_titulo, v_descripcion, v_frecuencia, v_inicio, v_fin, 'activa', v_actor, v_actor,
          v_ahora, v_ahora)
  returning indicacion_medica_id into v_id;
  return cuidared_interno.seg_indicacion_json(v_id);
end;
$$;

-- Edita campos de una indicación (no el estado). Una indicación finalizada es histórica y no se edita (D10). Una
-- indicación de otra cuenta, inexistente o fuera de alcance responde igual (P0002).
create function cuidared_api.api_indicacion_editar(p_cuenta_id bigint, p_indicacion_id uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_env uuid;
  v_i cuidared.indicacion_medica%rowtype;
  v_tipo integer;
  v_titulo text;
  v_descripcion text;
  v_frecuencia text;
  v_inicio date;
  v_fin date;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_indicacion_id is null
     or jsonb_typeof(p_datos) is distinct from 'object' or p_datos = '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  if exists (select 1 from jsonb_object_keys(p_datos) k where k <> all (array[
       'tipo_indicacion_id', 'titulo', 'descripcion', 'frecuencia_horario', 'fecha_inicio', 'fecha_fin'])) then
    raise invalid_parameter_value;
  end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'indicaciones:gestionar');
  v_actor := (v_ctx ->> 'usuario_id')::uuid;
  select i.envejeciente_id into v_env
    from cuidared.indicacion_medica i
    join cuidared.envejeciente e on e.envejeciente_id = i.envejeciente_id and e.cuenta_id = p_cuenta_id
   where i.indicacion_medica_id = p_indicacion_id;
  if not found or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_actor) then raise no_data_found; end if;
  select * into v_i from cuidared.indicacion_medica i where i.indicacion_medica_id = p_indicacion_id for update;
  if v_i.estado::text = 'finalizada' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;

  v_tipo := v_i.tipo_indicacion_id;
  v_titulo := v_i.titulo;
  v_descripcion := v_i.descripcion;
  v_frecuencia := v_i.frecuencia_horario;
  v_inicio := v_i.fecha_inicio;
  v_fin := v_i.fecha_fin;
  if p_datos ? 'tipo_indicacion_id' then
    v_tipo := cuidared_interno.seg_entero_campo(p_datos -> 'tipo_indicacion_id', 1, 32767);
    if v_tipo is null or not exists (select 1 from cuidared.tipo_indicacion t where t.tipo_indicacion_id = v_tipo) then
      raise invalid_parameter_value;
    end if;
  end if;
  if p_datos ? 'titulo' then
    v_titulo := cuidared_interno.seg_texto_campo(p_datos -> 'titulo', 3, 80);
    if v_titulo is null then raise invalid_parameter_value; end if;
  end if;
  if p_datos ? 'descripcion' then v_descripcion := cuidared_interno.seg_texto_campo(p_datos -> 'descripcion', 1, 300); end if;
  if p_datos ? 'frecuencia_horario' then v_frecuencia := cuidared_interno.seg_texto_campo(p_datos -> 'frecuencia_horario', 1, 60); end if;
  if p_datos ? 'fecha_inicio' then
    v_inicio := cuidared_interno.seg_fecha_campo(p_datos -> 'fecha_inicio');
    if v_inicio is null then raise invalid_parameter_value; end if;
  end if;
  if p_datos ? 'fecha_fin' then v_fin := cuidared_interno.seg_fecha_campo(p_datos -> 'fecha_fin'); end if;
  if v_fin is not null and v_fin < v_inicio then raise invalid_parameter_value; end if;

  update cuidared.indicacion_medica
     set tipo_indicacion_id = v_tipo, titulo = v_titulo, descripcion = v_descripcion, frecuencia_horario = v_frecuencia,
         fecha_inicio = v_inicio, fecha_fin = v_fin, actualizado_por = v_actor, fecha_actualizacion = clock_timestamp()
   where indicacion_medica_id = p_indicacion_id;
  return cuidared_interno.seg_indicacion_json(p_indicacion_id);
end;
$$;

-- Cambia el estado (D10): activa ⇄ suspendida; activa | suspendida → finalizada; «finalizada» es terminal. Repetir el
-- estado actual no cambia nada.
create function cuidared_api.api_indicacion_estado(p_cuenta_id bigint, p_indicacion_id uuid, p_estado text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_env uuid;
  v_actual text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_indicacion_id is null
     or p_estado is null or p_estado not in ('activa', 'suspendida', 'finalizada') then
    raise invalid_parameter_value;
  end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'indicaciones:gestionar');
  v_actor := (v_ctx ->> 'usuario_id')::uuid;
  select i.envejeciente_id into v_env
    from cuidared.indicacion_medica i
    join cuidared.envejeciente e on e.envejeciente_id = i.envejeciente_id and e.cuenta_id = p_cuenta_id
   where i.indicacion_medica_id = p_indicacion_id;
  if not found or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_actor) then raise no_data_found; end if;
  select i.estado::text into v_actual from cuidared.indicacion_medica i where i.indicacion_medica_id = p_indicacion_id for update;
  if v_actual = p_estado then return cuidared_interno.seg_indicacion_json(p_indicacion_id); end if;
  if v_actual = 'finalizada' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  update cuidared.indicacion_medica
     set estado = p_estado, actualizado_por = v_actor, fecha_actualizacion = clock_timestamp()
   where indicacion_medica_id = p_indicacion_id;
  return cuidared_interno.seg_indicacion_json(p_indicacion_id);
end;
$$;

/* ───────────── 10. RPC expuesta: historial consolidado (RF-3.4 / CU-06) ───────────── */

-- Paginado (adultos:ver + alcance), por fecha descendente por defecto. Cada tipo exige su permiso; ver el comentario de
-- historial_eventos. Devuelve {items:[{tipo, fecha, titulo, detalle, referencia_id}], total}.
create function cuidared_api.api_historial_listar(
  p_cuenta_id bigint, p_envejeciente_id uuid, p_tipo text default null, p_desc boolean default true,
  p_limite integer default 20, p_desplazamiento bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_sensible boolean;
  v_indicaciones boolean;
  v_visitas boolean;
  v_necesidades boolean;
  v_alertas boolean;
  v_total bigint;
  v_items jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_envejeciente_id is null
     or (p_tipo is not null and p_tipo not in ('riesgo', 'evaluacion', 'indicacion', 'visita', 'necesidad', 'alerta'))
     or p_desc is null or p_limite is null or p_limite not between 1 and 100
     or p_desplazamiento is null or p_desplazamiento < 0 then
    raise invalid_parameter_value;
  end if;
  v_ctx := cuidared_interno.exigir_envejeciente(p_cuenta_id, 'adultos:ver', p_envejeciente_id);
  v_uid := (v_ctx ->> 'usuario_id')::uuid;
  v_sensible := cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'adultos:ver-sensible');
  v_indicaciones := cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'indicaciones:ver');
  v_visitas := cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'visitas:ver');
  v_necesidades := cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'necesidades:ver');
  v_alertas := cuidared_interno.seg_tiene_permiso(p_cuenta_id, v_uid, 'alertas:ver');

  select count(*) into v_total
    from cuidared_interno.historial_eventos(p_envejeciente_id, v_sensible, v_indicaciones, v_visitas, v_necesidades, v_alertas) e
   where p_tipo is null or e.tipo = p_tipo;
  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo', t.tipo, 'fecha', cuidared_interno.seg_iso_utc(t.fecha), 'titulo', t.titulo,
           'detalle', t.detalle, 'referencia_id', t.referencia_id) order by t.n), '[]'::jsonb)
    into v_items
  from (select e.*,
               row_number() over (order by
                 case when p_desc then e.fecha end desc, case when not p_desc then e.fecha end asc,
                 e.tipo, e.referencia_id, e.orden) as n
          from cuidared_interno.historial_eventos(p_envejeciente_id, v_sensible, v_indicaciones, v_visitas, v_necesidades, v_alertas) e
         where p_tipo is null or e.tipo = p_tipo
         order by n
         limit p_limite offset p_desplazamiento) t;
  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;

/* ───────────── 11. Permisos de ejecución ───────────── */

revoke all on function
  cuidared_api.api_asignaciones_listar(bigint, uuid),
  cuidared_api.api_asignar(bigint, uuid, text, uuid),
  cuidared_api.api_asignacion_revocar(bigint, uuid, uuid, text),
  cuidared_api.api_familiar_autorizar(bigint, uuid, uuid),
  cuidared_api.api_familiar_revocar(bigint, uuid, uuid, text),
  cuidared_api.api_riesgo_consultar(bigint, uuid),
  cuidared_api.api_riesgo_evaluar(bigint, uuid, jsonb),
  cuidared_api.api_riesgo_registrar(bigint, uuid, integer, text, text, text),
  cuidared_api.api_riesgo_resolver(bigint, bigint, text),
  cuidared_api.api_indicaciones_listar(bigint, uuid, text, text, boolean, integer, bigint),
  cuidared_api.api_indicacion_crear(bigint, uuid, jsonb),
  cuidared_api.api_indicacion_editar(bigint, uuid, jsonb),
  cuidared_api.api_indicacion_estado(bigint, uuid, text),
  cuidared_api.api_historial_listar(bigint, uuid, text, boolean, integer, bigint)
  from public, anon;
grant execute on function
  cuidared_api.api_asignaciones_listar(bigint, uuid),
  cuidared_api.api_asignar(bigint, uuid, text, uuid),
  cuidared_api.api_asignacion_revocar(bigint, uuid, uuid, text),
  cuidared_api.api_familiar_autorizar(bigint, uuid, uuid),
  cuidared_api.api_familiar_revocar(bigint, uuid, uuid, text),
  cuidared_api.api_riesgo_consultar(bigint, uuid),
  cuidared_api.api_riesgo_evaluar(bigint, uuid, jsonb),
  cuidared_api.api_riesgo_registrar(bigint, uuid, integer, text, text, text),
  cuidared_api.api_riesgo_resolver(bigint, bigint, text),
  cuidared_api.api_indicaciones_listar(bigint, uuid, text, text, boolean, integer, bigint),
  cuidared_api.api_indicacion_crear(bigint, uuid, jsonb),
  cuidared_api.api_indicacion_editar(bigint, uuid, jsonb),
  cuidared_api.api_indicacion_estado(bigint, uuid, text),
  cuidared_api.api_historial_listar(bigint, uuid, text, boolean, integer, bigint)
  to authenticated;

commit;
