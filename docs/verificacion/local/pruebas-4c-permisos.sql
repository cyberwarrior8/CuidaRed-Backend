-- pruebas-4c-permisos.sql — Sincronización de visitas (4c): los permisos se revalidan en cada operación al sincronizar. Roles sin
-- sync:usar, cuenta vencida (D07), alcance sobre el adulto, participación, membresía o rol que cambian entre la captura y el
-- envío, aislamiento entre cuentas y privacidad de lo que se responde. Requiere 2a, 3b y 4a: `--solo=3a,3b,4a,4c`. Corre dentro de
-- una transacción con ROLLBACK. © 2026 Equipo CuidaRed – INTEC.
begin;

/* ───────────── Ayudas locales ───────────── */
create function pruebas.iso_4c(p_marca timestamptz) returns text language sql as $$
  select to_char(p_marca at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;
create function pruebas.det_4c(p_adulto uuid, p_estado text, p_obs text default 'Se encuentra bien y colabora.')
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('envejeciente_id', p_adulto, 'estado_general', p_estado, 'observacion', p_obs))
$$;
create function pruebas.reg_4c(p_adulto uuid, p_estado text default 'estable') returns jsonb
language sql as $$
  select jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(p_adulto, p_estado)))
$$;
create function pruebas.op_4c(p_id uuid, p_tipo text, p_visita uuid, p_datos jsonb, p_cliente timestamptz,
                              p_base timestamptz default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('id_cliente', p_id, 'entidad', 'visita', 'tipo', p_tipo, 'registro_id', p_visita,
    'datos', p_datos, 'actualizado_en', pruebas.iso_4c(p_cliente), 'base_actualizado_en', pruebas.iso_4c(p_base)))
$$;
create function pruebas.vincular_4c(p_adulto uuid, p_usuario uuid, p_tipo text) returns void language sql as $$
  insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select p_adulto, p_usuario, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = p_tipo
$$;
create function pruebas.visita_4c(p_cuenta bigint, p_adulto uuid, p_participante uuid, p_estado text, p_s timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into cuidared.visita (fecha, hora_programada, razon, estado, cuenta_id, creada_por, origen, fecha_actualizacion)
  select cuidared_interno.hoy(), time '09:00', 'Visita de rutina', p_estado, p_cuenta, c.usuario_titular_id, 'interna', p_s
  from cuidared.cuenta c where c.cuenta_id = p_cuenta
  returning visita_id into v_id;
  insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id)
    select v_id, p_participante, c.usuario_titular_id from cuidared.cuenta c where c.cuenta_id = p_cuenta;
  insert into cuidared.detalle_visita (visita_id, envejeciente_id) values (v_id, p_adulto);
  return v_id;
end $$;

/* ───────────── Datos ───────────── */
select pruebas.usuario('adm4cC@x.test', '04400000001', 'Alba') as adm \gset
select pruebas.usuario('coord4cC@x.test', '04400000002', 'Carlos') as coord \gset
select pruebas.usuario('cuid4cC@x.test', '04400000003', 'Cora') as cuid \gset
select pruebas.usuario('cuid24cC@x.test', '04400000004', 'Dani') as cuid2 \gset
select pruebas.usuario('cuid34cC@x.test', '04400000005', 'Elisa') as cuid3 \gset
select pruebas.usuario('cuid44cC@x.test', '04400000006', 'Fidel') as cuid4 \gset
select pruebas.usuario('vol4cC@x.test', '04400000007', 'Vera') as vol \gset
select pruebas.usuario('fam4cC@x.test', '04400000008', 'Flor') as fam \gset
select pruebas.usuario('fuera4cC@x.test', '04400000009', 'Nadie') as fuera \gset
select pruebas.usuario('adm24cC@x.test', '04400000010', 'Omar') as adm2 \gset
select pruebas.usuario('coord24cC@x.test', '04400000011', 'Olga') as coord2 \gset
select pruebas.usuario('ftit4cC@x.test', '04400000012', 'Fabio') as ftit \gset
select pruebas.usuario('fcuid4cC@x.test', '04400000013', 'Fela') as fcuid \gset
select pruebas.usuario('exp4cC@x.test', '04400000014', 'Ezra') as exp_adm \gset
select pruebas.usuario('expc4cC@x.test', '04400000015', 'Eva') as exp_cuid \gset

