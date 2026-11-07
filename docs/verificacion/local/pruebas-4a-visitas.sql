-- pruebas-4a-visitas.sql — Programación con autorización, inicio, registro, cancelación, historial y aislamiento (4a).
-- Los adultos se crean con la ayuda común pruebas.envejeciente y los vínculos con insert directos como superusuario (otros
-- bloques construyen esos módulos). Requiere 2a y 3b: `--solo=3a,3b,4a`. Corre dentro de una transacción con ROLLBACK. © 2026 Equipo CuidaRed – INTEC.
begin;

/* ───────────── Ayudas locales ───────────── */
create function pruebas.vincular_4a(p_adulto uuid, p_usuario uuid, p_tipo text) returns void language sql as $$
  insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select p_adulto, p_usuario, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = p_tipo
$$;
create function pruebas.prog_4a(p_fecha date, p_hora text, p_adultos uuid[], p_parts uuid[], p_razon text default 'Visita de rutina')
returns jsonb language sql as $$
  select jsonb_build_object('fecha', p_fecha, 'hora_programada', p_hora, 'razon', p_razon,
                            'envejeciente_ids', to_jsonb(p_adultos), 'participante_ids', to_jsonb(p_parts))
$$;
create function pruebas.det_4a(p_adulto uuid, p_estado text, p_obs text default 'Se encuentra bien y colabora.')
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('envejeciente_id', p_adulto, 'estado_general', p_estado, 'observacion', p_obs))
$$;

/* ───────────── Datos ───────────── */
select pruebas.usuario('adm4a@x.test', '04100000001', 'Alba') as adm \gset
select pruebas.usuario('coord4a@x.test', '04100000002', 'Carlos') as coord \gset
select pruebas.usuario('cuid4a@x.test', '04100000003', 'Cora') as cuid \gset
select pruebas.usuario('cuid24a@x.test', '04100000004', 'Dani') as cuid2 \gset
select pruebas.usuario('vol4a@x.test', '04100000005', 'Vera') as vol \gset
select pruebas.usuario('vol24a@x.test', '04100000006', 'Vicente') as vol2 \gset
select pruebas.usuario('fam4a@x.test', '04100000007', 'Flor') as fam \gset
select pruebas.usuario('adm24a@x.test', '04100000008', 'Omar') as adm2 \gset
select pruebas.usuario('coord24a@x.test', '04100000009', 'Olga') as coord2 \gset
select pruebas.usuario('ftit4a@x.test', '04100000010', 'Fabio') as ftit \gset
select pruebas.usuario('fcuid4a@x.test', '04100000011', 'Fela') as fcuid \gset
select pruebas.usuario('exp4a@x.test', '04100000012', 'Ezra') as exp_adm \gset

select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as org \gset
select pruebas.miembro(:org, :'coord', 'coordinador');
select pruebas.miembro(:org, :'cuid', 'cuidador');
select pruebas.miembro(:org, :'cuid2', 'cuidador');
select pruebas.miembro(:org, :'vol', 'voluntario');
select pruebas.miembro(:org, :'vol2', 'voluntario');
select pruebas.miembro(:org, :'fam', 'familiar');
select pruebas.cuenta('organizacion', :'adm2', 'activa', 'Operación Base') as org2 \gset
select pruebas.miembro(:org2, :'coord2', 'coordinador');
select pruebas.cuenta('familia', :'ftit') as fcta \gset
select pruebas.miembro(:fcta, :'fcuid', 'cuidador');
select pruebas.cuenta('organizacion', :'exp_adm', 'prueba', null, cuidared_interno.hoy() - 1) as vencida \gset

select pruebas.envejeciente(:org, 'Ana', 'Mayor') as a1 \gset
select pruebas.envejeciente(:org, 'Berta', 'Mayor') as a2 \gset
select pruebas.envejeciente(:org, 'Clara', 'Mayor') as a3 \gset
select pruebas.envejeciente(:org, 'Delia', 'Mayor', 'F', 'inactivo') as a4 \gset
select pruebas.envejeciente(:org2, 'Elena', 'Mayor') as b1 \gset
select pruebas.envejeciente(:fcta, 'Flavia', 'Mayor') as f1 \gset
select cuidared_interno.hoy() as hoy, cuidared_interno.hoy() + 1 as manana, cuidared_interno.hoy() - 1 as ayer \gset

