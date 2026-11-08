-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 3 · Envejecientes (ID03), bloque 3a — perfiles, consentimiento, contactos de emergencia y cambio de estado.
-- RF-01, RF-13, RF-17 · CR-158 (consentimiento informado, Ley 172-13) · CR-172 (baja) · Reglas de Negocio V2.
-- Depende de docs/propuestas/fase-2a-base.sql (cuidared_interno.exigir, alcanza_envejeciente, limites, hoy).
-- Validada en un PostgreSQL local con `node scripts/validar-propuestas-local.js --solo=3a` (no certifica RLS ni Auth).
-- © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (registro en docs/contratos/envejecientes.md):
--   · Cédula del adulto obligatoria y única en toda la plataforma (confirmado 2026-10-24, D09): NOT NULL + índice único.
--     Un duplicado concurrente lo rechaza el índice; la RPC lo traduce a CR_CEDULA_DUPLICADA sin revelar la cuenta.
--   · Consentimiento informado como columnas del perfil; el CHECK impide guardar un perfil sin consentimiento.
--   · Condición general: autonomía, condiciones (lista cerrada, CHECK) y nota. Propuesta técnica (D14): el catálogo
--     de condiciones es un CHECK sincronizado con CONDICIONES del frontend, no una tabla.
--   · Edad: 60 a 120 años, validada en la RPC con la fecha de negocio. Propuesta técnica (D09).
--   · Estados activo → inactivo | fallecido; inactivo → activo | fallecido; fallecido es terminal; el motivo es
--     obligatorio al inactivar. Propuesta técnica (D10 / D15).
--   · Al inactivar o registrar el fallecimiento se cancelan tareas abiertas, se resuelven alertas abiertas y se cancelan
--     las visitas programadas cuyo único adulto es ese. Los vínculos y contactos se conservan (historial).
--   · Aislamiento: un adulto de otra cuenta, uno fuera del alcance del usuario y uno inexistente responden igual (P0002).
--     Por eso se usa exigir() + alcanza_envejeciente() y no exigir_envejeciente(), que responde 42501.
--
-- Al cargar esta propuesta junto con la de 3b (que reemplaza alcanza_envejeciente) el alcance de las RPC cambia sin
-- tocar este archivo: todas las lecturas llaman a cuidared_interno.alcanza_envejeciente.
-- Integración con otros bloques:
--   · Con esta propuesta, todo INSERT directo en cuidared.envejeciente (datos de prueba, cargas) debe aportar la cédula
--     y las columnas consentimiento_otorgado, _otorgado_por, _fecha y _registrado_por (ck_envejeciente_consentimiento).
--   · api_estado_envejeciente solo cambia el estado de tareas, alertas y visitas; si 4b/4a agregaron columnas de
--     trazabilidad de la cancelación (motivo_cancelacion, cancelada_por, fecha_cancelacion, actualizado_por) las rellena,
--     y si no existen funciona igual (se consulta pg_attribute en cada llamada).
begin;

/* ───────────── 0. Consultas previas (ejecutar ANTES de aplicar; todas deben devolver 0 filas) ───────────── */
-- Tipo físico de la cédula: debe ser character(11) (DB.sql la exporta sin longitud).
--   select format_type(a.atttypid, a.atttypmod) from pg_attribute a
--   where a.attrelid = 'cuidared.envejeciente'::regclass and a.attname = 'cedula' and format_type(a.atttypid, a.atttypmod) <> 'character(11)';
-- Perfiles sin cédula (impediría el NOT NULL) y cédulas repetidas (impedirían el índice único):
--   select envejeciente_id from cuidared.envejeciente where cedula is null;
--   select cedula, count(*) from cuidared.envejeciente where cedula is not null group by cedula having count(*) > 1;
-- Perfiles existentes sin consentimiento registrado (el CHECK de consentimiento los rechazaría). Si hubiera, completar
-- primero las columnas consentimiento_* y condición general con datos reales; no inventar consentimientos:
--   select count(*) from cuidared.envejeciente;
-- Contactos con más de un principal (impedirían el índice único parcial):
--   select envejeciente_id from cuidared.contacto_emergencia where es_principal group by envejeciente_id having count(*) > 1;
-- Perfiles anonimizados (D15, sin política final): comparten cédula placeholder y chocarían con el índice único.

/* ───────────── 1. Esquema: envejeciente ───────────── */

-- Cédula obligatoria y única en toda la plataforma (D09 resuelta). El CHECK de formato ya existe en DB.sql.
alter table cuidared.envejeciente alter column cedula set not null;
create unique index uq_envejeciente_cedula on cuidared.envejeciente (cedula);

alter table cuidared.envejeciente
  -- Ubicación: sector o barrio (la dirección ya existe). Obligatorio al registrar; nulo solo en filas anteriores.
  add column zona character varying check (zona is null or char_length(btrim(zona)) between 1 and 60),
  -- Condición general (RF-01): listas cerradas, sin información clínica detallada (minimización, Ley 42-01).
  add column autonomia character varying check (autonomia in ('independiente', 'parcial', 'dependiente')),
  add column condiciones text[] not null default '{}'
    check (condiciones <@ array['cronica', 'movilidad', 'cognitivo', 'sensorial', 'vive_solo', 'sin_ingresos',
                                'vivienda', 'aislamiento']::text[]),
  add column nota_condicion character varying check (nota_condicion is null or char_length(nota_condicion) <= 500),
  -- Consentimiento informado (Ley 172-13, CR-158): quién lo otorgó, cuándo y quién lo registró.
  add column consentimiento_otorgado boolean,
  add column consentimiento_otorgado_por character varying check (consentimiento_otorgado_por in ('adulto', 'representante')),
  add column consentimiento_representante character varying
    check (consentimiento_representante is null or char_length(btrim(consentimiento_representante)) between 2 and 120),
  add column consentimiento_fecha timestamp with time zone,
  add column consentimiento_registrado_por uuid references cuidared.usuario(usuario_id),
  -- Último cambio de estado (CR-172): motivo y fecha.
  add column motivo_estado character varying check (motivo_estado is null or char_length(motivo_estado) between 1 and 200),
  add column fecha_estado timestamp with time zone;

