-- pruebas-4b-agenda.sql — Agenda de cuidado, ejecución y evidencias privadas (fase 4, bloque 4b).
-- Cubre: esquema, autorización por rol y alcance, aislamiento entre cuentas, series, estados, D12 (evidencia
-- validada antes de completar), validación/rechazo, avisos, privilegios y políticas de Storage (con stub local).
-- Los adultos, vínculos y perfiles Cuidador se crean con insert directo como superusuario (las RPC de las fases 2 y 3
-- no son necesarias aquí). Todo corre en una transacción con ROLLBACK. © 2026 Equipo CuidaRed – INTEC.
begin;

/* ───────────── Ayudas (se descartan con el ROLLBACK) ───────────── */
-- Insert directo como superusuario. Con el bloque 3a cargado, un perfil sin consentimiento no se guarda
-- (ck_envejeciente_consentimiento): entonces se registra el consentimiento; sin 3a, el insert es el de DB.sql.
create function pruebas.adulto_4b(p_cuenta bigint, p_cedula text, p_estado text default 'activo') returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_registrador uuid;
begin
  select c.usuario_titular_id into v_registrador from cuidared.cuenta c where c.cuenta_id = p_cuenta;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cuidared' and table_name = 'envejeciente' and column_name = 'consentimiento_otorgado') then
    execute $q$
      insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
                                         municipio_cod, direccion, estado, consentimiento_otorgado, consentimiento_otorgado_por,
                                         consentimiento_fecha, consentimiento_registrado_por)
      values ($1, $2, 'Adulto', 'Mayor ' || $3, $3, date '1945-05-05', 'F', '0101', 'Calle 1', $4, true, 'adulto', now(), $2)
      returning envejeciente_id$q$
      into v_id using p_cuenta, v_registrador, p_cedula, p_estado;
  else
    insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
                                       municipio_cod, direccion, estado)
    values (p_cuenta, v_registrador, 'Adulto', 'Mayor ' || p_cedula, p_cedula, date '1945-05-05', 'F', '0101', 'Calle 1', p_estado)
    returning envejeciente_id into v_id;
  end if;
  return v_id;
end $$;
-- Fecha de negocio utilizable bajo el rol authenticated (cuidared_interno no es accesible para él).
create function pruebas.hoy_4b() returns date
language sql security definer set search_path = '' as $$ select cuidared_interno.hoy() $$;
create function pruebas.vincular_4b(p_adulto uuid, p_usuario uuid, p_tipo text) returns void
language sql security definer set search_path = '' as $$
  insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select p_adulto, p_usuario, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = p_tipo
$$;
create function pruebas.perfil_cuidador_4b(p_cuenta bigint, p_usuario uuid) returns bigint
language sql security definer set search_path = '' as $$
  insert into cuidared.cuidador (usuario_id, tipo_cuidado_id, cuenta_id)
  values (p_usuario, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), p_cuenta)
  returning cuidador_id
$$;
-- Carga útil válida de una tarea; p_extra la sobrescribe (jsonb ||).
create function pruebas.datos_tarea_4b(p_env uuid, p_cuidador bigint, p_prio smallint, p_extra jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('envejeciente_id', p_env, 'cuidador_id', p_cuidador, 'titulo', 'Medir la presión',
    'prioridad_id', p_prio, 'fecha_programada', (cuidared_interno.hoy() + 1)::text, 'hora_programada', '08:00',
    'requiere_evidencia', false) || p_extra
$$;
-- Objeto ya subido al bucket (lo que haría Storage tras la subida firmada).
create function pruebas.objeto_4b(p_ruta text, p_bytes bigint default 1000, p_mime text default 'image/jpeg') returns void
language sql security definer set search_path = '' as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('evidencias', p_ruta, jsonb_build_object('size', p_bytes, 'mimetype', p_mime))
$$;
create function pruebas.ruta_4b(p_cuenta bigint, p_tarea uuid, p_ext text default 'jpg') returns text
language sql set search_path = '' as $$
  select format('cuenta/%s/tarea/%s/%s.%s', p_cuenta, p_tarea, gen_random_uuid(), p_ext)
$$;
create function pruebas.datos_evidencia_4b(p_ruta text, p_extra jsonb default '{}'::jsonb) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('ruta', p_ruta, 'nombre_archivo', 'foto.jpg', 'tipo_mime', 'image/jpeg', 'tamano_bytes', 1000,
    'observacion', 'Tomada tras la visita') || p_extra
$$;

/* ───────────── Escenario ───────────── */
select pruebas.usuario('fam.coord@x.test', '00200000001', 'Patricia') as fam_coord \gset
select pruebas.usuario('fam.cuid1@x.test', '00200000002', 'Carmen') as fam_cuid1 \gset
select pruebas.usuario('fam.cuid2@x.test', '00200000003', 'Cecilia') as fam_cuid2 \gset
select pruebas.usuario('fam.fliar@x.test', '00200000004', 'Felipe') as fam_fliar \gset
select pruebas.usuario('org.admin@x.test', '00200000005', 'Andrea') as org_admin \gset
select pruebas.usuario('org.coord@x.test', '00200000006', 'Laura') as org_coord \gset
select pruebas.usuario('org.cuid@x.test', '00200000007', 'Olga') as org_cuid \gset
select pruebas.usuario('org.vol@x.test', '00200000008', 'Victor') as org_vol \gset
select pruebas.usuario('otra.coord@x.test', '00200000009', 'Omar') as otra_coord \gset
select pruebas.usuario('otra.cuid@x.test', '00200000010', 'Olivia') as otra_cuid \gset
select pruebas.cuenta('familia', :'fam_coord') as cta_fam \gset
select pruebas.cuenta('organizacion', :'org_admin', 'activa', 'Operación Base') as cta_org \gset
select pruebas.cuenta('familia', :'otra_coord') as cta_otra \gset
select pruebas.miembro(:cta_fam, :'fam_cuid1', 'cuidador');
select pruebas.miembro(:cta_fam, :'fam_cuid2', 'cuidador');
select pruebas.miembro(:cta_fam, :'fam_fliar', 'familiar');
select pruebas.miembro(:cta_org, :'org_coord', 'coordinador');
select pruebas.miembro(:cta_org, :'org_cuid', 'cuidador');
select pruebas.miembro(:cta_org, :'org_vol', 'voluntario');
select pruebas.miembro(:cta_otra, :'otra_cuid', 'cuidador');
select pruebas.adulto_4b(:cta_fam, '10000000001') as a1 \gset
select pruebas.adulto_4b(:cta_fam, '10000000002') as a2 \gset
select pruebas.adulto_4b(:cta_fam, '10000000003', 'inactivo') as a_inactivo \gset
select pruebas.adulto_4b(:cta_org, '10000000004') as ao \gset
select pruebas.adulto_4b(:cta_otra, '10000000005') as ax \gset
-- fam_cuid1 cuida a a1; fam_cuid2 cuida a a1 y a2; el familiar solo está vinculado a a1.
select pruebas.vincular_4b(:'a1', :'fam_cuid1', 'cuidador_asignado');
select pruebas.vincular_4b(:'a1', :'fam_cuid2', 'cuidador_asignado');
select pruebas.vincular_4b(:'a2', :'fam_cuid2', 'cuidador_asignado');
select pruebas.vincular_4b(:'a1', :'fam_fliar', 'familiar_responsable');
select pruebas.vincular_4b(:'a_inactivo', :'fam_cuid1', 'cuidador_asignado');
select pruebas.vincular_4b(:'ao', :'org_cuid', 'cuidador_asignado');
select pruebas.vincular_4b(:'ao', :'org_vol', 'voluntario_asignado');
select pruebas.vincular_4b(:'ax', :'otra_cuid', 'cuidador_asignado');
select pruebas.perfil_cuidador_4b(:cta_fam, :'fam_cuid1') as c1 \gset
select pruebas.perfil_cuidador_4b(:cta_fam, :'fam_cuid2') as c2 \gset
select pruebas.perfil_cuidador_4b(:cta_org, :'org_cuid') as co \gset
select pruebas.perfil_cuidador_4b(:cta_otra, :'otra_cuid') as cx \gset
-- Perfil de la coordinadora (tiene perfil Cuidador pero su rol no ejecuta tareas) y perfil vencido.
select pruebas.perfil_cuidador_4b(:cta_fam, :'fam_coord') as c_coord \gset
select pruebas.perfil_cuidador_4b(:cta_fam, :'fam_fliar') as c_fliar \gset
-- Cuidadora con vínculo pero con el perfil Cuidador ya finalizado.
select pruebas.usuario('fam.cuid3@x.test', '00200000013', 'Carla') as fam_cuid3 \gset
select pruebas.miembro(:cta_fam, :'fam_cuid3', 'cuidador');
select pruebas.vincular_4b(:'a1', :'fam_cuid3', 'cuidador_asignado');
select pruebas.perfil_cuidador_4b(:cta_fam, :'fam_cuid3') as c_old \gset
update cuidared.cuidador set fecha_fin = pruebas.hoy_4b() - 1 where cuidador_id = :c_old;
insert into cuidared.prioridad (nombre, orden) values ('Alta', 1), ('Media', 2), ('Baja', 3) on conflict do nothing;
select prioridad_id as prio from cuidared.prioridad where nombre = 'Media' \gset
insert into cuidared.tipo_indicacion (nombre) values ('Medicamento') on conflict do nothing;
select tipo_indicacion_id as tipo_ind from cuidared.tipo_indicacion where nombre = 'Medicamento' \gset
insert into cuidared.indicacion_medica (envejeciente_id, tipo_indicacion_id, titulo) values (:'a1', :tipo_ind, 'Metformina 850 mg') returning indicacion_medica_id as ind_a1 \gset
insert into cuidared.indicacion_medica (envejeciente_id, tipo_indicacion_id, titulo) values (:'a2', :tipo_ind, 'Losartán 50 mg') returning indicacion_medica_id as ind_a2 \gset

/* ───────────── Esquema ───────────── */
select pruebas.afirmar((select count(*) from information_schema.columns where table_schema = 'cuidared' and table_name = 'tarea_agenda'
  and column_name in ('serie_id', 'motivo_cancelacion', 'cancelada_por', 'completada_por', 'fecha_completada', 'actualizado_por')) = 6,
  'columnas nuevas de tarea_agenda');
select pruebas.afirmar((select count(*) from information_schema.columns where table_schema = 'cuidared' and table_name = 'evidencia'
  and column_name in ('registrada_por', 'validada_por', 'fecha_validacion', 'motivo_rechazo', 'nombre_archivo', 'tipo_mime', 'tamano_bytes')) = 7,
  'columnas nuevas de evidencia');
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.tarea_agenda'::regclass)
  and (select relrowsecurity from pg_class where oid = 'cuidared.evidencia'::regclass), 'RLS en tarea_agenda y evidencia');
