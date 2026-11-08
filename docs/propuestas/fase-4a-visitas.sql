-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 4 · Visitas y Seguimiento, bloque 4a (ID04) — programación con autorización, inicio, registro de realización,
-- cancelación, historial y solicitudes de visita de personas externas. RF-02, RF-10 (base), Reglas de Negocio V2.
-- Depende de docs/propuestas/fase-2a-base.sql (cuidared_interno.exigir / exigir_envejeciente / alcanza_envejeciente /
-- membresia_activa / permisos / acceso_operativo / hoy y la matriz de permisos) y de fase-3b-seguimiento.sql (vínculos con
-- permiso explícito y revocación: cuidared_interno.seg_vincular y alcanza_envejeciente, que exige fecha_revocacion is null);
-- las pruebas de adultos usan además las columnas de consentimiento de fase-3a. Validada en un PostgreSQL local con
-- `node scripts/validar-propuestas-local.js --solo=3a,3b,4a` (esquema auth simulado; no certifica RLS ni Auth de Supabase).
-- © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (registro y razones en docs/contratos/visitas.md):
--   · Autorizan las visitas el Coordinador en Familia y el Administrador o Coordinador en Organización (D05, confirmado):
--     programar equivale a autorizar y exige visitas:programar + visitas:autorizar.
--   · Solo una visita completada (realizada) cuenta como contacto efectivo; programada o cancelada no lo cuenta.
--   · El Voluntario inicia sesión y registra únicamente que la visita ocurrió más una observación (registro mínimo).
--   · Propuesta técnica (D05): una visita pertenece a una sola cuenta; la solicitud de personas externas la autoriza un
--     usuario principal; cancelar o revocar una autorización = cancelar la visita (programada o en curso).
--   · Propuesta técnica (D10): programada → en_curso → completada; programada | en_curso → cancelada; completada y
--     cancelada son terminales (no se reabren). Solicitud: pendiente → autorizada | rechazada; autorizada → realizada |
--     cancelada.
--   · Propuesta técnica (D14): el catálogo de aspectos del checklist es el del frontend (ASPECTOS_VISITA).
--   · Privacidad: la cédula y el teléfono del visitante viven solo en cuidared.solicitud_visita (RLS, sin acceso directo) y
--     solo los ven quienes autorizan; nunca se copian a visita.notas ni a ninguna otra tabla.
--
-- Las solicitudes externas quedan aisladas. No se conceden privilegios para las RPC públicas.
begin;


/* ───────────── 1. Solicitudes de visita de personas externas ───────────── */