/* ───────────── Programar ───────────── */
select pruebas.como(:'coord');
set local role authenticated;

select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'hoy'::date, '23:59', array[:'a1', :'a2']::uuid[], array[:'cuid', :'vol']::uuid[])) as j1 \gset
select (:'j1'::jsonb)->>'visita_id' as v1 \gset
select pruebas.afirmar((:'j1'::jsonb)->>'estado' = 'programada' and (:'j1'::jsonb)->>'origen' = 'interna', 'visita programada de origen interno');
select pruebas.afirmar(jsonb_array_length((:'j1'::jsonb)->'adultos') = 2 and jsonb_array_length((:'j1'::jsonb)->'participantes') = 2, 'adultos y participantes');
select pruebas.afirmar((:'j1'::jsonb)->'autorizada_por'->>'usuario_id' = :'coord', 'autorizada por quien programa');
select pruebas.afirmar(not ((:'j1'::jsonb)::text like '%cedula%'), 'la representación no expone cédulas');

select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1']::uuid[], array[:'cuid2']::uuid[])) ->> 'visita_id' as v2 \gset
select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'hoy'::date, '23:58', array[:'a1']::uuid[], array[:'vol']::uuid[])) ->> 'visita_id' as v6 \gset
select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'hoy'::date, '23:57', array[:'a3']::uuid[], array[:'cuid2']::uuid[])) ->> 'visita_id' as v7 \gset
select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'hoy'::date, '23:56', array[:'a2']::uuid[], array[:'cuid']::uuid[])) ->> 'visita_id' as v8 \gset

-- Entradas inválidas y reglas de participantes y adultos.
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'ayer'::date, '10:00', array[:'a1']::uuid[], array[:'cuid']::uuid[])::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'hoy'::date, '00:00', array[:'a1']::uuid[], array[:'cuid']::uuid[])::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  (pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1']::uuid[], array[:'cuid']::uuid[]) || '{"fecha":"2026-02-30"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  (pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1']::uuid[], array[:'cuid']::uuid[]) || '{"hora_programada":"25:00"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1']::uuid[], array[:'cuid']::uuid[], 'ab')::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  (pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1']::uuid[], array[:'cuid']::uuid[]) || '{"rol":"admin"}')::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '10:00', array[]::uuid[], array[:'cuid']::uuid[])::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1', :'a1']::uuid[], array[:'cuid']::uuid[])::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1', :'a2', :'a3', :'a1', :'a2']::uuid[], array[:'cuid']::uuid[])::text), '22023');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '10:00', array[:'a1']::uuid[], array[:'cuid', :'cuid2', :'vol', :'vol2']::uuid[])::text), '22023');
-- Participantes: administrador, familiar, ajeno a la cuenta o inexistente → CR_PARTICIPANTE_INVALIDO.
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[:'a1']::uuid[], array[:'adm']::uuid[])::text), 'P0001', 'CR_PARTICIPANTE_INVALIDO');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[:'a1']::uuid[], array[:'fam']::uuid[])::text), 'P0001', 'CR_PARTICIPANTE_INVALIDO');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[:'a1']::uuid[], array[:'coord2']::uuid[])::text), 'P0001', 'CR_PARTICIPANTE_INVALIDO');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[:'a1']::uuid[], array[gen_random_uuid()]::uuid[])::text), 'P0001', 'CR_PARTICIPANTE_INVALIDO');
-- Adultos de otra cuenta o inexistentes: el mismo 42501.
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[:'b1']::uuid[], array[:'cuid']::uuid[])::text), '42501');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[gen_random_uuid()]::uuid[], array[:'cuid']::uuid[])::text), '42501');
-- Adulto inactivo y participante ocupado a esa hora.
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '11:00', array[:'a4']::uuid[], array[:'cuid']::uuid[])::text), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'hoy'::date, '23:59', array[:'a3']::uuid[], array[:'cuid']::uuid[])::text), 'P0001', 'CR_PARTICIPANTE_OCUPADO');
reset role;