select pruebas.afirmar((select count(*) from storage.buckets where id = 'evidencias' and not public
  and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']) = 1,
  'bucket privado de 5 MB con los cuatro tipos');

/* ───────────── Privilegios: sin acceso directo ni RPC para anónimos ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error('select count(*) from cuidared.tarea_agenda', '42501');
select pruebas.error('select count(*) from cuidared.evidencia', '42501');
select pruebas.error('select cuidared_interno.tarea_json(null)', '42501');
reset role;
set local role anon;
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s)', :cta_fam), '42501');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, '{}'), '42501');
select pruebas.error(format('select cuidared_storage.evidencia_permitida(%L, %L)', 'x', 'ver'), '42501');
reset role;
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s)', :cta_fam), '28000');
reset role;

/* ───────────── Crear tareas: autorización y reglas ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
-- El Coordinador de Familia crea una tarea puntual para c1 (cuidador de a1). Recibe fecha, hora y prioridad.
select (cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('titulo', '  Medir la presión  ', 'indicacion_medica_id', :'ind_a1', 'requiere_evidencia', true))))->'tareas'->0->>'tarea_id' as t1 \gset
select pruebas.afirmar(:'t1' is not null, 'tarea puntual creada');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'titulo') = 'Medir la presión', 'título recortado');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'estado') = 'pendiente'
  and (cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'hora_programada') = '08:00'
  and (cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'prioridad') = 'Media'
  and (cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'indicacion_titulo') = 'Metformina 850 mg'
  and (cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'es_repetitiva') = 'false'
  and (cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'serie_id') is null, 'estado inicial y datos de la tarea');
reset role;
select pruebas.afirmar((select usuario_creador_id::text = :'fam_coord' and actualizado_por::text = :'fam_coord'
  from cuidared.tarea_agenda where tarea_agenda_id = :'t1'), 'autoría tomada de la sesión');
select pruebas.afirmar((select count(*) from cuidared.notificacion where usuario_id = :'fam_cuid1' and cuenta_id = :cta_fam
  and mensaje like 'Se te asignó la tarea «Medir la presión»%') = 1, 'aviso al cuidador asignado');
set local role authenticated;

-- Sin hora: es opcional. Tarea de hoy: se admite (no es pasada).
select pruebas.afirmar((cuidared_api.api_tarea_crear(:cta_fam, (pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('fecha_programada', pruebas.hoy_4b()::text, 'titulo', 'Sin hora')) - 'hora_programada'))
  ->'tareas'->0->>'hora_programada') is null, 'hora opcional y fecha de hoy permitida');

-- Entradas inválidas: 22023.
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"fecha_programada":"2020-01-01"}')), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"titulo":"ab"}')), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"hora_programada":"25:00"}')), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"requiere_evidencia":"si"}')), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"campo_extra":1}')), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, 999::smallint)), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"envejeciente_id":"no-es-uuid"}')), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, '[]'), '22023');

-- Adulto de otra cuenta o inexistente: no existe (P0002); adulto inactivo: estado inválido.
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'ax', :c1, :prio::smallint)), 'P0002');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(gen_random_uuid(), :c1, :prio::smallint)), 'P0002');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a_inactivo', :c1, :prio::smallint)), 'P0001', 'CR_ESTADO_INVALIDO');

-- Cuidador: sin vínculo con el adulto, de otra cuenta, inexistente, con perfil vencido o con rol que no ejecuta.
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a2', :c1, :prio::smallint)), 'P0001', 'CR_CUIDADOR_NO_ASIGNADO');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :cx, :prio::smallint)), 'P0001', 'CR_CUIDADOR_NO_ASIGNADO');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', 999999, :prio::smallint)), 'P0001', 'CR_CUIDADOR_NO_ASIGNADO');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c_fliar, :prio::smallint)), 'P0001', 'CR_CUIDADOR_NO_ASIGNADO');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c_old, :prio::smallint)), 'P0001', 'CR_CUIDADOR_NO_ASIGNADO');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c_coord, :prio::smallint)), 'P0001', 'CR_CUIDADOR_NO_ASIGNADO');

-- Indicación de otro adulto.
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, jsonb_build_object('indicacion_medica_id', :'ind_a2'))), 'P0001', 'CR_INDICACION_NO_CORRESPONDE');
reset role;

-- Gestionar la agenda exige agenda:gestionar: Cuidador, Familiar y Voluntario no crean tareas; quien no es miembro, tampoco.
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint)), '42501');
reset role;
select pruebas.como(:'fam_fliar');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint)), '42501');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s)', :cta_fam), '42501');   -- el Familiar no tiene agenda:ver
reset role;
select pruebas.como(:'org_vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s)', :cta_org), '42501');
reset role;
select pruebas.como(:'otra_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam,
  pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint)), '42501');
reset role;

-- Organización: el Coordinador crea; el Administrador también (agenda:gestionar).
select pruebas.como(:'org_coord');
set local role authenticated;
select (cuidared_api.api_tarea_crear(:cta_org, pruebas.datos_tarea_4b(:'ao', :co, :prio::smallint)))->'tareas'->0->>'tarea_id' as t_org \gset
select pruebas.afirmar(:'t_org' is not null, 'Coordinador de Organización crea tarea');
reset role;
select pruebas.como(:'org_admin');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_crear(:cta_org, pruebas.datos_tarea_4b(:'ao', :co, :prio::smallint, '{"titulo":"Tarea del administrador"}'))
  ->'tareas'->0->>'tarea_id') is not null, 'Administrador de Organización crea tarea');
reset role;

/* ───────────── Series (propuesta técnica D12) ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
-- Semanal: lunes (1) y miércoles (3) durante 4 semanas. Una tarea por ocurrencia con serie_id común.
select cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, jsonb_build_object(
  'titulo', 'Ejercicios', 'fecha_programada', pruebas.hoy_4b()::text, 'requiere_evidencia', false,
  'repeticion', jsonb_build_object('frecuencia', 'semanal', 'dias_semana', jsonb_build_array(1, 3), 'hasta', (pruebas.hoy_4b() + 27)::text)))) as serie \gset
select pruebas.afirmar(jsonb_array_length((:'serie'::jsonb)->'tareas') = (
  select count(*) from generate_series(pruebas.hoy_4b()::timestamp, (pruebas.hoy_4b() + 27)::timestamp, interval '1 day') d
  where extract(isodow from d) in (1, 3)), 'semanal: una tarea por lunes y miércoles');
select pruebas.afirmar((select count(distinct t->>'serie_id') = 1 and bool_and(t->>'serie_id' = (:'serie'::jsonb)->>'serie_id')
  and bool_and((t->>'es_repetitiva')::boolean) from jsonb_array_elements((:'serie'::jsonb)->'tareas') t), 'serie_id común y es_repetitiva');
select pruebas.afirmar((select bool_and(extract(isodow from (t->>'fecha_programada')::date) in (1, 3))
  from jsonb_array_elements((:'serie'::jsonb)->'tareas') t), 'solo los días elegidos');
-- Diaria: un mes de 10 días = 10 tareas.
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, jsonb_build_object(
  'titulo', 'Diaria', 'repeticion', jsonb_build_object('frecuencia', 'diaria', 'hasta', (pruebas.hoy_4b() + 10)::text))))->'tareas') = 10,
  'diaria: de mañana a hoy+10');
-- Exactamente 60 ocurrencias: se admite; 61: CR_REPETICION_INVALIDA.
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, jsonb_build_object(
  'titulo', 'Sesenta', 'fecha_programada', pruebas.hoy_4b()::text,
  'repeticion', jsonb_build_object('frecuencia', 'diaria', 'hasta', (pruebas.hoy_4b() + 59)::text))))->'tareas') = 60, 'tope de 60 ocurrencias');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('fecha_programada', pruebas.hoy_4b()::text,
    'repeticion', jsonb_build_object('frecuencia', 'diaria', 'hasta', (pruebas.hoy_4b() + 60)::text)))), 'P0001', 'CR_REPETICION_INVALIDA');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('repeticion', jsonb_build_object('frecuencia', 'diaria', 'hasta', pruebas.hoy_4b()::text)))), 'P0001', 'CR_REPETICION_INVALIDA');   -- fin anterior al inicio (inicio es mañana)
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('repeticion', jsonb_build_object('frecuencia', 'semanal', 'hasta', (pruebas.hoy_4b() + 20)::text)))), 'P0001', 'CR_REPETICION_INVALIDA');   -- semanal sin días
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('repeticion', jsonb_build_object('frecuencia', 'semanal', 'dias_semana', jsonb_build_array(0, 8), 'hasta', (pruebas.hoy_4b() + 20)::text)))),
  'P0001', 'CR_REPETICION_INVALIDA');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('repeticion', jsonb_build_object('frecuencia', 'diaria', 'dias_semana', jsonb_build_array(1), 'hasta', (pruebas.hoy_4b() + 5)::text)))),
  'P0001', 'CR_REPETICION_INVALIDA');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('repeticion', jsonb_build_object('frecuencia', 'mensual', 'hasta', (pruebas.hoy_4b() + 5)::text)))), 'P0001', 'CR_REPETICION_INVALIDA');
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint,
  jsonb_build_object('repeticion', jsonb_build_object('frecuencia', 'diaria', 'hasta', (pruebas.hoy_4b() + 900)::text)))), 'P0001', 'CR_REPETICION_INVALIDA');
reset role;
-- Un rechazo no deja filas a medias.
select pruebas.afirmar((select count(*) from cuidared.tarea_agenda where titulo like 'Sesenta%') = 60, 'sin tareas parciales');

/* ───────────── Listado: alcance, filtros, orden y paginación ───────────── */
-- Tareas de c2 en a2 (para distinguir entre cuidadores).
select pruebas.como(:'fam_coord');
set local role authenticated;
select (cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a2', :c2, :prio::smallint, '{"titulo":"Tarea de Cecilia"}')))->'tareas'->0->>'tarea_id' as t2 \gset
reset role;

select pruebas.como(:'fam_cuid1');
set local role authenticated;
-- El Cuidador ve solo las de su perfil en la cuenta (nunca la de Cecilia).
select pruebas.afirmar((select count(*) from jsonb_array_elements(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[]', 100, 0)->'data') t
  where (t->>'cuidador_id')::bigint <> :c1) = 0, 'el cuidador solo ve sus tareas');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam)->>'total')::int = (
  select count(*) from (select 1 from jsonb_array_elements(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[]', 100, 0)->'data')) q)
  and (cuidared_api.api_tareas_listar(:cta_fam)->>'total')::int > 20, 'total consistente y mayor que una página');
-- Tarea de otro cuidador del mismo adulto o de otra cuenta: 404 (no se revela).
select pruebas.error(format('select cuidared_api.api_tarea_obtener(%s, %L)', :cta_fam, :'t2'), 'P0002');
select pruebas.error(format('select cuidared_api.api_tarea_obtener(%s, %L)', :cta_fam, :'t_org'), 'P0002');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'tarea_id') = :'t1', 'el cuidador ve la suya');
reset role;

select count(*) as n_fam from cuidared.tarea_agenda t join cuidared.envejeciente e using (envejeciente_id) where e.cuenta_id = :cta_fam \gset
select max(fecha_programada)::text as max_fecha from cuidared.tarea_agenda t join cuidared.envejeciente e using (envejeciente_id) where e.cuenta_id = :cta_fam \gset
select pruebas.como(:'fam_coord');
set local role authenticated;
-- El Coordinador ve las de todos los cuidadores de su cuenta y ninguna de otras cuentas.
select pruebas.afirmar((select count(*) from jsonb_array_elements(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[]', 100, 0)->'data') t
  where t->>'tarea_id' = :'t2') = 1, 'el coordinador ve la tarea de otro cuidador');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam)->>'total')::bigint = :n_fam, 'total = solo tareas de la cuenta');
