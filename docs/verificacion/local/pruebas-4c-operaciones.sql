-- pruebas-4c-operaciones.sql — Sincronización de visitas (4c): aplicar operaciones, idempotencia por id_cliente, consulta del
-- resultado y entradas inválidas. Requiere 2a, 3b y 4a: `--solo=3a,3b,4a,4c`. Los adultos se crean con la ayuda común
-- pruebas.envejeciente y los vínculos con insert directos como superusuario. Corre dentro de una transacción con ROLLBACK
-- (ojo: now() es constante en toda la prueba, así que las versiones del servidor se fijan a mano cuando hace falta un orden).
-- © 2026 Equipo CuidaRed – INTEC.
begin;

/* ───────────── Ayudas locales ───────────── */
create function pruebas.iso_4c(p_marca timestamptz) returns text language sql as $$
  select to_char(p_marca at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;
create function pruebas.det_4c(p_adulto uuid, p_estado text, p_obs text default 'Se encuentra bien y colabora.')
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('envejeciente_id', p_adulto, 'estado_general', p_estado, 'observacion', p_obs))
$$;
create function pruebas.op_4c(p_id uuid, p_tipo text, p_visita uuid, p_datos jsonb, p_cliente timestamptz,
                              p_base timestamptz default null, p_entidad text default 'visita')
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('id_cliente', p_id, 'entidad', p_entidad, 'tipo', p_tipo, 'registro_id', p_visita,
    'datos', p_datos, 'actualizado_en', pruebas.iso_4c(p_cliente), 'base_actualizado_en', pruebas.iso_4c(p_base)))
$$;
create function pruebas.vincular_4c(p_adulto uuid, p_usuario uuid, p_tipo text) returns void language sql as $$
  insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select p_adulto, p_usuario, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = p_tipo
$$;
-- Datos mínimos de registro: un adulto estable.
create function pruebas.reg_4c(p_adulto uuid, p_obs text default 'Se encuentra bien y colabora.') returns jsonb
language sql as $$
  select jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(p_adulto, 'estable', p_obs)))
$$;

/* ───────────── Datos ───────────── */
select pruebas.usuario('adm4cA@x.test', '04200000001', 'Alba') as adm \gset
select pruebas.usuario('coord4cA@x.test', '04200000002', 'Carlos') as coord \gset
select pruebas.usuario('cuid4cA@x.test', '04200000003', 'Cora') as cuid \gset
select pruebas.usuario('cuid24cA@x.test', '04200000004', 'Dani') as cuid2 \gset
select pruebas.usuario('vol4cA@x.test', '04200000005', 'Vera') as vol \gset
select pruebas.usuario('multi4cA@x.test', '04200000006', 'Marta') as multi \gset
select pruebas.usuario('adm24cA@x.test', '04200000007', 'Omar') as adm2 \gset

select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as org \gset
select pruebas.miembro(:org, :'coord', 'coordinador');
select pruebas.miembro(:org, :'cuid', 'cuidador');
select pruebas.miembro(:org, :'cuid2', 'cuidador');
select pruebas.miembro(:org, :'vol', 'voluntario');
select pruebas.miembro(:org, :'multi', 'cuidador');
select pruebas.cuenta('organizacion', :'adm2', 'activa', 'Operación Base') as org2 \gset
select pruebas.miembro(:org2, :'multi', 'cuidador');

select pruebas.envejeciente(:org, 'Ana', 'Mayor') as a1 \gset
select pruebas.envejeciente(:org, 'Berta', 'Mayor') as a2 \gset
select pruebas.envejeciente(:org2, 'Elena', 'Mayor') as b1 \gset
select pruebas.vincular_4c(:'a1'::uuid, :'cuid'::uuid, 'cuidador_asignado');
select pruebas.vincular_4c(:'a1'::uuid, :'vol'::uuid, 'voluntario_asignado');
select pruebas.vincular_4c(:'a1'::uuid, :'multi'::uuid, 'cuidador_asignado');
select pruebas.vincular_4c(:'b1'::uuid, :'multi'::uuid, 'cuidador_asignado');
-- t0 en milisegundos exactos: el cliente solo envía milisegundos y las marcas guardadas deben coincidir con lo enviado.
select cuidared_interno.hoy() as hoy, date_trunc('milliseconds', now()) as t0 \gset