-- Efectos en las tablas: vínculos creados, autorización registrada, cuenta asignada.
select pruebas.afirmar((select count(*) from cuidared.vinculo l join cuidared.tipo_vinculo t using (tipo_vinculo_id)
  where l.envejeciente_id in (:'a1'::uuid, :'a2'::uuid) and l.usuario_id = :'cuid'::uuid and t.codigo = 'cuidador_asignado') = 2, 'vínculos de cuidador creados');
select pruebas.afirmar((select count(*) from cuidared.vinculo l join cuidared.tipo_vinculo t using (tipo_vinculo_id)
  where l.envejeciente_id = :'a1'::uuid and l.usuario_id = :'vol'::uuid and t.codigo = 'voluntario_asignado') = 1, 'vínculo de voluntario creado');
select pruebas.afirmar((select count(*) from cuidared.registro_visita where visita_id = :'v1'::uuid and autorizada_por_usuario_id = :'coord'::uuid) = 2,
  'cada participante queda autorizado por quien programa');
select pruebas.afirmar((select cuenta_id from cuidared.visita where visita_id = :'v1'::uuid) = :org, 'la visita pertenece a la cuenta');
select pruebas.afirmar((select count(*) from cuidared.visita where cuenta_id = :org) = 5, 'las entradas inválidas no crean visitas');

-- Quién puede programar: el Administrador sí; Cuidador, Voluntario y Familiar no.
select pruebas.como(:'adm');
set local role authenticated;
select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'manana'::date, '09:00', array[:'a3']::uuid[], array[:'cuid2', :'coord']::uuid[])) ->> 'visita_id' as v4 \gset
reset role;
select pruebas.afirmar((select creada_por from cuidared.visita where visita_id = :'v4'::uuid) = :'adm'::uuid, 'el administrador programa y autoriza');
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '15:00', array[:'a1']::uuid[], array[:'cuid']::uuid[])::text), '42501');
reset role;
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '15:00', array[:'a1']::uuid[], array[:'vol']::uuid[])::text), '42501');
reset role;
select pruebas.como(:'fam');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L)', :org,
  pruebas.prog_4a(:'manana'::date, '15:00', array[:'a1']::uuid[], array[:'cuid']::uuid[])::text), '42501');
reset role;

-- Familia: el Coordinador programa y autoriza; el Cuidador participa.
select pruebas.como(:'ftit');
set local role authenticated;
select cuidared_api.api_programar_visita(:fcta, pruebas.prog_4a(:'manana'::date, '10:00', array[:'f1']::uuid[], array[:'fcuid', :'ftit']::uuid[])) ->> 'visita_id' as fv1 \gset
reset role;
select pruebas.afirmar((select count(*) from cuidared.registro_visita where visita_id = :'fv1'::uuid) = 2, 'visita de Familia con dos participantes');

/* ───────────── Historial: alcance, filtros, paginación y orden ───────────── */
-- Resumen: v1 (hoy 23:59, a1+a2, cuid+vol), v2 (mañana, a1, cuid2), v4 (mañana 09:00, a3, cuid2+coord), v6, v7, v8.
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org)->>'total')::int = 6, 'el gestor ve todas las de la cuenta');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, '{"estado":"programada"}')->>'total')::int = 6, 'filtro por estado');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, '{"estado":"completada"}')->>'total')::int = 0, 'sin completadas aún');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, jsonb_build_object('envejeciente_id', :'a3'))->>'total')::int = 2, 'filtro por adulto (v4 y v7)');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, jsonb_build_object('desde', :'manana'))->>'total')::int = 2, 'filtro desde');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, jsonb_build_object('hasta', :'hoy'))->>'total')::int = 4, 'filtro hasta');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, '{}', '[]', 2, 0)->'items')::text <> '[]'
  and jsonb_array_length(cuidared_api.api_listar_visitas(:org, '{}', '[]', 2, 0)->'items') = 2, 'página de 2');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_visitas(:org, '{}', '[]', 2, 4)->'items') = 2
  and (cuidared_api.api_listar_visitas(:org, '{}', '[]', 2, 4)->>'total')::int = 6, 'última página');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_visitas(:org, '{}', '[]', 2, 40)->'items') = 0
  and (cuidared_api.api_listar_visitas(:org, '{}', '[]', 2, 40)->>'total')::int = 6, 'página fuera del conjunto');