-- Sin consentimiento no se guarda un perfil. Si lo otorga un representante, su nombre es obligatorio.
alter table cuidared.envejeciente add constraint ck_envejeciente_consentimiento check (
  consentimiento_otorgado is true
  and consentimiento_fecha is not null
  and consentimiento_registrado_por is not null
  -- `is not distinct from`: un CHECK que da NULL se acepta, y aquí un otorgante nulo debe rechazarse.
  and ((consentimiento_otorgado_por is not distinct from 'adulto' and consentimiento_representante is null)
    or (consentimiento_otorgado_por is not distinct from 'representante' and consentimiento_representante is not null)));

comment on column cuidared.envejeciente.cedula is 'Obligatoria y única en toda la plataforma (D09). 11 dígitos, sin guiones.';
comment on column cuidared.envejeciente.consentimiento_registrado_por is 'Usuario que registró el consentimiento (trazabilidad, CR-158).';

-- Listados por cuenta (orden por apellidos, nombres, creación) y conteo de activos para el límite del plan.
create index ix_envejeciente_cuenta_orden on cuidared.envejeciente (cuenta_id, apellidos, nombres, fecha_creacion);
create index ix_envejeciente_cuenta_estado on cuidared.envejeciente (cuenta_id, estado);

/* ───────────── 2. Esquema: contacto_emergencia (RF-17) ───────────── */

-- Exactamente un principal por adulto: el índice único parcial impide dos principales, incluso concurrentes.
create unique index uq_contacto_principal on cuidared.contacto_emergencia (envejeciente_id) where es_principal;
create index ix_contacto_envejeciente on cuidared.contacto_emergencia (envejeciente_id);

-- Defensa en profundidad: sin acceso directo, solo a través de las RPC (security definer). Como en fase 1 (usuario).
-- Revisar antes de aplicar si algún otro proceso del proyecto remoto usa estas tablas con el rol authenticated.
alter table cuidared.envejeciente enable row level security;
alter table cuidared.contacto_emergencia enable row level security;
revoke all on cuidared.envejeciente, cuidared.contacto_emergencia from public, anon, authenticated;

/* ───────────── 3. Funciones internas (esquema NO expuesto) ───────────── */