select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as org \gset
select pruebas.miembro(:org, :'coord', 'coordinador');
select pruebas.miembro(:org, :'cuid', 'cuidador');
select pruebas.miembro(:org, :'cuid2', 'cuidador');
select pruebas.miembro(:org, :'cuid3', 'cuidador');
select pruebas.miembro(:org, :'cuid4', 'cuidador');
select pruebas.miembro(:org, :'vol', 'voluntario');
select pruebas.miembro(:org, :'fam', 'familiar');
select pruebas.cuenta('organizacion', :'adm2', 'activa', 'Operación Base') as org2 \gset
select pruebas.miembro(:org2, :'coord2', 'coordinador');
select pruebas.cuenta('familia', :'ftit') as fcta \gset
select pruebas.miembro(:fcta, :'fcuid', 'cuidador');
select pruebas.cuenta('organizacion', :'exp_adm') as vencible \gset
select pruebas.miembro(:vencible, :'exp_cuid', 'cuidador');

select pruebas.envejeciente(:org, 'Ana', 'Mayor') as a1 \gset
select pruebas.envejeciente(:org, 'Berta', 'Mayor') as a2 \gset
select pruebas.envejeciente(:org2, 'Elena', 'Mayor') as b1 \gset
select pruebas.envejeciente(:fcta, 'Flavia', 'Mayor') as f1 \gset
select pruebas.envejeciente(:vencible, 'Gloria', 'Mayor') as g1 \gset
select pruebas.vincular_4c(:'a1'::uuid, :'cuid'::uuid, 'cuidador_asignado');
select pruebas.vincular_4c(:'a1'::uuid, :'cuid3'::uuid, 'cuidador_asignado');
select pruebas.vincular_4c(:'a1'::uuid, :'cuid4'::uuid, 'cuidador_asignado');
select pruebas.vincular_4c(:'a1'::uuid, :'vol'::uuid, 'voluntario_asignado');
select pruebas.vincular_4c(:'f1'::uuid, :'fcuid'::uuid, 'cuidador_asignado');
select pruebas.vincular_4c(:'g1'::uuid, :'exp_cuid'::uuid, 'cuidador_asignado');
select cuidared_interno.hoy() as hoy, date_trunc('milliseconds', now()) as t0 \gset

/* ───────────── Quién puede sincronizar: sync:usar y membresía activa ───────────── */
-- Administrador, Familiar, ajeno a la cuenta y miembro de otra cuenta: 42501 y nada se guarda.
select pruebas.como(:'adm');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '42501');
reset role;
select pruebas.como(:'fam');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '42501');
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org, gen_random_uuid()::text), '42501');
reset role;
select pruebas.como(:'fuera');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '42501');
reset role;
select pruebas.como(:'coord2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '42501');
reset role;
-- Sin sesión: 28000.
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '28000');
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org, gen_random_uuid()::text), '28000');
reset role;
select pruebas.afirmar((select count(*) from cuidared.operacion_sync) = 0, 'los rechazos por membresía o rol no dejan filas');

-- Quien perdió la membresía o cambió de rol entre la captura y el envío ya no puede sincronizar.
update cuidared.membresia set estado = 'inactiva', fecha_fin = cuidared_interno.hoy()
  where usuario_id = :'cuid3'::uuid and cuenta_id = :org;
update cuidared.membresia set rol_id = (select rol_id from cuidared.rol where codigo = 'familiar')
  where usuario_id = :'cuid4'::uuid and cuenta_id = :org;
select pruebas.como(:'cuid3');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '42501');
reset role;
select pruebas.como(:'cuid4');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz)::text), '42501');
reset role;
select pruebas.afirmar((select count(*) from cuidared.operacion_sync) = 0 and (select count(*) from cuidared.visita) = 0,
  'sin membresía vigente o sin sync:usar no se registra ni se escribe nada');

