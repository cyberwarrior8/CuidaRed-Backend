-- pruebas-4c-esquema.sql — Sincronización de visitas (4c): esquema de cuidared.operacion_sync, restricciones, RLS, privilegios y
-- funciones auxiliares (formato de marcas, comparación en milisegundos, validación de marcas de entrada). Requiere 2a, 3b y 4a:
-- `--solo=3a,3b,4a,4c`. Corre dentro de una transacción con ROLLBACK. © 2026 Equipo CuidaRed – INTEC.
begin;

select pruebas.usuario('adm4cD@x.test', '04500000001', 'Alba') as adm \gset
select pruebas.usuario('cuid4cD@x.test', '04500000002', 'Cora') as cuid \gset
select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as org \gset
select pruebas.miembro(:org, :'cuid', 'cuidador');

/* ───────────── Tabla ───────────── */
select pruebas.afirmar((select count(*) from information_schema.columns where table_schema = 'cuidared' and table_name = 'operacion_sync'
    and (column_name, data_type, is_nullable) in (
      ('id_cliente', 'uuid', 'NO'), ('usuario_id', 'uuid', 'NO'), ('cuenta_id', 'bigint', 'NO'),
      ('entidad', 'character varying', 'NO'), ('tipo', 'character varying', 'NO'), ('registro_id', 'uuid', 'NO'),
      ('resultado', 'character varying', 'NO'), ('motivo', 'character varying', 'YES'), ('gana', 'character varying', 'YES'),
      ('actualizado_en_cliente', 'timestamp with time zone', 'NO'), ('base_actualizado_en', 'timestamp with time zone', 'YES'),
      ('actualizado_en_servidor', 'timestamp with time zone', 'YES'), ('procesada_en', 'timestamp with time zone', 'NO'))) = 13,
  'columnas de operacion_sync');
select pruebas.afirmar((select array_agg(a.attname::text order by a.attname) from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
    where i.indrelid = 'cuidared.operacion_sync'::regclass and i.indisprimary) = array['id_cliente'], 'la clave primaria es id_cliente');
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.operacion_sync'::regclass), 'RLS activa');
select pruebas.afirmar(not has_table_privilege('authenticated', 'cuidared.operacion_sync', 'select')
  and not has_table_privilege('authenticated', 'cuidared.operacion_sync', 'insert')
  and not has_table_privilege('authenticated', 'cuidared.operacion_sync', 'update')
  and not has_table_privilege('authenticated', 'cuidared.operacion_sync', 'delete')
  and not has_table_privilege('anon', 'cuidared.operacion_sync', 'select')
  and not has_table_privilege('anon', 'cuidared.operacion_sync', 'insert'), 'sin acceso directo para los roles de la API');

-- Restricciones.
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'visita', 'registrar', gen_random_uuid(), 'rara', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'visita', 'registrar', gen_random_uuid(), 'rechazada', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  gana, actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'visita', 'registrar', gen_random_uuid(), 'aplicada', 'local', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'visita', 'registrar', gen_random_uuid(), 'conflicto', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  gana, actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'visita', 'registrar', gen_random_uuid(), 'conflicto', 'nadie', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  motivo, actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'Visita', 'registrar', gen_random_uuid(), 'rechazada', 'FORBIDDEN', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  motivo, actualizado_en_cliente) values (gen_random_uuid(), %L, %s, 'visita', 'registrar', gen_random_uuid(), 'rechazada', 'prohibido', now())$q$, :'cuid', :org), '23514');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  actualizado_en_cliente) values (gen_random_uuid(), gen_random_uuid(), %s, 'visita', 'registrar', gen_random_uuid(), 'aplicada', now())$q$, :org), '23503');
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  actualizado_en_cliente) values (gen_random_uuid(), %L, 999999, 'visita', 'registrar', gen_random_uuid(), 'aplicada', now())$q$, :'cuid'), '23503');
-- Filas válidas: una de cada resultado; la clave de idempotencia es única.
insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado, motivo, gana, actualizado_en_cliente)
values ('e0000000-0000-4000-8000-000000000001', :'cuid', :org, 'visita', 'registrar', gen_random_uuid(), 'aplicada', null, null, now()),
       ('e0000000-0000-4000-8000-000000000002', :'cuid', :org, 'visita', 'registrar', gen_random_uuid(), 'duplicada', 'YA_REGISTRADA', null, now()),
       ('e0000000-0000-4000-8000-000000000003', :'cuid', :org, 'visita', 'registrar', gen_random_uuid(), 'conflicto', 'SERVIDOR_MAS_RECIENTE', 'servidor', now()),
       ('e0000000-0000-4000-8000-000000000004', :'cuid', :org, 'necesidad', 'crear', gen_random_uuid(), 'rechazada', 'ENTIDAD_NO_SOPORTADA', null, now());
select pruebas.error(format($q$insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado,
  actualizado_en_cliente) values ('e0000000-0000-4000-8000-000000000001', %L, %s, 'visita', 'registrar', gen_random_uuid(), 'aplicada', now())$q$,
  :'cuid', :org), '23505');
select pruebas.afirmar((select procesada_en from cuidared.operacion_sync where id_cliente = 'e0000000-0000-4000-8000-000000000001') is not null,
  'procesada_en se completa sola');

-- sync_registrar: no pisa lo ya resuelto; sí reevalúa una rechazada, y solo para quien la envió.
select cuidared_interno.sync_registrar('e0000000-0000-4000-8000-000000000001', :'cuid', :org, 'visita', 'registrar', gen_random_uuid(),
  'rechazada', 'FORBIDDEN', null, now(), null, null);
