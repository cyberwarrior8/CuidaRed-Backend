-- pruebas-4a-solicitudes.sql — Solicitudes de visita de personas externas: RPC públicas (anon), autorización, privacidad y
-- exposición mínima de cuidared_api (4a). Los adultos se crean con la ayuda común pruebas.envejeciente. Requiere 2a y 3b:
-- `--solo=3a,3b,4a`. Corre dentro de una transacción con ROLLBACK. © 2026 Equipo CuidaRed – INTEC.
begin;

/* ───────────── Ayudas locales ───────────── */
create function pruebas.hash_4a(p_codigo text) returns text language sql as $$
  select encode(sha256(convert_to(p_codigo, 'UTF8')), 'hex')
$$;
-- Cuerpo de solicitud válido; p_extra sobrescribe o agrega campos.
create function pruebas.sol_4a(p_cuenta bigint, p_codigo text, p_fecha date, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('cuenta_id', p_cuenta, 'nombres', 'Juan', 'apellidos', 'Pérez', 'cedula', '00112345678',
                            'telefono', '8095550100', 'persona_a_visitar', 'Doña Ana', 'fecha_propuesta', p_fecha,
                            'hora_propuesta', '10:30', 'motivo', 'Visita de compañía',
                            'codigo_hash', pruebas.hash_4a(p_codigo)) || p_extra
$$;

/* ───────────── Datos ───────────── */
select pruebas.usuario('adm4s@x.test', '04300000001', 'Alba') as adm \gset
select pruebas.usuario('coord4s@x.test', '04300000002', 'Carlos') as coord \gset
select pruebas.usuario('cuid4s@x.test', '04300000003', 'Cora') as cuid \gset
select pruebas.usuario('vol4s@x.test', '04300000004', 'Vera') as vol \gset
select pruebas.usuario('fam4s@x.test', '04300000005', 'Flor') as fam \gset
select pruebas.usuario('adm24s@x.test', '04300000006', 'Omar') as adm2 \gset
select pruebas.usuario('coord24s@x.test', '04300000007', 'Olga') as coord2 \gset
select pruebas.usuario('ftit4s@x.test', '04300000008', 'Fabio') as ftit \gset
select pruebas.usuario('exp4s@x.test', '04300000009', 'Ezra') as exp_adm \gset

select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as org \gset
select pruebas.miembro(:org, :'coord', 'coordinador');
select pruebas.miembro(:org, :'cuid', 'cuidador');
select pruebas.miembro(:org, :'vol', 'voluntario');
select pruebas.miembro(:org, :'fam', 'familiar');
select pruebas.cuenta('organizacion', :'adm2', 'activa', 'Operación Base') as org2 \gset
select pruebas.miembro(:org2, :'coord2', 'coordinador');
select pruebas.cuenta('familia', :'ftit') as fcta \gset
select pruebas.cuenta('organizacion', :'exp_adm', 'prueba', null, cuidared_interno.hoy() - 1) as vencida \gset

select pruebas.envejeciente(:org, 'Ana', 'Mayor') as a1 \gset
select pruebas.envejeciente(:org, 'Berta', 'Mayor') as a2 \gset
select pruebas.envejeciente(:org, 'Clara', 'Mayor') as a3 \gset
select pruebas.envejeciente(:org2, 'Elena', 'Mayor') as b1 \gset
select cuidared_interno.hoy() as hoy, cuidared_interno.hoy() + 1 as manana, cuidared_interno.hoy() - 1 as ayer \gset
select 'VIS-AAAA-0001' as c1, 'VIS-AAAA-0002' as c2, 'VIS-AAAA-0003' as c3, 'VIS-AAAA-0004' as c4,
       'VIS-AAAA-0005' as c5, 'VIS-AAAA-0006' as c6, 'VIS-AAAA-0007' as c7 \gset

/* ───────────── Exposición mínima de cuidared_api a anon ───────────── */
select pruebas.afirmar(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'cuidared_api' and has_function_privilege('anon', p.oid, 'execute') and p.proname not like 'api\_publico\_%'),
  'anon solo ejecuta las funciones api_publico_*');
