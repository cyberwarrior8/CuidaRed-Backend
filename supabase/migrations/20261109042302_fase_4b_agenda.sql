-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 4 · Visitas y Seguimiento (ID04), bloque 4b — agenda de cuidado, ejecución y evidencias privadas.
-- RF-16, RF-10 (agenda), RS-013 (archivos), RS-005/016 (trazabilidad) · Reglas de Negocio V2 · D12 (D13 en archivos).
-- Basada en docs/DB.sql y docs/propuestas/fase-2a-base.sql (cuidared_interno.exigir/alcanza_envejeciente/hoy,
-- perfil global de cuidador). Validada en un PostgreSQL local con `node scripts/validar-propuestas-local.js --solo=4b`
-- (Auth y Storage simulados: no certifica RLS de Supabase ni el comportamiento real del servicio Storage).
-- © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (contrato en docs/contratos/agenda.md):
--   · D12 (resuelta): una tarea que requiere evidencia solo se completa con evidencia VALIDADA.
--   · Propuesta técnica (D12, recurrencia): diaria o semanal con fecha de fin; una tarea por ocurrencia (máx. 60) con
--     serie_id común; editar/cancelar «esta» o «esta y las siguientes». Con varias evidencias basta UNA validada.
--     Validar la evidencia de una tarea abierta que la requiere la completa (completada_por = quien valida); rechazar
--     una evidencia de una tarea en progreso la devuelve a pendiente. Cerrada o cancelada la tarea no admite evidencias.
--   · Propuesta técnica (D13, archivos): JPG, PNG, WEBP o PDF de hasta 5 MB (RS-013), máximo 5 evidencias no rechazadas
--     por tarea, bucket privado `evidencias`, URL firmada de descarga de 5 minutos. Retención y borrado: sin definir.
--   · «Alcance» del adulto con cuidared_interno.alcanza_envejeciente, incluida la revocación.
begin;

-- Marcar las filas previas sin inferir autoría, cierre ni metadatos. El valor por defecto operativo será false.
alter table cuidared.tarea_agenda add column es_historica boolean not null default true;
alter table cuidared.tarea_agenda alter column es_historica set default false;
alter table cuidared.evidencia add column es_historica boolean not null default true;
alter table cuidared.evidencia alter column es_historica set default false;

/* ───────────── 1. Tarea de agenda: series, cancelación y cierre ───────────── */

alter table cuidared.tarea_agenda
  add column serie_id uuid,                                  -- ocurrencias creadas juntas por una repetición
  add column motivo_cancelacion text,
  add column cancelada_por uuid references cuidared.usuario(usuario_id),
  add column completada_por uuid references cuidared.usuario(usuario_id),
  add column fecha_completada timestamp with time zone,
  add column actualizado_por uuid references cuidared.usuario(usuario_id);

alter table cuidared.tarea_agenda
  add constraint ck_tarea_titulo check (es_historica or char_length(btrim(titulo::text)) between 3 and 80),
  add constraint ck_tarea_serie check (serie_id is null or es_repetitiva),
  add constraint ck_tarea_motivo_cancelacion check (motivo_cancelacion is null or char_length(motivo_cancelacion) between 1 and 500),
  add constraint ck_tarea_completada check (es_historica or estado::text <> 'completada'
    or (completada_por is not null and fecha_completada is not null));

create index ix_tarea_envejeciente_fecha on cuidared.tarea_agenda (envejeciente_id, fecha_programada);
create index if not exists ix_tarea_cuidador_fecha on cuidared.tarea_agenda (cuidador_id, fecha_programada);
create index ix_tarea_serie on cuidared.tarea_agenda (serie_id) where serie_id is not null;

/* ───────────── 2. Evidencia: archivo privado, autoría y validación ───────────── */

alter table cuidared.evidencia
  add column registrada_por uuid references cuidared.usuario(usuario_id),
  add column nombre_archivo character varying,
  add column tipo_mime character varying,
  add column tamano_bytes integer,
  add column validada_por uuid references cuidared.usuario(usuario_id),
  add column fecha_validacion timestamp with time zone,
  add column motivo_rechazo text;