select pruebas.afirmar(cuidared_api.api_listar_visitas(:org, '{}', '[{"campo":"fecha","direccion":"asc"},{"campo":"hora_programada","direccion":"asc"}]', 1, 0)->'items'->0->>'visita_id' = :'v8',
  'orden ascendente por fecha y hora');
select pruebas.afirmar(cuidared_api.api_listar_visitas(:org, '{}', '[{"campo":"fecha","direccion":"desc"},{"campo":"hora_programada","direccion":"desc"}]', 1, 0)->'items'->0->>'visita_id' = :'v2',
  'orden descendente por fecha y hora');
select pruebas.afirmar(cuidared_api.api_listar_visitas(:org, '{}', '[]', 100, 0)->'items'->0 ? 'visita_id', 'el listado incluye visita_id');
select pruebas.afirmar(not (cuidared_api.api_listar_visitas(:org, '{}', '[]', 100, 0)->'items'->0->'adultos'->0 ? 'observacion'), 'el listado no incluye observaciones');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L)', :org, '{"estado":"borrada"}'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L)', :org, '{"cuenta_id":1}'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L)', :org, '{"desde":"2030-01-02","hasta":"2030-01-01"}'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L, %L)', :org, '{}', '[{"campo":"razon","direccion":"asc"}]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L, %L)', :org, '{}', '[{"campo":"fecha; drop table cuidared.visita","direccion":"asc"}]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L, %L)', :org, '{}', '[{"campo":"fecha","direccion":"asc; --"}]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L, %L, 0, 0)', :org, '{}', '[]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L, %L, 101, 0)', :org, '{}', '[]'), '22023');
-- Filtrar por un adulto de otra cuenta o inexistente = adulto inexistente.
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L)', :org, jsonb_build_object('envejeciente_id', :'b1')::text), 'P0002');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s, %L)', :org, jsonb_build_object('envejeciente_id', gen_random_uuid())::text), 'P0002');
reset role;

-- Cuidador: las visitas en que participa o con adultos que alcanza (a1, a2 por la programación de v1 y v8).
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org)->>'total')::int = 4, 'cuidador: v1, v2 (a1), v6 (a1) y v8');
select pruebas.afirmar((cuidared_api.api_obtener_visita(:org, :'v1')->'adultos'->0->>'estado_general') is null, 'visita sin registrar: sin estado');
select pruebas.error(format('select cuidared_api.api_obtener_visita(%s, %L)', :org, :'v4'), 'P0002');
reset role;
-- Voluntario sin vínculos ni participación: nada. Voluntario participante: lo suyo.
select pruebas.como(:'vol2');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org)->>'total')::int = 0, 'voluntario sin relación: ninguna visita');
select pruebas.error(format('select cuidared_api.api_obtener_visita(%s, %L)', :org, :'v1'), 'P0002');
reset role;
-- Familiar: solo los adultos autorizados (vínculo familiar). El alcance lo define alcanza_envejeciente.
select pruebas.vincular_4a(:'a2'::uuid, :'fam'::uuid, 'familiar_responsable');
select cuidared_interno.alcanza_envejeciente(:org, :'a2'::uuid, :'fam'::uuid) as fam_alcanza_a2 \gset
select pruebas.como(:'fam');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org)->>'total')::int = (case when :'fam_alcanza_a2' = 't' then 2 else 0 end),
  'familiar: visitas de los adultos autorizados (v1 y v8 incluyen a a2)');
select pruebas.afirmar(case when :'fam_alcanza_a2' = 't'
  then jsonb_array_length(cuidared_api.api_obtener_visita(:org, :'v1')->'adultos') = 1
   and (cuidared_api.api_obtener_visita(:org, :'v1')->'adultos'->0->>'envejeciente_id') = :'a2'
  else true end, 'familiar: el detalle solo incluye el adulto autorizado');
select pruebas.error(format('select cuidared_api.api_obtener_visita(%s, %L)', :org, :'v4'), 'P0002');
reset role;