\set k1 c0000000-0000-4000-8000-000000000001
\set k2 c0000000-0000-4000-8000-000000000002
\set k3 c0000000-0000-4000-8000-000000000003
\set k4 c0000000-0000-4000-8000-000000000004
\set k5 c0000000-0000-4000-8000-000000000005
\set k6 c0000000-0000-4000-8000-000000000006
\set k7 c0000000-0000-4000-8000-000000000007
\set k8 c0000000-0000-4000-8000-000000000008
\set k9 c0000000-0000-4000-8000-000000000009
\set v1 a0000000-0000-4000-8000-000000000001
\set v2 a0000000-0000-4000-8000-000000000002
\set v3 a0000000-0000-4000-8000-000000000003
\set v4 a0000000-0000-4000-8000-000000000004

/* ───────────── Registrar una visita nueva (sin programar) registrada sin conexión ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k1', 'registrar', :'v1',
  jsonb_build_object('fecha', :'hoy', 'checklist', jsonb_build_array('higiene'),
    'detalles', jsonb_build_array(pruebas.det_4c(:'a1', 'situacion_critica', 'Presenta mareos y dificultad para caminar.'))),
  :'t0'::timestamptz - interval '10 minutes')) as r1 \gset
reset role;
select pruebas.afirmar((:'r1'::jsonb)->>'resultado' = 'aplicada' and (:'r1'::jsonb)->>'id_cliente' = :'k1'
  and (:'r1'::jsonb)->>'registro_id' = :'v1' and (:'r1'::jsonb)->>'motivo' is null and (:'r1'::jsonb)->>'gana' is null
  and (:'r1'::jsonb)->>'resultado_original' is null, 'la visita nueva se aplica');
select pruebas.afirmar((:'r1'::jsonb)->>'actualizado_en_servidor' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$',
  'la versión del servidor sale en ISO UTC con milisegundos');
select pruebas.afirmar((select count(*) from cuidared.visita where visita_id = :'v1'::uuid and cuenta_id = :org
    and estado = 'completada' and origen = 'sin_programar' and creada_por = :'cuid'::uuid) = 1, 'visita completada sin programar');
select pruebas.afirmar((select count(*) from cuidared.detalle_visita where visita_id = :'v1'::uuid) = 1
  and (select count(*) from cuidared.registro_visita where visita_id = :'v1'::uuid) = 1, 'un detalle y un participante');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = :'k1'::uuid and usuario_id = :'cuid'::uuid
    and cuenta_id = :org and entidad = 'visita' and tipo = 'registrar' and registro_id = :'v1'::uuid and resultado = 'aplicada'
    and motivo is null and gana is null and actualizado_en_servidor is not null
    and actualizado_en_cliente = :'t0'::timestamptz - interval '10 minutes') = 1, 'la operación queda registrada');
select count(*) as avisos1 from cuidared.notificacion where cuenta_id = :org and mensaje like 'Situación crítica%' \gset
select pruebas.afirmar(:avisos1 = 2, 'la situación crítica avisó a los dos gestores una vez');

/* ───────────── Idempotencia: el reintento no duplica ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k1', 'registrar', :'v1',
  jsonb_build_object('fecha', :'hoy', 'checklist', jsonb_build_array('vivienda', 'animo'),
    'detalles', jsonb_build_array(pruebas.det_4c(:'a1', 'estable', 'Otra observación distinta.'))),
  :'t0'::timestamptz - interval '10 minutes')) as r2 \gset
reset role;
select pruebas.afirmar((:'r2'::jsonb)->>'resultado' = 'duplicada' and (:'r2'::jsonb)->>'resultado_original' = 'aplicada'
  and (:'r2'::jsonb)->>'registro_id' = :'v1' and (:'r2'::jsonb)->>'actualizado_en_servidor' = (:'r1'::jsonb)->>'actualizado_en_servidor',
  'el reintento devuelve lo resuelto como duplicada');
select pruebas.afirmar((select count(*) from cuidared.visita where cuenta_id = :org) = 1
  and (select count(*) from cuidared.detalle_visita where visita_id = :'v1'::uuid) = 1
  and (select count(*) from cuidared.registro_visita where visita_id = :'v1'::uuid) = 1
  and (select count(*) from cuidared.operacion_sync where id_cliente = :'k1'::uuid) = 1, 'sin visitas, detalles ni operaciones duplicados');
select pruebas.afirmar((select observacion from cuidared.detalle_visita where visita_id = :'v1'::uuid) like 'Presenta mareos%',
  'el reintento no vuelve a escribir lo que cambió en el contenido');
select pruebas.afirmar((select count(*) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Situación crítica%') = :avisos1,
  'el reintento no repite avisos');

-- Reutilizar la clave: otro usuario, otra cuenta u otra operación se rechaza sin tocar la fila original.
select pruebas.como(:'vol');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k1', 'registrar', :'v1', pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '10 minutes')) as r3 \gset
reset role;
select pruebas.afirmar((:'r3'::jsonb)->>'resultado' = 'rechazada' and (:'r3'::jsonb)->>'motivo' = 'ID_CLIENTE_EN_USO'
  and (:'r3'::jsonb)->>'actualizado_en_servidor' is null and (:'r3'::jsonb)->>'resultado_original' is null,
  'la clave de otra persona se rechaza sin revelar nada');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = :'k1'::uuid and usuario_id = :'cuid'::uuid
    and resultado = 'aplicada') = 1, 'la fila original sigue intacta');

select pruebas.como(:'multi');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k2', 'registrar', :'v2', pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes')) as r4 \gset
select cuidared_api.api_sync_aplicar_operacion(:org2, pruebas.op_4c(:'k2', 'registrar', :'v2', pruebas.reg_4c(:'b1'),
  :'t0'::timestamptz - interval '5 minutes')) as r5 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k2', 'registrar', :'v3', pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes')) as r6 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k2', 'iniciar', :'v2', '{}'::jsonb,
  :'t0'::timestamptz - interval '5 minutes')) as r7 \gset
reset role;
select pruebas.afirmar((:'r4'::jsonb)->>'resultado' = 'aplicada', 'la persona de dos cuentas opera en la primera');
select pruebas.afirmar((:'r5'::jsonb)->>'motivo' = 'ID_CLIENTE_EN_USO' and (:'r5'::jsonb)->>'resultado' = 'rechazada',
  'la misma clave en otra cuenta se rechaza');
select pruebas.afirmar((:'r6'::jsonb)->>'motivo' = 'ID_CLIENTE_EN_USO', 'la misma clave para otro registro se rechaza');
select pruebas.afirmar((:'r7'::jsonb)->>'motivo' = 'ID_CLIENTE_EN_USO', 'la misma clave para otro tipo se rechaza');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = :'k2'::uuid and cuenta_id = :org
    and registro_id = :'v2'::uuid and tipo = 'registrar') = 1
  and (select count(*) from cuidared.visita where cuenta_id = :org2) = 0, 'nada se escribió en la otra cuenta');

/* ───────────── Visita programada: iniciar y registrar sin conexión ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_programar_visita(:org, jsonb_build_object('fecha', :'hoy', 'hora_programada', '23:59', 'razon', 'Visita de rutina',
  'envejeciente_ids', jsonb_build_array(:'a1'), 'participante_ids', jsonb_build_array(:'cuid'))) ->> 'visita_id' as vp \gset
reset role;
select fecha_actualizacion as s0 from cuidared.visita where visita_id = :'vp'::uuid \gset

select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k3', 'iniciar', :'vp', '{}'::jsonb,
  :'t0'::timestamptz - interval '3 minutes', :'s0'::timestamptz)) as r8 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k4', 'iniciar', :'vp', '{}'::jsonb,
  :'t0'::timestamptz - interval '2 minutes', :'s0'::timestamptz)) as r9 \gset
reset role;
select pruebas.afirmar((:'r8'::jsonb)->>'resultado' = 'aplicada' and (select estado from cuidared.visita where visita_id = :'vp'::uuid) = 'en_curso',
  'iniciar una visita programada');
select pruebas.afirmar((:'r9'::jsonb)->>'resultado' = 'duplicada' and (:'r9'::jsonb)->>'motivo' = 'YA_INICIADA'
  and (:'r9'::jsonb)->>'resultado_original' is null, 'iniciar otra vez una visita en curso no cambia nada');

select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k5', 'registrar', :'vp', pruebas.reg_4c(:'a1', 'La visita transcurrió con normalidad.'),
  :'t0'::timestamptz - interval '1 minute', :'s0'::timestamptz)) as r10 \gset
reset role;
select pruebas.afirmar((:'r10'::jsonb)->>'resultado' = 'aplicada' and (select estado from cuidared.visita where visita_id = :'vp'::uuid) = 'completada'
  and (select count(*) from cuidared.detalle_visita where visita_id = :'vp'::uuid and observacion like 'La visita transcurrió%') = 1,
  'registrar completa la visita programada');

-- La misma captura (misma marca del dispositivo) reenviada con otra clave: segunda barrera.
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k6', 'registrar', :'vp', pruebas.reg_4c(:'a1', 'La visita transcurrió con normalidad.'),
  :'t0'::timestamptz - interval '1 minute', :'s0'::timestamptz)) as r11 \gset
reset role;
select pruebas.afirmar((:'r11'::jsonb)->>'resultado' = 'duplicada' and (:'r11'::jsonb)->>'motivo' = 'YA_REGISTRADA',
  'la misma captura con otra clave es duplicada');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where registro_id = :'vp'::uuid) = 4
  and (select count(*) from cuidared.detalle_visita where visita_id = :'vp'::uuid) = 1, 'no se duplica el registro');

/* ───────────── Consulta del resultado (GET) ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_obtener_operacion(:org, :'k1'::uuid) as g1 \gset
select cuidared_api.api_sync_obtener_operacion(:org, :'k6'::uuid) as g2 \gset
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org, :'k2'), 'P0002');
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org, gen_random_uuid()::text), 'P0002');
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org2, :'k1'), '42501');
reset role;
select pruebas.afirmar((:'g1'::jsonb)->>'resultado' = 'aplicada' and (:'g1'::jsonb)->>'registro_id' = :'v1'
  and (:'g1'::jsonb)->>'entidad' = 'visita' and (:'g1'::jsonb)->>'tipo' = 'registrar'
  and (:'g1'::jsonb)->>'actualizado_en_servidor' = (:'r1'::jsonb)->>'actualizado_en_servidor'
  and (:'g1'::jsonb)->>'procesada_en' is not null, 'la consulta devuelve el resultado guardado, no «duplicada»');
select pruebas.afirmar((:'g2'::jsonb)->>'resultado' = 'duplicada' and (:'g2'::jsonb)->>'motivo' = 'YA_REGISTRADA',
  'la consulta de una duplicada por otra operación');
-- Ni otra persona de la misma cuenta ni otra cuenta ven la operación (404 sin distinguir cuál).
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org, :'k1'), 'P0002');
reset role;
select pruebas.como(:'multi');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org2, :'k1'), 'P0002');
reset role;

/* ───────────── Una rechazada se vuelve a evaluar al reintentar ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
-- Reloj del dispositivo adelantado más de 5 minutos.
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k7', 'registrar', :'v4', pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz + interval '10 minutes')) as r12 \gset
reset role;
select pruebas.afirmar((:'r12'::jsonb)->>'resultado' = 'rechazada' and (:'r12'::jsonb)->>'motivo' = 'RELOJ_INVALIDO'
  and (:'r12'::jsonb)->>'actualizado_en_servidor' is null, 'reloj en el futuro: RELOJ_INVALIDO');
select pruebas.afirmar((select count(*) from cuidared.visita where visita_id = :'v4'::uuid) = 0
  and (select count(*) from cuidared.operacion_sync where id_cliente = :'k7'::uuid and resultado = 'rechazada'
       and motivo = 'RELOJ_INVALIDO') = 1, 'la rechazada queda registrada y no escribe la visita');
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k7', 'registrar', :'v4', pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '1 minute')) as r13 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k7', 'registrar', :'v4', pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '1 minute')) as r14 \gset
reset role;
select pruebas.afirmar((:'r13'::jsonb)->>'resultado' = 'aplicada' and (:'r14'::jsonb)->>'resultado' = 'duplicada'
  and (:'r14'::jsonb)->>'resultado_original' = 'aplicada', 'corregido el reloj, la misma clave se aplica una vez y luego es duplicada');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = :'k7'::uuid) = 1
  and (select resultado from cuidared.operacion_sync where id_cliente = :'k7'::uuid) = 'aplicada'
  and (select count(*) from cuidared.visita where visita_id = :'v4'::uuid) = 1, 'una sola fila y una sola visita');
-- Hasta 5 minutos en el futuro se tolera.
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k8', 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz + interval '4 minutes')) ->> 'resultado' as r15 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '1 hour', :'t0'::timestamptz + interval '6 minutes')) ->> 'motivo' as r16 \gset
reset role;
select pruebas.afirmar(:'r15' = 'aplicada', 'cuatro minutos de adelanto se toleran');
select pruebas.afirmar(:'r16' = 'RELOJ_INVALIDO', 'la versión base en el futuro también es un reloj inválido');

/* ───────────── Entidades y tipos no soportados; entradas inválidas ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'k9', 'registrar', gen_random_uuid(), '{"cualquier":"cosa"}'::jsonb,
  :'t0'::timestamptz - interval '1 minute', null, 'necesidad')) as r17 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'borrar', gen_random_uuid(), '{}'::jsonb,
  :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r18 \gset
reset role;
select pruebas.afirmar((:'r17'::jsonb)->>'resultado' = 'rechazada' and (:'r17'::jsonb)->>'motivo' = 'ENTIDAD_NO_SOPORTADA',
  'otra entidad: ENTIDAD_NO_SOPORTADA');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = :'k9'::uuid and entidad = 'necesidad'
    and resultado = 'rechazada' and motivo = 'ENTIDAD_NO_SOPORTADA') = 1, 'la fila registra la entidad pedida, sin su contenido');
select pruebas.afirmar(:'r18' = 'TIPO_NO_SOPORTADO', 'un tipo desconocido de una visita: TIPO_NO_SOPORTADO');

select pruebas.como(:'cuid');
set local role authenticated;
-- Operación mal formada: 22023 (Express la valida antes; la base no se fía).
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org, '[]'), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org, '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', 0, '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"usuario_id":"x"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"id_cliente":"no-es-uuid"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"registro_id":"123"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"entidad":"Visita"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"tipo":"registrar; drop table x"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"datos":[]}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"datos":"texto"}')::text), '22023');
-- Marcas: solo ISO 8601 UTC con «Z».
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"actualizado_en":"2026-11-06T10:00:00-04:00"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"actualizado_en":"2026-11-06 10:00:00"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"actualizado_en":"2026-02-30T10:00:00Z"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"actualizado_en":12345}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) - 'actualizado_en')::text), '22023');
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org,
  (pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'), :'t0'::timestamptz) || '{"base_actualizado_en":"ayer"}')::text), '22023');
-- Datos de la visita inválidos: resultado rechazado, no una excepción (el lote sigue).
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(),
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(:'a1', null))), :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r19 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(),
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(:'a1', 'estable', 'ab'))), :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r20 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(),
  (pruebas.reg_4c(:'a1') || '{"rol":"admin"}'), :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r21 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', gen_random_uuid(),
  '{"algo":1}'::jsonb, :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r22 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', gen_random_uuid(),
  '{}'::jsonb, :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r23 \gset
reset role;
select pruebas.afirmar(:'r19' = 'INVALID_INPUT' and :'r20' = 'INVALID_INPUT' and :'r21' = 'INVALID_INPUT' and :'r22' = 'INVALID_INPUT',
  'datos inválidos: rechazada / INVALID_INPUT');
select pruebas.afirmar(:'r23' = 'NOT_FOUND', 'iniciar una visita inexistente: NOT_FOUND');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where motivo = 'INVALID_INPUT' and usuario_id = :'cuid'::uuid) = 4,
  'las rechazadas por datos quedan registradas');

/* ───────────── Varias operaciones, cada una en su propia transacción ───────────── */
-- Una operación rechazada no revierte las demás: la visita de la rechazada no existe y las aplicadas siguen ahí.
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', 'a0000000-0000-4000-8000-0000000000b1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(:'a1', 'estable'), pruebas.det_4c(:'a2', 'estable'))),
  :'t0'::timestamptz - interval '1 minute')) ->> 'motivo' as r24 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', 'a0000000-0000-4000-8000-0000000000b2',
  pruebas.reg_4c(:'a1'), :'t0'::timestamptz - interval '1 minute')) ->> 'resultado' as r25 \gset
reset role;
select pruebas.afirmar(:'r24' = 'FORBIDDEN' and :'r25' = 'aplicada', 'la rechazada no impide la siguiente del lote');
select pruebas.afirmar((select count(*) from cuidared.visita where visita_id = 'a0000000-0000-4000-8000-0000000000b1'::uuid) = 0
  and (select count(*) from cuidared.visita where visita_id = 'a0000000-0000-4000-8000-0000000000b2'::uuid) = 1,
  'la visita de la operación rechazada no existe; la de la siguiente sí');

rollback;