select pruebas.afirmar((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'cuidared_api' and has_function_privilege('anon', p.oid, 'execute')
    and p.proname in ('api_publico_listar_organizaciones', 'api_publico_crear_solicitud', 'api_publico_consultar_solicitud',
                      'api_publico_registrar_observacion')) = 4, 'las cuatro RPC públicas de 4a son ejecutables por anon');
select pruebas.afirmar(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'cuidared_api' and p.proname like 'api\_publico\_%'
    and not (p.prosecdef and 'search_path=""' = any (p.proconfig))), 'las RPC públicas son security definer con search_path vacío');
select pruebas.afirmar(not has_table_privilege('anon', 'cuidared.solicitud_visita', 'select')
  and not has_table_privilege('authenticated', 'cuidared.solicitud_visita', 'select')
  and not has_table_privilege('anon', 'cuidared.solicitud_visita', 'insert'), 'sin acceso directo a solicitud_visita');
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.solicitud_visita'::regclass), 'RLS activa en solicitud_visita');

/* ───────────── Público: organizaciones ───────────── */
select set_config('request.jwt.claims', '', true);
set local role anon;
select cuidared_api.api_publico_listar_organizaciones() as orgs \gset
select pruebas.afirmar(jsonb_array_length(:'orgs'::jsonb) = 2
  and exists (select 1 from jsonb_array_elements(:'orgs'::jsonb) e where (e->>'cuenta_id')::bigint = :org)
  and exists (select 1 from jsonb_array_elements(:'orgs'::jsonb) e where (e->>'cuenta_id')::bigint = :org2),
  'solo organizaciones con acceso operativo');
select pruebas.afirmar(not exists (select 1 from jsonb_array_elements(:'orgs'::jsonb) e where (e->>'cuenta_id')::bigint in (:fcta, :vencida)),
  'ni familias ni cuentas vencidas');
select pruebas.afirmar(not exists (select 1 from jsonb_array_elements(:'orgs'::jsonb) e, jsonb_object_keys(e) k where k not in ('cuenta_id', 'nombre')),
  'solo cuenta_id y nombre');

/* ───────────── Público: crear solicitud ───────────── */
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org, :'c1', :'manana'::date)) as s1 \gset
select pruebas.afirmar((:'s1'::jsonb)->>'estado' = 'pendiente' and (:'s1'::jsonb) ? 'organizacion'
  and not exists (select 1 from jsonb_object_keys(:'s1'::jsonb) k where k not in ('organizacion', 'estado', 'fecha_propuesta', 'hora_propuesta')),
  'la respuesta solo contiene lo que el visitante necesita');
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org, :'c2', :'manana'::date)) ->> 'estado' as ok2 \gset
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org, :'c3', :'hoy'::date, '{"hora_propuesta":"23:59","correo":"Juan@Correo.TEST"}')) ->> 'estado' as ok3 \gset
-- Tope de pendientes por visitante (misma cédula en la misma cuenta).
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org, :'c4', :'manana'::date)::text),
  'P0001', 'CR_CONFLICTO');
-- Familia, vencida e inexistente responden igual: no se distingue.
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:fcta, :'c4', :'manana'::date)::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:vencida, :'c4', :'manana'::date)::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(999999, :'c4', :'manana'::date)::text), '22023');
-- Entrada estricta.
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'ayer'::date)::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"cedula":"abc"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"telefono":"123"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"correo":"sin-arroba"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"hora_propuesta":"25:00"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"motivo":"ab"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"cuenta_id":"1"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"estado":"autorizada"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"codigo_hash":"abc"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c4', :'manana'::date, '{"nombres":"A"}')::text), '22023');
select pruebas.error('select cuidared_api.api_publico_crear_solicitud(null)', '22023');
-- El mismo código no se puede registrar dos veces.
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, :'c1', :'manana'::date, '{"cedula":"00198765432"}')::text), '23505');
-- Otras personas y otras cuentas.
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org, :'c5', :'manana'::date, '{"cedula":"00111111111","nombres":"Rosa"}')) ->> 'estado' as ok5 \gset
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org2, :'c6', :'hoy'::date, '{"cedula":"00122222222","hora_propuesta":"23:59"}')) ->> 'estado' as ok6 \gset
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org, :'c7', :'hoy'::date, '{"cedula":"00133333333","hora_propuesta":"23:58"}')) ->> 'estado' as ok7 \gset
-- Sin acceso a lo privado.
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s)', :org), '42501');
select pruebas.error('select * from cuidared.solicitud_visita', '42501');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s)', :org), '42501');
reset role;