-- Filtros.
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, jsonb_build_object('cuidador_id', :c2))->>'total')::int = 1, 'filtro por cuidador');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, jsonb_build_object('envejeciente_id', :'a2'))->>'total')::int = 1, 'filtro por adulto');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, '{"estado":"completada"}')->>'total')::int = 0, 'filtro por estado');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, jsonb_build_object('desde', (pruebas.hoy_4b() + 1)::text,
  'hasta', (pruebas.hoy_4b() + 1)::text, 'cuidador_id', :c1))->>'total')::int >= 1, 'filtro por rango de fechas (inclusivo)');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, jsonb_build_object('desde', (pruebas.hoy_4b() + 3000)::text))->>'total')::int = 0,
  'rango sin resultados');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, jsonb_build_object('envejeciente_id', :'ax'))->>'total')::int = 0,
  'filtrar por adulto de otra cuenta no devuelve nada');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb)', :cta_fam, '{"estado":"borrada"}'), '22023');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb)', :cta_fam, '{"columna":"x"}'), '22023');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb)', :cta_fam, '{"desde":"2026-12-31","hasta":"2026-01-01"}'), '22023');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb, %L::jsonb)', :cta_fam, '{}', '[{"campo":"titulo; drop table x","direccion":"asc"}]'), '22023');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb, %L::jsonb)', :cta_fam, '{}', '[{"campo":"estado","direccion":"sideways"}]'), '22023');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb, %L::jsonb, 101, 0)', :cta_fam, '{}', '[]'), '22023');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s, %L::jsonb, %L::jsonb, 10, -1)', :cta_fam, '{}', '[]'), '22023');