-- Aislamiento entre cuentas: otra organización no ve ni opera visitas ajenas; una visita ajena = una inexistente.
select pruebas.como(:'coord2');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org2)->>'total')::int = 0, 'otra cuenta: sin visitas');
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s)', :org), '42501');
select pruebas.error(format('select cuidared_api.api_obtener_visita(%s, %L)', :org2, :'v1'), 'P0002');
select pruebas.error(format('select cuidared_api.api_obtener_visita(%s, %L)', :org2, gen_random_uuid()::text), 'P0002');
select pruebas.error(format('select cuidared_api.api_cancelar_visita(%s, %L, %L)', :org2, :'v1', 'Motivo de prueba'), 'P0002');
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org2, :'v1'), 'P0002');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org2, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'b1', 'estable')))::text), 'P0002');
reset role;

/* ───────────── Iniciar ───────────── */
select pruebas.como(:'vol2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v1'), 'P0002');
reset role;
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v1'), 'P0001', 'CR_NO_PARTICIPA');
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v2'), 'P0001', 'CR_ESTADO_INVALIDO');
reset role;
select pruebas.como(:'fam');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v1'), '42501');
reset role;
select pruebas.como(:'adm');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v1'), '42501');
reset role;
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar(cuidared_api.api_iniciar_visita(:org, :'v1')->>'estado' = 'en_curso'
  and cuidared_api.api_iniciar_visita(:org, :'v1')->>'hora_inicio' is not null, 'el participante inicia y es idempotente');
select pruebas.afirmar(cuidared_api.api_iniciar_visita(:org, :'v8')->>'estado' = 'en_curso', 'v8 en curso');
reset role;

/* ───────────── Registrar realización ───────────── */
-- No participantes y datos incompletos.
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')))::text), 'P0001', 'CR_NO_PARTICIPA');
reset role;
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', null), pruebas.det_4a(:'a2', 'estable')))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable', 'ab'), pruebas.det_4a(:'a2', 'estable')))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a3', 'estable')))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'raro')))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')),
                     'checklist', jsonb_build_array('inventado'))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')),
                     'checklist', jsonb_build_array('higiene', 'higiene'))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')),
                     'hora_inicio', '12:00', 'hora_fin', '11:00')::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')), 'rol', 'admin')::text), '22023');
reset role;
-- Sin alcance sobre un adulto (el vínculo se perdió): 42501.
delete from cuidared.vinculo where envejeciente_id = :'a2'::uuid and usuario_id = :'cuid'::uuid;
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')))::text), '42501');
reset role;
select pruebas.vincular_4a(:'a2'::uuid, :'cuid'::uuid, 'cuidador_asignado');

-- Registro completo con situación crítica: completada, horas, checklist y notificación a los gestores.
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_registrar_visita(:org, :'v1', jsonb_build_object(
  'detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'situacion_critica', 'Presenta mareos y dificultad para caminar.')),
  'checklist', jsonb_build_array('alimentacion', 'higiene'))) as r1 \gset