alter table cuidared.evidencia
  add constraint ck_evidencia_metadatos check (es_historica or (registrada_por is not null
    and nombre_archivo is not null and tipo_mime is not null and tamano_bytes is not null)),
  add constraint ck_evidencia_tipo_mime check (tipo_mime::text in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  add constraint ck_evidencia_tamano check (tamano_bytes between 1 and 5242880),            -- RS-013: 5 MB
  add constraint ck_evidencia_nombre check (char_length(btrim(nombre_archivo::text)) between 1 and 150
                                            and nombre_archivo::text !~ '[/\\]'),
  add constraint ck_evidencia_observacion check (es_historica or observacion is null or char_length(observacion) <= 300),
  -- archivo_url guarda la RUTA en el bucket privado: cuenta/<cuenta_id>/tarea/<tarea_id>/<uuid>.<ext>
  add constraint ck_evidencia_ruta check (es_historica or archivo_url ~ ('^cuenta/[1-9][0-9]{0,17}/tarea/' || tarea_agenda_id::text
    || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$')),
  add constraint ck_evidencia_ruta_tipo check (
    (tipo_mime::text = 'image/jpeg' and archivo_url ~ '\.jpg$') or (tipo_mime::text = 'image/png' and archivo_url ~ '\.png$')
    or (tipo_mime::text = 'image/webp' and archivo_url ~ '\.webp$') or (tipo_mime::text = 'application/pdf' and archivo_url ~ '\.pdf$')),
  add constraint ck_evidencia_revision check (
    es_historica or (estado_validacion::text = 'pendiente' and validada_por is null and fecha_validacion is null and motivo_rechazo is null)
    or (estado_validacion::text = 'validada' and validada_por is not null and fecha_validacion is not null and motivo_rechazo is null)
    or (estado_validacion::text = 'rechazada' and validada_por is not null and fecha_validacion is not null
        and motivo_rechazo is not null and char_length(btrim(motivo_rechazo)) between 5 and 200));

create unique index uq_evidencia_archivo on cuidared.evidencia (archivo_url) where not es_historica;
create index ix_evidencia_tarea_estado on cuidared.evidencia (tarea_agenda_id, estado_validacion);

create function cuidared_interno.trg_agenda_historica_solo_lectura() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op <> 'INSERT' and old.es_historica then raise check_violation; end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.es_historica then raise check_violation; end if;
  return new;
end $$;
create trigger trg_tarea_historica_solo_lectura before insert or update or delete on cuidared.tarea_agenda
  for each row execute function cuidared_interno.trg_agenda_historica_solo_lectura();
create trigger trg_evidencia_historica_solo_lectura before insert or update or delete on cuidared.evidencia
  for each row execute function cuidared_interno.trg_agenda_historica_solo_lectura();

-- Sin acceso directo: solo a través de las RPC de cuidared_api (CR-160).
alter table cuidared.tarea_agenda enable row level security;
alter table cuidared.evidencia enable row level security;
revoke all on cuidared.tarea_agenda, cuidared.evidencia from public, anon, authenticated;

/* Coherencia entre tablas (FKs sueltas no la garantizan, CONTEXTO §8.4): el cuidador trabaja en la cuenta del adulto y
   la indicación es del mismo adulto. Defensa en profundidad: las RPC ya lo validan con errores CR_*. */
create function cuidared_interno.tarea_coherencia() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from cuidared.cuidador c
    join cuidared.envejeciente e on e.envejeciente_id = new.envejeciente_id
    join lateral cuidared_interno.membresia_activa(e.cuenta_id, c.usuario_id) m on m.rol = 'cuidador'
    where c.cuidador_id = new.cuidador_id and c.fecha_fin is null) then
    raise exception 'El cuidador no pertenece a la cuenta del adulto mayor' using errcode = '23514';
  end if;
  if new.indicacion_medica_id is not null and not exists (
    select 1 from cuidared.indicacion_medica i
    where i.indicacion_medica_id = new.indicacion_medica_id and i.envejeciente_id = new.envejeciente_id) then
    raise exception 'La indicación no corresponde al adulto mayor' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger trg_tarea_coherencia before insert or update of cuidador_id, envejeciente_id, indicacion_medica_id
  on cuidared.tarea_agenda for each row execute function cuidared_interno.tarea_coherencia();

/* ───────────── 3. Utilidades internas de entrada (prefijo agenda_; no expuestas) ───────────── */

-- Lee una clave del JSON comprobando su tipo JSON. null/ausente: error si es obligatoria, null si no.
create function cuidared_interno.agenda_dato(p_datos jsonb, p_clave text, p_tipo text, p_requerido boolean default true)
returns text language plpgsql immutable set search_path = '' as $$
declare v jsonb := p_datos -> p_clave;
begin
  if v is null or jsonb_typeof(v) = 'null' then
    if p_requerido then raise invalid_parameter_value; end if;
    return null;
  end if;
  if jsonb_typeof(v) is distinct from p_tipo then raise invalid_parameter_value; end if;
  return p_datos ->> p_clave;
end $$;

create function cuidared_interno.agenda_texto(p_datos jsonb, p_clave text, p_min integer, p_max integer, p_requerido boolean default true)
returns text language plpgsql immutable set search_path = '' as $$
declare v text := cuidared_interno.agenda_dato(p_datos, p_clave, 'string', p_requerido);
begin
  if v is null then return null; end if;
  v := btrim(v);
  if char_length(v) < p_min or char_length(v) > p_max or v ~ '[[:cntrl:]]' then raise invalid_parameter_value; end if;
  return v;
end $$;

create function cuidared_interno.agenda_fecha(p_datos jsonb, p_clave text, p_requerido boolean default true)
returns date language plpgsql immutable set search_path = '' as $$
declare v text := cuidared_interno.agenda_dato(p_datos, p_clave, 'string', p_requerido);
begin
  if v is null then return null; end if;
  if v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise invalid_parameter_value; end if;
  return v::date;
end $$;

create function cuidared_interno.agenda_hora(p_datos jsonb, p_clave text)
returns time language plpgsql immutable set search_path = '' as $$
declare v text := cuidared_interno.agenda_dato(p_datos, p_clave, 'string', false);
begin
  if v is null then return null; end if;
  if v !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise invalid_parameter_value; end if;
  return v::time;
end $$;

/* ───────────── 4. Autorización y carga de tareas (no expuestas) ───────────── */

-- ¿El usuario tiene una membresía activa en la cuenta cuyo rol incluye la acción?
create function cuidared_interno.agenda_tiene_permiso(p_cuenta_id bigint, p_usuario_id uuid, p_accion text) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m
    where p_accion = any (cuidared_interno.permisos(m.rol_id, m.tipo_cuenta_id)))
$$;

-- ¿La tarea (de la cuenta) está asignada al usuario mediante su perfil Cuidador en esa cuenta?
create function cuidared_interno.tarea_es_del_cuidador(p_cuenta_id bigint, p_tarea_id uuid, p_usuario_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from cuidared.tarea_agenda t
    join cuidared.cuidador c on c.cuidador_id = t.cuidador_id
    join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
    where t.tarea_agenda_id = p_tarea_id and c.usuario_id = p_usuario_id and c.fecha_fin is null
      and e.cuenta_id = p_cuenta_id)
$$;

/* Visibilidad (agenda:ver): quien gestiona la agenda ve todas las tareas de los adultos a su alcance; el resto (el
   Cuidador) solo las asignadas a su perfil en la cuenta, y siempre con alcance sobre el adulto. */
create function cuidared_interno.tarea_puede_ver(p_cuenta_id bigint, p_tarea_id uuid, p_usuario_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from cuidared.tarea_agenda t
    join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
    where t.tarea_agenda_id = p_tarea_id and e.cuenta_id = p_cuenta_id
      and cuidared_interno.agenda_tiene_permiso(p_cuenta_id, p_usuario_id, 'agenda:ver')
      and cuidared_interno.alcanza_envejeciente(p_cuenta_id, t.envejeciente_id, p_usuario_id)
      and (cuidared_interno.agenda_tiene_permiso(p_cuenta_id, p_usuario_id, 'agenda:gestionar')
           or cuidared_interno.tarea_es_del_cuidador(p_cuenta_id, t.tarea_agenda_id, p_usuario_id)))
$$;

/* El perfil Cuidador puede recibir tareas del adulto: vigente en la cuenta, membresía activa con agenda:ejecutar y
   alcance sobre el adulto (vínculo cuidador_asignado no revocado, vía alcanza_envejeciente). Devuelve su usuario_id.
   Un perfil inexistente o de otra cuenta recibe el mismo error: no se revela. */
create function cuidared_interno.tarea_exigir_cuidador(p_cuenta_id bigint, p_cuidador_id bigint, p_envejeciente_id uuid) returns uuid
language plpgsql stable set search_path = '' as $$
declare v_usuario uuid;
begin
  select c.usuario_id into v_usuario from cuidared.cuidador c
  where c.cuidador_id = p_cuidador_id
    and (c.fecha_fin is null or c.fecha_fin >= cuidared_interno.hoy());
  if v_usuario is null
     or not cuidared_interno.agenda_tiene_permiso(p_cuenta_id, v_usuario, 'agenda:ejecutar')
     or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, p_envejeciente_id, v_usuario) then
    raise exception 'CR_CUIDADOR_NO_ASIGNADO' using errcode = 'P0001';
  end if;
  return v_usuario;
end $$;

-- Carga y bloquea la tarea de la cuenta. Una tarea de otra cuenta se trata como inexistente (P0002).
create function cuidared_interno.tarea_cargar(p_cuenta_id bigint, p_tarea_id uuid) returns cuidared.tarea_agenda
language plpgsql set search_path = '' as $$
declare v_t cuidared.tarea_agenda;
begin
  select t.* into v_t from cuidared.tarea_agenda t
  join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
  where t.tarea_agenda_id = p_tarea_id and e.cuenta_id = p_cuenta_id
  for update of t;
  if not found then raise no_data_found; end if;
  if v_t.es_historica then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  return v_t;
end $$;

-- Usuario Cuidador de la tarea (para avisos).
create function cuidared_interno.tarea_usuario_cuidador(p_cuidador_id bigint) returns uuid
language sql stable set search_path = '' as $$
  select c.usuario_id from cuidared.cuidador c where c.cuidador_id = p_cuidador_id
$$;

create function cuidared_interno.agenda_notificar(p_usuario_id uuid, p_cuenta_id bigint, p_mensaje text) returns void
language sql set search_path = '' as $$
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
  select p_usuario_id, p_cuenta_id, p_mensaje where p_usuario_id is not null
$$;

/* ───────────── 5. Representación JSON (snake_case) ───────────── */

