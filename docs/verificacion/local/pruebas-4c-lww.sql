-- pruebas-4c-lww.sql — Sincronización de visitas (4c): Last-Write-Wins con marcas UTC. Conflicto frente a la versión base del
-- cliente, empate (gana el servidor), precisión de milisegundos, escritura efectiva de una versión producida por otra
-- operación sincronizada (cadena propia y de otra persona), visitas cerradas (terminales) y el carácter definitivo de un
-- conflicto. Requiere 2a, 3b y 4a: `--solo=3a,3b,4a,4c`. Corre dentro de una transacción con ROLLBACK; como now() es constante,
-- la versión del servidor de cada visita se fija a mano (fecha_actualizacion) para construir el orden que se quiere probar.
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
create function pruebas.reg_4c(p_adulto uuid, p_obs text default 'Se encuentra bien y colabora.') returns jsonb
language sql as $$
  select jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4c(p_adulto, 'estable', p_obs)))
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
-- Visita con un participante, un adulto y la versión del servidor fijada (insert directo como superusuario).
create function pruebas.visita_4c(p_cuenta bigint, p_adulto uuid, p_participante uuid, p_estado text, p_s timestamptz,
                                  p_fecha date default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into cuidared.visita (fecha, hora_programada, hora_inicio, razon, estado, cuenta_id, creada_por, origen,
                               motivo_cancelacion, cancelada_por, fecha_cancelacion, fecha_actualizacion)
  select coalesce(p_fecha, cuidared_interno.hoy()), time '09:00', case when p_estado = 'en_curso' then time '00:00' end,
         'Visita de rutina', p_estado, p_cuenta, c.usuario_titular_id, 'interna',
         case when p_estado = 'cancelada' then 'Motivo de prueba' end,
         case when p_estado = 'cancelada' then c.usuario_titular_id end,
         case when p_estado = 'cancelada' then p_s end, p_s
  from cuidared.cuenta c where c.cuenta_id = p_cuenta
  returning visita_id into v_id;
  insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id)
    select v_id, p_participante, c.usuario_titular_id from cuidared.cuenta c where c.cuenta_id = p_cuenta;
  insert into cuidared.detalle_visita (visita_id, envejeciente_id) values (v_id, p_adulto);
  return v_id;
end $$;

/* ───────────── Datos ───────────── */
select pruebas.usuario('adm4cB@x.test', '04300000001', 'Alba') as adm \gset
select pruebas.usuario('coord4cB@x.test', '04300000002', 'Carlos') as coord \gset
select pruebas.usuario('cuid4cB@x.test', '04300000003', 'Cora') as cuid \gset
select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as org \gset
select pruebas.miembro(:org, :'coord', 'coordinador');
select pruebas.miembro(:org, :'cuid', 'cuidador');
select pruebas.envejeciente(:org, 'Ana', 'Mayor') as a1 \gset
select pruebas.vincular_4c(:'a1'::uuid, :'cuid'::uuid, 'cuidador_asignado');
-- t0 en milisegundos exactos: el cliente solo envía milisegundos y las marcas guardadas deben coincidir con lo enviado.
select cuidared_interno.hoy() as hoy, date_trunc('milliseconds', now()) as t0 \gset

/* ───────────── Sin cambios en el servidor desde la versión base: se aplica ───────────── */
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v1 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v1'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '60 minutes')) as r1 \gset
reset role;
select pruebas.afirmar((:'r1'::jsonb)->>'resultado' = 'aplicada' and (:'r1'::jsonb)->>'gana' is null and (:'r1'::jsonb)->>'motivo' is null
  and (select estado from cuidared.visita where visita_id = :'v1'::uuid) = 'completada', 'versión base = versión del servidor: aplicada');

-- El cliente va por detrás del servidor en el tiempo (reloj atrasado) pero no hay cambios: se aplica igual.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v2 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v2'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '90 minutes', :'t0'::timestamptz - interval '60 minutes')) ->> 'resultado' as r2 \gset
reset role;
select pruebas.afirmar(:'r2' = 'aplicada', 'sin cambios en el servidor la marca del cliente no importa');

-- Una versión base más nueva que la del servidor tampoco es un cambio.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v3 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v3'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '10 minutes')) ->> 'resultado' as r3 \gset
reset role;
select pruebas.afirmar(:'r3' = 'aplicada', 'base posterior a la versión del servidor: aplicada');