select pruebas.afirmar((select count(*) from cuidared.solicitud_visita where cuenta_id = :org) = 5, 'las solicitudes inválidas no se guardan');
select pruebas.afirmar((select codigo_hash from cuidared.solicitud_visita where visitante_correo is not null and cuenta_id = :org)
  = pruebas.hash_4a(:'c3'), 'solo se guarda el hash del código');
select pruebas.afirmar((select visitante_correo from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c3')) = 'juan@correo.test', 'correo normalizado');
select pruebas.afirmar((select count(*) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Nueva solicitud de visita de Juan Pérez%') = 8
  and (select count(distinct usuario_id) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Nueva solicitud de visita%'
       and usuario_id in (:'adm'::uuid, :'coord'::uuid)) = 2, 'aviso a los dos usuarios principales por cada solicitud de Juan Pérez (c1, c2, c3 y c7)');
select pruebas.afirmar((select count(*) from cuidared.notificacion where mensaje like '%00112345678%' or mensaje like '%8095550100%') = 0,
  'los avisos no incluyen cédula ni teléfono');

/* ───────────── Público: consultar y observar ───────────── */
select set_config('request.jwt.claims', '', true);
set local role anon;
select cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a(:'c1')) as q1 \gset
select pruebas.afirmar((:'q1'::jsonb)->>'estado' = 'pendiente' and (:'q1'::jsonb)->>'puede_registrar_observacion' = 'false'
  and not exists (select 1 from jsonb_object_keys(:'q1'::jsonb) k
    where k not in ('organizacion', 'estado', 'fecha', 'hora', 'motivo_rechazo', 'puede_registrar_observacion', 'observacion')),
  'estado público sin datos del adulto ni del personal');
select pruebas.afirmar(not ((:'q1'::jsonb)::text like '%00112345678%' or (:'q1'::jsonb)::text like '%8095550100%'), 'sin cédula ni teléfono');
select pruebas.error(format('select cuidared_api.api_publico_consultar_solicitud(%L)', pruebas.hash_4a('VIS-ZZZZ-9999')), 'P0002');
select pruebas.error('select cuidared_api.api_publico_consultar_solicitud(''no-es-un-hash'')', 'P0002');
select pruebas.error('select cuidared_api.api_publico_consultar_solicitud(null)', 'P0002');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a('VIS-ZZZZ-9999'), 'Todo bien.'), 'P0002');
-- Aún pendiente: no admite observaciones.
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c1'), 'Llegué y todo bien.'),
  'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
reset role;
-- Un usuario con sesión también puede usar las RPC públicas.
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_publico_listar_organizaciones()) = 2, 'las RPC públicas también sirven con sesión');
reset role;

/* ───────────── Gestión: quién puede y aislamiento ───────────── */
select solicitud_visita_id as sid1 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c1') \gset
select solicitud_visita_id as sid2 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c2') \gset
select solicitud_visita_id as sid3 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c3') \gset
select solicitud_visita_id as sid5 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c5') \gset
select solicitud_visita_id as sid6 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c6') \gset
select solicitud_visita_id as sid7 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a(:'c7') \gset

select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s)', :org), '42501');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '10:00')::text), '42501');
select pruebas.error(format('select cuidared_api.api_rechazar_solicitud_visita(%s, %L, %L)', :org, :'sid1', 'No procede.'), '42501');
reset role;
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s)', :org), '42501');
reset role;
select pruebas.como(:'fam');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s)', :org), '42501');
reset role;
-- Otra cuenta: no ve ni opera las solicitudes ajenas (igual que inexistentes).
select pruebas.como(:'coord2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s)', :org), '42501');
select pruebas.afirmar((cuidared_api.api_listar_solicitudes_visita(:org2)->>'total')::int = 1, 'otra cuenta: solo las suyas');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org2, :'sid1',
  jsonb_build_object('envejeciente_id', :'b1', 'fecha', :'manana'::text, 'hora', '10:00')::text), 'P0002');