-- Marca temporal en UTC (ISO 8601) con independencia de la zona horaria de la sesión (CR-162).
create function cuidared_interno.env_ts(p_ts timestamp with time zone) returns text
language sql immutable strict set search_path = '' as $$
  select to_char(p_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

-- Texto de una sola línea: espacios colapsados, sin caracteres de control, con longitud entre p_min y p_max. 22023 si no.
create function cuidared_interno.env_texto(p_valor jsonb, p_min integer, p_max integer) returns text
language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  if jsonb_typeof(p_valor) is distinct from 'string' then raise invalid_parameter_value; end if;
  v := regexp_replace(btrim(p_valor #>> '{}'), '\s+', ' ', 'g');
  if char_length(v) not between p_min and p_max or v ~ '[[:cntrl:]]' then raise invalid_parameter_value; end if;
  return v;
end;
$$;

-- Nombre de persona. Lista de exclusión (no depende de la configuración regional): sin dígitos ni símbolos de marcado.
create function cuidared_interno.env_nombre(p_valor jsonb, p_max integer default 60) returns text
language plpgsql immutable set search_path = '' as $$
declare v text := cuidared_interno.env_texto(p_valor, 2, p_max);
begin
  if v ~ '[0-9<>{}\[\]\\/@#$%^&*=+|~`_;:!?()",]' or v ~ '^[ .''-]' then raise invalid_parameter_value; end if;
  return v;
end;
$$;

-- Teléfono: se quitan espacios y guiones y debe cumplir el patrón del modelo (^\+?[0-9]{10,15}$).
create function cuidared_interno.env_telefono(p_valor jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare v text;
begin
  if jsonb_typeof(p_valor) is distinct from 'string' then raise invalid_parameter_value; end if;
  v := regexp_replace(p_valor #>> '{}', '[\s-]', '', 'g');
  if v !~ '^\+?[0-9]{10,15}$' then raise invalid_parameter_value; end if;
  return v;
end;
$$;

-- Fecha AAAA-MM-DD real; 22023 (no 22008) si no lo es.
create function cuidared_interno.env_fecha(p_valor jsonb) returns date
language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(p_valor) is distinct from 'string' or (p_valor #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise invalid_parameter_value;
  end if;
  return (p_valor #>> '{}')::date;
exception when others then
  raise invalid_parameter_value;
end;
$$;

-- Fecha de nacimiento de un adulto mayor: no futura y con 60 a 120 años (fecha de negocio). Propuesta técnica (D09).
create function cuidared_interno.env_fecha_nacimiento(p_valor jsonb) returns date
language plpgsql stable set search_path = '' as $$
declare
  v date := cuidared_interno.env_fecha(p_valor);
  v_edad integer;
begin
  v_edad := extract(year from age(cuidared_interno.hoy(), v))::integer;
  if v > cuidared_interno.hoy() or v_edad < 60 or v_edad > 120 then raise invalid_parameter_value; end if;
  return v;
end;
$$;

-- Condiciones: arreglo de cadenas únicas del catálogo cerrado (sincronizado con CONDICIONES del frontend).
create function cuidared_interno.env_condiciones(p_valor jsonb) returns text[]
language plpgsql immutable set search_path = '' as $$
declare v text[];
begin
  if jsonb_typeof(p_valor) is distinct from 'array' or jsonb_array_length(p_valor) > 8
     or exists (select 1 from jsonb_array_elements(p_valor) x where jsonb_typeof(x) is distinct from 'string') then
    raise invalid_parameter_value;
  end if;
  select coalesce(array_agg(distinct x order by x), array[]::text[]) into v from jsonb_array_elements_text(p_valor) x;
  if not v <@ array['cronica', 'movilidad', 'cognitivo', 'sensorial', 'vive_solo', 'sin_ingresos', 'vivienda',
                    'aislamiento']::text[] then
    raise invalid_parameter_value;
  end if;
  return v;
end;
$$;

/*
 * Consentimiento informado (CR-158). Devuelve {por, representante}.
 *   CR_CONSENTIMIENTO_REQUERIDO  falta el objeto, otorgado = false, o el representante no indicó su nombre.
 *   22023                        forma inválida (claves desconocidas, tipos, otorgado_por fuera de lista).
 */
create function cuidared_interno.env_consentimiento(p_valor jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_por text;
  v_rep text;
begin
  if jsonb_typeof(p_valor) is distinct from 'object' then
    raise exception 'CR_CONSENTIMIENTO_REQUERIDO' using errcode = 'P0001';
  end if;
  if p_valor - array['otorgado', 'otorgado_por', 'representante'] <> '{}'::jsonb
     or jsonb_typeof(p_valor->'otorgado') is distinct from 'boolean'
     or jsonb_typeof(p_valor->'otorgado_por') is distinct from 'string'
     or (p_valor->>'otorgado_por') not in ('adulto', 'representante') then
    raise invalid_parameter_value;
  end if;
  if (p_valor->>'otorgado')::boolean is not true then
    raise exception 'CR_CONSENTIMIENTO_REQUERIDO' using errcode = 'P0001';
  end if;
  v_por := p_valor->>'otorgado_por';
  if v_por = 'representante' then
    if jsonb_typeof(p_valor->'representante') is distinct from 'string' then
      raise exception 'CR_CONSENTIMIENTO_REQUERIDO' using errcode = 'P0001';
    end if;
    v_rep := cuidared_interno.env_nombre(p_valor->'representante', 120);
  elsif p_valor ? 'representante' and jsonb_typeof(p_valor->'representante') <> 'null' then
    raise invalid_parameter_value;
  end if;
  return jsonb_build_object('por', v_por, 'representante', v_rep);
end;
$$;

/*
 * Valida y normaliza los datos del perfil (alta o edición parcial). Devuelve solo las claves presentes, ya normalizadas.
 * No procesa `consentimiento` ni `contactos` (los validan sus propias funciones). 22023 ante cualquier entrada inválida.
 */
create function cuidared_interno.env_perfil_normalizar(p_datos jsonb, p_crear boolean) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v jsonb := '{}'::jsonb;
  v_nota text;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['nombres', 'apellidos', 'cedula', 'fecha_nacimiento', 'sexo', 'telefono', 'municipio_cod', 'zona',
                        'direccion', 'autonomia', 'condiciones', 'nota_condicion', 'consentimiento', 'contactos'] <> '{}'::jsonb
     or (p_crear and not (p_datos ?& array['nombres', 'apellidos', 'cedula', 'fecha_nacimiento', 'sexo', 'municipio_cod',
                                           'zona', 'autonomia']))
     or (not p_crear and (p_datos = '{}'::jsonb or p_datos ? 'contactos')) then
    raise invalid_parameter_value;
  end if;

  if p_datos ? 'nombres' then v := v || jsonb_build_object('nombres', cuidared_interno.env_nombre(p_datos->'nombres')); end if;
  if p_datos ? 'apellidos' then v := v || jsonb_build_object('apellidos', cuidared_interno.env_nombre(p_datos->'apellidos')); end if;
  if p_datos ? 'cedula' then
    if jsonb_typeof(p_datos->'cedula') is distinct from 'string'
       or regexp_replace(p_datos->>'cedula', '[\s-]', '', 'g') !~ '^[0-9]{11}$' then
      raise invalid_parameter_value;
    end if;
    v := v || jsonb_build_object('cedula', regexp_replace(p_datos->>'cedula', '[\s-]', '', 'g'));
  end if;
  if p_datos ? 'fecha_nacimiento' then
    v := v || jsonb_build_object('fecha_nacimiento', cuidared_interno.env_fecha_nacimiento(p_datos->'fecha_nacimiento'));
  end if;
  if p_datos ? 'sexo' then
    if jsonb_typeof(p_datos->'sexo') is distinct from 'string' or (p_datos->>'sexo') not in ('F', 'M') then
      raise invalid_parameter_value;
    end if;
    v := v || jsonb_build_object('sexo', p_datos->>'sexo');
  end if;
  if p_datos ? 'telefono' then
    v := v || jsonb_build_object('telefono',
      case when jsonb_typeof(p_datos->'telefono') = 'null' then null else cuidared_interno.env_telefono(p_datos->'telefono') end);
  end if;
  if p_datos ? 'municipio_cod' then
    -- La FK no basta: un 23503 llegaría a la API como indisponibilidad en lugar de entrada inválida.
    if jsonb_typeof(p_datos->'municipio_cod') is distinct from 'string'
       or (p_datos->>'municipio_cod') !~ '^[0-9]{4,6}$'
       or not exists (select 1 from cuidared.municipio m where m.municipio_cod = p_datos->>'municipio_cod') then
      raise invalid_parameter_value;
    end if;
    v := v || jsonb_build_object('municipio_cod', p_datos->>'municipio_cod');
  end if;
  if p_datos ? 'zona' then v := v || jsonb_build_object('zona', cuidared_interno.env_texto(p_datos->'zona', 1, 60)); end if;
  if p_datos ? 'direccion' then v := v || jsonb_build_object('direccion', cuidared_interno.env_texto(p_datos->'direccion', 0, 150)); end if;
  if p_datos ? 'autonomia' then
    if jsonb_typeof(p_datos->'autonomia') is distinct from 'string'
       or (p_datos->>'autonomia') not in ('independiente', 'parcial', 'dependiente') then
      raise invalid_parameter_value;
    end if;
    v := v || jsonb_build_object('autonomia', p_datos->>'autonomia');
  end if;
  if p_datos ? 'condiciones' then
    v := v || jsonb_build_object('condiciones', to_jsonb(cuidared_interno.env_condiciones(p_datos->'condiciones')));
  end if;
  if p_datos ? 'nota_condicion' then
    if jsonb_typeof(p_datos->'nota_condicion') = 'null' then
      v := v || jsonb_build_object('nota_condicion', null);
    else
      if jsonb_typeof(p_datos->'nota_condicion') is distinct from 'string' then raise invalid_parameter_value; end if;
      v_nota := nullif(btrim(p_datos->>'nota_condicion'), '');
      if char_length(coalesce(v_nota, '')) > 500 then raise invalid_parameter_value; end if;
      v := v || jsonb_build_object('nota_condicion', v_nota);
    end if;
  end if;
  return v;
end;
$$;

-- Normaliza un contacto de emergencia (alta completa o edición parcial). `es_principal` solo en altas.
create function cuidared_interno.env_contacto_normalizar(p_datos jsonb, p_crear boolean) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['nombres', 'apellidos', 'parentesco', 'telefono', 'es_principal'] <> '{}'::jsonb
     or (p_crear and not (p_datos ?& array['nombres', 'apellidos', 'parentesco', 'telefono']))
     or (not p_crear and (p_datos = '{}'::jsonb or p_datos ? 'es_principal')) then
    raise invalid_parameter_value;
  end if;
  if p_datos ? 'nombres' then v := v || jsonb_build_object('nombres', cuidared_interno.env_nombre(p_datos->'nombres')); end if;
  if p_datos ? 'apellidos' then v := v || jsonb_build_object('apellidos', cuidared_interno.env_nombre(p_datos->'apellidos')); end if;
  if p_datos ? 'parentesco' then v := v || jsonb_build_object('parentesco', cuidared_interno.env_texto(p_datos->'parentesco', 2, 40)); end if;
  if p_datos ? 'telefono' then v := v || jsonb_build_object('telefono', cuidared_interno.env_telefono(p_datos->'telefono')); end if;
  if p_crear then
    if p_datos ? 'es_principal' and jsonb_typeof(p_datos->'es_principal') is distinct from 'boolean' then
      raise invalid_parameter_value;
    end if;
    v := v || jsonb_build_object('es_principal', coalesce((p_datos->>'es_principal')::boolean, false));
  end if;
  return v;
end;
$$;

-- Contacto de emergencia como DTO (snake_case).
create function cuidared_interno.env_contacto(c cuidared.contacto_emergencia) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('contacto_id', c.contacto_emergencia_id::text, 'envejeciente_id', c.envejeciente_id,
                            'nombres', c.nombres, 'apellidos', c.apellidos, 'parentesco', c.parentesco,
                            'telefono', c.telefono, 'es_principal', c.es_principal)
$$;

/*
 * Nivel de visibilidad del usuario sobre los perfiles de la cuenta (D04, propuesta):
 *   minimo    Voluntario: nombres, dirección, zona, municipio y contacto principal.
 *   basico    quien consulta sin adultos:ver-sensible (Familiar): identificación y contactos, sin condición ni consentimiento.
 *   completo  con adultos:ver-sensible: además condición general, consentimiento y motivo de estado.
 */
create function cuidared_interno.env_nivel(p_cuenta_id bigint, p_usuario_id uuid) returns text
language sql stable set search_path = '' as $$
  select case
    when m.rol = 'voluntario' then 'minimo'
    when 'adultos:ver-sensible' = any (cuidared_interno.permisos(m.rol_id, m.tipo_cuenta_id)) then 'completo'
    else 'basico' end
  from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m
$$;

-- Perfil como DTO según el nivel de visibilidad. null si el adulto no existe (los llamadores ya comprobaron el alcance).
create function cuidared_interno.env_detalle(p_envejeciente_id uuid, p_nivel text) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
      'envejeciente_id', e.envejeciente_id,
      'estado', e.estado,
      'nombres', e.nombres,
      'apellidos', e.apellidos,
      'direccion', e.direccion,
      'zona', e.zona,
      'municipio_cod', e.municipio_cod,
      'municipio_nombre', m.nombre,
      'provincia_cod', m.provincia_cod,
      'contacto_principal', (select cuidared_interno.env_contacto(c) from cuidared.contacto_emergencia c
                             where c.envejeciente_id = e.envejeciente_id and c.es_principal))
    || case when p_nivel in ('basico', 'completo') then jsonb_build_object(
      'cedula', e.cedula::text,
      'fecha_nacimiento', e.fecha_nacimiento,
      'sexo', e.sexo,
      'telefono', e.telefono,
      'fecha_creacion', cuidared_interno.env_ts(e.fecha_creacion),
      'fecha_actualizacion', cuidared_interno.env_ts(e.fecha_actualizacion),
      'contactos', coalesce((select jsonb_agg(cuidared_interno.env_contacto(c) order by c.es_principal desc, c.contacto_emergencia_id)
                             from cuidared.contacto_emergencia c where c.envejeciente_id = e.envejeciente_id), '[]'::jsonb))
      else '{}'::jsonb end
    || case when p_nivel = 'completo' then jsonb_build_object(
      'motivo_estado', e.motivo_estado,
      'fecha_estado', cuidared_interno.env_ts(e.fecha_estado),
      'condicion_general', jsonb_build_object('autonomia', e.autonomia, 'condiciones', to_jsonb(e.condiciones),
                                              'nota', e.nota_condicion),
      'consentimiento', jsonb_build_object('otorgado', e.consentimiento_otorgado,
                                           'otorgado_por', e.consentimiento_otorgado_por,
                                           'representante', e.consentimiento_representante,
                                           'fecha', cuidared_interno.env_ts(e.consentimiento_fecha),
                                           'registrado_por', e.consentimiento_registrado_por))
      else '{}'::jsonb end
  from cuidared.envejeciente e
  left join cuidared.municipio m on m.municipio_cod = e.municipio_cod
  where e.envejeciente_id = p_envejeciente_id
$$;

/*
 * Autoriza la acción y el alcance sobre el adulto. 42501 si el rol no tiene la acción; P0002 si el adulto no existe en
 * ESTA cuenta o no está al alcance del usuario (asignación o autorización): las tres causas responden igual.
 */
create function cuidared_interno.env_exigir(p_cuenta_id bigint, p_accion text, p_envejeciente_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, p_accion);
begin
  if p_envejeciente_id is null
     or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, p_envejeciente_id, (v_ctx->>'usuario_id')::uuid) then
    raise exception 'adulto no encontrado' using errcode = 'P0002';
  end if;
  return v_ctx;
end;
$$;

-- Igual que env_exigir, partiendo de un contacto. Devuelve el adulto al que pertenece (en esta cuenta) o P0002.
create function cuidared_interno.env_contacto_exigir(p_cuenta_id bigint, p_accion text, p_contacto_id bigint) returns uuid
language plpgsql set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, p_accion);
  v_env uuid;
begin
  select c.envejeciente_id into v_env
  from cuidared.contacto_emergencia c
  join cuidared.envejeciente e on e.envejeciente_id = c.envejeciente_id
  where c.contacto_emergencia_id = p_contacto_id and e.cuenta_id = p_cuenta_id;
  if v_env is null or not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, (v_ctx->>'usuario_id')::uuid) then
    raise exception 'contacto no encontrado' using errcode = 'P0002';
  end if;
  return v_env;
end;
$$;

-- ¿Existe la columna? Permite rellenar la trazabilidad que agregan otros bloques sin depender de que estén cargados.
create function cuidared_interno.env_tiene_columna(p_tabla regclass, p_columna name) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from pg_catalog.pg_attribute a
                 where a.attrelid = p_tabla and a.attname = p_columna and a.attnum > 0 and not a.attisdropped)
$$;

-- Serializa las altas y reactivaciones de una cuenta (límite del plan) y el resto de operaciones que cuentan adultos.
create function cuidared_interno.env_bloquear_limite(p_cuenta_id bigint) returns void
language sql set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('cuidared:envejecientes:' || p_cuenta_id::text, 0))
$$;

-- CR_LIMITE_PLAN si la cuenta ya tiene el máximo de adultos activos de su plan o de su prueba. Llamar tras el bloqueo.
create function cuidared_interno.env_exigir_cupo(p_cuenta_id bigint) returns void
language plpgsql set search_path = '' as $$
declare
  v_limite integer := (cuidared_interno.limites(p_cuenta_id)->>'envejecientes')::integer;
begin
  if v_limite is not null
     and (select count(*) from cuidared.envejeciente e where e.cuenta_id = p_cuenta_id and e.estado = 'activo') >= v_limite then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
end;
$$;

revoke all on all functions in schema cuidared_interno from public, anon, authenticated;

/* ───────────── 4. RPC expuestas (cuidared_api): perfiles ───────────── */

/*
 * Alta del perfil con su consentimiento, condición general y contactos en UNA transacción (RF-01/RF-17).
 *   42501 sin permiso · 22023 entrada inválida · CR_CONSENTIMIENTO_REQUERIDO · CR_CONTACTO_PRINCIPAL (1 a 5 contactos,
 *   exactamente uno principal) · CR_LIMITE_PLAN · CR_CEDULA_DUPLICADA (cualquier cuenta; sin revelar cuál).
 */
create function cuidared_api.api_crear_envejeciente(p_cuenta_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'adultos:crear');
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_n jsonb;
  v_consent jsonb;
  v_contactos jsonb;
  v_id uuid;
begin
  v_n := cuidared_interno.env_perfil_normalizar(p_datos, true);
  v_consent := cuidared_interno.env_consentimiento(p_datos->'consentimiento');
  if jsonb_typeof(p_datos->'contactos') is distinct from 'array' or jsonb_array_length(p_datos->'contactos') not between 1 and 5 then
    raise exception 'CR_CONTACTO_PRINCIPAL' using errcode = 'P0001';
  end if;
  select jsonb_agg(cuidared_interno.env_contacto_normalizar(c.valor, true) order by c.orden) into v_contactos
  from jsonb_array_elements(p_datos->'contactos') with ordinality as c(valor, orden);
  if (select count(*) from jsonb_array_elements(v_contactos) c where (c->>'es_principal')::boolean) <> 1 then
    raise exception 'CR_CONTACTO_PRINCIPAL' using errcode = 'P0001';
  end if;

  perform cuidared_interno.env_bloquear_limite(p_cuenta_id);
  perform cuidared_interno.env_exigir_cupo(p_cuenta_id);

  begin
    insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
        municipio_cod, direccion, telefono, zona, autonomia, condiciones, nota_condicion, consentimiento_otorgado,
        consentimiento_otorgado_por, consentimiento_representante, consentimiento_fecha, consentimiento_registrado_por,
        fecha_estado)
    values (p_cuenta_id, v_uid, v_n->>'nombres', v_n->>'apellidos', v_n->>'cedula', (v_n->>'fecha_nacimiento')::date,
        v_n->>'sexo', v_n->>'municipio_cod', coalesce(v_n->>'direccion', ''), v_n->>'telefono', v_n->>'zona',
        v_n->>'autonomia', coalesce(array(select jsonb_array_elements_text(v_n->'condiciones')), array[]::text[]),
        v_n->>'nota_condicion', true, v_consent->>'por', v_consent->>'representante', now(), v_uid, now())
    returning envejeciente_id into v_id;
  exception when unique_violation then
    raise exception 'CR_CEDULA_DUPLICADA' using errcode = 'P0001';
  end;

  insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal)
  select v_id, c.valor->>'nombres', c.valor->>'apellidos', c.valor->>'parentesco', c.valor->>'telefono',
         (c.valor->>'es_principal')::boolean
  from jsonb_array_elements(v_contactos) with ordinality as c(valor, orden)
  order by c.orden;

  return cuidared_interno.env_detalle(v_id, cuidared_interno.env_nivel(p_cuenta_id, v_uid));