-- V2: el visitante no es un rol ni tiene cuenta; pide la visita y un usuario principal la autoriza. El código de seguimiento
-- lo genera Express; aquí solo se guarda su huella HMAC-SHA256 (nunca el código). Sin acceso directo: solo a través de las RPC.
create table cuidared.solicitud_visita (
  solicitud_visita_id uuid not null default gen_random_uuid(),
  cuenta_id bigint not null,
  visitante_nombres character varying not null check (length(btrim(visitante_nombres)) between 2 and 60),
  visitante_apellidos character varying not null check (length(btrim(visitante_apellidos)) between 2 and 60),
  visitante_cedula character varying not null check (visitante_cedula ~ '^[0-9]{11}$'),
  visitante_telefono character varying not null check (visitante_telefono ~ '^\+?[0-9]{10,15}$'),
  visitante_correo character varying check (visitante_correo is null
    or (length(visitante_correo) <= 254 and visitante_correo ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  persona_a_visitar character varying not null check (length(btrim(persona_a_visitar)) between 3 and 120),
  fecha_propuesta date not null,
  hora_propuesta time without time zone not null,
  motivo character varying not null check (length(btrim(motivo)) between 3 and 300),
  estado character varying not null default 'pendiente'
    check (estado::text in ('pendiente', 'autorizada', 'rechazada', 'realizada', 'cancelada')),
  codigo_hash character varying not null check (codigo_hash ~ '^[0-9a-f]{64}$'),
  fecha_creacion timestamp with time zone not null default now(),
  revisada_por uuid,
  revisada_en timestamp with time zone,
  motivo_rechazo text check (motivo_rechazo is null or length(btrim(motivo_rechazo)) between 3 and 300),
  envejeciente_id uuid,
  visita_id uuid,
  observacion_visitante text check (observacion_visitante is null or length(btrim(observacion_visitante)) between 3 and 600),
  observacion_en timestamp with time zone,
  constraint solicitud_visita_pkey primary key (solicitud_visita_id),
  constraint uq_solicitud_visita_codigo unique (codigo_hash),
  constraint uq_solicitud_visita_visita unique (visita_id),
  constraint fk_solicitud_visita_cuenta foreign key (cuenta_id) references cuidared.cuenta(cuenta_id),
  constraint fk_solicitud_visita_revisor foreign key (revisada_por) references cuidared.usuario(usuario_id),
  constraint fk_solicitud_visita_envejeciente foreign key (envejeciente_id) references cuidared.envejeciente(envejeciente_id),
  constraint fk_solicitud_visita_visita foreign key (visita_id) references cuidared.visita(visita_id),
  -- Coherencia de la revisión con el estado (D10): pendiente sin revisar; rechazada con motivo y sin visita; el resto, con
  -- revisor, adulto confirmado y visita creada.
  constraint ck_solicitud_visita_revision check (case estado::text
    when 'pendiente' then revisada_por is null and visita_id is null and envejeciente_id is null and motivo_rechazo is null
    when 'rechazada' then revisada_por is not null and motivo_rechazo is not null and visita_id is null
    else revisada_por is not null and visita_id is not null and envejeciente_id is not null end)
);
create index ix_solicitud_visita_cuenta on cuidared.solicitud_visita (cuenta_id, estado, fecha_creacion desc);
create index ix_solicitud_visita_creacion on cuidared.solicitud_visita (cuenta_id, fecha_creacion desc);
create index ix_solicitud_visita_pendiente on cuidared.solicitud_visita (cuenta_id, visitante_cedula) where estado::text = 'pendiente';

/* ───────────── 2. Visitas: cuenta, programación, cancelación, checklist y origen ───────────── */

-- Catálogo de aspectos del checklist (propuesta, D14: el del frontend). Una sola fuente para la tabla y las RPC.
create function cuidared_interno.aspectos_visita() returns text[]
language sql immutable set search_path = '' as $$
  select array['alimentacion', 'medicamentos', 'higiene', 'vivienda', 'animo', 'movilidad']::text[]
$$;

alter table cuidared.visita
  add column cuenta_id bigint,
  add column hora_programada time without time zone,
  add column creada_por uuid,
  add column motivo_cancelacion text check (motivo_cancelacion is null or length(btrim(motivo_cancelacion)) between 3 and 300),
  add column cancelada_por uuid,
  add column fecha_cancelacion timestamp with time zone,
  add column checklist text[] not null default '{}'::text[],
  add column notas text check (notas is null or length(notas) <= 300),
  add column origen character varying not null default 'interna'
    check (origen::text in ('interna', 'solicitud')),
  add column solicitud_visita_id uuid;

alter table cuidared.visita
  add constraint fk_visita_cuenta foreign key (cuenta_id) references cuidared.cuenta(cuenta_id),
  add constraint fk_visita_creada_por foreign key (creada_por) references cuidared.usuario(usuario_id),
  add constraint fk_visita_cancelada_por foreign key (cancelada_por) references cuidared.usuario(usuario_id),
  add constraint fk_visita_solicitud foreign key (solicitud_visita_id) references cuidared.solicitud_visita(solicitud_visita_id),
  add constraint ck_visita_checklist check (checklist <@ cuidared_interno.aspectos_visita()),
  add constraint ck_visita_origen_solicitud check ((origen::text = 'solicitud') = (solicitud_visita_id is not null));
create unique index uq_visita_solicitud on cuidared.visita (solicitud_visita_id) where solicitud_visita_id is not null;
create index ix_visita_cuenta_fecha on cuidared.visita (cuenta_id, fecha desc);

-- Relleno de las filas existentes (si las hay): visitas cuyos adultos pertenecen todos a la misma cuenta.
update cuidared.visita v set cuenta_id = x.cuenta_id
from (
  select d.visita_id, min(e.cuenta_id) as cuenta_id
  from cuidared.detalle_visita d join cuidared.envejeciente e on e.envejeciente_id = d.envejeciente_id
  group by d.visita_id having count(distinct e.cuenta_id) = 1
) x
where v.visita_id = x.visita_id and v.cuenta_id is null;

-- Obligatorias para las filas nuevas; las existentes sin cuenta (ambiguas) no se validan. Se validan solas si no quedan.
alter table cuidared.visita
  add constraint ck_visita_cuenta check (cuenta_id is not null) not valid,
  add constraint ck_visita_cancelacion check (estado::text <> 'cancelada' or (motivo_cancelacion is not null and cancelada_por is not null)) not valid,
  add constraint ck_visita_horas check (hora_inicio is null or hora_fin is null or hora_fin >= hora_inicio) not valid;
do $$ begin
  if not exists (select 1 from cuidared.visita where cuenta_id is null) then
    alter table cuidared.visita validate constraint ck_visita_cuenta;
  end if;
end $$;

-- La cuenta de una visita no cambia una vez asignada.
create function cuidared_interno.trg_visita_cuenta_inmutable() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.cuenta_id is not null and new.cuenta_id is distinct from old.cuenta_id then
    raise exception 'La cuenta de la visita no puede cambiar' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger trg_visita_cuenta_inmutable before update of cuenta_id on cuidared.visita
  for each row execute function cuidared_interno.trg_visita_cuenta_inmutable();

-- La solicitud de origen sigue a su visita, venga el cambio de donde venga (cancelar, registrar o la baja de un adulto, 3a):
-- visita cancelada → solicitud cancelada; visita completada → solicitud realizada. Solo desde «autorizada».
create function cuidared_interno.trg_visita_sincroniza_solicitud() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.solicitud_visita_id is not null and new.estado::text in ('cancelada', 'completada') then
    update cuidared.solicitud_visita
      set estado = case new.estado::text when 'cancelada' then 'cancelada' else 'realizada' end
      where solicitud_visita_id = new.solicitud_visita_id and estado::text = 'autorizada';
  end if;
  return new;
end $$;
create trigger trg_visita_sincroniza_solicitud after update of estado on cuidared.visita
  for each row when (old.estado is distinct from new.estado)
  execute function cuidared_interno.trg_visita_sincroniza_solicitud();

alter table cuidared.detalle_visita
  add column registrado_por uuid,
  add column fecha_registro timestamp with time zone;
alter table cuidared.detalle_visita
  add constraint fk_detalle_visita_registrado_por foreign key (registrado_por) references cuidared.usuario(usuario_id);
create index ix_detalle_visita_envejeciente on cuidared.detalle_visita (envejeciente_id);
create index ix_registro_visita_usuario on cuidared.registro_visita (usuario_id);

-- Aislamiento: el adulto de un detalle pertenece a la misma cuenta que la visita.
create function cuidared_interno.trg_detalle_visita_misma_cuenta() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (
    select 1 from cuidared.visita v join cuidared.envejeciente e on e.envejeciente_id = new.envejeciente_id
    where v.visita_id = new.visita_id and v.cuenta_id is not null and v.cuenta_id <> e.cuenta_id) then
    raise exception 'El adulto no pertenece a la cuenta de la visita' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger trg_detalle_visita_misma_cuenta before insert or update of visita_id, envejeciente_id on cuidared.detalle_visita
  for each row execute function cuidared_interno.trg_detalle_visita_misma_cuenta();

-- Sin acceso directo a las tablas de visitas: solo a través de las RPC.
alter table cuidared.solicitud_visita enable row level security;
alter table cuidared.visita enable row level security;
alter table cuidared.registro_visita enable row level security;
alter table cuidared.detalle_visita enable row level security;
revoke all on cuidared.solicitud_visita, cuidared.visita, cuidared.registro_visita, cuidared.detalle_visita
  from public, anon, authenticated;

/* ───────────── 3. Validadores de entrada (jsonb → tipo) y utilidades internas ───────────── */

-- Toda entrada incorrecta termina en 22023 (422 en la API): nunca un error de conversión sin clasificar.
create function cuidared_interno.v_texto(p_valor jsonb, p_min integer, p_max integer, p_requerido boolean default true)
returns text language plpgsql immutable set search_path = '' as $$
declare v_texto text;
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    if p_requerido then raise invalid_parameter_value; end if;
    return null;
  end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := btrim(p_valor #>> '{}');
  if v_texto = '' and not p_requerido then return null; end if;
  if length(v_texto) < p_min or length(v_texto) > p_max
     or v_texto ~ '[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]' then
    raise invalid_parameter_value;
  end if;
  return v_texto;
end $$;

create function cuidared_interno.v_fecha(p_valor jsonb, p_requerido boolean default true)
returns date language plpgsql immutable set search_path = '' as $$
declare v_texto text;
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    if p_requerido then raise invalid_parameter_value; end if;
    return null;
  end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := p_valor #>> '{}';
  if v_texto !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise invalid_parameter_value; end if;
  begin
    return v_texto::date;
  exception when datetime_field_overflow or invalid_datetime_format then
    raise invalid_parameter_value;
  end;
end $$;

create function cuidared_interno.v_hora(p_valor jsonb, p_requerido boolean default true)
returns time language plpgsql immutable set search_path = '' as $$
declare v_texto text;
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    if p_requerido then raise invalid_parameter_value; end if;
    return null;
  end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := p_valor #>> '{}';
  if v_texto !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise invalid_parameter_value; end if;
  return v_texto::time;
end $$;

create function cuidared_interno.v_uuid(p_valor jsonb, p_requerido boolean default true)
returns uuid language plpgsql immutable set search_path = '' as $$
declare v_texto text;
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    if p_requerido then raise invalid_parameter_value; end if;
    return null;
  end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := p_valor #>> '{}';
  if v_texto !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise invalid_parameter_value; end if;
  return v_texto::uuid;
end $$;

-- Arreglo de uuid sin repetidos y con cantidad acotada.
create function cuidared_interno.v_uuids(p_valor jsonb, p_min integer, p_max integer)
returns uuid[] language plpgsql immutable set search_path = '' as $$
declare v_elem jsonb; v_ids uuid[] := '{}'; v_id uuid;
begin
  if jsonb_typeof(p_valor) is distinct from 'array'
     or jsonb_array_length(p_valor) < p_min or jsonb_array_length(p_valor) > p_max then
    raise invalid_parameter_value;
  end if;
  for v_elem in select e.value from jsonb_array_elements(p_valor) as e loop
    v_id := cuidared_interno.v_uuid(v_elem);
    if v_id = any (v_ids) then raise invalid_parameter_value; end if;
    v_ids := array_append(v_ids, v_id);
  end loop;
  return v_ids;
end $$;

create function cuidared_interno.hora_local() returns time
language sql stable set search_path = '' as $$
  select date_trunc('minute', pg_catalog.now() at time zone 'America/Santo_Domingo')::time
$$;

create function cuidared_interno.hhmm(p_hora time) returns text
language sql immutable set search_path = '' as $$
  select left(p_hora::text, 5)
$$;

create function cuidared_interno.tiene_permiso(p_cuenta_id bigint, p_usuario_id uuid, p_accion text) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m
    where p_accion = any (cuidared_interno.permisos(m.rol_id, m.tipo_cuenta_id)))
$$;

-- Administrador y Coordinador: los usuarios principales de la cuenta (autorizan y gestionan).
create function cuidared_interno.es_gestor(p_cuenta_id bigint, p_usuario_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m
                 where m.rol in ('administrador', 'coordinador'))
$$;

create function cuidared_interno.gestores_cuenta(p_cuenta_id bigint) returns setof uuid
language sql stable set search_path = '' as $$
  select m.usuario_id
  from cuidared.membresia m
  join cuidared.rol r on r.rol_id = m.rol_id and r.activo
  join cuidared.usuario u on u.usuario_id = m.usuario_id and u.estado::text = 'activo'
  where m.cuenta_id = p_cuenta_id and m.estado::text = 'activa' and r.codigo::text in ('administrador', 'coordinador')
    and m.fecha_inicio <= cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
$$;

-- Los gestores ven las visitas de su cuenta. Los demás roles requieren alcance vigente sobre algún adulto.
create function cuidared_interno.visita_visible(p_cuenta_id bigint, p_visita_id uuid, p_usuario_id uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1
    from cuidared.visita v
    join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where v.visita_id = p_visita_id and v.cuenta_id = p_cuenta_id
      and (m.rol in ('administrador', 'coordinador')
        or exists (select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id
                   and cuidared_interno.alcanza_envejeciente(p_cuenta_id, d.envejeciente_id, p_usuario_id))))
$$;

/*
 * Quien inicia o registra tiene visitas:registrar, fue autorizado como participante y alcanza a todos los adultos.
 * Orden de errores: 42501 sin
 * membresía/permiso; P0002 si no la ve (otra cuenta, inexistente o fuera de su alcance); CR_NO_PARTICIPA si la ve pero no
 * participa; CR_CUENTA_SIN_ACCESO si la cuenta no tiene prueba/plan vigente.
 */
create function cuidared_interno.exigir_operar_visita(p_cuenta_id bigint, p_visita_id uuid, p_usuario_id uuid) returns void
language plpgsql stable set search_path = '' as $$
declare v_m record;
begin
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id);
  if not found or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise insufficient_privilege;
  end if;
  if not cuidared_interno.acceso_operativo(p_cuenta_id) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;
  if not cuidared_interno.visita_visible(p_cuenta_id, p_visita_id, p_usuario_id) then
    raise no_data_found;
  end if;
  if not exists (select 1 from cuidared.registro_visita r join cuidared.visita v using (visita_id)
                  where r.visita_id = p_visita_id and r.usuario_id = p_usuario_id
                    and r.autorizada_por_usuario_id is not null and v.hora_programada is not null) then
    raise exception 'CR_NO_PARTICIPA' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita_id)
     or exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita_id
                and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, d.envejeciente_id, p_usuario_id)) then
    raise insufficient_privilege;
  end if;