/* ───────────── Precisión de milisegundos ───────────── */
-- La base que devuelve el cliente tiene milisegundos; la del servidor, microsegundos: se compara a milisegundos.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes' + interval '999 microseconds') as v4 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v4'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '90 minutes', :'t0'::timestamptz - interval '60 minutes')) ->> 'resultado' as r4 \gset
reset role;
select pruebas.afirmar(:'r4' = 'aplicada', 'los microsegundos del servidor no crean un conflicto falso');
-- Un milisegundo más en el servidor sí es un cambio (y gana el servidor si es más reciente que el cliente).
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes' + interval '1 millisecond') as v5 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v5'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '90 minutes', :'t0'::timestamptz - interval '60 minutes')) as r5 \gset
reset role;
select pruebas.afirmar((:'r5'::jsonb)->>'resultado' = 'conflicto' and (:'r5'::jsonb)->>'gana' = 'servidor', 'un milisegundo de diferencia sí es un cambio');

/* ───────────── Conflicto: el servidor es más reciente → gana el servidor ───────────── */
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '30 minutes') as v6 \gset
\set kc c1000000-0000-4000-8000-000000000001
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'kc', 'registrar', :'v6'::uuid, pruebas.reg_4c(:'a1', 'Observación que no debe aplicarse.'),
  :'t0'::timestamptz - interval '60 minutes', :'t0'::timestamptz - interval '120 minutes')) as r6 \gset
reset role;
select pruebas.afirmar((:'r6'::jsonb)->>'resultado' = 'conflicto' and (:'r6'::jsonb)->>'gana' = 'servidor'
  and (:'r6'::jsonb)->>'motivo' = 'SERVIDOR_MAS_RECIENTE'
  and (:'r6'::jsonb)->>'actualizado_en_servidor' = pruebas.iso_4c(:'t0'::timestamptz - interval '30 minutes'),
  'servidor más reciente: conflicto y gana el servidor, con su versión');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v6'::uuid) = 'programada'
  and (select observacion from cuidared.detalle_visita where visita_id = :'v6'::uuid) is null
  and (select fecha_actualizacion from cuidared.visita where visita_id = :'v6'::uuid) = :'t0'::timestamptz - interval '30 minutes',
  'lo que pierde no modifica la visita');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = :'kc'::uuid and resultado = 'conflicto'
    and gana = 'servidor' and motivo = 'SERVIDOR_MAS_RECIENTE'
    and actualizado_en_servidor = :'t0'::timestamptz - interval '30 minutes' and base_actualizado_en = :'t0'::timestamptz - interval '120 minutes') = 1,
  'el conflicto queda registrado con la versión que ganó');

-- El resultado de un conflicto es definitivo: reintentar no lo vuelve a evaluar, aunque la visita cambie después.
update cuidared.visita set fecha_actualizacion = :'t0'::timestamptz - interval '200 minutes' where visita_id = :'v6'::uuid;
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'kc', 'registrar', :'v6'::uuid, pruebas.reg_4c(:'a1', 'Observación que no debe aplicarse.'),
  :'t0'::timestamptz - interval '60 minutes', :'t0'::timestamptz - interval '120 minutes')) as r7 \gset
reset role;
select pruebas.afirmar((:'r7'::jsonb)->>'resultado' = 'duplicada' and (:'r7'::jsonb)->>'resultado_original' = 'conflicto'
  and (:'r7'::jsonb)->>'gana' = 'servidor' and (:'r7'::jsonb)->>'motivo' = 'SERVIDOR_MAS_RECIENTE'
  and (:'r7'::jsonb)->>'actualizado_en_servidor' = pruebas.iso_4c(:'t0'::timestamptz - interval '30 minutes')
  and (select estado from cuidared.visita where visita_id = :'v6'::uuid) = 'programada',
  'reintentar un conflicto devuelve el mismo resultado como duplicada y no aplica nada');

/* ───────────── Empate: gana el servidor ───────────── */
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '45 minutes') as v7 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v7'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '45 minutes', :'t0'::timestamptz - interval '120 minutes')) as r8 \gset
reset role;
select pruebas.afirmar((:'r8'::jsonb)->>'resultado' = 'conflicto' and (:'r8'::jsonb)->>'gana' = 'servidor'
  and (select estado from cuidared.visita where visita_id = :'v7'::uuid) = 'programada', 'empate de marcas: gana el servidor');