-- Orden y paginación estables: la unión de páginas no repite ni omite tareas.
select pruebas.afirmar((
  select count(distinct t->>'tarea_id') = 30 from (
    select jsonb_array_elements(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[{"campo":"fecha_programada","direccion":"desc"},{"campo":"tarea_id","direccion":"asc"}]', 10, 0)->'data') t
    union all select jsonb_array_elements(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[{"campo":"fecha_programada","direccion":"desc"},{"campo":"tarea_id","direccion":"asc"}]', 10, 10)->'data')
    union all select jsonb_array_elements(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[{"campo":"fecha_programada","direccion":"desc"},{"campo":"tarea_id","direccion":"asc"}]', 10, 20)->'data')) q),
  'tres páginas de 10 sin repetidos');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, '{}', '[{"campo":"fecha_programada","direccion":"desc"}]', 1, 0)->'data'->0->>'fecha_programada') = :'max_fecha', 'orden descendente por fecha');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_tareas_listar(:cta_fam, '{}', '[]', 10, 100000)->'data') = 0
  and (cuidared_api.api_tareas_listar(:cta_fam, '{}', '[]', 10, 100000)->>'total')::int > 0, 'página fuera del conjunto: vacía con total');
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_fam, '{}', '[{"campo":"prioridad","direccion":"asc"},{"campo":"hora_programada","direccion":"desc"}]', 5, 0)->'data'->0->>'tarea_id') is not null,
  'orden por prioridad y hora');
-- Otra cuenta: sus tareas no aparecen en la mía ni se alcanzan con su id.
select pruebas.error(format('select cuidared_api.api_tarea_obtener(%s, %L)', :cta_fam, :'t_org'), 'P0002');
reset role;
select pruebas.como(:'otra_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tareas_listar(:cta_otra)->>'total')::int = 0, 'otra cuenta: sin tareas');
select pruebas.error(format('select cuidared_api.api_tarea_obtener(%s, %L)', :cta_otra, :'t1'), 'P0002');
select pruebas.error(format('select cuidared_api.api_tarea_cancelar(%s, %L, %L)', :cta_otra, :'t1', 'Intento ajeno'), 'P0002');
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_otra, :'t1', '{"titulo":"Hackeada"}'), 'P0002');
select pruebas.error(format('select cuidared_api.api_tarea_obtener(%s, %L)', :cta_fam, :'t1'), '42501');   -- sin membresía en esa cuenta
reset role;

/* ───────────── Editar tareas pendientes ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_actualizar(:cta_fam, :'t2', jsonb_build_object('titulo', 'Cambio de título', 'cuidador_id', :c2,
  'prioridad_id', :prio, 'hora_programada', null, 'requiere_evidencia', true))->>'titulo') = 'Cambio de título', 'edición de campos');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t2')->>'hora_programada') is null
  and (cuidared_api.api_tarea_obtener(:cta_fam, :'t2')->>'requiere_evidencia')::boolean, 'hora quitada y evidencia requerida');
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t2', '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t2', '{"alcance":"esta"}'), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t2', '{"estado":"completada"}'), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t2', '{"fecha_programada":"2020-01-01"}'), '22023');
-- No se puede asignar a un cuidador sin vínculo con ese adulto, ni cambiar el estado por esta vía.
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t2', jsonb_build_object('cuidador_id', :c1)),
  'P0001', 'CR_CUIDADOR_NO_ASIGNADO');
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t2', jsonb_build_object('indicacion_medica_id', :'ind_a1')),
  'P0001', 'CR_INDICACION_NO_CORRESPONDE');
-- Reasignar a otro cuidador de a1: avisa al nuevo y al anterior.
select pruebas.afirmar((cuidared_api.api_tarea_actualizar(:cta_fam, :'t1', jsonb_build_object('cuidador_id', :c2))->>'cuidador_id')::bigint = :c2, 'reasignación');
reset role;
select pruebas.afirmar((select count(*) from cuidared.notificacion where usuario_id = :'fam_cuid2' and mensaje like 'Se te asignó la tarea «Medir la presión»%') = 1
  and (select count(*) from cuidared.notificacion where usuario_id = :'fam_cuid1' and mensaje like 'La tarea «Medir la presión»%ya no está asignada a ti.') = 1,
  'avisos al nuevo y al anterior cuidador');
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_tarea_actualizar(:cta_fam, :'t1', jsonb_build_object('cuidador_id', :c1));    -- vuelve a c1 para el resto
-- «Esta y las siguientes»: cambia el título de las ocurrencias pendientes desde la tercera.
select (t->>'tarea_id') as s3 from jsonb_array_elements((:'serie'::jsonb)->'tareas') with ordinality x(t, n) where n = 3 \gset
select pruebas.afirmar(cuidared_api.api_tarea_actualizar(:cta_fam, :'s3', '{"titulo":"Ejercicios nuevos","alcance":"siguientes"}') is not null, 'editar siguientes');
reset role;
select pruebas.afirmar((select count(*) from cuidared.tarea_agenda where serie_id = ((:'serie'::jsonb)->>'serie_id')::uuid and titulo = 'Ejercicios nuevos')
  = jsonb_array_length((:'serie'::jsonb)->'tareas') - 2, 'solo la tercera y las siguientes cambiaron');
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'s3',
  jsonb_build_object('fecha_programada', (pruebas.hoy_4b() + 40)::text, 'alcance', 'siguientes')), '22023');
reset role;

/* ───────────── Iniciar y completar: solo el cuidador asignado ───────────── */
select pruebas.como(:'fam_cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_iniciar(%s, %L)', :cta_fam, :'t1'), 'P0002');         -- tarea de c1: no la ve
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_iniciar(%s, %L)', :cta_fam, :'t1'), '42501');         -- agenda:ejecutar es del Cuidador
select pruebas.error(format('select cuidared_api.api_tarea_completar(%s, %L)', :cta_fam, :'t1'), '42501');
reset role;
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_iniciar(:cta_fam, :'t1')->>'estado') = 'en_progreso', 'iniciar');
select pruebas.error(format('select cuidared_api.api_tarea_iniciar(%s, %L)', :cta_fam, :'t1'), 'P0001', 'CR_ESTADO_INVALIDO');
-- Editar solo pendientes.
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_actualizar(%s, %L, %L::jsonb)', :cta_fam, :'t1', '{"titulo":"Ya en curso"}'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;