end $$;

/* ───────────── 4. Representación JSON de visitas y solicitudes ───────────── */

-- Visita tal como la ve el usuario: los adultos se filtran por su alcance (los gestores ven todos los de la cuenta). Con
-- p_detalle = false no se incluyen estado ni observación por adulto (listados). El visitante externo se identifica solo por
-- su nombre: la cédula y el teléfono no salen de solicitud_visita.
create function cuidared_interno.visita_json(p_visita_id uuid, p_usuario_id uuid, p_detalle boolean default true) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'visita_id', v.visita_id,
    'fecha', v.fecha,
    'hora_programada', cuidared_interno.hhmm(v.hora_programada),
    'hora_inicio', cuidared_interno.hhmm(v.hora_inicio),
    'hora_fin', cuidared_interno.hhmm(v.hora_fin),
    'razon', v.razon,
    'estado', v.estado,
    'origen', v.origen,
    'notas', v.notas,
    'checklist', to_jsonb(v.checklist),
    'motivo_cancelacion', v.motivo_cancelacion,
    'creada_por', v.creada_por,
    'autorizada_por', (
      select jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos)
      from cuidared.registro_visita r join cuidared.usuario u on u.usuario_id = r.autorizada_por_usuario_id
      where r.visita_id = v.visita_id order by r.usuario_id limit 1),
    'participantes', coalesce((
      select jsonb_agg(jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos)
                       order by u.apellidos, u.nombres, u.usuario_id)
      from cuidared.registro_visita r join cuidared.usuario u on u.usuario_id = r.usuario_id
      where r.visita_id = v.visita_id), '[]'::jsonb),
    'adultos', coalesce((
      select jsonb_agg(
        case when p_detalle then jsonb_build_object(
               'envejeciente_id', e.envejeciente_id, 'nombres', e.nombres, 'apellidos', e.apellidos,
               'estado_general', d.estado_general, 'observacion', d.observacion, 'fecha_registro', d.fecha_registro)
             else jsonb_build_object('envejeciente_id', e.envejeciente_id, 'nombres', e.nombres, 'apellidos', e.apellidos) end
        order by e.apellidos, e.nombres, e.envejeciente_id)
      from cuidared.detalle_visita d
      join cuidared.envejeciente e on e.envejeciente_id = d.envejeciente_id
      where d.visita_id = v.visita_id
        and (cuidared_interno.es_gestor(v.cuenta_id, p_usuario_id)
             or cuidared_interno.alcanza_envejeciente(v.cuenta_id, d.envejeciente_id, p_usuario_id))), '[]'::jsonb),
    'visitante', (select jsonb_build_object('nombre', s.visitante_nombres || ' ' || s.visitante_apellidos)
                  from cuidared.solicitud_visita s where s.solicitud_visita_id = v.solicitud_visita_id),
    'fecha_creacion', v.fecha_creacion,
    'fecha_actualizacion', v.fecha_actualizacion)
  from cuidared.visita v where v.visita_id = p_visita_id