select pruebas.afirmar((:'r1'::jsonb)->>'estado' = 'completada' and (:'r1'::jsonb)->>'hora_fin' is not null, 'visita completada con hora de fin');
select pruebas.afirmar((:'r1'::jsonb)->'checklist' = '["alimentacion","higiene"]'::jsonb, 'checklist guardado');
select pruebas.afirmar((select count(*) from jsonb_array_elements((:'r1'::jsonb)->'adultos') x where x->>'observacion' is not null) = 2, 'observación por adulto');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'estable')))::text), 'P0001', 'CR_VISITA_CERRADA');
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v1'), 'P0001', 'CR_VISITA_CERRADA');
reset role;
select pruebas.afirmar((select count(*) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Situación crítica%') = 2,
  'aviso a los dos gestores, no a quien reportó');
select pruebas.afirmar((select count(*) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Situación crítica%'
  and usuario_id in (:'adm'::uuid, :'coord'::uuid)) = 2, 'destinatarios: administrador y coordinador');
select pruebas.afirmar((select count(*) from cuidared.notificacion where mensaje like '%mareos%') = 0, 'el aviso no copia la observación');
select pruebas.afirmar((select count(*) from cuidared.detalle_visita where visita_id = :'v1'::uuid and registrado_por = :'cuid'::uuid) = 2,
  'quién registró cada detalle');

-- La cancelación no aplica a una visita completada.
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_cancelar_visita(%s, %L, %L)', :org, :'v1', 'Motivo de prueba'), 'P0001', 'CR_VISITA_CERRADA');
reset role;

-- Registro mínimo del Voluntario (sin estado general ni checklist) directamente desde programada.
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v6',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', null, 'ab')))::text), '22023');
select cuidared_api.api_registrar_visita(:org, :'v6', jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', null)))) as r6 \gset
select pruebas.afirmar((:'r6'::jsonb)->>'estado' = 'completada' and (:'r6'::jsonb)->'checklist' = '[]'::jsonb
  and (:'r6'::jsonb)->'adultos'->0->>'estado_general' is null, 'registro mínimo del voluntario');
reset role;

-- Un gestor con visitas:registrar (Coordinador) puede registrar una visita ajena; el Administrador no tiene el permiso.
select pruebas.como(:'adm');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v7',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a3', 'estable')))::text), '42501');
reset role;
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_registrar_visita(:org, :'v7', jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a3', 'requiere_atencion')))) ->> 'estado' as e7 \gset
select pruebas.afirmar(:'e7' = 'completada', 'el coordinador registra una visita de otro participante');
reset role;
select pruebas.afirmar((select registrado_por from cuidared.detalle_visita where visita_id = :'v7'::uuid) = :'coord'::uuid, 'queda el coordinador como registrador');
-- requiere_atencion no genera aviso crítico: siguen siendo 2.
select pruebas.afirmar((select count(*) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Situación crítica%') = 2, 'sin aviso crítico adicional');

-- Idempotencia de la función interna (reutilizada por la sincronización 4c): repetir no modifica ni duplica avisos.
select fecha_actualizacion as fa1 from cuidared.visita where visita_id = :'v1'::uuid \gset
select cuidared_interno.registrar_visita_realizada(:org, :'cuid'::uuid, :'v1'::uuid, jsonb_build_object(
  'detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable'), pruebas.det_4a(:'a2', 'situacion_critica')))) as ri \gset
select pruebas.afirmar((:'ri'::jsonb)->>'ya_registrada' = 'true' and (:'ri'::jsonb)->>'creada' = 'false', 'repetir es idempotente');
select pruebas.afirmar((select fecha_actualizacion from cuidared.visita where visita_id = :'v1'::uuid) = :'fa1'::timestamptz, 'no se vuelve a modificar');
select pruebas.afirmar((select count(*) from cuidared.notificacion where cuenta_id = :org and mensaje like 'Situación crítica%') = 2, 'no se duplican los avisos');
-- Revalida el permiso: un familiar no puede registrar aunque llame a la función interna.
select pruebas.error(format('select cuidared_interno.registrar_visita_realizada(%s, %L, %L, %L)', :org, :'fam', :'v1',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')))::text), '42501');

/* ───────────── Visita realizada sin programar ───────────── */
select gen_random_uuid() as x1, gen_random_uuid() as x2, gen_random_uuid() as x3 \gset
select pruebas.como(:'cuid');
set local role authenticated;
select cuidared_api.api_registrar_visita_realizada(:org, jsonb_build_object('visita_id', :'x1',
  'detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')), 'razon', 'Visita sin aviso previo')) as rr1 \gset
select pruebas.afirmar((:'rr1'::jsonb)->>'creada' = 'true' and (:'rr1'::jsonb)->'visita'->>'origen' = 'sin_programar'
  and (:'rr1'::jsonb)->'visita'->>'estado' = 'completada' and (:'rr1'::jsonb)->'visita'->>'visita_id' = :'x1', 'creada ya completada y sin programar');
select pruebas.afirmar((:'rr1'::jsonb)->'visita'->>'autorizada_por' is null, 'sin autorización previa');
-- Reintento con el mismo id: no duplica.
select cuidared_api.api_registrar_visita_realizada(:org, jsonb_build_object('visita_id', :'x1',
  'detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')), 'razon', 'Visita sin aviso previo')) as rr1b \gset