/* ───────────── Evidencias: subida, registro y reglas de archivo ───────────── */
select pruebas.como(:'fam_cuid1');
set local role authenticated;
-- Preparar la subida: la ruta la genera la base con cuenta y tarea; el cliente no la elige.
select (cuidared_api.api_evidencia_preparar_subida(:cta_fam, :'t1', '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'))->>'ruta' as ruta1 \gset
select pruebas.afirmar(:'ruta1' ~ ('^cuenta/' || :cta_fam || '/tarea/' || :'t1' || '/[0-9a-f-]{36}\.jpg$'), 'ruta cuenta/<cuenta>/tarea/<tarea>/<uuid>.<ext>');
select pruebas.afirmar((cuidared_api.api_evidencia_preparar_subida(:cta_fam, :'t1', '{"nombre_archivo":"a.pdf","tipo_mime":"application/pdf","tamano_bytes":5242880}')->>'ruta') ~ '\.pdf$',
  'PDF de exactamente 5 MB permitido');
select pruebas.afirmar((cuidared_api.api_evidencia_preparar_subida(:cta_fam, :'t1', '{"nombre_archivo":"a.png","tipo_mime":"image/png","tamano_bytes":10}')->>'ruta') ~ '\.png$'
  and (cuidared_api.api_evidencia_preparar_subida(:cta_fam, :'t1', '{"nombre_archivo":"a.webp","tipo_mime":"image/webp","tamano_bytes":10}')->>'ruta') ~ '\.webp$', 'PNG y WEBP permitidos');
-- RS-013: tipo y tamaño.
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"a.pdf","tipo_mime":"application/pdf","tamano_bytes":5242881}'), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"a.gif","tipo_mime":"image/gif","tamano_bytes":100}'), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"a.jpg","tipo_mime":"image/jpeg","tamano_bytes":0}'), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"../a.jpg","tipo_mime":"image/jpeg","tamano_bytes":100}'), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"a.jpg","tipo_mime":"image/jpeg","tamano_bytes":99999999999}'), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"a.jpg","tipo_mime":"image/jpeg","tamano_bytes":"mucho"}'), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"a.jpg","tipo_mime":"image/jpeg","tamano_bytes":10,"ruta":"x"}'), '22023');
-- Solo el cuidador asignado puede preparar subidas: otro cuidador (404) o quien no ejecuta (403).
reset role;
select pruebas.como(:'fam_cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'), 'P0002');
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'), '42501');
reset role;

-- Registrar: la ruta debe ser de esta cuenta y tarea, y el objeto debe existir en el bucket.
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1', pruebas.datos_evidencia_4b(:'ruta1')),
  'P0001', 'CR_ARCHIVO_NO_SUBIDO');                                                    -- aún no se subió
reset role;
select pruebas.objeto_4b(:'ruta1', 1000, 'image/jpeg');
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  pruebas.datos_evidencia_4b(pruebas.ruta_4b(:cta_otra, :'t1'))), 'P0001', 'CR_ARCHIVO_INVALIDO');        -- ruta de otra cuenta
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  pruebas.datos_evidencia_4b(pruebas.ruta_4b(:cta_fam, :'t2'))), 'P0001', 'CR_ARCHIVO_INVALIDO');         -- ruta de otra tarea
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  pruebas.datos_evidencia_4b('cuenta/../../otra.jpg')), 'P0001', 'CR_ARCHIVO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  pruebas.datos_evidencia_4b(:'ruta1', '{"tipo_mime":"application/pdf"}')), 'P0001', 'CR_ARCHIVO_INVALIDO');   -- la extensión no corresponde al tipo
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  pruebas.datos_evidencia_4b(:'ruta1', '{"tamano_bytes":999}')), 'P0001', 'CR_ARCHIVO_INVALIDO');           -- no coincide con el objeto subido
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  pruebas.datos_evidencia_4b(:'ruta1', jsonb_build_object('observacion', repeat('x', 301)))), '22023');
select cuidared_api.api_evidencia_registrar(:cta_fam, :'t1', pruebas.datos_evidencia_4b(:'ruta1'))->>'evidencia_id' as ev1 \gset
select pruebas.afirmar(:'ev1' is not null, 'evidencia registrada');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->'evidencias'->>'pendientes') = '1', 'resumen: una pendiente');
-- La misma ruta no se registra dos veces (23505 → 409).
select pruebas.error(format('select cuidared_api.api_evidencia_registrar(%s, %L, %L::jsonb)', :cta_fam, :'t1', pruebas.datos_evidencia_4b(:'ruta1')), '23505');
reset role;
select pruebas.afirmar((select registrada_por::text = :'fam_cuid1' and estado_validacion = 'pendiente' and validada_por is null
  and tamano_bytes = 1000 and tipo_mime = 'image/jpeg' from cuidared.evidencia where evidencia_id = :'ev1'), 'nace pendiente, autoría de la sesión');

-- Sin validar, completar sigue bloqueado (D12): tarea que requiere evidencia con una pendiente.
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_completar(%s, %L)', :cta_fam, :'t1'), 'P0001', 'CR_EVIDENCIA_REQUERIDA');
-- Listar: el cuidador ve las evidencias de su tarea con ruta interna (para firmar); otro cuidador no ve la tarea.
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_evidencias_listar(:cta_fam, :'t1')) = 1
  and (cuidared_api.api_evidencias_listar(:cta_fam, :'t1')->0->>'ruta') = :'ruta1', 'listar evidencias con ruta interna');
reset role;
select pruebas.como(:'fam_cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencias_listar(%s, %L)', :cta_fam, :'t1'), 'P0002');
reset role;
select pruebas.como(:'fam_fliar');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencias_listar(%s, %L)', :cta_fam, :'t1'), '42501');
reset role;