$$;

-- Solicitud para quienes autorizan (incluye los datos del visitante: cédula y teléfono).
create function cuidared_interno.solicitud_json(p_solicitud_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'solicitud_visita_id', s.solicitud_visita_id,
    'estado', s.estado,
    'visitante', jsonb_build_object('nombres', s.visitante_nombres, 'apellidos', s.visitante_apellidos,
                                    'cedula', s.visitante_cedula, 'telefono', s.visitante_telefono,
                                    'correo', s.visitante_correo),
    'persona_a_visitar', s.persona_a_visitar,
    'fecha_propuesta', s.fecha_propuesta,
    'hora_propuesta', cuidared_interno.hhmm(s.hora_propuesta),
    'motivo', s.motivo,
    'fecha_creacion', s.fecha_creacion,
    'revisada_por', (select jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos)
                     from cuidared.usuario u where u.usuario_id = s.revisada_por),
    'revisada_en', s.revisada_en,
    'motivo_rechazo', s.motivo_rechazo,
    'envejeciente', (select jsonb_build_object('envejeciente_id', e.envejeciente_id, 'nombres', e.nombres, 'apellidos', e.apellidos)
                     from cuidared.envejeciente e where e.envejeciente_id = s.envejeciente_id),
    'visita_id', s.visita_id,
    'observacion_visitante', s.observacion_visitante,
    'observacion_en', s.observacion_en)
  from cuidared.solicitud_visita s where s.solicitud_visita_id = p_solicitud_id
$$;

/* ───────────── 5. Lógica interna reutilizable (también para la sincronización offline, bloque 4c) ───────────── */

-- Aviso a los gestores (excepto quien lo reportó) de una situación crítica. La alerta formal es de la fase 6.
create function cuidared_interno.notificar_situacion_critica(p_cuenta_id bigint, p_visita_id uuid, p_actor uuid) returns void
language plpgsql set search_path = '' as $$
declare v_mensaje text;
begin
  select format('Situación crítica reportada en la visita del %s: %s.', to_char(v.fecha, 'DD/MM/YYYY'),
                string_agg(e.nombres || ' ' || e.apellidos, ', ' order by e.apellidos, e.nombres))
  into v_mensaje
  from cuidared.visita v
  join cuidared.detalle_visita d on d.visita_id = v.visita_id and d.estado_general::text = 'situacion_critica'
  join cuidared.envejeciente e on e.envejeciente_id = d.envejeciente_id
  where v.visita_id = p_visita_id
  group by v.fecha;
  if v_mensaje is null then return; end if;
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
  select g, p_cuenta_id, v_mensaje from cuidared_interno.gestores_cuenta(p_cuenta_id) g where g <> p_actor;
end $$;

/*
 * Bloquea una visita con un orden de bloqueos único: primero su solicitud (si nació de una) y después la visita. Es el mismo
 * orden de api_publico_registrar_observacion y evita interbloqueos entre cancelar/registrar y la observación del visitante.
 * Devuelve la fila bloqueada, o una fila con todo nulo si no existe.
 */
create function cuidared_interno.bloquear_visita(p_visita_id uuid) returns cuidared.visita
language plpgsql set search_path = '' as $$
declare v_solicitud uuid; v_v cuidared.visita;
begin
  select v.solicitud_visita_id into v_solicitud from cuidared.visita v where v.visita_id = p_visita_id;
  if v_solicitud is not null then
    perform 1 from cuidared.solicitud_visita s where s.solicitud_visita_id = v_solicitud for update;
  end if;
  select * into v_v from cuidared.visita v where v.visita_id = p_visita_id for update;
  return v_v;
end $$;

/*
 * Pasa una visita programada a en curso. Idempotente: si ya está en curso devuelve ya_iniciada = true. Revalida membresía,
 * permiso, alcance y participación (el llamador ya autenticó la sesión). Devuelve {visita_id, estado, ya_iniciada}.
 */