create function cuidared_interno.tarea_json(p_tarea_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'tarea_id', t.tarea_agenda_id,
    'envejeciente_id', t.envejeciente_id,
    'envejeciente_nombre', btrim(e.nombres::text || ' ' || e.apellidos::text),
    'cuidador_id', t.cuidador_id::text,
    'cuidador_nombre', btrim(u.nombres::text || ' ' || u.apellidos::text),
    'indicacion_medica_id', t.indicacion_medica_id,
    'indicacion_titulo', i.titulo,
    'prioridad_id', t.prioridad_id,
    'prioridad', p.nombre,
    'titulo', t.titulo,
    'fecha_programada', t.fecha_programada,
    'hora_programada', to_char(t.hora_programada, 'HH24:MI'),
    'estado', t.estado,
    'es_historica', t.es_historica,
    'requiere_evidencia', t.requiere_evidencia,
    'es_repetitiva', t.es_repetitiva,
    'serie_id', t.serie_id,
    'motivo_cancelacion', t.motivo_cancelacion,
    'completada_por', t.completada_por,
    'fecha_completada', t.fecha_completada,
    'evidencias', jsonb_build_object(
      'pendientes', (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'pendiente'),
      'validadas', (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'validada'),
      'rechazadas', (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'rechazada')),
    -- Motivo visible para el cuidador: la tarea volvió a pendiente y espera una evidencia nueva.
    'ultimo_motivo_rechazo', case when t.estado::text = 'pendiente'
        and not exists (select 1 from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text in ('pendiente', 'validada'))
      then (select v.motivo_rechazo from cuidared.evidencia v
            where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'rechazada'
            order by v.fecha_validacion desc, v.evidencia_id limit 1) end,
    'usuario_creador_id', t.usuario_creador_id,
    'fecha_creacion', t.fecha_creacion,
    'fecha_actualizacion', t.fecha_actualizacion)
  from cuidared.tarea_agenda t
  join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
  join cuidared.cuidador c on c.cuidador_id = t.cuidador_id
  join cuidared.usuario u on u.usuario_id = c.usuario_id
  join cuidared.prioridad p on p.prioridad_id = t.prioridad_id
  left join cuidared.indicacion_medica i on i.indicacion_medica_id = t.indicacion_medica_id
    and i.envejeciente_id = t.envejeciente_id
  where t.tarea_agenda_id = p_tarea_id
$$;

-- `ruta` (interna) solo se incluye para que la API firme la descarga; la API no la devuelve al cliente.
create function cuidared_interno.evidencia_json(p_evidencia_id uuid, p_con_ruta boolean default false) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'evidencia_id', v.evidencia_id,
    'tarea_id', v.tarea_agenda_id,
    'nombre_archivo', v.nombre_archivo,
    'tipo_mime', v.tipo_mime,
    'tamano_bytes', v.tamano_bytes,
    'observacion', v.observacion,
    'estado_validacion', v.estado_validacion,
    'es_historica', v.es_historica,
    'motivo_rechazo', v.motivo_rechazo,
    'registrada_por', v.registrada_por,
    'registrada_por_nombre', btrim(r.nombres::text || ' ' || r.apellidos::text),
    'fecha_registro', v.fecha_registro,
    'validada_por', v.validada_por,
    'validada_por_nombre', btrim(a.nombres::text || ' ' || a.apellidos::text),
    'fecha_validacion', v.fecha_validacion)
    || case when p_con_ruta and not v.es_historica then jsonb_build_object('ruta', v.archivo_url) else '{}'::jsonb end
  from cuidared.evidencia v
  left join cuidared.usuario r on r.usuario_id = v.registrada_por
  left join cuidared.usuario a on a.usuario_id = v.validada_por
  where v.evidencia_id = p_evidencia_id
$$;

/* ───────────── 6. RPC de tareas (cuidared_api) ───────────── */

/*
 * Listado paginado. p_filtros: {desde, hasta, estado, envejeciente_id, cuidador_id} (todas opcionales).
 * p_orden: [{campo, direccion}] con campos de lista cerrada (se traducen a expresiones fijas; nunca se concatena
 * texto del cliente). Devuelve {data, total}. Quien gestiona ve todas las tareas de su alcance; el Cuidador, las suyas.
 */