end;
$$;

/*
 * Listado paginado con el alcance del rol: Administrador y Coordinador ven todos los adultos de la cuenta; el resto solo
 * los que alcanza (asignados o autorizados). p_orden: arreglo JSON de campos permitidos con «-» para descendente (lista
 * cerrada, nunca SQL del cliente). Devuelve {total, items}; ambos salen del mismo conjunto autorizado y filtrado.
 */
create function cuidared_api.api_listar_envejecientes(
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
      where e.cuenta_id = $1
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

-- Perfil según el nivel de visibilidad del usuario. P0002 si no existe en esta cuenta o no está a su alcance.
create function cuidared_api.api_ver_envejeciente(p_cuenta_id bigint, p_envejeciente_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.env_exigir(p_cuenta_id, 'adultos:ver', p_envejeciente_id);
begin
  return cuidared_interno.env_detalle(p_envejeciente_id,
    cuidared_interno.env_nivel(p_cuenta_id, (v_ctx->>'usuario_id')::uuid));
end;
$$;

/*
 * Edición parcial de los campos editables (nunca estado, cuenta ni registrador). `consentimiento` vuelve a registrar el
 * consentimiento con la fecha y el usuario actuales; no se puede retirar (para eso se inactiva el perfil).
 * La cédula puede cambiar si sigue siendo única en la plataforma (CR_CEDULA_DUPLICADA).
 */
create function cuidared_api.api_editar_envejeciente(p_cuenta_id bigint, p_envejeciente_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.env_exigir(p_cuenta_id, 'adultos:editar', p_envejeciente_id);
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_n jsonb;
  v_consent jsonb;
begin
  v_n := cuidared_interno.env_perfil_normalizar(p_datos, false);
  if p_datos ? 'consentimiento' then v_consent := cuidared_interno.env_consentimiento(p_datos->'consentimiento'); end if;

  perform 1 from cuidared.envejeciente e
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id for no key update;
  if not found then raise exception 'adulto no encontrado' using errcode = 'P0002'; end if;

  begin
    update cuidared.envejeciente e set
      nombres = case when v_n ? 'nombres' then v_n->>'nombres' else e.nombres end,
      apellidos = case when v_n ? 'apellidos' then v_n->>'apellidos' else e.apellidos end,
      cedula = case when v_n ? 'cedula' then v_n->>'cedula' else e.cedula end,
      fecha_nacimiento = case when v_n ? 'fecha_nacimiento' then (v_n->>'fecha_nacimiento')::date else e.fecha_nacimiento end,
      sexo = case when v_n ? 'sexo' then v_n->>'sexo' else e.sexo end,
      telefono = case when v_n ? 'telefono' then v_n->>'telefono' else e.telefono end,
      municipio_cod = case when v_n ? 'municipio_cod' then v_n->>'municipio_cod' else e.municipio_cod end,
      zona = case when v_n ? 'zona' then v_n->>'zona' else e.zona end,
      direccion = case when v_n ? 'direccion' then v_n->>'direccion' else e.direccion end,
      autonomia = case when v_n ? 'autonomia' then v_n->>'autonomia' else e.autonomia end,
      condiciones = case when v_n ? 'condiciones' then array(select jsonb_array_elements_text(v_n->'condiciones')) else e.condiciones end,
      nota_condicion = case when v_n ? 'nota_condicion' then v_n->>'nota_condicion' else e.nota_condicion end,
      consentimiento_otorgado = case when v_consent is not null then true else e.consentimiento_otorgado end,
      consentimiento_otorgado_por = case when v_consent is not null then v_consent->>'por' else e.consentimiento_otorgado_por end,
      consentimiento_representante = case when v_consent is not null then v_consent->>'representante' else e.consentimiento_representante end,
      consentimiento_fecha = case when v_consent is not null then now() else e.consentimiento_fecha end,
      consentimiento_registrado_por = case when v_consent is not null then v_uid else e.consentimiento_registrado_por end,
      fecha_actualizacion = now()
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id;
  exception when unique_violation then
    raise exception 'CR_CEDULA_DUPLICADA' using errcode = 'P0001';
  end;

  return cuidared_interno.env_detalle(p_envejeciente_id, cuidared_interno.env_nivel(p_cuenta_id, v_uid));
end;
$$;

/*
 * Cambio de estado (CR-172). Transiciones (D10, propuesta): activo → inactivo | fallecido; inactivo → activo | fallecido;
 * fallecido es terminal. Mismo estado o salir de fallecido: CR_ESTADO_INVALIDO. El motivo es obligatorio al inactivar.
 * Reactivar respeta el límite del plan (CR_LIMITE_PLAN). Al pasar a inactivo o fallecido, en la misma transacción:
 *   · tareas de agenda abiertas (pendiente, en_progreso) → cancelada;
 *   · alertas abiertas (pendiente, en_proceso) → resuelta, con acción automática;
 *   · visitas programadas cuyo único adulto es este → cancelada (las de varios adultos se conservan).
 */
create function cuidared_api.api_estado_envejeciente(p_cuenta_id bigint, p_envejeciente_id uuid, p_estado text, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.env_exigir(p_cuenta_id, 'adultos:desactivar', p_envejeciente_id);
  v_uid uuid := (v_ctx->>'usuario_id')::uuid;
  v_motivo text := nullif(regexp_replace(btrim(coalesce(p_motivo, '')), '\s+', ' ', 'g'), '');
  v_actual text;
  v_tareas integer := 0;
  v_alertas integer := 0;
  v_visitas integer := 0;
  v_fecha timestamptz := now();
  v_auto text;
  v_set text;
begin
  if p_estado is null or p_estado not in ('activo', 'inactivo', 'fallecido')
     or char_length(coalesce(v_motivo, '')) > 200 or v_motivo ~ '[[:cntrl:]]'
     or (p_estado = 'inactivo' and char_length(coalesce(v_motivo, '')) < 3) then
    raise invalid_parameter_value;
  end if;

  -- Orden de bloqueos: primero la cuenta (solo al reactivar, por el límite), después la fila del adulto.
  if p_estado = 'activo' then perform cuidared_interno.env_bloquear_limite(p_cuenta_id); end if;
  select e.estado into v_actual from cuidared.envejeciente e
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id for no key update;
  if not found then raise exception 'adulto no encontrado' using errcode = 'P0002'; end if;
  if v_actual = 'fallecido' or v_actual = p_estado then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if p_estado = 'activo' then perform cuidared_interno.env_exigir_cupo(p_cuenta_id); end if;

  update cuidared.envejeciente e set estado = p_estado, motivo_estado = v_motivo, fecha_estado = v_fecha,
      fecha_actualizacion = v_fecha
    where e.envejeciente_id = p_envejeciente_id;

  if p_estado in ('inactivo', 'fallecido') then
    v_auto := ' automáticamente: el adulto pasó a ' || p_estado || '.' || coalesce(' Motivo: ' || v_motivo, '');

    -- Tareas abiertas → canceladas. Los bloques 4b y 4a agregan columnas de trazabilidad de la cancelación; se rellenan
    -- solo si existen, para que esta propuesta funcione con o sin ellos (sin tocar sus tablas más que el estado).
    v_set := concat_ws(', ',
      case when cuidared_interno.env_tiene_columna('cuidared.tarea_agenda', 'motivo_cancelacion') then 'motivo_cancelacion = $3' end,
      case when cuidared_interno.env_tiene_columna('cuidared.tarea_agenda', 'cancelada_por') then 'cancelada_por = $4' end,
      case when cuidared_interno.env_tiene_columna('cuidared.tarea_agenda', 'actualizado_por') then 'actualizado_por = $4' end);
    execute format($q$
      update cuidared.tarea_agenda t set estado = 'cancelada', fecha_actualizacion = $1%s
      where t.envejeciente_id = $2 and t.estado in ('pendiente', 'en_progreso')$q$,
      case when v_set <> '' then ', ' || v_set else '' end)
      using v_fecha, p_envejeciente_id, left('Cancelada' || v_auto, 500), v_uid;
    get diagnostics v_tareas = row_count;

    -- Alertas abiertas → resueltas, con la acción automática, el autor y la fecha de atención.
    update cuidared.alerta_envejeciente a set estado = 'resuelta', fecha_atencion = v_fecha, usuario_atendio_id = v_uid,
        fecha_actualizacion = v_fecha, accion_tomada = 'Cerrada' || v_auto
      where a.envejeciente_id = p_envejeciente_id and a.estado in ('pendiente', 'en_proceso');
    get diagnostics v_alertas = row_count;

    -- Visitas programadas cuyo ÚNICO adulto es este → canceladas (las de varios adultos se conservan).
    v_set := concat_ws(', ',
      case when cuidared_interno.env_tiene_columna('cuidared.visita', 'motivo_cancelacion') then 'motivo_cancelacion = $3' end,
      case when cuidared_interno.env_tiene_columna('cuidared.visita', 'cancelada_por') then 'cancelada_por = $4' end,
      case when cuidared_interno.env_tiene_columna('cuidared.visita', 'fecha_cancelacion') then 'fecha_cancelacion = $1' end);
    execute format($q$
      update cuidared.visita v set estado = 'cancelada', fecha_actualizacion = $1%s
      where v.estado = 'programada'
        and exists (select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id and d.envejeciente_id = $2)
        and not exists (select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id and d.envejeciente_id <> $2)$q$,
      case when v_set <> '' then ', ' || v_set else '' end)
      using v_fecha, p_envejeciente_id, left('Cancelada' || v_auto, 300), v_uid;
    get diagnostics v_visitas = row_count;
  end if;

  return jsonb_build_object('envejeciente_id', p_envejeciente_id, 'estado', p_estado, 'motivo_estado', v_motivo,
                            'fecha_estado', cuidared_interno.env_ts(v_fecha), 'tareas_canceladas', v_tareas,
                            'alertas_resueltas', v_alertas, 'visitas_canceladas', v_visitas);
end;
$$;

/* ───────────── 5. RPC expuestas (cuidared_api): contactos de emergencia ───────────── */

/*
 * Contactos del adulto, el principal primero. Quien alcanza al adulto los consulta; el Voluntario solo ve el principal
 * (datos mínimos). P0002 si el adulto no existe en esta cuenta o no está a su alcance.
 */
create function cuidared_api.api_listar_contactos(p_cuenta_id bigint, p_envejeciente_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.env_exigir(p_cuenta_id, 'adultos:ver', p_envejeciente_id);
  v_nivel text := cuidared_interno.env_nivel(p_cuenta_id, (v_ctx->>'usuario_id')::uuid);
begin
  return coalesce((select jsonb_agg(cuidared_interno.env_contacto(c) order by c.es_principal desc, c.contacto_emergencia_id)
                   from cuidared.contacto_emergencia c
                   where c.envejeciente_id = p_envejeciente_id and (v_nivel <> 'minimo' or c.es_principal)), '[]'::jsonb);
end;
$$;

/*
 * Alta de un contacto (hasta 5 por adulto, CR_LIMITE_CONTACTOS). Con es_principal = true reemplaza al principal actual de
 * forma atómica. La fila del adulto se bloquea para serializar el conteo y el cambio de principal.
 */
create function cuidared_api.api_crear_contacto(p_cuenta_id bigint, p_envejeciente_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.env_exigir(p_cuenta_id, 'adultos:editar', p_envejeciente_id);
  v_n jsonb := cuidared_interno.env_contacto_normalizar(p_datos, true);
  v_total integer;
  v_principal boolean;
  v_contacto cuidared.contacto_emergencia;
begin
  perform 1 from cuidared.envejeciente e
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id for no key update;
  if not found then raise exception 'adulto no encontrado' using errcode = 'P0002'; end if;
  select count(*) into v_total from cuidared.contacto_emergencia c where c.envejeciente_id = p_envejeciente_id;
  if v_total >= 5 then raise exception 'CR_LIMITE_CONTACTOS' using errcode = 'P0001'; end if;
  -- El primer contacto de un adulto (p. ej. un perfil anterior sin contactos) es siempre el principal.
  v_principal := (v_n->>'es_principal')::boolean or v_total = 0;
  if v_principal then
    update cuidared.contacto_emergencia c set es_principal = false
      where c.envejeciente_id = p_envejeciente_id and c.es_principal;
  end if;
  insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal)
  values (p_envejeciente_id, v_n->>'nombres', v_n->>'apellidos', v_n->>'parentesco', v_n->>'telefono', v_principal)
  returning * into v_contacto;
  update cuidared.envejeciente e set fecha_actualizacion = now() where e.envejeciente_id = p_envejeciente_id;
  return cuidared_interno.env_contacto(v_contacto);
end;
$$;

-- Edición parcial de nombres, apellidos, parentesco y teléfono. El principal se cambia con api_principal_contacto.
create function cuidared_api.api_editar_contacto(p_cuenta_id bigint, p_contacto_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_env uuid := cuidared_interno.env_contacto_exigir(p_cuenta_id, 'adultos:editar', p_contacto_id);
  v_n jsonb := cuidared_interno.env_contacto_normalizar(p_datos, false);
  v_contacto cuidared.contacto_emergencia;
begin
  perform 1 from cuidared.envejeciente e where e.envejeciente_id = v_env for no key update;
  update cuidared.contacto_emergencia c set
      nombres = case when v_n ? 'nombres' then v_n->>'nombres' else c.nombres end,
      apellidos = case when v_n ? 'apellidos' then v_n->>'apellidos' else c.apellidos end,
      parentesco = case when v_n ? 'parentesco' then v_n->>'parentesco' else c.parentesco end,
      telefono = case when v_n ? 'telefono' then v_n->>'telefono' else c.telefono end
    where c.contacto_emergencia_id = p_contacto_id
    returning * into v_contacto;
  if not found then raise exception 'contacto no encontrado' using errcode = 'P0002'; end if;
  update cuidared.envejeciente e set fecha_actualizacion = now() where e.envejeciente_id = v_env;
  return cuidared_interno.env_contacto(v_contacto);
end;
$$;

-- Convierte el contacto en el principal del adulto; el principal anterior deja de serlo en la misma transacción.
create function cuidared_api.api_principal_contacto(p_cuenta_id bigint, p_contacto_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_env uuid := cuidared_interno.env_contacto_exigir(p_cuenta_id, 'adultos:editar', p_contacto_id);
  v_contacto cuidared.contacto_emergencia;
begin
  perform 1 from cuidared.envejeciente e where e.envejeciente_id = v_env for no key update;
  perform 1 from cuidared.contacto_emergencia c where c.contacto_emergencia_id = p_contacto_id;
  if not found then raise exception 'contacto no encontrado' using errcode = 'P0002'; end if;
  update cuidared.contacto_emergencia c set es_principal = false
    where c.envejeciente_id = v_env and c.es_principal and c.contacto_emergencia_id <> p_contacto_id;
  update cuidared.contacto_emergencia c set es_principal = true
    where c.contacto_emergencia_id = p_contacto_id
    returning * into v_contacto;
  update cuidared.envejeciente e set fecha_actualizacion = now() where e.envejeciente_id = v_env;
  return cuidared_interno.env_contacto(v_contacto);
end;
$$;

/*
 * Elimina un contacto. El adulto nunca queda sin contactos (CR_ULTIMO_CONTACTO) ni sin principal: para eliminar el
 * principal hay que designar antes otro (CR_CONTACTO_PRINCIPAL). Propuesta técnica: sin reasignación automática.
 */
create function cuidared_api.api_eliminar_contacto(p_cuenta_id bigint, p_contacto_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_env uuid := cuidared_interno.env_contacto_exigir(p_cuenta_id, 'adultos:editar', p_contacto_id);
  v_contacto cuidared.contacto_emergencia;
begin
  perform 1 from cuidared.envejeciente e where e.envejeciente_id = v_env for no key update;
  select c.* into v_contacto from cuidared.contacto_emergencia c where c.contacto_emergencia_id = p_contacto_id;
  if not found then raise exception 'contacto no encontrado' using errcode = 'P0002'; end if;
  if (select count(*) from cuidared.contacto_emergencia c where c.envejeciente_id = v_env) <= 1 then
    raise exception 'CR_ULTIMO_CONTACTO' using errcode = 'P0001';
  end if;
  if v_contacto.es_principal then raise exception 'CR_CONTACTO_PRINCIPAL' using errcode = 'P0001'; end if;
  delete from cuidared.contacto_emergencia c where c.contacto_emergencia_id = p_contacto_id;
  update cuidared.envejeciente e set fecha_actualizacion = now() where e.envejeciente_id = v_env;
  return jsonb_build_object('contacto_id', p_contacto_id, 'eliminado', true);
end;
$$;

/* ───────────── 6. Permisos de ejecución ───────────── */

revoke all on function
  cuidared_api.api_crear_envejeciente(bigint, jsonb),
  cuidared_api.api_listar_envejecientes(bigint, text, text, jsonb, integer, integer),
  cuidared_api.api_ver_envejeciente(bigint, uuid),
  cuidared_api.api_editar_envejeciente(bigint, uuid, jsonb),
  cuidared_api.api_estado_envejeciente(bigint, uuid, text, text),
  cuidared_api.api_listar_contactos(bigint, uuid),
  cuidared_api.api_crear_contacto(bigint, uuid, jsonb),
  cuidared_api.api_editar_contacto(bigint, bigint, jsonb),
  cuidared_api.api_principal_contacto(bigint, bigint),
  cuidared_api.api_eliminar_contacto(bigint, bigint)
  from public, anon;
grant execute on function
  cuidared_api.api_crear_envejeciente(bigint, jsonb),
  cuidared_api.api_listar_envejecientes(bigint, text, text, jsonb, integer, integer),
  cuidared_api.api_ver_envejeciente(bigint, uuid),
  cuidared_api.api_editar_envejeciente(bigint, uuid, jsonb),
  cuidared_api.api_estado_envejeciente(bigint, uuid, text, text),
  cuidared_api.api_listar_contactos(bigint, uuid),
  cuidared_api.api_crear_contacto(bigint, uuid, jsonb),
  cuidared_api.api_editar_contacto(bigint, bigint, jsonb),
  cuidared_api.api_principal_contacto(bigint, bigint),
  cuidared_api.api_eliminar_contacto(bigint, bigint)
  to authenticated;

commit;