/* ───────────── Cuenta vencida: D07, sin escrituras operativas ───────────── */
\set kv1 d1000000-0000-4000-8000-000000000001
\set kv2 d1000000-0000-4000-8000-000000000002
\set kv3 d1000000-0000-4000-8000-000000000003
-- Con la cuenta vigente se aplica una operación; después la cuenta vence.
select pruebas.como(:'exp_cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:vencible, pruebas.op_4c(:'kv1', 'registrar', 'a0000000-0000-4000-8000-0000000000c1',
  pruebas.reg_4c(:'g1'), :'t0'::timestamptz - interval '5 minutes')) ->> 'resultado' as rv0 \gset
reset role;
select pruebas.afirmar(:'rv0' = 'aplicada', 'con la cuenta vigente la operación se aplica');
update cuidared.cuenta set fecha_inicio_prueba = :'hoy'::date - 8, fecha_fin_prueba = :'hoy'::date - 1 where cuenta_id = :vencible;
select pruebas.como(:'exp_cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:vencible, pruebas.op_4c(:'kv2', 'registrar', 'a0000000-0000-4000-8000-0000000000c2',
  pruebas.reg_4c(:'g1'), :'t0'::timestamptz - interval '4 minutes')) as rv1 \gset
select cuidared_api.api_sync_aplicar_operacion(:vencible, pruebas.op_4c(:'kv3', 'iniciar', 'a0000000-0000-4000-8000-0000000000c1',
  '{}'::jsonb, :'t0'::timestamptz - interval '3 minutes')) as rv2 \gset
-- También una operación que ya estaba resuelta: no se devuelve como duplicada, porque la cuenta no admite nada operativo.
select cuidared_api.api_sync_aplicar_operacion(:vencible, pruebas.op_4c(:'kv1', 'registrar', 'a0000000-0000-4000-8000-0000000000c1',
  pruebas.reg_4c(:'g1'), :'t0'::timestamptz - interval '5 minutes')) as rv3 \gset
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :vencible, :'kv1'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
reset role;
select pruebas.afirmar((:'rv1'::jsonb)->>'resultado' = 'rechazada' and (:'rv1'::jsonb)->>'motivo' = 'SUBSCRIPTION_INACTIVE'
  and (:'rv2'::jsonb)->>'resultado' = 'rechazada' and (:'rv2'::jsonb)->>'motivo' = 'SUBSCRIPTION_INACTIVE'
  and (:'rv3'::jsonb)->>'resultado' = 'rechazada' and (:'rv3'::jsonb)->>'motivo' = 'SUBSCRIPTION_INACTIVE'
  and (:'rv1'::jsonb)->>'actualizado_en_servidor' is null and (:'rv3'::jsonb)->>'actualizado_en_servidor' is null,
  'cuenta vencida: todas las operaciones se rechazan con SUBSCRIPTION_INACTIVE');
select pruebas.afirmar((select count(*) from cuidared.visita where visita_id = 'a0000000-0000-4000-8000-0000000000c2'::uuid) = 0,
  'cuenta vencida: no se escribe nada');
select pruebas.afirmar((select resultado from cuidared.operacion_sync where id_cliente = :'kv1'::uuid) = 'aplicada'
  and (select resultado from cuidared.operacion_sync where id_cliente = :'kv2'::uuid) = 'rechazada'
  and (select motivo from cuidared.operacion_sync where id_cliente = :'kv2'::uuid) = 'SUBSCRIPTION_INACTIVE',
  'el rechazo se registra y no pisa lo ya resuelto');
-- Al renovar, el mismo reintento se resuelve sin perder la captura.
update cuidared.cuenta set fecha_inicio_prueba = :'hoy'::date, fecha_fin_prueba = :'hoy'::date + 7 where cuenta_id = :vencible;
select pruebas.como(:'exp_cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:vencible, pruebas.op_4c(:'kv2', 'registrar', 'a0000000-0000-4000-8000-0000000000c2',
  pruebas.reg_4c(:'g1'), :'t0'::timestamptz - interval '4 minutes')) as rv4 \gset