select pruebas.afirmar((:'rr1b'::jsonb)->>'creada' = 'false', 'el reintento no crea otra visita');
-- Sin alcance: a3 no está asignado a este cuidador; otra cuenta; fecha futura; id ajeno.
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a3', 'estable')))::text), '42501');
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'b1', 'estable')))::text), '42501');
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('fecha', :'manana'::text, 'detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')))::text), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('visita_id', :'v8', 'detalles', jsonb_build_array(pruebas.det_4a(:'a2', 'estable')))::text), 'P0001', 'CR_CONFLICTO');
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', null)))::text), '22023');
reset role;
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('visita_id', :'x1', 'detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')))::text), 'P0001', 'CR_CONFLICTO');
reset role;
select pruebas.como(:'coord2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org2,
  jsonb_build_object('visita_id', :'x1', 'detalles', jsonb_build_array(pruebas.det_4a(:'b1', 'estable')))::text), 'P0001', 'CR_CONFLICTO');
reset role;
select pruebas.afirmar((select count(*) from cuidared.visita where visita_id = :'x1'::uuid) = 1, 'una sola visita con ese id');
select pruebas.afirmar((select count(*) from cuidared.registro_visita where visita_id = :'x1'::uuid) = 1
  and (select count(*) from cuidared.detalle_visita where visita_id = :'x1'::uuid) = 1, 'un participante y un detalle');
-- Voluntario: registro mínimo directo.
select pruebas.como(:'vol');
set local role authenticated;
select cuidared_api.api_registrar_visita_realizada(:org, jsonb_build_object('visita_id', :'x2',
  'detalles', jsonb_build_array(pruebas.det_4a(:'a1', null)))) -> 'visita' ->> 'estado' as e_x2 \gset
select pruebas.afirmar(:'e_x2' = 'completada', 'el voluntario registra una visita mínima directa');
reset role;
-- El Familiar no registra.
select pruebas.como(:'fam');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_visita_realizada(%s, %L)', :org,
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a2', 'estable')))::text), '42501');
reset role;

/* ───────────── Cancelar ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_cancelar_visita(%s, %L, %L)', :org, :'v2', 'Motivo de prueba'), '42501');
reset role;
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_cancelar_visita(%s, %L, %L)', :org, :'v2', 'ab'), '22023');
select pruebas.error(format('select cuidared_api.api_cancelar_visita(%s, %L, %L)', :org, gen_random_uuid()::text, 'Motivo de prueba'), 'P0002');
select cuidared_api.api_cancelar_visita(:org, :'v2', 'El adulto está hospitalizado.') as c2 \gset
select pruebas.afirmar((:'c2'::jsonb)->>'estado' = 'cancelada' and (:'c2'::jsonb)->>'motivo_cancelacion' = 'El adulto está hospitalizado.', 'visita cancelada con motivo');
select pruebas.error(format('select cuidared_api.api_cancelar_visita(%s, %L, %L)', :org, :'v2', 'Otro motivo'), 'P0001', 'CR_VISITA_CERRADA');
-- Cancelar una visita en curso.
select cuidared_api.api_cancelar_visita(:org, :'v8', 'Se suspende por lluvia fuerte.') ->> 'estado' as c8 \gset
select pruebas.afirmar(:'c8' = 'cancelada', 'se cancela una visita en curso');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, '{"estado":"cancelada"}')->>'total')::int = 2, 'canceladas en el historial');
select pruebas.afirmar((cuidared_api.api_listar_visitas(:org, '{"estado":"completada"}')->>'total')::int = 5, 'completadas: v1, v6, v7, x1 y x2');
reset role;
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L)', :org, :'v2'), 'P0001', 'CR_VISITA_CERRADA');
select pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L, %L)', :org, :'v2',
  jsonb_build_object('detalles', jsonb_build_array(pruebas.det_4a(:'a1', 'estable')))::text), 'P0001', 'CR_VISITA_CERRADA');
reset role;
select pruebas.afirmar((select cancelada_por from cuidared.visita where visita_id = :'v2'::uuid) = :'coord'::uuid, 'quién canceló');
-- Solo lo completado cuenta como contacto efectivo: programada y cancelada no.
select pruebas.afirmar((select count(*) from cuidared.visita where cuenta_id = :org and estado = 'completada') = 5
  and (select count(*) from cuidared.visita where cuenta_id = :org and estado in ('programada', 'cancelada', 'en_curso')) = 3,
  'estados finales coherentes (contacto efectivo = completada)');

/* ───────────── Vínculo revocado (3b): no da alcance y programar lo renueva ───────────── */
update cuidared.vinculo set fecha_revocacion = clock_timestamp(), motivo_revocacion = 'Fin de turno'
  where envejeciente_id = :'a1'::uuid and usuario_id = :'cuid'::uuid;
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:org, :'a1'::uuid, :'cuid'::uuid), 'un vínculo revocado no da alcance');
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_programar_visita(:org, pruebas.prog_4a(:'manana'::date, '12:00', array[:'a1']::uuid[], array[:'cuid']::uuid[])) ->> 'visita_id' as v9 \gset
reset role;
select pruebas.afirmar(cuidared_interno.alcanza_envejeciente(:org, :'a1'::uuid, :'cuid'::uuid), 'programar renueva el vínculo revocado');
select pruebas.afirmar((select l.fecha_revocacion is null and l.motivo_revocacion is null and l.autorizado_por_usuario_id = :'coord'::uuid
                        from cuidared.vinculo l where l.envejeciente_id = :'a1'::uuid and l.usuario_id = :'cuid'::uuid),
  'el vínculo renovado limpia la revocación y registra a quien programa como autorizador');