select pruebas.error(format('select cuidared_api.api_rechazar_solicitud_visita(%s, %L, %L)', :org2, :'sid1', 'No procede.'), 'P0002');
select pruebas.error(format('select cuidared_api.api_rechazar_solicitud_visita(%s, %L, %L)', :org2, gen_random_uuid()::text, 'No procede.'), 'P0002');
reset role;

/* ───────────── Gestión: listar, autorizar y rechazar ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_listar_solicitudes_visita(:org) as l1 \gset
select pruebas.afirmar((:'l1'::jsonb)->>'total' = '5' and jsonb_array_length((:'l1'::jsonb)->'items') = 5, 'el gestor ve las solicitudes de su cuenta');
select pruebas.afirmar((:'l1'::jsonb)->'items'->0->'visitante'->>'cedula' is not null
  and (:'l1'::jsonb)->'items'->0->'visitante'->>'telefono' is not null, 'quien autoriza ve cédula y teléfono del visitante');
select pruebas.afirmar((cuidared_api.api_listar_solicitudes_visita(:org, '{"estado":"autorizada"}')->>'total')::int = 0, 'filtro por estado');
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s, %L)', :org, '{"estado":"x"}'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_solicitudes_visita(%s, %L, %L)', :org, '{}', '[{"campo":"motivo","direccion":"asc"}]'), '22023');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_solicitudes_visita(:org, '{}', '[]', 2, 4)->'items') = 1, 'paginación');

-- Autorizar: validaciones sin efecto sobre la solicitud.
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', :'b1', 'fecha', :'manana'::text, 'hora', '10:00')::text), '42501');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', gen_random_uuid(), 'fecha', :'manana'::text, 'hora', '10:00')::text), '42501');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'ayer'::text, 'hora', '10:00')::text), '22023');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '10:00', 'rol', 'x')::text), '22023');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '99:00')::text), '22023');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, gen_random_uuid()::text,
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '10:00')::text), 'P0002');

-- Autorizar crea la visita con participante y autorizador = quien autoriza.
select cuidared_api.api_autorizar_solicitud_visita(:org, :'sid1',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '10:00')) as av1 \gset
select pruebas.afirmar((:'av1'::jsonb)->>'origen' = 'solicitud' and (:'av1'::jsonb)->>'estado' = 'programada'
  and (:'av1'::jsonb)->'autorizada_por'->>'usuario_id' = :'coord' and jsonb_array_length((:'av1'::jsonb)->'participantes') = 1
  and (:'av1'::jsonb)->'participantes'->0->>'usuario_id' = :'coord', 'visita de origen solicitud autorizada por el actor');
select pruebas.afirmar((:'av1'::jsonb)->'visitante'->>'nombre' = 'Juan Pérez' and (:'av1'::jsonb)->>'notas' is null, 'solo el nombre del visitante');
select pruebas.afirmar(not ((:'av1'::jsonb)::text like '%00112345678%' or (:'av1'::jsonb)::text like '%8095550100%'),
  'la visita no expone cédula ni teléfono del visitante');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid1',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '11:00')::text), 'P0001', 'CR_SOLICITUD_REVISADA');
select pruebas.error(format('select cuidared_api.api_rechazar_solicitud_visita(%s, %L, %L)', :org, :'sid1', 'Ya no procede.'), 'P0001', 'CR_SOLICITUD_REVISADA');
reset role;
select (:'av1'::jsonb)->>'visita_id' as vis1 \gset
select pruebas.afirmar((select estado from cuidared.solicitud_visita where solicitud_visita_id = :'sid1'::uuid) = 'autorizada'
  and (select revisada_por from cuidared.solicitud_visita where solicitud_visita_id = :'sid1'::uuid) = :'coord'::uuid
  and (select envejeciente_id from cuidared.solicitud_visita where solicitud_visita_id = :'sid1'::uuid) = :'a1'::uuid
  and (select visita_id from cuidared.solicitud_visita where solicitud_visita_id = :'sid1'::uuid) = :'vis1'::uuid, 'solicitud autorizada y enlazada a la visita');
select pruebas.afirmar((select count(*) from cuidared.registro_visita where visita_id = :'vis1'::uuid and usuario_id = :'coord'::uuid
  and autorizada_por_usuario_id = :'coord'::uuid) = 1, 'participante y autorizador = quien autoriza');
-- Privacidad: ni la cédula ni el teléfono del visitante salen de solicitud_visita.
select pruebas.afirmar(not exists (select 1 from cuidared.visita v where v::text like '%00112345678%' or v::text like '%8095550100%'), 'visita sin datos del visitante');
select pruebas.afirmar(not exists (select 1 from cuidared.registro_visita v where v::text like '%00112345678%' or v::text like '%8095550100%'), 'registro_visita sin datos del visitante');
select pruebas.afirmar(not exists (select 1 from cuidared.detalle_visita v where v::text like '%00112345678%' or v::text like '%8095550100%'), 'detalle_visita sin datos del visitante');
select pruebas.afirmar(not exists (select 1 from cuidared.notificacion v where v::text like '%00112345678%' or v::text like '%8095550100%'), 'notificacion sin datos del visitante');

-- Rechazar y adulto inactivo.
update cuidared.envejeciente set estado = 'inactivo' where envejeciente_id = :'a3'::uuid;
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid2',
  jsonb_build_object('envejeciente_id', :'a3', 'fecha', :'manana'::text, 'hora', '10:00')::text), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_rechazar_solicitud_visita(%s, %L, %L)', :org, :'sid2', 'ab'), '22023');
select cuidared_api.api_rechazar_solicitud_visita(:org, :'sid2', 'No hay horario disponible ese día.') as rj2 \gset
select pruebas.afirmar((:'rj2'::jsonb)->>'estado' = 'rechazada' and (:'rj2'::jsonb)->>'motivo_rechazo' = 'No hay horario disponible ese día.', 'solicitud rechazada con motivo');
select pruebas.error(format('select cuidared_api.api_rechazar_solicitud_visita(%s, %L, %L)', :org, :'sid2', 'Otra vez.'), 'P0001', 'CR_SOLICITUD_REVISADA');
select pruebas.error(format('select cuidared_api.api_autorizar_solicitud_visita(%s, %L, %L)', :org, :'sid2',
  jsonb_build_object('envejeciente_id', :'a2', 'fecha', :'manana'::text, 'hora', '10:00')::text), 'P0001', 'CR_SOLICITUD_REVISADA');
-- Pendientes primero.
select pruebas.afirmar((cuidared_api.api_listar_solicitudes_visita(:org)->'items'->0->>'estado') = 'pendiente'
  and (cuidared_api.api_listar_solicitudes_visita(:org)->'items'->4->>'estado') <> 'pendiente', 'las pendientes van primero');
reset role;
update cuidared.envejeciente set estado = 'activo' where envejeciente_id = :'a3'::uuid;

/* ───────────── Visitante: consulta tras la revisión ───────────── */
select set_config('request.jwt.claims', '', true);
set local role anon;
select cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a(:'c2')) as q2 \gset
select pruebas.afirmar((:'q2'::jsonb)->>'estado' = 'rechazada' and (:'q2'::jsonb)->>'motivo_rechazo' = 'No hay horario disponible ese día.'
  and (:'q2'::jsonb)->>'puede_registrar_observacion' = 'false', 'el visitante ve el motivo del rechazo');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c2'), 'Quise pasar igual.'),
  'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