select cuidared_api.api_sync_aplicar_operacion(:vencible, pruebas.op_4c(:'kv1', 'registrar', 'a0000000-0000-4000-8000-0000000000c1',
  pruebas.reg_4c(:'g1'), :'t0'::timestamptz - interval '5 minutes')) as rv5 \gset
reset role;
select pruebas.afirmar((:'rv4'::jsonb)->>'resultado' = 'aplicada' and (:'rv5'::jsonb)->>'resultado' = 'duplicada'
  and (:'rv5'::jsonb)->>'resultado_original' = 'aplicada', 'renovada la cuenta, el reintento se aplica y lo ya resuelto es duplicada');
select pruebas.afirmar((select count(*) from cuidared.visita where cuenta_id = :vencible) = 2
  and (select count(*) from cuidared.operacion_sync where cuenta_id = :vencible) = 3, 'una fila por clave de operación, sin duplicados');

/* ───────────── Alcance sobre el adulto y participación ───────────── */
-- Cuidador sin vínculo con el adulto (a2) o con un adulto de otra cuenta (b1): FORBIDDEN, sin crear la visita.
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', 'a0000000-0000-4000-8000-0000000000d1',
  pruebas.reg_4c(:'a2'), :'t0'::timestamptz - interval '5 minutes')) as ra \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', 'a0000000-0000-4000-8000-0000000000d2',
  pruebas.reg_4c(:'b1'), :'t0'::timestamptz - interval '5 minutes')) as rb \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', 'a0000000-0000-4000-8000-0000000000d3',
  pruebas.reg_4c(gen_random_uuid()), :'t0'::timestamptz - interval '5 minutes')) as rc \gset
reset role;
select pruebas.afirmar((:'ra'::jsonb)->>'resultado' = 'rechazada' and (:'ra'::jsonb)->>'motivo' = 'FORBIDDEN'
  and (:'rb'::jsonb)->>'motivo' = 'FORBIDDEN' and (:'rc'::jsonb)->>'motivo' = 'FORBIDDEN',
  'adulto sin alcance, de otra cuenta o inexistente: el mismo FORBIDDEN');
select pruebas.afirmar((select count(*) from cuidared.visita where visita_id in
    ('a0000000-0000-4000-8000-0000000000d1'::uuid, 'a0000000-0000-4000-8000-0000000000d2'::uuid, 'a0000000-0000-4000-8000-0000000000d3'::uuid)) = 0,
  'las operaciones rechazadas no crean visitas');
select pruebas.afirmar((:'ra'::jsonb)->>'actualizado_en_servidor' is null and (:'ra'::jsonb)->>'gana' is null
  and (select array_agg(k order by k) from jsonb_object_keys(:'ra'::jsonb) k)
    = array['actualizado_en_servidor', 'gana', 'id_cliente', 'motivo', 'registro_id', 'resultado', 'resultado_original'],
  'el rechazo no revela datos: solo la lista cerrada de campos');

-- Visita programada para cuid: pierde el vínculo con el adulto antes de sincronizar → FORBIDDEN y la visita queda como estaba.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v1 \gset
delete from cuidared.vinculo where envejeciente_id = :'a1'::uuid and usuario_id = :'cuid'::uuid;
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v1'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '60 minutes')) as rd \gset
reset role;
select pruebas.afirmar((:'rd'::jsonb)->>'resultado' = 'rechazada' and (:'rd'::jsonb)->>'motivo' = 'FORBIDDEN'
  and (select estado from cuidared.visita where visita_id = :'v1'::uuid) = 'programada', 'sin vínculo con el adulto: FORBIDDEN y sin cambios');
select pruebas.vincular_4c(:'a1'::uuid, :'cuid'::uuid, 'cuidador_asignado');

-- Quien no participa: si no ve la visita, FORBIDDEN al registrar y NOT_FOUND al iniciar; si la ve, FORBIDDEN en ambos casos.
select pruebas.como(:'cuid2');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v1'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '60 minutes')) as re1 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v1'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '60 minutes')) as re2 \gset
reset role;
select pruebas.afirmar((:'re1'::jsonb)->>'motivo' = 'FORBIDDEN' and (:'re2'::jsonb)->>'motivo' = 'NOT_FOUND'
  and (:'re1'::jsonb)->>'actualizado_en_servidor' is null and (:'re2'::jsonb)->>'actualizado_en_servidor' is null,
  'una visita que no ve: no se revela ni su versión');