select pruebas.afirmar((select resultado from cuidared.operacion_sync where id_cliente = 'e0000000-0000-4000-8000-000000000001') = 'aplicada',
  'una fila ya resuelta no se sobrescribe');
select cuidared_interno.sync_registrar('e0000000-0000-4000-8000-000000000004', :'adm', :org, 'necesidad', 'crear', gen_random_uuid(),
  'aplicada', null, null, now(), null, null);
select pruebas.afirmar((select resultado from cuidared.operacion_sync where id_cliente = 'e0000000-0000-4000-8000-000000000004') = 'rechazada',
  'otra persona no reevalúa una rechazada ajena');
select cuidared_interno.sync_registrar('e0000000-0000-4000-8000-000000000004', :'cuid', :org, 'necesidad', 'crear',
  (select registro_id from cuidared.operacion_sync where id_cliente = 'e0000000-0000-4000-8000-000000000004'),
  'rechazada', 'FORBIDDEN', null, now(), null, null);
select pruebas.afirmar((select motivo from cuidared.operacion_sync where id_cliente = 'e0000000-0000-4000-8000-000000000004') = 'FORBIDDEN',
  'quien la envió sí reevalúa una rechazada');

/* ───────────── Funciones auxiliares ───────────── */
select pruebas.afirmar(cuidared_interno.sync_iso('2026-11-06 12:34:56.789123+00') = '2026-11-06T12:34:56.789Z', 'sync_iso trunca a milisegundos y usa UTC');
select pruebas.afirmar(cuidared_interno.sync_iso('2026-11-06 08:34:56-04') = '2026-11-06T12:34:56.000Z', 'sync_iso convierte a UTC');
select pruebas.afirmar(cuidared_interno.sync_iso(null) is null, 'sync_iso de nulo es nulo');
select pruebas.afirmar(cuidared_interno.sync_ms('2026-11-06 12:34:56.789999+00') = '2026-11-06 12:34:56.789+00', 'sync_ms trunca a milisegundos');
select pruebas.afirmar(cuidared_interno.v_marca('"2026-11-06T12:34:56.789Z"') = '2026-11-06 12:34:56.789+00', 'v_marca acepta ISO UTC con milisegundos');
select pruebas.afirmar(cuidared_interno.v_marca('"2026-11-06T12:34:56Z"') = '2026-11-06 12:34:56+00', 'v_marca acepta ISO UTC sin fracción');
select pruebas.afirmar(cuidared_interno.v_marca('null', false) is null and cuidared_interno.v_marca(null, false) is null, 'v_marca opcional acepta nulo');
select pruebas.error($$select cuidared_interno.v_marca('null')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca(null)$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-11-06T12:34:56+00:00"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-11-06T12:34:56-04:00"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-11-06 12:34:56Z"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-11-06"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-13-06T12:34:56Z"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-02-30T12:34:56Z"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"2026-11-06T25:34:56Z"')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('1762432496')$$, '22023');
select pruebas.error($$select cuidared_interno.v_marca('"ayer"')$$, '22023');
select pruebas.afirmar((cuidared_interno.sync_item('e0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-0000000000aa',
    'aplicada', null, null, null, null) ? 'actualizado_en_servidor')
  and (cuidared_interno.sync_item('e0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-0000000000aa',
    'aplicada', null, null, null, null)->'actualizado_en_servidor') = 'null'::jsonb, 'sync_item siempre incluye la versión del servidor (nula si no hay)');

/* ───────────── Privilegios de las funciones ───────────── */
select pruebas.afirmar(has_function_privilege('authenticated', 'cuidared_api.api_sync_aplicar_operacion(bigint, jsonb)', 'execute')
  and has_function_privilege('authenticated', 'cuidared_api.api_sync_obtener_operacion(bigint, uuid)', 'execute'), 'las RPC de sync son ejecutables con sesión');
select pruebas.afirmar(not has_function_privilege('anon', 'cuidared_api.api_sync_aplicar_operacion(bigint, jsonb)', 'execute')
  and not has_function_privilege('anon', 'cuidared_api.api_sync_obtener_operacion(bigint, uuid)', 'execute'), 'las RPC de sync no son ejecutables sin sesión');
select pruebas.afirmar((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'cuidared_interno' and p.proname like 'sync\_%'
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))) = 0
  and not has_function_privilege('authenticated', 'cuidared_interno.v_marca(jsonb, boolean)', 'execute'),
  'las funciones internas de sync no son ejecutables por la API');
select pruebas.afirmar((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'cuidared_api' and p.proname like 'api\_sync\_%' and p.prosecdef and p.proconfig = array['search_path=""']) = 2,
  'las RPC de sync son security definer con search_path vacío');
select pruebas.afirmar((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'cuidared_interno' and p.proname like 'sync\_%' and p.proconfig = array['search_path=""']) = (select count(*)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cuidared_interno' and p.proname like 'sync\_%'),
  'las funciones internas de sync fijan search_path');

-- Sin sesión: el rol anon no puede ni llamar a las RPC de sync.
select set_config('request.jwt.claims', '', true);
set local role anon;
select pruebas.error(format('select cuidared_api.api_sync_aplicar_operacion(%s, %L)', :org, '{}'), '42501');
select pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%s, %L)', :org, gen_random_uuid()::text), '42501');
reset role;

rollback;