-- Autorizada para mañana: todavía no admite observación (la fecha de la visita es futura).
select cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a(:'c1')) as q1b \gset
select pruebas.afirmar((:'q1b'::jsonb)->>'estado' = 'autorizada' and (:'q1b'::jsonb)->>'fecha' = :'manana'
  and (:'q1b'::jsonb)->>'hora' = '10:00' and (:'q1b'::jsonb)->>'puede_registrar_observacion' = 'false', 'autorizada con la fecha de la visita');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c1'), 'Fue muy bien.'),
  'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
reset role;

/* ───────────── Visitante: observación el día de la visita ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_autorizar_solicitud_visita(:org, :'sid3',
  jsonb_build_object('envejeciente_id', :'a2', 'fecha', :'hoy'::text, 'hora', '23:59')) ->> 'visita_id' as vis3 \gset
select cuidared_api.api_autorizar_solicitud_visita(:org, :'sid7',
  jsonb_build_object('envejeciente_id', :'a2', 'fecha', :'hoy'::text, 'hora', '23:58')) ->> 'visita_id' as vis7 \gset
select cuidared_api.api_autorizar_solicitud_visita(:org, :'sid5',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '15:00')) ->> 'visita_id' as vis5 \gset
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select pruebas.afirmar((cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a(:'c3'))->>'puede_registrar_observacion')::boolean, 'hoy sí admite observación');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c3'), 'ab'), '22023');
select cuidared_api.api_publico_registrar_observacion(pruebas.hash_4a(:'c3'), 'La visita fue agradable, la señora estaba animada.') as o3 \gset
select pruebas.afirmar((:'o3'::jsonb)->>'estado' = 'realizada' and (:'o3'::jsonb)->>'observacion' = 'La visita fue agradable, la señora estaba animada.'
  and (:'o3'::jsonb)->>'puede_registrar_observacion' = 'false', 'visita realizada con la observación del visitante');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c3'), 'Otra observación.'),
  'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
reset role;
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'vis3'::uuid) = 'completada'
  and (select hora_inicio from cuidared.visita where visita_id = :'vis3'::uuid) is not null, 'la visita queda completada (contacto efectivo)');
select pruebas.afirmar((select observacion from cuidared.detalle_visita where visita_id = :'vis3'::uuid) = 'La visita fue agradable, la señora estaba animada.'
  and (select registrado_por from cuidared.detalle_visita where visita_id = :'vis3'::uuid) is null, 'observación en el detalle; el visitante no es usuario');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'vis5'::uuid) = 'programada', 'las demás visitas siguen programadas');

-- Si el personal completa la visita de una solicitud, la solicitud también queda realizada.
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_registrar_visita(:org, :'vis7', jsonb_build_object('detalles',
  jsonb_build_array(jsonb_build_object('envejeciente_id', :'a2', 'estado_general', 'estable', 'observacion', 'Recibió a la persona sin novedad.')))) ->> 'estado' as e7 \gset
select pruebas.afirmar(:'e7' = 'completada', 'el personal completa la visita de la solicitud');
reset role;
select pruebas.afirmar((select estado from cuidared.solicitud_visita where solicitud_visita_id = :'sid7'::uuid) = 'realizada', 'la solicitud pasa a realizada');

-- Cancelar la visita de una solicitud cancela la solicitud y bloquea la observación.
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_cancelar_visita(:org, :'vis5', 'El visitante avisó que no puede asistir.') ->> 'estado' as cv5 \gset
reset role;
select pruebas.afirmar(:'cv5' = 'cancelada' and (select estado from cuidared.solicitud_visita where solicitud_visita_id = :'sid5'::uuid) = 'cancelada',
  'solicitud cancelada junto con su visita');
set local role anon;
select set_config('request.jwt.claims', '', true);
select pruebas.afirmar(cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a(:'c5'))->>'estado' = 'cancelada', 'el visitante ve la cancelación');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c5'), 'Igual pasé por allí.'),
  'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
reset role;

-- Cuenta que pierde el acceso operativo (D07): no admite observaciones ni aparece en el listado público.
select pruebas.como(:'coord2');
set local role authenticated;
select cuidared_api.api_autorizar_solicitud_visita(:org2, :'sid6',
  jsonb_build_object('envejeciente_id', :'b1', 'fecha', :'hoy'::text, 'hora', '23:59')) ->> 'estado' as av6 \gset
reset role;
update cuidared.cuenta set suscripcion_estado = 'vencida' where cuenta_id = :org2;
set local role anon;
select set_config('request.jwt.claims', '', true);
select pruebas.afirmar((cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a(:'c6'))->>'puede_registrar_observacion') = 'false', 'cuenta vencida: sin observación');
select pruebas.error(format('select cuidared_api.api_publico_registrar_observacion(%L, %L)', pruebas.hash_4a(:'c6'), 'Todo bien por aquí.'),
  'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_publico_listar_organizaciones()) = 1, 'la cuenta vencida deja de listarse');
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)', pruebas.sol_4a(:org2, 'VIS-AAAA-0008', :'manana'::date, '{"cedula":"00144444444"}')::text), '22023');
reset role;

/* ───────────── La solicitud sigue a su visita (p. ej. la baja de un adulto, 3a, cancela sus visitas programadas) ───────────── */
select set_config('request.jwt.claims', '', true);
set local role anon;
select cuidared_api.api_publico_crear_solicitud(pruebas.sol_4a(:org, 'VIS-AAAA-0010', :'manana'::date, '{"cedula":"00166666666"}')) ->> 'estado' as ok8 \gset
reset role;
select solicitud_visita_id as sid8 from cuidared.solicitud_visita where codigo_hash = pruebas.hash_4a('VIS-AAAA-0010') \gset
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_autorizar_solicitud_visita(:org, :'sid8',
  jsonb_build_object('envejeciente_id', :'a1', 'fecha', :'manana'::text, 'hora', '09:00')) ->> 'visita_id' as vis8 \gset