select pruebas.vincular_4c(:'a1'::uuid, :'cuid2'::uuid, 'cuidador_asignado');
select pruebas.como(:'cuid2');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v1'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '4 minutes', :'t0'::timestamptz - interval '60 minutes')) as re3 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v1'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '4 minutes', :'t0'::timestamptz - interval '60 minutes')) as re4 \gset
reset role;
select pruebas.afirmar((:'re3'::jsonb)->>'motivo' = 'FORBIDDEN' and (:'re4'::jsonb)->>'motivo' = 'FORBIDDEN'
  and (:'re3'::jsonb)->>'resultado' = 'rechazada' and (:'re3'::jsonb)->>'actualizado_en_servidor' is null,
  'una visita que ve pero en la que no participa: FORBIDDEN');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v1'::uuid) = 'programada', 'la visita no cambió');

-- El Coordinador gestiona: puede operar una visita en la que no participa.
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v1'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '3 minutes', :'t0'::timestamptz - interval '60 minutes')) ->> 'resultado' as rg \gset
reset role;
select pruebas.afirmar(:'rg' = 'aplicada' and (select estado from cuidared.visita where visita_id = :'v1'::uuid) = 'en_curso', 'el gestor opera la visita');

/* ───────────── Aislamiento entre cuentas ───────────── */
select pruebas.como(:'coord2');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org2, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v1'::uuid, pruebas.reg_4c(:'b1'),
  :'t0'::timestamptz - interval '3 minutes', :'t0'::timestamptz - interval '60 minutes')) as rx1 \gset
select cuidared_api.api_sync_aplicar_operacion(:org2, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v1'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '3 minutes', :'t0'::timestamptz - interval '60 minutes')) as rx2 \gset
-- Un adulto de otra cuenta en una visita nueva de esta.
select cuidared_api.api_sync_aplicar_operacion(:org2, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '3 minutes')) as rx3 \gset
reset role;
select pruebas.afirmar((:'rx1'::jsonb)->>'resultado' = 'rechazada' and (:'rx1'::jsonb)->>'motivo' = 'FORBIDDEN'
  and (:'rx2'::jsonb)->>'motivo' = 'NOT_FOUND' and (:'rx3'::jsonb)->>'motivo' = 'FORBIDDEN'
  and (:'rx1'::jsonb)->>'actualizado_en_servidor' is null and (:'rx2'::jsonb)->>'actualizado_en_servidor' is null,
  'la visita o el adulto de otra cuenta no se pueden tocar ni se revela su versión');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v1'::uuid) = 'en_curso'
  and (select count(*) from cuidared.visita where cuenta_id = :org2) = 0, 'la otra cuenta no escribió nada');

/* ───────────── Registro mínimo del Voluntario y Familia ───────────── */
select pruebas.como(:'vol');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(),
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(:'a1', null))), :'t0'::timestamptz - interval '3 minutes')) ->> 'resultado' as rm1 \gset
reset role;
select pruebas.afirmar(:'rm1' = 'aplicada', 'el Voluntario registra sin estado general');
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(),
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(:'a1', null))), :'t0'::timestamptz - interval '3 minutes')) ->> 'motivo' as rm2 \gset
reset role;
select pruebas.afirmar(:'rm2' = 'INVALID_INPUT', 'el Cuidador sí necesita el estado general (lo decide el rol real)');

select pruebas.como(:'ftit');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:fcta, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'f1'),
  :'t0'::timestamptz - interval '3 minutes')) ->> 'resultado' as rf1 \gset
reset role;
select pruebas.como(:'fcuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:fcta, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'f1'),
  :'t0'::timestamptz - interval '2 minutes')) ->> 'resultado' as rf2 \gset
reset role;
select pruebas.afirmar(:'rf1' = 'aplicada' and :'rf2' = 'aplicada', 'Familia: el Coordinador y el Cuidador sincronizan');

rollback;