/* ───────────── Conflicto: el cliente es más reciente → gana el cliente ───────────── */
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v8 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v8'::uuid, pruebas.reg_4c(:'a1', 'Esta observación sí gana.'),
  :'t0'::timestamptz - interval '30 minutes', :'t0'::timestamptz - interval '180 minutes')) as r9 \gset
reset role;
select pruebas.afirmar((:'r9'::jsonb)->>'resultado' = 'conflicto' and (:'r9'::jsonb)->>'gana' = 'local' and (:'r9'::jsonb)->>'motivo' is null,
  'cliente más reciente: conflicto y gana el cliente');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v8'::uuid) = 'completada'
  and (select observacion from cuidared.detalle_visita where visita_id = :'v8'::uuid) = 'Esta observación sí gana.', 'la versión del cliente se aplicó');
select pruebas.afirmar((:'r9'::jsonb)->>'actualizado_en_servidor' = pruebas.iso_4c((select fecha_actualizacion from cuidared.visita where visita_id = :'v8'::uuid))
  and (:'r9'::jsonb)->>'actualizado_en_servidor' <> pruebas.iso_4c(:'t0'::timestamptz - interval '60 minutes'),
  'se informa la nueva versión del servidor');
select pruebas.afirmar((select count(*) from cuidared.operacion_sync where id_cliente = (select id_cliente from cuidared.operacion_sync
    where registro_id = :'v8'::uuid) and resultado = 'conflicto' and gana = 'local') = 1, 'el conflicto ganado por el cliente queda registrado');

-- Sin versión base el cliente cree crear lo que ya existe: se resuelve igual por LWW.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v9 \gset
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes') as v10 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v9'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '30 minutes')) ->> 'gana' as r10 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v10'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '90 minutes')) ->> 'gana' as r11 \gset
reset role;
select pruebas.afirmar(:'r10' = 'local' and :'r11' = 'servidor', 'sin base, el servidor cuenta como cambiado y decide la marca más reciente');

/* ───────────── Iniciar con LWW ───────────── */
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '30 minutes') as v11 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v11'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '60 minutes', :'t0'::timestamptz - interval '120 minutes')) as r12 \gset
reset role;
select pruebas.afirmar((:'r12'::jsonb)->>'resultado' = 'conflicto' and (:'r12'::jsonb)->>'gana' = 'servidor'
  and (select estado from cuidared.visita where visita_id = :'v11'::uuid) = 'programada', 'iniciar con el servidor más reciente: gana el servidor');
-- Iniciar una visita futura: no es un conflicto, es un estado inválido.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '60 minutes', :'hoy'::date + 1) as v12 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v12'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '60 minutes')) as r13 \gset
reset role;
select pruebas.afirmar((:'r13'::jsonb)->>'resultado' = 'rechazada' and (:'r13'::jsonb)->>'motivo' = 'INVALID_STATE'
  and (select estado from cuidared.visita where visita_id = :'v12'::uuid) = 'programada', 'iniciar una visita de mañana: INVALID_STATE');

/* ───────────── La escritura efectiva de una versión producida por una operación sincronizada ───────────── */
-- Cadena propia: iniciar (capturado a T-120) y registrar (capturado a T-100), con la misma base (el cliente no supo del primero).
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '180 minutes') as v13 \gset
\set kp1 c2000000-0000-4000-8000-000000000001
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'kp1', 'iniciar', :'v13'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '120 minutes', :'t0'::timestamptz - interval '180 minutes')) ->> 'resultado' as r14 \gset
reset role;
select pruebas.afirmar(:'r14' = 'aplicada', 'la primera operación de la cadena se aplica');
-- El servidor la procesó a T-10: esa es ahora la versión de la visita, mucho más nueva que lo capturado por el cliente.
update cuidared.visita set fecha_actualizacion = :'t0'::timestamptz - interval '10 minutes' where visita_id = :'v13'::uuid;
update cuidared.operacion_sync set actualizado_en_servidor = :'t0'::timestamptz - interval '10 minutes' where id_cliente = :'kp1'::uuid;
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v13'::uuid, pruebas.reg_4c(:'a1', 'Cierre de la cadena propia.'),
  :'t0'::timestamptz - interval '100 minutes', :'t0'::timestamptz - interval '180 minutes')) as r15 \gset