create function cuidared_interno.iniciar_visita(p_cuenta_id bigint, p_usuario_id uuid, p_visita_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare v_v record;
begin
  select * into v_v from cuidared.visita where visita_id = p_visita_id and cuenta_id = p_cuenta_id for update;
  if not found then raise no_data_found; end if;
  perform cuidared_interno.exigir_operar_visita(p_cuenta_id, p_visita_id, p_usuario_id);
  if v_v.estado::text = 'en_curso' then
    return jsonb_build_object('visita_id', p_visita_id, 'estado', 'en_curso', 'ya_iniciada', true);
  end if;
  if v_v.estado::text <> 'programada' then
    raise exception 'CR_VISITA_CERRADA' using errcode = 'P0001';
  end if;
  if v_v.fecha > cuidared_interno.hoy() then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  update cuidared.visita
    set estado = 'en_curso', hora_inicio = coalesce(hora_inicio, cuidared_interno.hora_local()), fecha_actualizacion = now()
    where visita_id = p_visita_id;
  return jsonb_build_object('visita_id', p_visita_id, 'estado', 'en_curso', 'ya_iniciada', false);
end $$;

/*
 * Registra la realización de una visita. Punto único para la API en línea y para la sincronización offline (bloque 4c).
 *
 *   p_cuenta_id  cuenta de la visita.
 *   p_usuario_id quien registra. La sesión ya fue autenticada por el llamador (exigir o exigir de sync); aquí se
 *                revalidan membresía activa, visitas:registrar, acceso operativo, alcance y participación.
 *   p_visita_id  id de una visita existente, programada y autorizada para el actor.
 *   p_datos      {detalles:[{envejeciente_id, estado_general?, observacion}], checklist?, hora_inicio?, hora_fin?,
 *                 }. Los detalles deben
 *                cubrir todos los adultos de la visita (1 a 4); estado_general es obligatorio salvo para el Voluntario
 *                (registro mínimo) y la observación siempre (3 a 1000 caracteres).
 *
 * Idempotente respecto de p_visita_id: si la visita ya está completada devuelve ya_registrada = true sin modificarla. Una
 * visita cancelada → CR_VISITA_CERRADA. Inexistente o de otra cuenta → P0002.
 * Devuelve {visita_id, ya_registrada, estado}. Si algún adulto queda en situación crítica notifica a los gestores
 * (solo la primera vez, no en las repeticiones).
 */
create function cuidared_interno.registrar_visita_realizada(p_cuenta_id bigint, p_usuario_id uuid, p_visita_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_m record;
  v_v cuidared.visita;
  v_id uuid;
  v_hoy date := cuidared_interno.hoy();
  v_ahora time := cuidared_interno.hora_local();
  v_fecha date;
  v_ini time;
  v_fin time;
  v_ini_p time;
  v_fin_p time;
  v_checklist text[] := '{}'::text[];
  v_item jsonb;
  v_det jsonb;
  v_detalles jsonb := '[]'::jsonb;
  v_ids uuid[] := '{}';
  v_env uuid;
  v_eg text;
  v_obs text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_usuario_id is null or p_visita_id is null
     or jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['hora_inicio', 'hora_fin', 'checklist', 'detalles'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id);
  if not found or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise insufficient_privilege;
  end if;
  if not cuidared_interno.acceso_operativo(p_cuenta_id) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;

  -- Entrada (se valida completa antes de tocar datos).
  if jsonb_typeof(p_datos->'detalles') is distinct from 'array'
     or jsonb_array_length(p_datos->'detalles') not between 1 and 4 then
    raise invalid_parameter_value;
  end if;
  for v_det in select e.value from jsonb_array_elements(p_datos->'detalles') as e loop
    if jsonb_typeof(v_det) is distinct from 'object'
       or v_det - array['envejeciente_id', 'estado_general', 'observacion'] <> '{}'::jsonb then
      raise invalid_parameter_value;
    end if;
    v_env := cuidared_interno.v_uuid(v_det->'envejeciente_id');
    if v_env = any (v_ids) then raise invalid_parameter_value; end if;
    v_ids := array_append(v_ids, v_env);
    v_eg := cuidared_interno.v_texto(v_det->'estado_general', 1, 30, false);
    if v_eg is null then
      -- Registro mínimo: solo el Voluntario puede omitir el estado general.
      if v_m.rol <> 'voluntario' then raise invalid_parameter_value; end if;
    elsif v_eg not in ('estable', 'requiere_atencion', 'situacion_critica') then
      raise invalid_parameter_value;
    end if;
    v_obs := cuidared_interno.v_texto(v_det->'observacion', 3, 1000);
    v_detalles := v_detalles || jsonb_build_array(
      jsonb_build_object('envejeciente_id', v_env, 'estado_general', v_eg, 'observacion', v_obs));
  end loop;
  if p_datos ? 'checklist' and jsonb_typeof(p_datos->'checklist') <> 'null' then
    if jsonb_typeof(p_datos->'checklist') <> 'array' or jsonb_array_length(p_datos->'checklist') > 6 then
      raise invalid_parameter_value;
    end if;
    for v_item in select e.value from jsonb_array_elements(p_datos->'checklist') as e loop
      if jsonb_typeof(v_item) <> 'string' or not ((v_item #>> '{}') = any (cuidared_interno.aspectos_visita()))
         or (v_item #>> '{}') = any (v_checklist) then
        raise invalid_parameter_value;
      end if;
      v_checklist := array_append(v_checklist, v_item #>> '{}');
    end loop;
  end if;
  v_ini_p := cuidared_interno.v_hora(p_datos->'hora_inicio', false);
  v_fin_p := cuidared_interno.v_hora(p_datos->'hora_fin', false);

  v_id := p_visita_id;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id::text, 0));
  v_v := cuidared_interno.bloquear_visita(v_id);
  if v_v.visita_id is null or v_v.cuenta_id is distinct from p_cuenta_id then
    raise no_data_found;
  end if;

  perform cuidared_interno.exigir_operar_visita(p_cuenta_id, v_id, p_usuario_id);
    if v_v.estado::text = 'completada' then
      return jsonb_build_object('visita_id', v_id, 'creada', false, 'ya_registrada', true, 'estado', 'completada');
    end if;
    if v_v.estado::text = 'cancelada' then
      raise exception 'CR_VISITA_CERRADA' using errcode = 'P0001';
    end if;
    if v_v.fecha > v_hoy then
      raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
    end if;
    -- Los detalles cubren exactamente los adultos de la visita y el usuario alcanza a cada uno.
    if (select array_agg(d.envejeciente_id order by d.envejeciente_id) from cuidared.detalle_visita d where d.visita_id = v_id)
       is distinct from (select array_agg(x order by x) from unnest(v_ids) as x) then
      raise invalid_parameter_value;
    end if;
  v_fecha := v_v.fecha;

  -- Horas: las indicadas; si faltan, el inicio registrado (o programado) y, si la visita es de hoy, la hora actual.
  v_fin := coalesce(v_fin_p, case when v_fecha = v_hoy then v_ahora end);
  v_ini := coalesce(v_ini_p, v_v.hora_inicio);
  if v_ini is null and v_v.hora_programada is not null
     and (v_fin is null or v_v.hora_programada <= v_fin) then
    v_ini := v_v.hora_programada;
  end if;
  v_ini := coalesce(v_ini, v_fin);
  if v_ini is not null and v_fin is not null and v_fin < v_ini then
    raise invalid_parameter_value;
  end if;

    update cuidared.visita
      set estado = 'completada', hora_inicio = v_ini, hora_fin = v_fin, checklist = v_checklist, fecha_actualizacion = now()
      where visita_id = v_id;
    update cuidared.detalle_visita d
      set estado_general = x.estado_general, observacion = x.observacion, registrado_por = p_usuario_id, fecha_registro = now()
      from jsonb_to_recordset(v_detalles) as x(envejeciente_id uuid, estado_general text, observacion text)
      where d.visita_id = v_id and d.envejeciente_id = x.envejeciente_id;

  if exists (select 1 from jsonb_to_recordset(v_detalles) as x(envejeciente_id uuid, estado_general text, observacion text)
             where x.estado_general = 'situacion_critica') then
    perform cuidared_interno.notificar_situacion_critica(p_cuenta_id, v_id, p_usuario_id);
  end if;
  return jsonb_build_object('visita_id', v_id, 'ya_registrada', false, 'estado', 'completada');
end $$;

/* ───────────── 6. RPC de cuenta (cuidared_api) ───────────── */

-- Historial de la cuenta con el alcance del usuario. Filtros: estado, envejeciente_id, desde, hasta. Orden: lista cerrada.
create function cuidared_api.api_listar_visitas(
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
      where v.cuenta_id = $1
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

-- Detalle de una visita con los adultos y observaciones filtrados por el alcance del usuario.
create function cuidared_api.api_obtener_visita(p_cuenta_id bigint, p_visita_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_visita_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:ver');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  if not cuidared_interno.visita_visible(p_cuenta_id, p_visita_id, v_uid) then raise no_data_found; end if;
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $$;

/*
 * Programa (y autoriza) una visita: solo un usuario principal (visitas:programar + visitas:autorizar). Cuerpo:
 * {fecha, hora_programada, razon, notas?, envejeciente_ids: [1..4 adultos activos de la cuenta], participante_ids: [1..3]}.
 * Participantes: miembros activos con rol cuidador, voluntario o coordinador. Si a un cuidador o voluntario le falta el
 * vínculo vigente con el adulto se crea o renueva con cuidared_interno.seg_vincular (exige adultos:asignar). Estado programada; registro_visita.autorizada_por = quien programa.
 */
create function cuidared_api.api_programar_visita(p_cuenta_id bigint, p_datos jsonb) returns jsonb
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
        -- Sin vínculo vigente (no existe o fue revocado) se crea o renueva: 3b registra a quien programa como autorizador y
        -- limpia la revocación (RF-12/RF-13). Para estos roles, alcanza_envejeciente equivale a «vínculo vigente del tipo».
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

-- Inicia una visita programada (participante o gestor con visitas:registrar).
create function cuidared_api.api_iniciar_visita(p_cuenta_id bigint, p_visita_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_visita_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:registrar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  perform cuidared_interno.iniciar_visita(p_cuenta_id, v_uid, p_visita_id);
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $$;

-- Registra la realización de una visita existente (programada o en curso) y la pasa a completada.
create function cuidared_api.api_registrar_visita(p_cuenta_id bigint, p_visita_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid; v_v record; v_res jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_visita_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:registrar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  select * into v_v from cuidared.visita where visita_id = p_visita_id and cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  perform cuidared_interno.exigir_operar_visita(p_cuenta_id, p_visita_id, v_uid);
  -- En línea, repetir el registro de una visita cerrada es un error; la repetición idempotente es del flujo offline (4c).
  if v_v.estado::text in ('completada', 'cancelada') then
    raise exception 'CR_VISITA_CERRADA' using errcode = 'P0001';
  end if;
  v_res := cuidared_interno.registrar_visita_realizada(p_cuenta_id, v_uid, p_visita_id, p_datos - 'visita_id');
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $$;

-- Cancela una visita programada o en curso (visitas:programar). Si nació de una solicitud, esta pasa a cancelada (disparador).
create function cuidared_api.api_cancelar_visita(p_cuenta_id bigint, p_visita_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid; v_v cuidared.visita; v_motivo text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_visita_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  v_v := cuidared_interno.bloquear_visita(p_visita_id);
  if v_v.visita_id is null or v_v.cuenta_id is distinct from p_cuenta_id then raise no_data_found; end if;
  if v_v.estado::text not in ('programada', 'en_curso') then
    raise exception 'CR_VISITA_CERRADA' using errcode = 'P0001';
  end if;
  v_motivo := cuidared_interno.v_texto(to_jsonb(p_motivo), 3, 300);
  update cuidared.visita
    set estado = 'cancelada', motivo_cancelacion = v_motivo, cancelada_por = v_uid, fecha_cancelacion = now(),
        fecha_actualizacion = now()
    where visita_id = p_visita_id;
  -- Si nació de una solicitud externa, el disparador trg_visita_sincroniza_solicitud la pasa a cancelada.
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $$;

/* ───────────── 7. RPC de gestión de solicitudes (cuidared_api) ───────────── */

-- Solicitudes de la cuenta para quienes autorizan (con los datos del visitante). Las pendientes primero.
create function cuidared_api.api_listar_solicitudes_visita(
  p_cuenta_id bigint,
  p_filtros jsonb default '{}'::jsonb,
  p_orden jsonb default '[]'::jsonb,
  p_limite integer default 20,
  p_desplazamiento integer default 0
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_estado text;
  v_orden text := '';
  v_usados text[] := '{}';
  v_elem jsonb;
  v_campo text;
  v_dir text;
  v_res jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  perform cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar');
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(p_filtros) is distinct from 'object' or p_filtros - array['estado'] <> '{}'::jsonb
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) > 4 then
    raise invalid_parameter_value;
  end if;
  v_estado := cuidared_interno.v_texto(p_filtros->'estado', 1, 20, false);
  if v_estado is not null and v_estado not in ('pendiente', 'autorizada', 'rechazada', 'realizada', 'cancelada') then
    raise invalid_parameter_value;
  end if;
  for v_elem in select e.value from jsonb_array_elements(p_orden) as e loop
    if jsonb_typeof(v_elem) is distinct from 'object' or v_elem - array['campo', 'direccion'] <> '{}'::jsonb
       or jsonb_typeof(v_elem->'campo') is distinct from 'string' or jsonb_typeof(v_elem->'direccion') is distinct from 'string' then
      raise invalid_parameter_value;
    end if;
    v_campo := v_elem->>'campo';
    v_dir := v_elem->>'direccion';
    if not (v_campo = any (array['fecha_creacion', 'fecha_propuesta', 'solicitud_visita_id']))
       or v_dir not in ('asc', 'desc') or v_campo = any (v_usados) then
      raise invalid_parameter_value;
    end if;
    v_usados := array_append(v_usados, v_campo);
    v_orden := v_orden || format('f.%I %s, ', v_campo, v_dir);
  end loop;
  if v_orden = '' then v_orden := 'f.fecha_creacion desc, '; end if;
  if not ('solicitud_visita_id' = any (v_usados)) then v_orden := v_orden || 'f.solicitud_visita_id asc'; else v_orden := left(v_orden, length(v_orden) - 2); end if;

  execute format($q$
    with f as (
      select s.solicitud_visita_id, s.estado, s.fecha_creacion, s.fecha_propuesta
      from cuidared.solicitud_visita s
      where s.cuenta_id = $1 and ($2::text is null or s.estado::text = $2)
    ), p as (
      select f.solicitud_visita_id,
             row_number() over (order by (f.estado::text <> 'pendiente'), %s) as rn
      from f
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'items', coalesce((select jsonb_agg(cuidared_interno.solicitud_json(p.solicitud_visita_id) order by p.rn)
                         from p where p.rn > $3 and p.rn <= $3 + $4), '[]'::jsonb))
  $q$, v_orden)
  into v_res
  using p_cuenta_id, v_estado, p_desplazamiento, p_limite;
  return v_res;
end $$;

/*
 * Autoriza una solicitud pendiente: confirma el adulto y crea la visita programada (origen solicitud) con participante =
 * quien autoriza y autorizada_por = quien autoriza. Cuerpo: {envejeciente_id, fecha, hora}. Los datos del visitante no se
 * copian a la visita.
 */
create function cuidared_api.api_autorizar_solicitud_visita(p_cuenta_id bigint, p_solicitud_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_s record;
  v_env uuid;
  v_fecha date;
  v_hora time;
  v_hoy date := cuidared_interno.hoy();
  v_estado text;
  v_id uuid := gen_random_uuid();
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_solicitud_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  select * into v_s from cuidared.solicitud_visita where solicitud_visita_id = p_solicitud_id and cuenta_id = p_cuenta_id for update;
  if not found then raise no_data_found; end if;
  if v_s.estado::text <> 'pendiente' then raise exception 'CR_SOLICITUD_REVISADA' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['envejeciente_id', 'fecha', 'hora'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_env := cuidared_interno.v_uuid(p_datos->'envejeciente_id');
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hora := cuidared_interno.v_hora(p_datos->'hora');
  if v_fecha < v_hoy or (v_fecha = v_hoy and v_hora < cuidared_interno.hora_local()) then
    raise invalid_parameter_value;
  end if;
  -- El adulto lo confirma quien autoriza: de la cuenta (otra cuenta e inexistente responden igual, 42501) y activo.
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:autorizar', v_env);
  select e.estado into v_estado from cuidared.envejeciente e where e.envejeciente_id = v_env;
  if v_estado <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;

  insert into cuidared.visita (visita_id, cuenta_id, fecha, hora_programada, razon, estado, origen, creada_por, solicitud_visita_id)
    values (v_id, p_cuenta_id, v_fecha, v_hora, btrim(left(v_s.motivo, 120)), 'programada', 'solicitud', v_uid, p_solicitud_id);
  insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id) values (v_id, v_uid, v_uid);
  insert into cuidared.detalle_visita (visita_id, envejeciente_id) values (v_id, v_env);
  update cuidared.solicitud_visita
    set estado = 'autorizada', envejeciente_id = v_env, revisada_por = v_uid, revisada_en = now(), visita_id = v_id
    where solicitud_visita_id = p_solicitud_id;
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $$;

-- Rechaza una solicitud pendiente con un motivo que verá el visitante.
create function cuidared_api.api_rechazar_solicitud_visita(p_cuenta_id bigint, p_solicitud_id uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid; v_s record; v_motivo text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_solicitud_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  select * into v_s from cuidared.solicitud_visita where solicitud_visita_id = p_solicitud_id and cuenta_id = p_cuenta_id for update;
  if not found then raise no_data_found; end if;
  if v_s.estado::text <> 'pendiente' then raise exception 'CR_SOLICITUD_REVISADA' using errcode = 'P0001'; end if;
  v_motivo := cuidared_interno.v_texto(to_jsonb(p_motivo), 3, 300);
  update cuidared.solicitud_visita
    set estado = 'rechazada', motivo_rechazo = v_motivo, revisada_por = v_uid, revisada_en = now()
    where solicitud_visita_id = p_solicitud_id;
  return cuidared_interno.solicitud_json(p_solicitud_id);
end $$;

/* ───────────── 8. RPC públicas (anon): solicitudes de personas externas ───────────── */

-- Solo { cuenta_id, nombre } de cuentas tipo organización con acceso operativo. Las familias nunca se listan.
create function cuidared_api.api_publico_listar_organizaciones() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('cuenta_id', o.cuenta_id, 'nombre', o.nombre) order by o.nombre, o.cuenta_id), '[]'::jsonb)
  from (
    select c.cuenta_id, c.nombre
    from cuidared.cuenta c
    join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id and t.codigo::text = 'organizacion'
    where cuidared_interno.acceso_operativo(c.cuenta_id)
    order by c.nombre, c.cuenta_id
    limit 500
  ) o
$$;

/*
 * Crea una solicitud pendiente. Express genera el código de seguimiento y envía solo su huella HMAC-SHA256 (codigo_hash). Entrada
 * estricta; una cuenta que no es organización con acceso operativo (familia, vencida o inexistente) responde igual: 22023.
 * Devuelve solo lo que el visitante necesita; sin datos de cuentas ni de adultos.
 */
create function cuidared_api.api_publico_crear_solicitud(p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_cuenta bigint;
  v_nombres text;
  v_apellidos text;
  v_cedula text;
  v_telefono text;
  v_correo text;
  v_persona text;
  v_fecha date;
  v_hora time;
  v_motivo text;
  v_hash text;
  v_org text;
  v_id uuid;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['cuenta_id', 'nombres', 'apellidos', 'cedula', 'telefono', 'correo', 'persona_a_visitar',
                        'fecha_propuesta', 'hora_propuesta', 'motivo', 'codigo_hash'] <> '{}'::jsonb
     or jsonb_typeof(p_datos->'cuenta_id') is distinct from 'number'
     or (p_datos->>'cuenta_id') !~ '^[1-9][0-9]{0,17}$' then
    raise invalid_parameter_value;
  end if;
  v_cuenta := (p_datos->>'cuenta_id')::bigint;
  v_nombres := cuidared_interno.v_texto(p_datos->'nombres', 2, 60);
  v_apellidos := cuidared_interno.v_texto(p_datos->'apellidos', 2, 60);
  v_cedula := cuidared_interno.v_texto(p_datos->'cedula', 11, 11);
  v_telefono := cuidared_interno.v_texto(p_datos->'telefono', 10, 16);
  v_correo := cuidared_interno.v_texto(p_datos->'correo', 5, 254, false);
  v_persona := cuidared_interno.v_texto(p_datos->'persona_a_visitar', 3, 120);
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha_propuesta');
  v_hora := cuidared_interno.v_hora(p_datos->'hora_propuesta');
  v_motivo := cuidared_interno.v_texto(p_datos->'motivo', 3, 300);
  v_hash := cuidared_interno.v_texto(p_datos->'codigo_hash', 64, 64);
  if v_cedula !~ '^[0-9]{11}$' or v_telefono !~ '^\+?[0-9]{10,15}$' or v_hash !~ '^[0-9a-f]{64}$'
     or (v_correo is not null and v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
     or v_fecha < cuidared_interno.hoy() then
    raise invalid_parameter_value;
  end if;
  select c.nombre into v_org
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id and t.codigo::text = 'organizacion'
  where c.cuenta_id = v_cuenta and cuidared_interno.acceso_operativo(c.cuenta_id);
  if not found then raise invalid_parameter_value; end if;
  -- Frenos contra inundación: pendientes por visitante, pendientes por cuenta y creaciones por hora.
  if (select count(*) from cuidared.solicitud_visita s
      where s.cuenta_id = v_cuenta and s.visitante_cedula = v_cedula and s.estado::text = 'pendiente') >= 3 then
    raise exception 'CR_CONFLICTO' using errcode = 'P0001';
  end if;
  -- Las RPC públicas pueden llamarse directo (sin pasar por el límite de Express): estos topes acotan el daño por cuenta.
  if (select count(*) from cuidared.solicitud_visita s where s.cuenta_id = v_cuenta and s.estado::text = 'pendiente') >= 500
     or (select count(*) from cuidared.solicitud_visita s
         where s.cuenta_id = v_cuenta and s.fecha_creacion > now() - interval '1 hour') >= 60 then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  insert into cuidared.solicitud_visita (cuenta_id, visitante_nombres, visitante_apellidos, visitante_cedula, visitante_telefono,
                                        visitante_correo, persona_a_visitar, fecha_propuesta, hora_propuesta, motivo, codigo_hash)
    values (v_cuenta, v_nombres, v_apellidos, v_cedula, v_telefono, lower(v_correo), v_persona, v_fecha, v_hora, v_motivo, v_hash)
    returning solicitud_visita_id into v_id;
  -- Aviso a los usuarios principales de la cuenta (sin datos del adulto: aún no está confirmado ni identificado).
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
    select g, v_cuenta, format('Nueva solicitud de visita de %s %s para el %s.', v_nombres, v_apellidos, to_char(v_fecha, 'DD/MM/YYYY'))
    from cuidared_interno.gestores_cuenta(v_cuenta) g;
  return jsonb_build_object('organizacion', v_org, 'estado', 'pendiente', 'fecha_propuesta', v_fecha,
                            'hora_propuesta', cuidared_interno.hhmm(v_hora));
end $$;

-- Lo que el visitante ve de su solicitud: sin datos del adulto ni del personal. Código inexistente o inválido: P0002.
create function cuidared_api.api_publico_consultar_solicitud(p_codigo_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s record;
  v_org text;
  v_fecha date;
  v_hora time;
  v_abierta boolean := false;
begin
  if p_codigo_hash is null or p_codigo_hash !~ '^[0-9a-f]{64}$' then raise no_data_found; end if;
  select * into v_s from cuidared.solicitud_visita where codigo_hash = p_codigo_hash;
  if not found then raise no_data_found; end if;
  select c.nombre into v_org from cuidared.cuenta c where c.cuenta_id = v_s.cuenta_id;
  v_fecha := v_s.fecha_propuesta;
  v_hora := v_s.hora_propuesta;
  -- Una vez autorizada, la fecha y la hora vigentes son las de la visita creada (pueden diferir de las propuestas).
  if v_s.visita_id is not null then
    select v.fecha, v.hora_programada, v.estado::text in ('programada', 'en_curso')
      into v_fecha, v_hora, v_abierta
      from cuidared.visita v where v.visita_id = v_s.visita_id;
  end if;
  return jsonb_build_object(
    'organizacion', v_org,
    'estado', v_s.estado,
    'fecha', v_fecha,
    'hora', cuidared_interno.hhmm(v_hora),
    'motivo_rechazo', v_s.motivo_rechazo,
    'puede_registrar_observacion', v_s.estado::text = 'autorizada' and v_abierta and v_fecha <= cuidared_interno.hoy()
                                   and cuidared_interno.acceso_operativo(v_s.cuenta_id),
    'observacion', v_s.observacion_visitante);
end $$;

/*
 * El visitante deja su observación el día de la visita o después: la visita queda completada (cuenta como contacto efectivo)
 * con esa observación. Solo si la solicitud está autorizada y la visita sigue abierta y es de hoy o anterior; si no,
 * CR_SOLICITUD_NO_DISPONIBLE. Devuelve el estado público actualizado.
 */
create function cuidared_api.api_publico_registrar_observacion(p_codigo_hash text, p_observacion text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_s record; v_v record; v_obs text; v_hoy date := cuidared_interno.hoy(); v_fin time; v_ini time;
begin
  if p_codigo_hash is null or p_codigo_hash !~ '^[0-9a-f]{64}$' then raise no_data_found; end if;
  select * into v_s from cuidared.solicitud_visita where codigo_hash = p_codigo_hash for update;
  if not found then raise no_data_found; end if;
  v_obs := cuidared_interno.v_texto(to_jsonb(p_observacion), 3, 600);
  if v_s.estado::text <> 'autorizada' or v_s.visita_id is null then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  select * into v_v from cuidared.visita where visita_id = v_s.visita_id for update;
  if not found or v_v.estado::text not in ('programada', 'en_curso') or v_v.fecha > v_hoy
     or not cuidared_interno.acceso_operativo(v_s.cuenta_id) then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  v_fin := case when v_v.fecha = v_hoy then cuidared_interno.hora_local() end;
  v_ini := coalesce(v_v.hora_inicio, least(v_v.hora_programada, v_fin));
  update cuidared.visita
    set estado = 'completada', hora_inicio = v_ini, hora_fin = v_fin, fecha_actualizacion = now()
    where visita_id = v_v.visita_id;
  -- El visitante no es un usuario: registrado_por queda nulo.
  update cuidared.detalle_visita set observacion = v_obs, fecha_registro = now() where visita_id = v_v.visita_id;
  update cuidared.solicitud_visita
    set estado = 'realizada', observacion_visitante = v_obs, observacion_en = now()
    where solicitud_visita_id = v_s.solicitud_visita_id;
  return cuidared_api.api_publico_consultar_solicitud(p_codigo_hash);
end $$;

/* ───────────── 9. Privilegios ───────────── */

revoke all on all functions in schema cuidared_interno from public, anon, authenticated;

revoke all on function
  cuidared_api.api_listar_visitas(bigint, jsonb, jsonb, integer, integer),
  cuidared_api.api_obtener_visita(bigint, uuid),
  cuidared_api.api_programar_visita(bigint, jsonb),
  cuidared_api.api_iniciar_visita(bigint, uuid),
  cuidared_api.api_registrar_visita(bigint, uuid, jsonb),
  cuidared_api.api_cancelar_visita(bigint, uuid, text),
  cuidared_api.api_listar_solicitudes_visita(bigint, jsonb, jsonb, integer, integer),
  cuidared_api.api_autorizar_solicitud_visita(bigint, uuid, jsonb),
  cuidared_api.api_rechazar_solicitud_visita(bigint, uuid, text),
  cuidared_api.api_publico_listar_organizaciones(),
  cuidared_api.api_publico_crear_solicitud(jsonb),
  cuidared_api.api_publico_consultar_solicitud(text),
  cuidared_api.api_publico_registrar_observacion(text, text)
  from public, anon, authenticated;

grant execute on function
  cuidared_api.api_listar_visitas(bigint, jsonb, jsonb, integer, integer),
  cuidared_api.api_obtener_visita(bigint, uuid),
  cuidared_api.api_programar_visita(bigint, jsonb),
  cuidared_api.api_iniciar_visita(bigint, uuid),
  cuidared_api.api_registrar_visita(bigint, uuid, jsonb),
  cuidared_api.api_cancelar_visita(bigint, uuid, text),
  cuidared_api.api_listar_solicitudes_visita(bigint, jsonb, jsonb, integer, integer),
  cuidared_api.api_autorizar_solicitud_visita(bigint, uuid, jsonb),
  cuidared_api.api_rechazar_solicitud_visita(bigint, uuid, text)
  to authenticated;

commit;