reset role;
update cuidared.visita set estado = 'cancelada', motivo_cancelacion = 'Adulto dado de baja', cancelada_por = :'coord'::uuid,
  fecha_cancelacion = now(), fecha_actualizacion = now() where visita_id = :'vis8'::uuid;
select pruebas.afirmar((select estado from cuidared.solicitud_visita where solicitud_visita_id = :'sid8'::uuid) = 'cancelada',
  'la cancelación de la visita por otra vía cancela la solicitud');
select set_config('request.jwt.claims', '', true);
set local role anon;
select pruebas.afirmar(cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a('VIS-AAAA-0010'))->>'estado' = 'cancelada'
  and (cuidared_api.api_publico_consultar_solicitud(pruebas.hash_4a('VIS-AAAA-0010'))->>'puede_registrar_observacion') = 'false',
  'el visitante ve la cancelación y no puede dejar observación');
reset role;

/* ───────────── Topes por cuenta (las RPC públicas pueden llamarse sin pasar por Express) ───────────── */
select pruebas.usuario('adm34s@x.test', '04300000010', 'Tina') as adm3 \gset
select pruebas.cuenta('organizacion', :'adm3', 'activa', 'Operación Base') as org3 \gset
insert into cuidared.solicitud_visita (cuenta_id, visitante_nombres, visitante_apellidos, visitante_cedula, visitante_telefono,
  persona_a_visitar, fecha_propuesta, hora_propuesta, motivo, estado, codigo_hash)