/* ───────────── Validar y rechazar ───────────── */
-- Quien no tiene evidencias:validar: 403 (cuidador, familiar, voluntario).
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_validar(%s, %L)', :cta_fam, :'ev1'), '42501');
select pruebas.error(format('select cuidared_api.api_evidencia_rechazar(%s, %L, %L)', :cta_fam, :'ev1', 'No se ve bien la foto'), '42501');
reset role;
-- El coordinador de otra cuenta: la evidencia no existe en SU cuenta (P0002), ni con su propio cuentaId ni con el ajeno.
select pruebas.como(:'otra_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_validar(%s, %L)', :cta_otra, :'ev1'), 'P0002');
select pruebas.error(format('select cuidared_api.api_evidencia_rechazar(%s, %L, %L)', :cta_otra, :'ev1', 'No se ve bien la foto'), 'P0002');
select pruebas.error(format('select cuidared_api.api_evidencia_validar(%s, %L)', :cta_fam, :'ev1'), '42501');
select pruebas.error(format('select cuidared_api.api_evidencia_validar(%s, %L)', :cta_otra, gen_random_uuid()), 'P0002');
reset role;

select pruebas.como(:'fam_coord');
set local role authenticated;
-- El rechazo exige motivo (5 a 200 caracteres).
select pruebas.error(format('select cuidared_api.api_evidencia_rechazar(%s, %L, %L)', :cta_fam, :'ev1', ''), '22023');
select pruebas.error(format('select cuidared_api.api_evidencia_rechazar(%s, %L, %L)', :cta_fam, :'ev1', 'No'), '22023');
select pruebas.error(format('select cuidared_api.api_evidencia_rechazar(%s, %L, %L)', :cta_fam, :'ev1', repeat('x', 201)), '22023');
select pruebas.error(format('select cuidared_api.api_evidencia_rechazar(%s, %L, null)', :cta_fam, :'ev1'), '22023');
-- Rechazar con la tarea en progreso: la devuelve a pendiente con el motivo visible.
select pruebas.afirmar((cuidared_api.api_evidencia_rechazar(:cta_fam, :'ev1', 'La foto está borrosa')->'tarea'->>'estado') = 'pendiente', 'rechazo devuelve la tarea a pendiente');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'ultimo_motivo_rechazo') = 'La foto está borrosa', 'motivo de rechazo visible');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->'evidencias'->>'rechazadas') = '1', 'resumen: una rechazada');
-- Ya revisada: no se revisa de nuevo.
select pruebas.error(format('select cuidared_api.api_evidencia_validar(%s, %L)', :cta_fam, :'ev1'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;
select pruebas.afirmar((select estado_validacion = 'rechazada' and validada_por::text = :'fam_coord' and fecha_validacion is not null
  and motivo_rechazo = 'La foto está borrosa' from cuidared.evidencia where evidencia_id = :'ev1'), 'guarda quién, cuándo y por qué');
select pruebas.afirmar((select count(*) from cuidared.notificacion where usuario_id = :'fam_cuid1'
  and mensaje like 'Tu evidencia de la tarea «Medir la presión» fue rechazada: La foto está borrosa.%') = 1, 'aviso de rechazo al cuidador');
select pruebas.afirmar((select count(*) from cuidared.notificacion where usuario_id = :'fam_coord' and mensaje like 'Tu evidencia%') = 0,
  'quien revisa no se avisa a sí mismo');

-- Un rechazo no satisface D12: sigue sin poder completar. La nueva evidencia validada completa la tarea.
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_iniciar(:cta_fam, :'t1')->>'estado') = 'en_progreso', 'reinicia tras el rechazo');
select pruebas.error(format('select cuidared_api.api_tarea_completar(%s, %L)', :cta_fam, :'t1'), 'P0001', 'CR_EVIDENCIA_REQUERIDA');
reset role;
select pruebas.ruta_4b(:cta_fam, :'t1', 'png') as ruta2 \gset
select pruebas.objeto_4b(:'ruta2', 2000, 'image/png');
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select cuidared_api.api_evidencia_registrar(:cta_fam, :'t1', pruebas.datos_evidencia_4b(:'ruta2',
  '{"nombre_archivo":"foto.png","tipo_mime":"image/png","tamano_bytes":2000}'))->>'evidencia_id' as ev2 \gset
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t1')->>'ultimo_motivo_rechazo') is null, 'sin motivo visible si espera revisión');
select cuidared_api.api_evidencia_validar(:cta_fam, :'ev2') as res_val \gset
select pruebas.afirmar((:'res_val'::jsonb->>'tarea_completada')::boolean and (:'res_val'::jsonb->'tarea'->>'estado') = 'completada'
  and (:'res_val'::jsonb->'evidencia'->>'estado_validacion') = 'validada', 'validar completa la tarea que requiere evidencia');
reset role;
select pruebas.afirmar((select estado = 'completada' and completada_por::text = :'fam_coord' and fecha_completada is not null
  from cuidared.tarea_agenda where tarea_agenda_id = :'t1'), 'completada por quien valida');
select pruebas.afirmar((select count(*) from cuidared.notificacion where usuario_id = :'fam_cuid1'
  and mensaje = 'Tu evidencia de la tarea «Medir la presión» fue validada. La tarea quedó completada.') = 1, 'aviso de validación al cuidador');

-- Una tarea cerrada no admite más evidencias, ni inicio, ni cancelación.
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t1',
  '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_tarea_completar(%s, %L)', :cta_fam, :'t1'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_cancelar(%s, %L, %L)', :cta_fam, :'t1', 'Ya no hace falta'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;