reset role;
select pruebas.afirmar((:'r15'::jsonb)->>'resultado' = 'aplicada' and (:'r15'::jsonb)->>'gana' is null
  and (select estado from cuidared.visita where visita_id = :'v13'::uuid) = 'completada',
  'una operación posterior de la misma persona sobre su propia versión no es un conflicto');

-- La misma cadena pero llegando al revés (lo capturado después ya está en el servidor): gana lo más reciente.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '180 minutes') as v14 \gset
\set kp2 c2000000-0000-4000-8000-000000000002
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'kp2', 'iniciar', :'v14'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '120 minutes', :'t0'::timestamptz - interval '180 minutes')) ->> 'resultado' as r16 \gset
reset role;
update cuidared.visita set fecha_actualizacion = :'t0'::timestamptz - interval '10 minutes' where visita_id = :'v14'::uuid;
update cuidared.operacion_sync set actualizado_en_servidor = :'t0'::timestamptz - interval '10 minutes' where id_cliente = :'kp2'::uuid;
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v14'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '130 minutes', :'t0'::timestamptz - interval '180 minutes')) as r17 \gset
reset role;
select pruebas.afirmar((:'r17'::jsonb)->>'resultado' = 'conflicto' and (:'r17'::jsonb)->>'gana' = 'servidor'
  and (select estado from cuidared.visita where visita_id = :'v14'::uuid) = 'en_curso',
  'lo capturado antes que la versión efectiva del servidor pierde');

-- Otra persona produjo la versión (el Coordinador inició sin conexión a T-120 y se procesó a T-10): se compara su marca del
-- dispositivo, no la hora en que llegó, así que el Cuidador que registró a T-90 gana.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '180 minutes') as v15 \gset
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '180 minutes') as v16 \gset
\set kp3 c2000000-0000-4000-8000-000000000003
\set kp4 c2000000-0000-4000-8000-000000000004
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'kp3', 'iniciar', :'v15'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '120 minutes', :'t0'::timestamptz - interval '180 minutes')) ->> 'resultado' as r18 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(:'kp4', 'iniciar', :'v16'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '120 minutes', :'t0'::timestamptz - interval '180 minutes')) ->> 'resultado' as r19 \gset
reset role;
select pruebas.afirmar(:'r18' = 'aplicada' and :'r19' = 'aplicada', 'el Coordinador inicia dos visitas sin conexión');
update cuidared.visita set fecha_actualizacion = :'t0'::timestamptz - interval '10 minutes' where visita_id in (:'v15'::uuid, :'v16'::uuid);
update cuidared.operacion_sync set actualizado_en_servidor = :'t0'::timestamptz - interval '10 minutes' where id_cliente in (:'kp3'::uuid, :'kp4'::uuid);
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v15'::uuid, pruebas.reg_4c(:'a1', 'Gana por marca del dispositivo.'),
  :'t0'::timestamptz - interval '90 minutes', :'t0'::timestamptz - interval '180 minutes')) as r20 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v16'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '150 minutes', :'t0'::timestamptz - interval '180 minutes')) as r21 \gset
reset role;
select pruebas.afirmar((:'r20'::jsonb)->>'resultado' = 'conflicto' and (:'r20'::jsonb)->>'gana' = 'local'
  and (select estado from cuidared.visita where visita_id = :'v15'::uuid) = 'completada', 'la marca del dispositivo de la otra operación decide, no su hora de llegada');
select pruebas.afirmar((:'r21'::jsonb)->>'resultado' = 'conflicto' and (:'r21'::jsonb)->>'gana' = 'servidor'
  and (select estado from cuidared.visita where visita_id = :'v16'::uuid) = 'en_curso', 'y una marca anterior a la suya pierde');

/* ───────────── Visitas cerradas: terminales (D10), nunca se modifican ───────────── */
-- Cancelada en línea (sin operación sincronizada): con cambios desde la base es un conflicto que gana el servidor…
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'cancelada', :'t0'::timestamptz - interval '30 minutes') as v17 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v17'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '10 minutes', :'t0'::timestamptz - interval '180 minutes')) as r22 \gset
-- … y sin cambios desde la base (el cliente ya veía la visita cancelada) es una operación inválida, como en línea.
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v17'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '9 minutes', :'t0'::timestamptz - interval '30 minutes')) as r23 \gset
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'iniciar', :'v17'::uuid, '{}'::jsonb,
  :'t0'::timestamptz - interval '10 minutes', :'t0'::timestamptz - interval '180 minutes')) as r24 \gset