select :org3, 'Persona', 'Prueba', lpad(g::text, 11, '0'), '8095550100', 'Alguien', current_date + 1, '10:00',
       'Motivo de prueba', 'pendiente', encode(sha256(convert_to('semilla' || g, 'UTF8')), 'hex')
from generate_series(1, 60) g;
select set_config('request.jwt.claims', '', true);
set local role anon;
select pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L)',
  pruebas.sol_4a(:org3, 'VIS-AAAA-0009', :'manana'::date, '{"cedula":"00155555555"}')::text), 'P0001', 'CR_SOLICITUD_NO_DISPONIBLE');
reset role;
select pruebas.afirmar((select count(*) from cuidared.solicitud_visita where cuenta_id = :org3) = 60, 'el tope por hora no guarda la solicitud excedente');
select pruebas.afirmar((cuidared_interno.bloquear_visita(gen_random_uuid())).visita_id is null, 'bloquear una visita inexistente devuelve fila vacía');

/* ───────────── Restricciones del modelo ───────────── */
select pruebas.error(format('update cuidared.solicitud_visita set estado = ''autorizada'' where solicitud_visita_id = %L', :'sid2'), '23514');
select pruebas.error(format('update cuidared.solicitud_visita set estado = ''pendiente'', motivo_rechazo = null where solicitud_visita_id = %L', :'sid1'), '23514');
select pruebas.error(format('update cuidared.solicitud_visita set codigo_hash = %L where solicitud_visita_id = %L', 'VIS-AAAA-0001', :'sid1'), '23514');
select pruebas.error(format('update cuidared.solicitud_visita set visitante_cedula = ''123'' where solicitud_visita_id = %L', :'sid1'), '23514');
select pruebas.error(format('update cuidared.solicitud_visita set codigo_hash = %L where solicitud_visita_id = %L', pruebas.hash_4a(:'c1'), :'sid3'), '23505');
rollback;