select pruebas.afirmar((select count(*) from cuidared.vinculo where envejeciente_id = :'a1'::uuid and usuario_id = :'cuid'::uuid) = 1,
  'se reutiliza la misma fila de vínculo');

/* ───────────── Cuenta vencida, sin sesión y acceso directo ───────────── */
select pruebas.como(:'exp_adm');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s)', :vencida), 'P0001', 'CR_CUENTA_SIN_ACCESO');
reset role;
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s)', :org), '28000');
select pruebas.error('select * from cuidared.visita', '42501');
select pruebas.error('select * from cuidared.detalle_visita', '42501');
reset role;
set local role anon;
select pruebas.error(format('select cuidared_api.api_listar_visitas(%s)', :org), '42501');
select pruebas.error('select * from cuidared.visita', '42501');
reset role;

/* ───────────── Restricciones del modelo ───────────── */
select pruebas.error(format('insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (%L, %L)', :'v1', :'b1'), '23514');
select pruebas.error(format('update cuidared.visita set cuenta_id = %s where visita_id = %L', :org2, :'v1'), '23514');
select pruebas.error('insert into cuidared.visita(fecha, razon) values (current_date, ''Sin cuenta'')', '23514');
select pruebas.error(format('update cuidared.visita set checklist = array[''inventado''] where visita_id = %L', :'v1'), '23514');
select pruebas.error(format('update cuidared.visita set origen = ''solicitud'' where visita_id = %L', :'v1'), '23514');
select pruebas.error(format('update cuidared.visita set estado = ''cancelada'' where visita_id = %L', :'v4'), '23514');
select pruebas.error(format('update cuidared.visita set hora_fin = ''01:00'', hora_inicio = ''02:00'' where visita_id = %L', :'v4'), '23514');
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.visita'::regclass)
  and (select relrowsecurity from pg_class where oid = 'cuidared.detalle_visita'::regclass)
  and (select relrowsecurity from pg_class where oid = 'cuidared.registro_visita'::regclass), 'RLS activa en las tablas de visitas');
select pruebas.afirmar(not has_table_privilege('authenticated', 'cuidared.visita', 'select')
  and not has_table_privilege('anon', 'cuidared.visita', 'select')
  and not has_table_privilege('authenticated', 'cuidared.registro_visita', 'insert'), 'sin privilegios de tabla para los roles de la API');
select pruebas.afirmar(not has_function_privilege('authenticated', 'cuidared_interno.registrar_visita_realizada(bigint, uuid, uuid, jsonb)', 'execute'),
  'la función interna no es ejecutable por la API');
select pruebas.afirmar(not has_function_privilege('authenticated', 'cuidared_interno.iniciar_visita(bigint, uuid, uuid)', 'execute'),
  'iniciar_visita interna no es ejecutable por la API');
rollback;