/* ───────────── D12: completar con evidencia validada (el cuidador) y sin evidencia requerida ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
-- Tarea que NO requiere evidencia: el cuidador la completa sin adjuntar nada.
select (cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"titulo":"Sin evidencia"}')))->'tareas'->0->>'tarea_id' as t_sin \gset
-- Tarea que requiere evidencia, con una evidencia validada de antemano y la exigencia añadida después.
select (cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"titulo":"Evidencia previa"}')))->'tareas'->0->>'tarea_id' as t_prev \gset
reset role;
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_completar(:cta_fam, :'t_sin')->>'estado') = 'completada', 'completar sin evidencia requerida (desde pendiente)');
reset role;
select pruebas.ruta_4b(:cta_fam, :'t_prev', 'pdf') as ruta3 \gset
select pruebas.objeto_4b(:'ruta3', 3000, 'application/pdf');
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select cuidared_api.api_evidencia_registrar(:cta_fam, :'t_prev', pruebas.datos_evidencia_4b(:'ruta3',
  '{"nombre_archivo":"receta.pdf","tipo_mime":"application/pdf","tamano_bytes":3000}'))->>'evidencia_id' as ev3 \gset
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar(not (cuidared_api.api_evidencia_validar(:cta_fam, :'ev3')->>'tarea_completada')::boolean,
  'validar una evidencia de una tarea que no la exige no la completa');
select pruebas.afirmar((cuidared_api.api_tarea_actualizar(:cta_fam, :'t_prev', '{"requiere_evidencia":true}')->>'estado') = 'pendiente', 'se exige evidencia después');
reset role;
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_tarea_completar(:cta_fam, :'t_prev')->>'estado') = 'completada', 'el cuidador completa con evidencia validada');
reset role;
select pruebas.afirmar((select completada_por::text = :'fam_cuid1' from cuidared.tarea_agenda where tarea_agenda_id = :'t_prev'), 'completada_por = cuidador');

/* ───────────── Cancelar: esta o las siguientes ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_cancelar(%s, %L, %L)', :cta_fam, :'s3', ''), '22023');
select pruebas.error(format('select cuidared_api.api_tarea_cancelar(%s, %L, %L, %L)', :cta_fam, :'s3', 'Motivo válido', 'todas'), '22023');
select pruebas.afirmar((cuidared_api.api_tarea_cancelar(:cta_fam, :'s3', 'La terapia termina antes', 'siguientes')->>'canceladas')::int
  = jsonb_array_length((:'serie'::jsonb)->'tareas') - 2, 'cancelar esta y las siguientes');
reset role;
select pruebas.afirmar((select count(*) = jsonb_array_length((:'serie'::jsonb)->'tareas') - 2 and bool_and(cancelada_por::text = :'fam_coord')
  and bool_and(motivo_cancelacion = 'La terapia termina antes') from cuidared.tarea_agenda
  where serie_id = ((:'serie'::jsonb)->>'serie_id')::uuid and estado = 'cancelada'), 'motivo y autor de la cancelación');
select pruebas.afirmar((select count(*) from cuidared.tarea_agenda where serie_id = ((:'serie'::jsonb)->>'serie_id')::uuid and estado = 'pendiente') = 2,
  'las anteriores siguen pendientes');
select pruebas.afirmar((select count(*) from cuidared.notificacion where usuario_id = :'fam_cuid1' and mensaje like 'Se cancelaron % tareas «Ejercicios nuevos»%Motivo: La terapia termina antes') = 1,
  'un solo aviso por cuidador afectado');
select pruebas.como(:'fam_coord');
set local role authenticated;
-- Cancelar solo «esta»; una tarea ya cancelada no se vuelve a cancelar.
select pruebas.afirmar((cuidared_api.api_tarea_cancelar(:cta_fam, :'t2', 'Se pospone')->>'canceladas')::int = 1, 'cancelar solo esta');
select pruebas.error(format('select cuidared_api.api_tarea_cancelar(%s, %L, %L)', :cta_fam, :'t2', 'Otra vez'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.afirmar((cuidared_api.api_tarea_obtener(:cta_fam, :'t2')->>'motivo_cancelacion') = 'Se pospone', 'motivo visible en la tarea');
reset role;
-- El cuidador no cancela; ni inicia una tarea cancelada.
select pruebas.como(:'fam_cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_cancelar(%s, %L, %L)', :cta_fam, :'t2', 'Intento'), '42501');
select pruebas.error(format('select cuidared_api.api_tarea_iniciar(%s, %L)', :cta_fam, :'t2'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;
-- Evidencias de una tarea cancelada: no se registran ni se revisan.
select pruebas.como(:'fam_cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t2',
  '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;

/* ───────────── Límite de evidencias por tarea (D13) ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select (cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"titulo":"Muchas fotos"}')))->'tareas'->0->>'tarea_id' as t_max \gset
reset role;
do $$
declare v_t uuid := (select tarea_agenda_id from cuidared.tarea_agenda where titulo = 'Muchas fotos'); v_u uuid; i integer;
begin
  select usuario_id into v_u from cuidared.cuidador c join cuidared.tarea_agenda t using (cuidador_id) where t.tarea_agenda_id = v_t;
  for i in 1..5 loop
    insert into cuidared.evidencia (tarea_agenda_id, archivo_url, registrada_por, nombre_archivo, tipo_mime, tamano_bytes)
    values (v_t, format('cuenta/%s/tarea/%s/%s.jpg', (select e.cuenta_id from cuidared.envejeciente e join cuidared.tarea_agenda t using (envejeciente_id) where t.tarea_agenda_id = v_t), v_t, gen_random_uuid()),
            v_u, 'f.jpg', 'image/jpeg', 10);
  end loop;
end $$;
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_fam, :'t_max',
  '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'), 'P0001', 'CR_LIMITE_EVIDENCIAS');
reset role;

/* ───────────── Restricciones de la tabla (defensa en profundidad) ───────────── */
select pruebas.error(format($q$insert into cuidared.evidencia (tarea_agenda_id, archivo_url, registrada_por, nombre_archivo, tipo_mime, tamano_bytes)
  values (%L, %L, %L, 'f.jpg', 'image/jpeg', 5242881)$q$, :'t_sin', format('cuenta/%s/tarea/%s/%s.jpg', :cta_fam, :'t_sin', gen_random_uuid()), :'fam_cuid1'), '23514');
select pruebas.error(format($q$insert into cuidared.evidencia (tarea_agenda_id, archivo_url, registrada_por, nombre_archivo, tipo_mime, tamano_bytes)
  values (%L, %L, %L, 'f.exe', 'application/x-msdownload', 10)$q$, :'t_sin', format('cuenta/%s/tarea/%s/%s.exe', :cta_fam, :'t_sin', gen_random_uuid()), :'fam_cuid1'), '23514');
select pruebas.error(format($q$insert into cuidared.evidencia (tarea_agenda_id, archivo_url, registrada_por, nombre_archivo, tipo_mime, tamano_bytes)
  values (%L, %L, %L, 'f.jpg', 'image/jpeg', 10)$q$, :'t_sin', format('cuenta/%s/tarea/%s/%s.jpg', :cta_fam, :'t_prev', gen_random_uuid()), :'fam_cuid1'), '23514');   -- ruta de otra tarea
select pruebas.error(format($q$insert into cuidared.evidencia (tarea_agenda_id, archivo_url, registrada_por, nombre_archivo, tipo_mime, tamano_bytes)
  values (%L, 'https://externo.test/foto.jpg', %L, 'f.jpg', 'image/jpeg', 10)$q$, :'t_sin', :'fam_cuid1'), '23514');                                     -- no es una ruta del bucket
select pruebas.error(format($q$insert into cuidared.evidencia (tarea_agenda_id, archivo_url, registrada_por, nombre_archivo, tipo_mime, tamano_bytes, estado_validacion)
  values (%L, %L, %L, 'f.jpg', 'image/jpeg', 10, 'validada')$q$, :'t_sin', format('cuenta/%s/tarea/%s/%s.jpg', :cta_fam, :'t_sin', gen_random_uuid()), :'fam_cuid1'), '23514');   -- validada sin validador
select pruebas.error(format($q$update cuidared.tarea_agenda set estado = 'completada' where tarea_agenda_id = %L$q$, :'t_max'), '23514');                   -- completada sin autor ni fecha
select pruebas.error(format($q$update cuidared.tarea_agenda set serie_id = gen_random_uuid() where tarea_agenda_id = %L$q$, :'t_max'), '23514');           -- serie sin es_repetitiva
select pruebas.error(format($q$update cuidared.tarea_agenda set cuidador_id = %s where tarea_agenda_id = %L$q$, :cx, :'t_max'), '23514');                  -- cuidador de otra cuenta
select pruebas.error(format($q$update cuidared.tarea_agenda set indicacion_medica_id = %L where tarea_agenda_id = %L$q$, :'ind_a2', :'t_max'), '23514');   -- indicación de otro adulto