reset role;
select pruebas.afirmar((:'r22'::jsonb)->>'resultado' = 'conflicto' and (:'r22'::jsonb)->>'gana' = 'servidor' and (:'r22'::jsonb)->>'motivo' = 'VISIT_CLOSED'
  and (:'r22'::jsonb)->>'actualizado_en_servidor' = pruebas.iso_4c(:'t0'::timestamptz - interval '30 minutes'),
  'visita cancelada con cambios: conflicto, gana el servidor (VISIT_CLOSED)');
select pruebas.afirmar((:'r23'::jsonb)->>'resultado' = 'rechazada' and (:'r23'::jsonb)->>'motivo' = 'VISIT_CLOSED'
  and (:'r23'::jsonb)->>'gana' is null, 'visita cancelada sin cambios: rechazada (VISIT_CLOSED)');
select pruebas.afirmar((:'r24'::jsonb)->>'resultado' = 'conflicto' and (:'r24'::jsonb)->>'motivo' = 'VISIT_CLOSED', 'iniciar una cancelada: igual');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v17'::uuid) = 'cancelada'
  and (select observacion from cuidared.detalle_visita where visita_id = :'v17'::uuid) is null
  and (select fecha_actualizacion from cuidared.visita where visita_id = :'v17'::uuid) = :'t0'::timestamptz - interval '30 minutes',
  'la visita cancelada no cambió, aunque la marca del cliente sea posterior');

-- Completada por una operación sincronizada: otra persona que registra después, con una base anterior, pierde.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'programada', :'t0'::timestamptz - interval '180 minutes') as v18 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v18'::uuid, pruebas.reg_4c(:'a1', 'Primera observación que queda.'),
  :'t0'::timestamptz - interval '100 minutes', :'t0'::timestamptz - interval '180 minutes')) ->> 'resultado' as r25 \gset
reset role;
select pruebas.afirmar(:'r25' = 'aplicada', 'el Cuidador completa la visita sin conexión');
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v18'::uuid, pruebas.reg_4c(:'a1', 'Otra observación posterior.'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '180 minutes')) as r26 \gset
reset role;
select pruebas.afirmar((:'r26'::jsonb)->>'resultado' = 'conflicto' and (:'r26'::jsonb)->>'gana' = 'servidor' and (:'r26'::jsonb)->>'motivo' = 'VISIT_CLOSED'
  and (select observacion from cuidared.detalle_visita where visita_id = :'v18'::uuid) = 'Primera observación que queda.',
  'una visita completada no se sobrescribe, ni siquiera con una marca más reciente');
-- Con la versión actual como base (el cliente ya veía la visita completada) no hay conflicto: la operación no es válida.
select visita_fecha as s18 from (select fecha_actualizacion as visita_fecha from cuidared.visita where visita_id = :'v18'::uuid) x \gset
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v18'::uuid, pruebas.reg_4c(:'a1', 'Otra observación posterior.'),
  :'t0'::timestamptz - interval '4 minutes', :'s18'::timestamptz)) as r27 \gset
reset role;
select pruebas.afirmar((:'r27'::jsonb)->>'resultado' = 'rechazada' and (:'r27'::jsonb)->>'motivo' = 'VISIT_CLOSED', 'completada y sin cambios: rechazada (VISIT_CLOSED)');

-- Registrar en una visita en curso (estado abierto) también se resuelve por LWW.
select pruebas.visita_4c(:org, :'a1'::uuid, :'cuid'::uuid, 'en_curso', :'t0'::timestamptz - interval '60 minutes') as v19 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', :'v19'::uuid, pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '60 minutes')) ->> 'resultado' as r28 \gset
reset role;
select pruebas.afirmar(:'r28' = 'aplicada' and (select estado from cuidared.visita where visita_id = :'v19'::uuid) = 'completada', 'registrar una visita en curso');

-- Una visita nueva (el id no existe) no tiene versión del servidor: se crea sin conflicto aunque traiga una base.
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_sync_aplicar_operacion(:org, pruebas.op_4c(gen_random_uuid(), 'registrar', gen_random_uuid(), pruebas.reg_4c(:'a1'),
  :'t0'::timestamptz - interval '5 minutes', :'t0'::timestamptz - interval '500 minutes')) ->> 'resultado' as r29 \gset
reset role;
select pruebas.afirmar(:'r29' = 'aplicada', 'la visita nueva no entra en conflicto');

rollback;
