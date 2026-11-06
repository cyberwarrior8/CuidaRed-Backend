-- pruebas-3a-esquema.sql — Restricciones del modelo de envejecientes y contactos (fase 3, bloque 3a).
-- Cédula obligatoria y única en toda la plataforma, consentimiento, condición general y contacto principal único.
-- Las inserciones directas se hacen como superusuario: comprueban el modelo, no las RPC. © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('esq.tit1@x.test', '00100000101') as tit1 \gset
select pruebas.usuario('esq.tit2@x.test', '00100000102') as tit2 \gset
select pruebas.cuenta('familia', :'tit1') as cta1 \gset
select pruebas.cuenta('familia', :'tit2') as cta2 \gset

-- Inserta un adulto válido, con los cambios indicados (una clave en null o una clave nueva sustituyen al valor base).
create function pruebas.env_insertar(p_cuenta bigint, p_usuario uuid, p_cedula text, p_cambios jsonb default '{}')
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into cuidared.envejeciente
  select * from jsonb_populate_record(null::cuidared.envejeciente, jsonb_build_object(
    'envejeciente_id', v_id, 'cuenta_id', p_cuenta, 'usuario_registrador_id', p_usuario, 'nombres', 'Rosa',
    'apellidos', 'Pena', 'cedula', p_cedula, 'fecha_nacimiento', '1950-01-01', 'sexo', 'F', 'municipio_cod', '0101',
    'direccion', 'Calle 1', 'estado', 'activo', 'fecha_creacion', now(), 'fecha_actualizacion', now(),
    'zona', 'Centro', 'autonomia', 'parcial', 'condiciones', '[]'::jsonb, 'nota_condicion', null,
    'consentimiento_otorgado', true, 'consentimiento_otorgado_por', 'adulto', 'consentimiento_representante', null,
    'consentimiento_fecha', now(), 'consentimiento_registrado_por', p_usuario) || p_cambios);
  return v_id;
end $$;

select pruebas.env_insertar(:cta1, :'tit1', '00111111111') as a1 \gset
select pruebas.afirmar((select count(*) from cuidared.envejeciente where envejeciente_id = :'a1') = 1, 'perfil válido insertado');

-- Cédula: obligatoria, con formato y única en TODA la plataforma (también entre cuentas).
select pruebas.error(format('select pruebas.env_insertar(%s, %L, null)', :cta1, :'tit1'), '23502');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L)', :cta1, :'tit1', '1234567890'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L)', :cta1, :'tit1', '0011111111a'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L)', :cta1, :'tit1', '00111111111'), '23505');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L)', :cta2, :'tit2', '00111111111'), '23505');
select pruebas.afirmar((select indisunique from pg_index where indexrelid = 'cuidared.uq_envejeciente_cedula'::regclass),
  'índice único global de cédula');
select pruebas.afirmar((select attnotnull from pg_attribute
  where attrelid = 'cuidared.envejeciente'::regclass and attname = 'cedula'), 'cédula NOT NULL');

-- Sin consentimiento no se guarda un perfil (CR-158).
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_otorgado": false}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_otorgado": null}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_otorgado_por": null}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_fecha": null}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_registrado_por": null}'), '23514');
-- Un representante debe indicar su nombre; si consiente el adulto, no hay representante.
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_otorgado_por": "representante"}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_representante": "Maria Perez"}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00122222222',
  '{"consentimiento_otorgado_por": "otro"}'), '23514');
select pruebas.env_insertar(:cta1, :'tit1', '00122222222',
  '{"consentimiento_otorgado_por": "representante", "consentimiento_representante": "Maria Perez"}');

-- Condición general: autonomía y condiciones de lista cerrada; nota de hasta 500 caracteres.
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00133333333',
  '{"autonomia": "total"}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00133333333',
  '{"condiciones": ["cronica", "diabetes"]}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, jsonb_build_object(%L, repeat(%L, 501)))',
  :cta1, :'tit1', '00133333333', 'nota_condicion', 'a'), '23514');
select pruebas.env_insertar(:cta1, :'tit1', '00133333333',
  jsonb_build_object('nota_condicion', repeat('a', 500), 'condiciones', '["cronica","movilidad","cognitivo","sensorial","vive_solo","sin_ingresos","vivienda","aislamiento"]'::jsonb));
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00144444444',
  '{"zona": ""}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00144444444',
  '{"motivo_estado": ""}'), '23514');
select pruebas.error(format('select pruebas.env_insertar(%s, %L, %L, %L)', :cta1, :'tit1', '00144444444',
  '{"sexo": "X"}'), '23514');

-- Contactos: exactamente un principal por adulto (índice único parcial); los no principales no tienen tope en el modelo.
insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal)
values (:'a1', 'Luis', 'Pena', 'Hijo/a', '8095550100', true);
insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal)
values (:'a1', 'Ana', 'Pena', 'Hijo/a', '8095550101', false);
select pruebas.error(format('insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal) values (%L, %L, %L, %L, %L, true)',
  :'a1', 'Eva', 'Pena', 'Hijo/a', '8095550102'), '23505');
select pruebas.error(format('update cuidared.contacto_emergencia set es_principal = true where envejeciente_id = %L and not es_principal', :'a1'), '23505');
select pruebas.error(format('insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono) values (%L, %L, %L, %L, %L)',
  :'a1', 'Eva', 'Pena', 'Hijo/a', '123'), '23514');
-- Otro adulto puede tener su propio principal.
select pruebas.env_insertar(:cta2, :'tit2', '00155555555') as a2 \gset
insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal)
values (:'a2', 'Pedro', 'Diaz', 'Amigo/a', '8095550103', true);

-- Defensa en profundidad: RLS activado y sin acceso directo para los roles de la API.
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.envejeciente'::regclass), 'RLS en envejeciente');
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.contacto_emergencia'::regclass), 'RLS en contacto_emergencia');
select pruebas.afirmar(not has_table_privilege('authenticated', 'cuidared.envejeciente', 'select'), 'authenticated sin select directo');
select pruebas.afirmar(not has_table_privilege('anon', 'cuidared.envejeciente', 'select'), 'anon sin select directo');
select pruebas.afirmar(not has_table_privilege('authenticated', 'cuidared.contacto_emergencia', 'insert'), 'authenticated sin insert directo');

-- Las RPC no están al alcance de anon; las funciones internas no lo están de nadie fuera del propietario.
select pruebas.afirmar(not has_function_privilege('anon', 'cuidared_api.api_crear_envejeciente(bigint, jsonb)', 'execute'), 'anon sin RPC de alta');
select pruebas.afirmar(has_function_privilege('authenticated', 'cuidared_api.api_crear_envejeciente(bigint, jsonb)', 'execute'), 'authenticated con RPC de alta');
select pruebas.afirmar(not has_function_privilege('authenticated', 'cuidared_interno.env_exigir(bigint, text, uuid)', 'execute'), 'interna sin ejecución');
select pruebas.afirmar(not has_schema_privilege('authenticated', 'cuidared_interno', 'usage'), 'esquema interno cerrado');
select pruebas.afirmar((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'cuidared_api' and p.proname in ('api_crear_envejeciente', 'api_listar_envejecientes', 'api_ver_envejeciente',
    'api_editar_envejeciente', 'api_estado_envejeciente', 'api_listar_contactos', 'api_crear_contacto', 'api_editar_contacto',
    'api_principal_contacto', 'api_eliminar_contacto')), 'RPC security definer con search_path vacío');
rollback;