/* ───────────── Políticas de Storage (stub local de storage.objects) ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select (cuidared_api.api_tarea_crear(:cta_fam, pruebas.datos_tarea_4b(:'a1', :c1, :prio::smallint, '{"titulo":"Para Storage"}')))->'tareas'->0->>'tarea_id' as t_st \gset
reset role;
select pruebas.ruta_4b(:cta_fam, :'t_st') as r_st \gset
select pruebas.ruta_4b(:cta_fam, :'t_st', 'pdf') as r_st2 \gset

-- El cuidador asignado sube a la ruta de su tarea y la ve; no puede sobrescribir ni borrar.
select pruebas.como(:'fam_cuid1');
set local role authenticated;
insert into storage.objects (bucket_id, name) values ('evidencias', :'r_st');
select pruebas.afirmar((select count(*) from storage.objects where name = :'r_st') = 1, 'el cuidador asignado sube y ve su evidencia');
-- Sin políticas de update ni delete: el cuidador no sobrescribe ni borra lo que subió (0 filas afectadas).
select set_config('pruebas.objeto', :'r_st', true);
do $$
declare n integer;
begin
  update storage.objects set metadata = '{}' where name = current_setting('pruebas.objeto');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FALLA: se pudo modificar un objeto de Storage'; end if;
  delete from storage.objects where name = current_setting('pruebas.objeto');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FALLA: se pudo borrar un objeto de Storage'; end if;
end $$;
-- Rutas que no corresponden: otra tarea (de otro cuidador), otra cuenta, otro bucket, formato, tarea inexistente.
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', pruebas.ruta_4b(:cta_fam, :'t2')), '42501');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', pruebas.ruta_4b(:cta_otra, :'t_st')), '42501');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', pruebas.ruta_4b(:cta_fam, gen_random_uuid())), '42501');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', 'cuenta/' || :cta_fam || '/tarea/' || :'t_st' || '/foto.jpg'), '42501');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', 'otra-cosa/foto.jpg'), '42501');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', pruebas.ruta_4b(:cta_fam, :'t_st', 'exe')), '42501');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'avatares', :'r_st2'), '42501');
reset role;

-- El coordinador la ve (agenda:ver con alcance) pero no sube (no es el cuidador asignado, no tiene agenda:ejecutar).
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar((select count(*) from storage.objects where name = :'r_st') = 1, 'el coordinador ve evidencias de su cuenta');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', :'r_st2'), '42501');
reset role;
-- Otro cuidador del mismo adulto no ve la evidencia de una tarea ajena ni sube a ella.
select pruebas.como(:'fam_cuid2');
set local role authenticated;
select pruebas.afirmar((select count(*) from storage.objects where name = :'r_st') = 0, 'otro cuidador no ve evidencias de tareas ajenas');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', :'r_st2'), '42501');
reset role;
-- Familiar (sin agenda:ver) y coordinador de otra cuenta: nada.
select pruebas.como(:'fam_fliar');
set local role authenticated;
select pruebas.afirmar((select count(*) from storage.objects) = 0, 'el familiar no ve evidencias');
reset role;
select pruebas.como(:'otra_coord');
set local role authenticated;
select pruebas.afirmar((select count(*) from storage.objects) = 0, 'otra cuenta no ve evidencias');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', :'r_st2'), '42501');
reset role;
-- Organización: el cuidador de la organización no alcanza a los adultos de la familia.
select pruebas.como(:'org_cuid');
set local role authenticated;
select pruebas.afirmar((select count(*) from storage.objects) = 0, 'cuidador de otra organización no ve evidencias');
reset role;
-- Sesión anónima o sin JWT: nada.
set local role anon;
select pruebas.error('select count(*) from storage.objects', '42501');
reset role;
-- Tarea cancelada o cerrada: ya no se sube; sí se sigue viendo.
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_tarea_cancelar(:cta_fam, :'t_st', 'Ya no hace falta');
reset role;
select pruebas.como(:'fam_cuid1');
set local role authenticated;
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', :'r_st2'), '42501');
select pruebas.afirmar((select count(*) from storage.objects where name = :'r_st') = 1, 'se sigue viendo tras cancelar');
reset role;
-- Cuenta vencida: ni subir ni ver (D07).
select pruebas.usuario('venc.coord@x.test', '00200000011', 'Vera') as venc_coord \gset
select pruebas.usuario('venc.cuid@x.test', '00200000012', 'Vicente') as venc_cuid \gset
select pruebas.cuenta('familia', :'venc_coord') as cta_venc \gset
select pruebas.miembro(:cta_venc, :'venc_cuid', 'cuidador');
select pruebas.adulto_4b(:cta_venc, '10000000006') as av \gset
select pruebas.vincular_4b(:'av', :'venc_cuid', 'cuidador_asignado');
select pruebas.perfil_cuidador_4b(:cta_venc, :'venc_cuid') as cv \gset
select pruebas.como(:'venc_coord');
set local role authenticated;
select (cuidared_api.api_tarea_crear(:cta_venc, pruebas.datos_tarea_4b(:'av', :cv, :prio::smallint)))->'tareas'->0->>'tarea_id' as t_venc \gset
reset role;
select pruebas.ruta_4b(:cta_venc, :'t_venc') as r_venc \gset
select pruebas.como(:'venc_cuid');
set local role authenticated;
insert into storage.objects (bucket_id, name) values ('evidencias', :'r_venc');
reset role;
update cuidared.cuenta set fecha_fin_prueba = pruebas.hoy_4b() - 1, fecha_inicio_prueba = pruebas.hoy_4b() - 8 where cuenta_id = :cta_venc;
select pruebas.como(:'venc_cuid');
set local role authenticated;
select pruebas.afirmar((select count(*) from storage.objects where name = :'r_venc') = 0, 'cuenta vencida: no se ve');
select pruebas.error(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'evidencias', pruebas.ruta_4b(:cta_venc, :'t_venc')), '42501');
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s)', :cta_venc), 'P0001', 'CR_CUENTA_SIN_ACCESO');
select pruebas.error(format('select cuidared_api.api_tarea_iniciar(%s, %L)', :cta_venc, :'t_venc'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
select pruebas.error(format('select cuidared_api.api_evidencia_preparar_subida(%s, %L, %L::jsonb)', :cta_venc, :'t_venc',
  '{"nombre_archivo":"foto.jpg","tipo_mime":"image/jpeg","tamano_bytes":1000}'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
reset role;
select pruebas.como(:'venc_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tarea_crear(%s, %L::jsonb)', :cta_venc, pruebas.datos_tarea_4b(:'av', :cv, :prio::smallint)), 'P0001', 'CR_CUENTA_SIN_ACCESO');
reset role;

/* ───────────── Sesión no vigente: Storage y RPC lo respetan ───────────── */
select pruebas.como(:'fam_cuid1') as sid \gset
update auth.sessions set created_at = now() - interval '13 hours' where id = :'sid';
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_tareas_listar(%s)', :cta_fam), '28000');
select pruebas.afirmar((select count(*) from storage.objects where name = :'r_st') = 0, 'sesión vencida: Storage no entrega objetos');
reset role;

/* ───────────── Auditoría de datos de las filas ───────────── */
select pruebas.afirmar((select count(*) from cuidared.tarea_agenda where actualizado_por is null) = 0, 'toda tarea creada por RPC tiene actualizado_por');
rollback;