create function cuidared_api.api_tareas_listar(p_cuenta_id bigint, p_filtros jsonb default '{}'::jsonb,
  p_orden jsonb default '[]'::jsonb, p_limit integer default 20, p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_gestor boolean;
  v_desde date; v_hasta date; v_estado text; v_env uuid; v_cuidador bigint;
  v_visibles uuid[]; v_propios bigint[];
  v_order text; v_where text; v_ids uuid[]; v_total bigint;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'agenda:ver');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset < 0 then
    raise invalid_parameter_value;
  end if;
  if jsonb_typeof(p_filtros) is distinct from 'object'
     or p_filtros - array['desde', 'hasta', 'estado', 'envejeciente_id', 'cuidador_id'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  begin
    v_desde := cuidared_interno.agenda_fecha(p_filtros, 'desde', false);
    v_hasta := cuidared_interno.agenda_fecha(p_filtros, 'hasta', false);
    v_estado := cuidared_interno.agenda_dato(p_filtros, 'estado', 'string', false);
    v_env := cuidared_interno.agenda_dato(p_filtros, 'envejeciente_id', 'string', false)::uuid;
    v_cuidador := cuidared_interno.agenda_dato(p_filtros, 'cuidador_id', 'string', false)::bigint;
  exception when data_exception then raise invalid_parameter_value;
  end;
  if v_estado is not null and v_estado not in ('pendiente', 'en_progreso', 'completada', 'cancelada') then
    raise invalid_parameter_value;
  end if;
  if v_desde is not null and v_hasta is not null and v_desde > v_hasta then raise invalid_parameter_value; end if;

  if jsonb_typeof(p_orden) is distinct from 'array' or exists (
    select 1 from jsonb_array_elements(p_orden) o
    where jsonb_typeof(o) is distinct from 'object'
       or (o->>'campo') is null or (o->>'campo') not in ('fecha_programada', 'hora_programada', 'estado', 'prioridad', 'fecha_creacion', 'tarea_id')
       or (o->>'direccion') is null or (o->>'direccion') not in ('asc', 'desc')) then
    raise invalid_parameter_value;
  end if;
  select string_agg(
      case o->>'campo'
        when 'fecha_programada' then 't.fecha_programada'
        when 'hora_programada' then 't.hora_programada'
        when 'estado' then 't.estado'
        when 'prioridad' then 'p.orden'
        when 'fecha_creacion' then 't.fecha_creacion'
        else 't.tarea_agenda_id' end
      || case o->>'direccion' when 'desc' then ' desc nulls last' else ' asc nulls last' end, ', ' order by ord)
    into v_order from jsonb_array_elements(p_orden) with ordinality as x(o, ord);
  v_order := coalesce(v_order, 't.fecha_programada asc, t.hora_programada asc nulls last, t.tarea_agenda_id asc');

  v_gestor := cuidared_interno.agenda_tiene_permiso(p_cuenta_id, v_uid, 'agenda:gestionar');
  -- El alcance se evalúa una vez por adulto, no por tarea.
  select coalesce(array_agg(e.envejeciente_id), array[]::uuid[]) into v_visibles
  from cuidared.envejeciente e
  where e.cuenta_id = p_cuenta_id and cuidared_interno.alcanza_envejeciente(p_cuenta_id, e.envejeciente_id, v_uid);
  if not v_gestor then
    select coalesce(array_agg(c.cuidador_id), array[]::bigint[]) into v_propios
    from cuidared.cuidador c where c.usuario_id = v_uid and c.fecha_fin is null;
  end if;

  v_where := $w$ e.cuenta_id = $1 and t.envejeciente_id = any ($2)
    and ($3::bigint[] is null or t.cuidador_id = any ($3))
    and ($4::date is null or t.fecha_programada >= $4) and ($5::date is null or t.fecha_programada <= $5)
    and ($6::text is null or t.estado = $6) and ($7::uuid is null or t.envejeciente_id = $7)
    and ($8::bigint is null or t.cuidador_id = $8) $w$;
  execute format($q$ select count(*) from cuidared.tarea_agenda t
      join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id where %s $q$, v_where)
    into v_total using p_cuenta_id, v_visibles, v_propios, v_desde, v_hasta, v_estado, v_env, v_cuidador;
  execute format($q$ select array_agg(s.tarea_id order by s.rn) from (
      select t.tarea_agenda_id as tarea_id, row_number() over (order by %1$s) as rn
      from cuidared.tarea_agenda t
      join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
      join cuidared.prioridad p on p.prioridad_id = t.prioridad_id
      where %2$s order by %1$s limit $9 offset $10) s $q$, v_order, v_where)
    into v_ids using p_cuenta_id, v_visibles, v_propios, v_desde, v_hasta, v_estado, v_env, v_cuidador, p_limit, p_offset;

  return jsonb_build_object(
    'data', coalesce((select jsonb_agg(cuidared_interno.tarea_json(u.id) order by u.ord)
                      from unnest(v_ids) with ordinality as u(id, ord)), '[]'::jsonb),
    'total', v_total);
end;
$$;

create function cuidared_api.api_tarea_obtener(p_cuenta_id bigint, p_tarea_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:ver')->>'usuario_id')::uuid;
  -- Otra cuenta, otro cuidador o tarea inexistente: la misma respuesta (404).
  if not cuidared_interno.tarea_puede_ver(p_cuenta_id, p_tarea_id, v_uid) then raise no_data_found; end if;
  return cuidared_interno.tarea_json(p_tarea_id);
end;
$$;

/*
 * Crea la tarea o, con `repeticion`, una tarea por ocurrencia (máx. 60) con un serie_id común.
 * p_datos: {envejeciente_id, cuidador_id, titulo, indicacion_medica_id?, prioridad_id, fecha_programada,
 *           hora_programada? 'HH:MM', requiere_evidencia, repeticion?: {frecuencia, dias_semana?, hasta}}
 * dias_semana usa ISO 8601: 1 = lunes … 7 = domingo.
 */
create function cuidared_api.api_tarea_crear(p_cuenta_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_env uuid; v_cuidador bigint; v_titulo text; v_indicacion uuid; v_prioridad smallint;
  v_fecha date; v_hora time; v_evidencia boolean;
  v_rep jsonb; v_frec text; v_hasta date; v_dias integer[]; v_fechas date[];
  v_e record;
  v_usuario_cuidador uuid;
  v_serie uuid; v_id uuid; v_ids uuid[] := array[]::uuid[]; v_f date;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:gestionar')->>'usuario_id')::uuid;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['envejeciente_id', 'cuidador_id', 'titulo',
       'indicacion_medica_id', 'prioridad_id', 'fecha_programada', 'hora_programada', 'requiere_evidencia', 'repeticion'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  begin
    v_env := cuidared_interno.agenda_dato(p_datos, 'envejeciente_id', 'string')::uuid;
    v_cuidador := cuidared_interno.agenda_dato(p_datos, 'cuidador_id', 'string')::bigint;
    v_titulo := cuidared_interno.agenda_texto(p_datos, 'titulo', 3, 80);
    v_indicacion := cuidared_interno.agenda_dato(p_datos, 'indicacion_medica_id', 'string', false)::uuid;
    v_prioridad := cuidared_interno.agenda_dato(p_datos, 'prioridad_id', 'number')::smallint;
    v_fecha := cuidared_interno.agenda_fecha(p_datos, 'fecha_programada');
    v_hora := cuidared_interno.agenda_hora(p_datos, 'hora_programada');
    v_evidencia := cuidared_interno.agenda_dato(p_datos, 'requiere_evidencia', 'boolean')::boolean;
  exception when data_exception then raise invalid_parameter_value;
  end;
  if v_fecha < cuidared_interno.hoy() then raise invalid_parameter_value; end if;

  -- Repetición (propuesta técnica D12): diaria o semanal con fecha de fin; máximo 60 ocurrencias.
  v_rep := p_datos -> 'repeticion';
  if v_rep is null or jsonb_typeof(v_rep) = 'null' then
    v_fechas := array[v_fecha];
  else
    begin
      if jsonb_typeof(v_rep) <> 'object' or v_rep - array['frecuencia', 'dias_semana', 'hasta'] <> '{}'::jsonb then
        raise invalid_parameter_value;
      end if;
      v_frec := cuidared_interno.agenda_dato(v_rep, 'frecuencia', 'string');
      v_hasta := cuidared_interno.agenda_fecha(v_rep, 'hasta');
      if v_frec = 'semanal' then
        if jsonb_typeof(v_rep -> 'dias_semana') is distinct from 'array'
           or exists (select 1 from jsonb_array_elements(v_rep -> 'dias_semana') d
                      where jsonb_typeof(d) <> 'number' or (d #>> '{}') !~ '^[1-7]$') then
          raise invalid_parameter_value;
        end if;
        select array_agg(distinct (d #>> '{}')::integer) into v_dias from jsonb_array_elements(v_rep -> 'dias_semana') d;
      elsif v_frec = 'diaria' then
        if v_rep ? 'dias_semana' and jsonb_typeof(v_rep -> 'dias_semana') <> 'null'
           and v_rep -> 'dias_semana' <> '[]'::jsonb then
          raise invalid_parameter_value;
        end if;
      else
        raise invalid_parameter_value;
      end if;
      if v_hasta < v_fecha or v_hasta - v_fecha > 730 then raise invalid_parameter_value; end if;
    exception when data_exception then
      raise exception 'CR_REPETICION_INVALIDA' using errcode = 'P0001';
    end;
    select array_agg(d::date order by d) into v_fechas
    from generate_series(v_fecha::timestamp, v_hasta::timestamp, interval '1 day') d
    where v_frec = 'diaria' or extract(isodow from d)::integer = any (v_dias);
    if v_fechas is null or cardinality(v_fechas) > 60 then
      raise exception 'CR_REPETICION_INVALIDA' using errcode = 'P0001';
    end if;
    v_serie := gen_random_uuid();
  end if;

  -- El adulto debe ser de la cuenta (si no, "no existe"), estar a mi alcance y activo.
  select e.nombres, e.apellidos, e.estado into v_e
  from cuidared.envejeciente e where e.envejeciente_id = v_env and e.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_uid) then raise insufficient_privilege; end if;
  if v_e.estado::text <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if not exists (select 1 from cuidared.prioridad where prioridad_id = v_prioridad) then
    raise invalid_parameter_value;
  end if;
  if v_indicacion is not null and not exists (
    select 1 from cuidared.indicacion_medica i where i.indicacion_medica_id = v_indicacion and i.envejeciente_id = v_env) then
    raise exception 'CR_INDICACION_NO_CORRESPONDE' using errcode = 'P0001';
  end if;
  v_usuario_cuidador := cuidared_interno.tarea_exigir_cuidador(p_cuenta_id, v_cuidador, v_env);

  foreach v_f in array v_fechas loop
    insert into cuidared.tarea_agenda (cuidador_id, envejeciente_id, indicacion_medica_id, prioridad_id, usuario_creador_id,
                                       titulo, fecha_programada, hora_programada, requiere_evidencia, es_repetitiva, serie_id,
                                       actualizado_por)
    values (v_cuidador, v_env, v_indicacion, v_prioridad, v_uid, v_titulo, v_f, v_hora, v_evidencia, v_serie is not null,
            v_serie, v_uid)
    returning tarea_agenda_id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  if v_usuario_cuidador <> v_uid then
    perform cuidared_interno.agenda_notificar(v_usuario_cuidador, p_cuenta_id,
      case when cardinality(v_fechas) > 1
        then format('Se te asignaron %s tareas «%s» para %s, del %s al %s.', cardinality(v_fechas), v_titulo,
                    btrim(v_e.nombres::text || ' ' || v_e.apellidos::text), to_char(v_fechas[1], 'DD/MM/YYYY'),
                    to_char(v_fechas[cardinality(v_fechas)], 'DD/MM/YYYY'))
        else format('Se te asignó la tarea «%s» para %s: %s%s.', v_titulo, btrim(v_e.nombres::text || ' ' || v_e.apellidos::text),
                    to_char(v_fechas[1], 'DD/MM/YYYY'), coalesce(' ' || to_char(v_hora, 'HH24:MI'), '')) end);
  end if;

  return jsonb_build_object('serie_id', v_serie, 'tareas',
    (select jsonb_agg(cuidared_interno.tarea_json(u.id) order by u.ord) from unnest(v_ids) with ordinality as u(id, ord)));
end;
$$;

/*
 * Edita una tarea PENDIENTE. p_datos admite titulo, cuidador_id, indicacion_medica_id (null la quita), prioridad_id,
 * fecha_programada, hora_programada (null la quita), requiere_evidencia y alcance ('esta' | 'siguientes').
 * Con 'siguientes' los cambios también se aplican a las ocurrencias pendientes posteriores de la serie; la fecha solo
 * puede cambiarse en 'esta'.
 */
create function cuidared_api.api_tarea_actualizar(p_cuenta_id bigint, p_tarea_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_t cuidared.tarea_agenda;
  v_alcance text;
  v_titulo text; v_cuidador bigint; v_indicacion uuid; v_prioridad smallint; v_fecha date; v_hora time; v_evidencia boolean;
  v_ids uuid[]; v_olds uuid[]; v_nuevo uuid; v_e record; v_n integer;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:gestionar')->>'usuario_id')::uuid;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos = '{}'::jsonb or p_datos - 'alcance' = '{}'::jsonb
     or p_datos - array['titulo', 'cuidador_id', 'indicacion_medica_id', 'prioridad_id', 'fecha_programada',
                        'hora_programada', 'requiere_evidencia', 'alcance'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  begin
    v_alcance := coalesce(cuidared_interno.agenda_dato(p_datos, 'alcance', 'string', false), 'esta');
    if p_datos ? 'titulo' then v_titulo := cuidared_interno.agenda_texto(p_datos, 'titulo', 3, 80); end if;
    if p_datos ? 'cuidador_id' then v_cuidador := cuidared_interno.agenda_dato(p_datos, 'cuidador_id', 'string')::bigint; end if;
    if p_datos ? 'indicacion_medica_id' then v_indicacion := cuidared_interno.agenda_dato(p_datos, 'indicacion_medica_id', 'string', false)::uuid; end if;
    if p_datos ? 'prioridad_id' then v_prioridad := cuidared_interno.agenda_dato(p_datos, 'prioridad_id', 'number')::smallint; end if;
    if p_datos ? 'fecha_programada' then v_fecha := cuidared_interno.agenda_fecha(p_datos, 'fecha_programada'); end if;
    if p_datos ? 'hora_programada' then v_hora := cuidared_interno.agenda_hora(p_datos, 'hora_programada'); end if;
    if p_datos ? 'requiere_evidencia' then v_evidencia := cuidared_interno.agenda_dato(p_datos, 'requiere_evidencia', 'boolean')::boolean; end if;
  exception when data_exception then raise invalid_parameter_value;
  end;
  if v_alcance not in ('esta', 'siguientes') or (v_alcance = 'siguientes' and p_datos ? 'fecha_programada')
     or v_fecha < cuidared_interno.hoy() then
    raise invalid_parameter_value;
  end if;
  if p_datos ? 'prioridad_id' and not exists (select 1 from cuidared.prioridad where prioridad_id = v_prioridad) then
    raise invalid_parameter_value;
  end if;

  v_t := cuidared_interno.tarea_cargar(p_cuenta_id, p_tarea_id);
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_t.envejeciente_id, v_uid) then raise insufficient_privilege; end if;
  if v_t.estado::text <> 'pendiente' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if p_datos ? 'indicacion_medica_id' and v_indicacion is not null and not exists (
    select 1 from cuidared.indicacion_medica i where i.indicacion_medica_id = v_indicacion and i.envejeciente_id = v_t.envejeciente_id) then
    raise exception 'CR_INDICACION_NO_CORRESPONDE' using errcode = 'P0001';
  end if;
  if p_datos ? 'cuidador_id' then v_nuevo := cuidared_interno.tarea_exigir_cuidador(p_cuenta_id, v_cuidador, v_t.envejeciente_id); end if;

  -- Objetivos en orden cronológico (mismo orden de bloqueo en todas las operaciones de serie).
  if v_alcance = 'siguientes' and v_t.serie_id is not null then
    select coalesce(array_agg(x.tarea_agenda_id order by x.fecha_programada, x.hora_programada nulls first, x.tarea_agenda_id), array[]::uuid[])
      into v_ids
    from cuidared.tarea_agenda x
    where x.serie_id = v_t.serie_id and x.estado::text = 'pendiente'
      and (x.tarea_agenda_id = v_t.tarea_agenda_id
           or (x.fecha_programada, coalesce(x.hora_programada, time '00:00'))
              > (v_t.fecha_programada, coalesce(v_t.hora_programada, time '00:00')));
    perform 1 from cuidared.tarea_agenda x where x.tarea_agenda_id = any (v_ids)
      order by x.fecha_programada, x.hora_programada nulls first, x.tarea_agenda_id for update;
  else
    v_ids := array[v_t.tarea_agenda_id];
  end if;
  v_n := cardinality(v_ids);
  select array_agg(distinct c.usuario_id) into v_olds from cuidared.tarea_agenda x
    join cuidared.cuidador c on c.cuidador_id = x.cuidador_id where x.tarea_agenda_id = any (v_ids);

  update cuidared.tarea_agenda t set
    titulo = case when p_datos ? 'titulo' then v_titulo else t.titulo end,
    cuidador_id = case when p_datos ? 'cuidador_id' then v_cuidador else t.cuidador_id end,
    indicacion_medica_id = case when p_datos ? 'indicacion_medica_id' then v_indicacion else t.indicacion_medica_id end,
    prioridad_id = case when p_datos ? 'prioridad_id' then v_prioridad else t.prioridad_id end,
    fecha_programada = case when p_datos ? 'fecha_programada' then v_fecha else t.fecha_programada end,
    hora_programada = case when p_datos ? 'hora_programada' then v_hora else t.hora_programada end,
    requiere_evidencia = case when p_datos ? 'requiere_evidencia' then v_evidencia else t.requiere_evidencia end,
    actualizado_por = v_uid,
    fecha_actualizacion = now()
  where t.tarea_agenda_id = any (v_ids);

  select e.nombres, e.apellidos into v_e from cuidared.envejeciente e where e.envejeciente_id = v_t.envejeciente_id;
  if p_datos ? 'cuidador_id' then
    if v_nuevo <> v_uid then
      perform cuidared_interno.agenda_notificar(v_nuevo, p_cuenta_id,
        case when v_n > 1 then format('Se te asignaron %s tareas «%s» para %s.', v_n, coalesce(v_titulo, v_t.titulo), btrim(v_e.nombres::text || ' ' || v_e.apellidos::text))
             else format('Se te asignó la tarea «%s» para %s.', coalesce(v_titulo, v_t.titulo), btrim(v_e.nombres::text || ' ' || v_e.apellidos::text)) end);
    end if;
    perform cuidared_interno.agenda_notificar(o, p_cuenta_id,
      format('La tarea «%s» (%s) ya no está asignada a ti.', coalesce(v_titulo, v_t.titulo), to_char(v_t.fecha_programada, 'DD/MM/YYYY')))
      from unnest(v_olds) o where o <> v_nuevo and o <> v_uid;
  else
    perform cuidared_interno.agenda_notificar(o, p_cuenta_id,
      format('Se actualizó la tarea «%s» (%s).', coalesce(v_titulo, v_t.titulo), to_char(coalesce(v_fecha, v_t.fecha_programada), 'DD/MM/YYYY')))
      from unnest(v_olds) o where o <> v_uid;
  end if;
  return cuidared_interno.tarea_json(p_tarea_id);
end;
$$;

/*
 * Cancela una tarea abierta (pendiente o en progreso) o, con alcance 'siguientes', esta y las siguientes ocurrencias
 * abiertas de su serie. Motivo obligatorio. Devuelve {canceladas, tarea}.
 */
create function cuidared_api.api_tarea_cancelar(p_cuenta_id bigint, p_tarea_id uuid, p_motivo text, p_alcance text default 'esta')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_t cuidared.tarea_agenda;
  v_motivo text := btrim(p_motivo);
  v_ids uuid[]; v_n integer; v_e record;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:gestionar')->>'usuario_id')::uuid;
  if v_motivo is null or char_length(v_motivo) not between 3 and 300 or v_motivo ~ '[[:cntrl:]]'
     or p_alcance is null or p_alcance not in ('esta', 'siguientes') then
    raise invalid_parameter_value;
  end if;
  v_t := cuidared_interno.tarea_cargar(p_cuenta_id, p_tarea_id);
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_t.envejeciente_id, v_uid) then raise insufficient_privilege; end if;
  if v_t.estado::text not in ('pendiente', 'en_progreso') then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;

  if p_alcance = 'siguientes' and v_t.serie_id is not null then
    select coalesce(array_agg(x.tarea_agenda_id order by x.fecha_programada, x.hora_programada nulls first, x.tarea_agenda_id), array[]::uuid[])
      into v_ids
    from cuidared.tarea_agenda x
    where x.serie_id = v_t.serie_id and x.estado::text in ('pendiente', 'en_progreso')
      and (x.tarea_agenda_id = v_t.tarea_agenda_id
           or (x.fecha_programada, coalesce(x.hora_programada, time '00:00'))
              > (v_t.fecha_programada, coalesce(v_t.hora_programada, time '00:00')));
    perform 1 from cuidared.tarea_agenda x where x.tarea_agenda_id = any (v_ids)
      order by x.fecha_programada, x.hora_programada nulls first, x.tarea_agenda_id for update;
  else
    v_ids := array[v_t.tarea_agenda_id];
  end if;
  v_n := cardinality(v_ids);

  -- Un aviso por cuidador afectado (antes de cambiar el estado, con los datos de cada tarea).
  select e.nombres, e.apellidos into v_e from cuidared.envejeciente e where e.envejeciente_id = v_t.envejeciente_id;
  perform cuidared_interno.agenda_notificar(g.usuario_id, p_cuenta_id,
    case when g.n > 1 then format('Se cancelaron %s tareas «%s» para %s, desde el %s. Motivo: %s', g.n, v_t.titulo,
                                  btrim(v_e.nombres::text || ' ' || v_e.apellidos::text), to_char(g.desde, 'DD/MM/YYYY'), v_motivo)
         else format('Se canceló la tarea «%s» para %s (%s). Motivo: %s', v_t.titulo,
                     btrim(v_e.nombres::text || ' ' || v_e.apellidos::text), to_char(g.desde, 'DD/MM/YYYY'), v_motivo) end)
  from (select c.usuario_id, count(*) as n, min(x.fecha_programada) as desde
        from cuidared.tarea_agenda x join cuidared.cuidador c on c.cuidador_id = x.cuidador_id
        where x.tarea_agenda_id = any (v_ids) group by c.usuario_id) g
  where g.usuario_id <> v_uid;

  update cuidared.tarea_agenda t set
    estado = 'cancelada', motivo_cancelacion = v_motivo, cancelada_por = v_uid,
    actualizado_por = v_uid, fecha_actualizacion = now()
  where t.tarea_agenda_id = any (v_ids);
  return jsonb_build_object('canceladas', v_n, 'tarea', cuidared_interno.tarea_json(p_tarea_id));
end;
$$;

-- Carga la tarea para ejecutarla: solo su cuidador asignado, con alcance sobre el adulto.
create function cuidared_interno.tarea_para_ejecutar(p_cuenta_id bigint, p_tarea_id uuid, out o_uid uuid, out o_tarea cuidared.tarea_agenda)
language plpgsql set search_path = '' as $$
begin
  o_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:ejecutar')->>'usuario_id')::uuid;
  -- Tarea de otra cuenta, de otro cuidador o inexistente: 404 (el Cuidador no ve las ajenas).
  if not cuidared_interno.tarea_puede_ver(p_cuenta_id, p_tarea_id, o_uid) then raise no_data_found; end if;
  o_tarea := cuidared_interno.tarea_cargar(p_cuenta_id, p_tarea_id);
  if not cuidared_interno.tarea_es_del_cuidador(p_cuenta_id, p_tarea_id, o_uid) then raise insufficient_privilege; end if;
end $$;

create function cuidared_api.api_tarea_iniciar(p_cuenta_id bigint, p_tarea_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_r record; v_uid uuid; v_t cuidared.tarea_agenda;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  select * into v_r from cuidared_interno.tarea_para_ejecutar(p_cuenta_id, p_tarea_id);
  v_uid := v_r.o_uid; v_t := v_r.o_tarea;
  if v_t.estado::text <> 'pendiente' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  update cuidared.tarea_agenda set estado = 'en_progreso', actualizado_por = v_uid, fecha_actualizacion = now()
  where tarea_agenda_id = p_tarea_id;
  return cuidared_interno.tarea_json(p_tarea_id);
end;
$$;

/* Completa la tarea. D12 (resuelta): si requiere evidencia, debe existir al menos una evidencia VALIDADA; una pendiente
   o rechazada no basta. Se comprueba aquí, nunca con el estado enviado por el cliente. */
create function cuidared_api.api_tarea_completar(p_cuenta_id bigint, p_tarea_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_r record; v_uid uuid; v_t cuidared.tarea_agenda;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  select * into v_r from cuidared_interno.tarea_para_ejecutar(p_cuenta_id, p_tarea_id);
  v_uid := v_r.o_uid; v_t := v_r.o_tarea;
  if v_t.estado::text not in ('pendiente', 'en_progreso') then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if v_t.requiere_evidencia and not exists (
    select 1 from cuidared.evidencia v where v.tarea_agenda_id = p_tarea_id and v.estado_validacion::text = 'validada') then
    raise exception 'CR_EVIDENCIA_REQUERIDA' using errcode = 'P0001';
  end if;
  update cuidared.tarea_agenda set estado = 'completada', completada_por = v_uid, fecha_completada = now(),
    actualizado_por = v_uid, fecha_actualizacion = now()
  where tarea_agenda_id = p_tarea_id;
  return cuidared_interno.tarea_json(p_tarea_id);
end;
$$;

/* ───────────── 7. RPC de evidencias (cuidared_api) ───────────── */

-- Valida los metadatos del archivo (RS-013). Devuelve la extensión de la ruta. CR_ARCHIVO_INVALIDO si no cumple.
create function cuidared_interno.evidencia_validar_archivo(p_datos jsonb, out o_nombre text, out o_tipo text, out o_tamano integer, out o_ext text)
language plpgsql immutable set search_path = '' as $$
begin
  o_nombre := cuidared_interno.agenda_texto(p_datos, 'nombre_archivo', 1, 150);
  o_tipo := cuidared_interno.agenda_dato(p_datos, 'tipo_mime', 'string');
  o_tamano := cuidared_interno.agenda_dato(p_datos, 'tamano_bytes', 'number')::integer;
  o_ext := case o_tipo when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp'
                       when 'application/pdf' then 'pdf' end;
  if o_ext is null or o_tamano not between 1 and 5242880 or o_nombre ~ '[/\\]' then
    raise exception 'CR_ARCHIVO_INVALIDO' using errcode = 'P0001';
  end if;
exception when data_exception then
  raise exception 'CR_ARCHIVO_INVALIDO' using errcode = 'P0001';
end $$;

-- Tarea del cuidador asignado, abierta y con cupo de evidencias (D13: máx. 5 no rechazadas).
create function cuidared_interno.evidencia_exigir_tarea(p_cuenta_id bigint, p_tarea_id uuid) returns uuid
language plpgsql set search_path = '' as $$
declare v_r record;
begin
  select * into v_r from cuidared_interno.tarea_para_ejecutar(p_cuenta_id, p_tarea_id);
  if (v_r.o_tarea).estado::text not in ('pendiente', 'en_progreso') then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = p_tarea_id and v.estado_validacion::text <> 'rechazada') >= 5 then
    raise exception 'CR_LIMITE_EVIDENCIAS' using errcode = 'P0001';
  end if;
  return v_r.o_uid;
end $$;

/*
 * Prepara la subida: autoriza al cuidador asignado, valida tipo y tamaño y genera la ruta del objeto
 * (cuenta/<cuenta_id>/tarea/<tarea_id>/<uuid>.<ext>). La API firma la subida con esa ruta (nunca la elige el cliente).
 * p_datos: {nombre_archivo, tipo_mime, tamano_bytes}.
 */
create function cuidared_api.api_evidencia_preparar_subida(p_cuenta_id bigint, p_tarea_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_a record; v_ruta text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  perform cuidared_interno.evidencia_exigir_tarea(p_cuenta_id, p_tarea_id);
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['nombre_archivo', 'tipo_mime', 'tamano_bytes'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  select * into v_a from cuidared_interno.evidencia_validar_archivo(p_datos);
  v_ruta := format('cuenta/%s/tarea/%s/%s.%s', p_cuenta_id, p_tarea_id, gen_random_uuid(), v_a.o_ext);
  return jsonb_build_object('ruta', v_ruta, 'tipo_mime', v_a.o_tipo, 'tamano_bytes', v_a.o_tamano);
end;
$$;

/*
 * Registra la evidencia (pendiente) de un archivo ya subido. p_datos: {ruta, observacion?, nombre_archivo, tipo_mime,
 * tamano_bytes}. La ruta debe ser de ESTA cuenta y ESTA tarea, el objeto debe existir en el bucket privado y, si Storage
 * informa tamaño y tipo, deben coincidir con lo declarado y cumplir RS-013.
 */
create function cuidared_api.api_evidencia_registrar(p_cuenta_id bigint, p_tarea_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid; v_a record; v_ruta text; v_obs text; v_id uuid; v_meta jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := cuidared_interno.evidencia_exigir_tarea(p_cuenta_id, p_tarea_id);
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['ruta', 'observacion', 'nombre_archivo', 'tipo_mime', 'tamano_bytes'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  begin
    v_ruta := cuidared_interno.agenda_dato(p_datos, 'ruta', 'string');
    v_obs := cuidared_interno.agenda_texto(p_datos, 'observacion', 1, 300, false);
  exception when data_exception then raise invalid_parameter_value;
  end;
  select * into v_a from cuidared_interno.evidencia_validar_archivo(p_datos);
  if v_ruta !~ format('^cuenta/%s/tarea/%s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.%s$',
                      p_cuenta_id, p_tarea_id, v_a.o_ext) then
    raise exception 'CR_ARCHIVO_INVALIDO' using errcode = 'P0001';
  end if;
  if exists (select 1 from cuidared.evidencia v where v.es_historica and v.archivo_url = v_ruta) then
    raise exception 'CR_ARCHIVO_INVALIDO' using errcode = 'P0001';
  end if;
  select o.metadata into v_meta from storage.objects o where o.bucket_id = 'evidencias' and o.name = v_ruta;
  if not found then raise exception 'CR_ARCHIVO_NO_SUBIDO' using errcode = 'P0001'; end if;
  if v_meta ? 'size' and (v_meta->>'size')::bigint is distinct from v_a.o_tamano then
    raise exception 'CR_ARCHIVO_INVALIDO' using errcode = 'P0001';
  end if;
  if v_meta ? 'mimetype' and lower(split_part(v_meta->>'mimetype', ';', 1)) <> v_a.o_tipo then
    raise exception 'CR_ARCHIVO_INVALIDO' using errcode = 'P0001';
  end if;
  insert into cuidared.evidencia (tarea_agenda_id, archivo_url, observacion, registrada_por, nombre_archivo, tipo_mime, tamano_bytes)
  values (p_tarea_id, v_ruta, v_obs, v_uid, v_a.o_nombre, v_a.o_tipo, v_a.o_tamano)
  returning evidencia_id into v_id;
  update cuidared.tarea_agenda set actualizado_por = v_uid, fecha_actualizacion = now() where tarea_agenda_id = p_tarea_id;
  return cuidared_interno.evidencia_json(v_id);
end;
$$;

/* Evidencias de una tarea con su ruta interna (la API firma la descarga y no devuelve la ruta). Solo quien ve la tarea. */
create function cuidared_api.api_evidencias_listar(p_cuenta_id bigint, p_tarea_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:ver')->>'usuario_id')::uuid;
  if not cuidared_interno.tarea_puede_ver(p_cuenta_id, p_tarea_id, v_uid) then raise no_data_found; end if;
  return coalesce((select jsonb_agg(cuidared_interno.evidencia_json(v.evidencia_id, true) order by v.fecha_registro, v.evidencia_id)
                   from cuidared.evidencia v where v.tarea_agenda_id = p_tarea_id), '[]'::jsonb);
end;
$$;

/*
 * Valida o rechaza una evidencia pendiente (evidencias:validar sobre el adulto de la tarea). Guarda quién y cuándo,
 * avisa a quien la registró y al cuidador de la tarea.
 *  · validada: si la tarea requiere evidencia y sigue abierta, queda completada (completada_por = quien valida).
 *  · rechazada (motivo de 5 a 200 caracteres): si la tarea requiere evidencia y estaba en progreso, vuelve a pendiente.
 * Devuelve {evidencia, tarea, tarea_completada}.
 */
create function cuidared_interno.evidencia_revisar(p_cuenta_id bigint, p_evidencia_id uuid, p_decision text, p_motivo text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_uid uuid; v_tarea_id uuid; v_t cuidared.tarea_agenda; v_ev cuidared.evidencia;
  v_motivo text := btrim(p_motivo);
  v_completada boolean := false; v_efecto text := '';
begin
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'evidencias:validar')->>'usuario_id')::uuid;
  if p_decision = 'rechazada' and (v_motivo is null or char_length(v_motivo) not between 5 and 200 or v_motivo ~ '[[:cntrl:]]') then
    raise invalid_parameter_value;
  end if;
  if p_decision = 'validada' and p_motivo is not null then raise invalid_parameter_value; end if;
  select v.tarea_agenda_id into v_tarea_id from cuidared.evidencia v where v.evidencia_id = p_evidencia_id;
  if not found then raise no_data_found; end if;
  v_t := cuidared_interno.tarea_cargar(p_cuenta_id, v_tarea_id);   -- orden de bloqueo: tarea y luego evidencia
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_t.envejeciente_id, v_uid) then raise insufficient_privilege; end if;
  select * into v_ev from cuidared.evidencia where evidencia_id = p_evidencia_id for update;
  if v_ev.es_historica or v_ev.estado_validacion::text <> 'pendiente' or v_t.estado::text = 'cancelada' then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;

  if p_decision = 'validada' then
    update cuidared.evidencia set estado_validacion = 'validada', validada_por = v_uid, fecha_validacion = now()
    where evidencia_id = p_evidencia_id;
    if v_t.requiere_evidencia and v_t.estado::text in ('pendiente', 'en_progreso') then
      update cuidared.tarea_agenda set estado = 'completada', completada_por = v_uid, fecha_completada = now(),
        actualizado_por = v_uid, fecha_actualizacion = now()
      where tarea_agenda_id = v_t.tarea_agenda_id;
      v_completada := true;
      v_efecto := ' La tarea quedó completada.';
    end if;
  else
    update cuidared.evidencia set estado_validacion = 'rechazada', validada_por = v_uid, fecha_validacion = now(),
      motivo_rechazo = v_motivo
    where evidencia_id = p_evidencia_id;
    if v_t.requiere_evidencia and v_t.estado::text = 'en_progreso' then
      update cuidared.tarea_agenda set estado = 'pendiente', actualizado_por = v_uid, fecha_actualizacion = now()
      where tarea_agenda_id = v_t.tarea_agenda_id;
      v_efecto := ' La tarea volvió a pendiente.';
    end if;
  end if;

  perform cuidared_interno.agenda_notificar(d, p_cuenta_id,
    case p_decision
      when 'validada' then format('Tu evidencia de la tarea «%s» fue validada.%s', v_t.titulo, v_efecto)
      else format('Tu evidencia de la tarea «%s» fue rechazada: %s.%s Adjunta una nueva.', v_t.titulo, v_motivo, v_efecto) end)
  from (select distinct u from unnest(array[v_ev.registrada_por, cuidared_interno.tarea_usuario_cuidador(v_t.cuidador_id)]) u
        where u is not null and u <> v_uid) q(d);

  return jsonb_build_object('evidencia', cuidared_interno.evidencia_json(p_evidencia_id),
                            'tarea', cuidared_interno.tarea_json(v_t.tarea_agenda_id), 'tarea_completada', v_completada);
end $$;

create function cuidared_api.api_evidencia_validar(p_cuenta_id bigint, p_evidencia_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  return cuidared_interno.evidencia_revisar(p_cuenta_id, p_evidencia_id, 'validada', null);
end;
$$;

create function cuidared_api.api_evidencia_rechazar(p_cuenta_id bigint, p_evidencia_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  return cuidared_interno.evidencia_revisar(p_cuenta_id, p_evidencia_id, 'rechazada', p_motivo);
end;
$$;

/* ───────────── 8. Storage: bucket privado y políticas de storage.objects ───────────── */

-- Bucket privado de 5 MB con los cuatro tipos permitidos. Equivale a crearlo en el panel de Supabase
-- (Storage → New bucket → Private, límite 5 MB, tipos MIME permitidos).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidencias', 'evidencias', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

/*
 * Esquema mínimo para las políticas: `authenticated` evalúa la política con su propio rol, así que necesita USAGE y
 * EXECUTE sobre la función. Se aísla en cuidared_storage para no abrir cuidared_interno a ese rol. PostgREST solo
 * publica cuidared_api: nada de esto es invocable desde la Data API con otras funciones.
 * Ruta autorizada: cuenta/<cuenta_id>/tarea/<tarea_id>/<uuid>.<ext>, con la tarea realmente de esa cuenta.
 *  · 'subir': cuidador asignado con agenda:ejecutar y alcance, tarea abierta, cuenta con acceso operativo.
 *  · 'ver'  : quien ve la tarea (agenda:ver con alcance; el Cuidador solo la suya), cuenta con acceso operativo.
 */
create schema if not exists cuidared_storage;
revoke all on schema cuidared_storage from public, anon;
grant usage on schema cuidared_storage to authenticated;

create function cuidared_storage.evidencia_permitida(p_nombre text, p_modo text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_m text[];
  v_cuenta bigint; v_tarea uuid; v_t record;
begin
  if v_uid is null or p_nombre is null or p_modo is null or p_modo not in ('subir', 'ver') then return false; end if;
  v_m := regexp_match(p_nombre, '^cuenta/([1-9][0-9]{0,18})/tarea/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$');
  if v_m is null then return false; end if;
  v_cuenta := v_m[1]::bigint;
  v_tarea := v_m[2]::uuid;
  -- Misma sesión vigente (12 h / 30 min) que exige la API.
  if not coalesce((cuidared_api.api_sesion('validar')->>'vigente')::boolean, false) then return false; end if;
  if not cuidared_interno.acceso_operativo(v_cuenta) then return false; end if;
  select t.estado, t.envejeciente_id into v_t from cuidared.tarea_agenda t
  join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
  where t.tarea_agenda_id = v_tarea and e.cuenta_id = v_cuenta and not t.es_historica;
  if not found then return false; end if;
  if p_modo = 'subir' then
    return v_t.estado::text in ('pendiente', 'en_progreso')
      and cuidared_interno.agenda_tiene_permiso(v_cuenta, v_uid, 'agenda:ejecutar')
      and cuidared_interno.tarea_es_del_cuidador(v_cuenta, v_tarea, v_uid)
      and cuidared_interno.alcanza_envejeciente(v_cuenta, v_t.envejeciente_id, v_uid);
  end if;
  return cuidared_interno.tarea_puede_ver(v_cuenta, v_tarea, v_uid)
    and exists (select 1 from cuidared.evidencia v
      where v.tarea_agenda_id = v_tarea and v.archivo_url = p_nombre and not v.es_historica);
end;
$$;

-- Sin políticas de update/delete: nadie sobrescribe ni borra evidencias desde el cliente (retención sin definir, D13).
create policy cuidared_evidencias_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'evidencias' and cuidared_storage.evidencia_permitida(name, 'subir'));
create policy cuidared_evidencias_ver on storage.objects for select to authenticated
  using (bucket_id = 'evidencias' and cuidared_storage.evidencia_permitida(name, 'ver'));

/* ───────────── 9. Privilegios ───────────── */

-- Toda función nueva nace con EXECUTE para PUBLIC: se retira de las internas y de la API antes de conceder.
revoke all on all functions in schema cuidared_interno from public, anon, authenticated;
revoke all on all functions in schema cuidared_storage from public, anon;
revoke all on function
  cuidared_api.api_tareas_listar(bigint, jsonb, jsonb, integer, integer),
  cuidared_api.api_tarea_obtener(bigint, uuid),
  cuidared_api.api_tarea_crear(bigint, jsonb),
  cuidared_api.api_tarea_actualizar(bigint, uuid, jsonb),
  cuidared_api.api_tarea_cancelar(bigint, uuid, text, text),
  cuidared_api.api_tarea_iniciar(bigint, uuid),
  cuidared_api.api_tarea_completar(bigint, uuid),
  cuidared_api.api_evidencia_preparar_subida(bigint, uuid, jsonb),
  cuidared_api.api_evidencia_registrar(bigint, uuid, jsonb),
  cuidared_api.api_evidencias_listar(bigint, uuid),
  cuidared_api.api_evidencia_validar(bigint, uuid),
  cuidared_api.api_evidencia_rechazar(bigint, uuid, text)
  from public, anon;
grant execute on function
  cuidared_api.api_tareas_listar(bigint, jsonb, jsonb, integer, integer),
  cuidared_api.api_tarea_obtener(bigint, uuid),
  cuidared_api.api_tarea_crear(bigint, jsonb),
  cuidared_api.api_tarea_actualizar(bigint, uuid, jsonb),
  cuidared_api.api_tarea_cancelar(bigint, uuid, text, text),
  cuidared_api.api_tarea_iniciar(bigint, uuid),
  cuidared_api.api_tarea_completar(bigint, uuid),
  cuidared_api.api_evidencia_preparar_subida(bigint, uuid, jsonb),
  cuidared_api.api_evidencia_registrar(bigint, uuid, jsonb),
  cuidared_api.api_evidencias_listar(bigint, uuid),
  cuidared_api.api_evidencia_validar(bigint, uuid),
  cuidared_api.api_evidencia_rechazar(bigint, uuid, text)
  to authenticated;
grant execute on function cuidared_storage.evidencia_permitida(text, text) to authenticated;

commit;
