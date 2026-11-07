-- pruebas-3b-indicaciones-historial.sql — Indicaciones médicas (RF-15) e historial consolidado (RF-3.4 / CU-06).
-- © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('coord.ih3b@x.test', '00132000001', 'Patricia') as coord \gset
select pruebas.usuario('cuid.ih3b@x.test', '00132000002', 'Carla') as cuid \gset
select pruebas.usuario('cuid2.ih3b@x.test', '00132000003', 'Camila') as cuid2 \gset
select pruebas.usuario('fami.ih3b@x.test', '00132000004', 'Fabio') as fami \gset
select pruebas.usuario('fami2.ih3b@x.test', '00132000005', 'Flavia') as fami2 \gset
select pruebas.usuario('adm.ih3b@x.test', '00132000006', 'Andrea') as adm \gset
select pruebas.usuario('coord.org.ih3b@x.test', '00132000007', 'Laura') as org_coord \gset
select pruebas.usuario('vol.ih3b@x.test', '00132000008', 'Vera') as vol \gset
select pruebas.usuario('otra.ih3b@x.test', '00132000009', 'Olga') as otra \gset
select pruebas.cuenta('familia', :'coord') as cta \gset
select pruebas.miembro(:cta, :'cuid', 'cuidador');
select pruebas.miembro(:cta, :'cuid2', 'cuidador');
select pruebas.miembro(:cta, :'fami', 'familiar');
select pruebas.miembro(:cta, :'fami2', 'familiar');
select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as cta_org \gset
select pruebas.miembro(:cta_org, :'org_coord', 'coordinador');
select pruebas.miembro(:cta_org, :'vol', 'voluntario');
select pruebas.cuenta('familia', :'otra') as cta_otra \gset
select pruebas.adulto_3b(:cta, '93200000001') as adulto \gset
select pruebas.adulto_3b(:cta, '93200000002') as adulto2 \gset
select pruebas.adulto_3b(:cta_org, '93200000003') as adulto_org \gset
select pruebas.adulto_3b(:cta_otra, '93200000004') as adulto_otra \gset
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'adulto', :'cuid', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'adulto', :'fami', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'familiar_responsable';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'adulto_org', :'vol', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'voluntario_asignado';
insert into cuidared.tipo_indicacion (nombre) values ('Medicamento 3b') returning tipo_indicacion_id as tipo_med \gset
insert into cuidared.riesgo (nombre) values ('Riesgo de caídas 3b') returning riesgo_id as f_caidas \gset

/* ───────────── Crear indicaciones (indicaciones:gestionar + alcance) ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_indicacion_crear(:cta, :'adulto', format(
  '{"tipo_indicacion_id": %s, "titulo": "  Metformina 850 mg  ", "descripcion": "Con las comidas", "frecuencia_horario": "Cada 12 horas", "fecha_inicio": "2026-10-01", "fecha_fin": "2026-12-31"}', :tipo_med)::jsonb)::text as ind1 \gset
select (:'ind1'::jsonb->>'indicacion_medica_id') as ind1_id \gset
select pruebas.afirmar((:'ind1'::jsonb->>'titulo') = 'Metformina 850 mg' and (:'ind1'::jsonb->>'estado') = 'activa'
  and (:'ind1'::jsonb->>'registrado_por') = :'coord' and (:'ind1'::jsonb->>'actualizado_por') = :'coord'
  and (:'ind1'::jsonb->>'tipo') = 'Medicamento 3b' and (:'ind1'::jsonb->>'fecha_inicio') = '2026-10-01', 'crea la indicación activa con autoría');
select cuidared_api.api_indicacion_crear(:cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Fisioterapia", "fecha_inicio": "2026-10-15"}', :tipo_med)::jsonb)::text as ind2 \gset
select pruebas.afirmar((:'ind2'::jsonb->'descripcion') = 'null'::jsonb and (:'ind2'::jsonb->'fecha_fin') = 'null'::jsonb, 'descripción, frecuencia y fin son opcionales');
select (:'ind2'::jsonb->>'indicacion_medica_id') as ind2_id \gset
select cuidared_api.api_indicacion_crear(:cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Dieta baja en sal", "fecha_inicio": "2026-11-01"}', :tipo_med)::jsonb)::text as ind3 \gset
-- Entradas inválidas.
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', '{"tipo_indicacion_id": 1, "titulo": "x", "fecha_inicio": "2026-10-01"}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Sin inicio"}', :tipo_med)), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Fecha falsa", "fecha_inicio": "2026-02-30"}', :tipo_med)), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Fin previo", "fecha_inicio": "2026-10-01", "fecha_fin": "2026-09-30"}', :tipo_med)), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', '{"tipo_indicacion_id": 9999, "titulo": "Tipo inexistente", "fecha_inicio": "2026-10-01"}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Estado ajeno", "fecha_inicio": "2026-10-01", "estado": "finalizada"}', :tipo_med)), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Larga", "descripcion": "%s", "fecha_inicio": "2026-10-01"}', :tipo_med, repeat('x', 301))), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', '[]'), '22023');
-- Un adulto de otra cuenta se trata igual que uno inexistente.
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto_otra', format('{"tipo_indicacion_id": %s, "titulo": "Ajena", "fecha_inicio": "2026-10-01"}', :tipo_med)), '42501');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, gen_random_uuid(), format('{"tipo_indicacion_id": %s, "titulo": "Inexistente", "fecha_inicio": "2026-10-01"}', :tipo_med)), '42501');
reset role;

-- El cuidador asignado registra y actualiza; el no asignado, el familiar y el voluntario no.
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_indicacion_crear(:cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Insulina", "fecha_inicio": "2026-11-02"}', :tipo_med)::jsonb)->>'registrado_por') = :'cuid', 'el cuidador asignado registra indicaciones');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto2', format('{"tipo_indicacion_id": %s, "titulo": "Sin asignar", "fecha_inicio": "2026-10-01"}', :tipo_med)), '42501');
reset role;
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L)', :cta, :'adulto'), '42501');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{"titulo": "Cambio ajeno"}'), 'P0002');
select pruebas.error(format('select cuidared_api.api_indicacion_estado(%s, %L, %L)', :cta, :'ind1_id', 'suspendida'), 'P0002');
reset role;
select pruebas.como(:'fami');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta, :'adulto', format('{"tipo_indicacion_id": %s, "titulo": "Del familiar", "fecha_inicio": "2026-10-01"}', :tipo_med)), '42501');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{"titulo": "Cambio del familiar"}'), '42501');
select pruebas.error(format('select cuidared_api.api_indicacion_estado(%s, %L, %L)', :cta, :'ind1_id', 'finalizada'), '42501');
reset role;
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L)', :cta_org, :'adulto_org'), '42501');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta_org, :'adulto_org', format('{"tipo_indicacion_id": %s, "titulo": "Del voluntario", "fecha_inicio": "2026-10-01"}', :tipo_med)), '42501');
reset role;
-- En Organización el Administrador consulta pero no gestiona; el Coordinador sí.
select pruebas.como(:'adm');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_indicaciones_listar(:cta_org, :'adulto_org')->>'total') = '0', 'el administrador consulta las indicaciones');
select pruebas.error(format('select cuidared_api.api_indicacion_crear(%s, %L, %L::jsonb)', :cta_org, :'adulto_org', format('{"tipo_indicacion_id": %s, "titulo": "Del administrador", "fecha_inicio": "2026-10-01"}', :tipo_med)), '42501');
reset role;
select pruebas.como(:'org_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_indicacion_crear(:cta_org, :'adulto_org', format('{"tipo_indicacion_id": %s, "titulo": "Del coordinador", "fecha_inicio": "2026-10-01"}', :tipo_med)::jsonb)->>'estado') = 'activa', 'el coordinador de Organización registra indicaciones');
reset role;

/* ───────────── Listar: paginado, ordenado y filtrado ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_indicaciones_listar(:cta, :'adulto', null, 'fecha_inicio', true, 2, 0)::text as pag1 \gset
select pruebas.afirmar((:'pag1'::jsonb->>'total') = '4' and jsonb_array_length(:'pag1'::jsonb->'items') = 2
  and (:'pag1'::jsonb->'items'->0->>'titulo') = 'Insulina' and (:'pag1'::jsonb->'items'->1->>'titulo') = 'Dieta baja en sal', 'página 1: orden por inicio descendente y total');
select cuidared_api.api_indicaciones_listar(:cta, :'adulto', null, 'fecha_inicio', true, 2, 2)::text as pag2 \gset
select pruebas.afirmar(jsonb_array_length(:'pag2'::jsonb->'items') = 2 and (:'pag2'::jsonb->'items'->1->>'titulo') = 'Metformina 850 mg', 'página 2');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_indicaciones_listar(:cta, :'adulto', null, 'fecha_inicio', true, 20, 100)->'items') = 0
  and (cuidared_api.api_indicaciones_listar(:cta, :'adulto', null, 'fecha_inicio', true, 20, 100)->>'total') = '4', 'una página fuera del conjunto devuelve vacío con el total');
select pruebas.afirmar((cuidared_api.api_indicaciones_listar(:cta, :'adulto', null, 'fecha_inicio', false, 1, 0)->'items'->0->>'titulo') = 'Metformina 850 mg', 'orden ascendente');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_indicaciones_listar(:cta, :'adulto', null, 'fecha_inicio', true, 20, 5000000000)->'items') = 0, 'un desplazamiento enorme no desborda');
select pruebas.afirmar((cuidared_api.api_indicaciones_listar(:cta, :'adulto2')->>'total') = '0', 'los demás adultos no mezclan indicaciones');
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L, %L)', :cta, :'adulto', 'vigente'), '22023');
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L, null, %L)', :cta, :'adulto', 'titulo'), '22023');
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L, null, %L, true, 0, 0)', :cta, :'adulto', 'fecha_inicio'), '22023');
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L, null, %L, true, 101, 0)', :cta, :'adulto', 'fecha_inicio'), '22023');
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L, null, %L, true, 20, -1)', :cta, :'adulto', 'fecha_inicio'), '22023');
reset role;

/* ───────────── Editar y cambiar el estado ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_indicacion_editar(:cta, :'ind1_id', '{"titulo": "Metformina 1000 mg", "frecuencia_horario": null}'::jsonb)->>'titulo') = 'Metformina 1000 mg', 'el cuidador asignado edita');
reset role;
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_indicacion_editar(:cta, :'ind1_id', '{"descripcion": null, "fecha_fin": null}'::jsonb)::text as editada \gset
select pruebas.afirmar((:'editada'::jsonb->>'titulo') = 'Metformina 1000 mg' and (:'editada'::jsonb->'descripcion') = 'null'::jsonb
  and (:'editada'::jsonb->'fecha_fin') = 'null'::jsonb and (:'editada'::jsonb->'frecuencia_horario') = 'null'::jsonb
  and (:'editada'::jsonb->>'actualizado_por') = :'coord' and (:'editada'::jsonb->>'registrado_por') = :'coord', 'edición parcial: null limpia, lo omitido se conserva');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{"estado": "finalizada"}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{"fecha_fin": "2026-09-01"}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{"titulo": null}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind1_id', '{"tipo_indicacion_id": 9999}'), '22023');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, gen_random_uuid(), '{"titulo": "Inexistente"}'), 'P0002');
-- Estados (D10): activa ⇄ suspendida, → finalizada (terminal); repetir el estado no cambia nada.
select pruebas.afirmar((cuidared_api.api_indicacion_estado(:cta, :'ind1_id', 'suspendida')->>'estado') = 'suspendida', 'suspende');
select pruebas.afirmar((cuidared_api.api_indicacion_estado(:cta, :'ind1_id', 'suspendida')->>'estado') = 'suspendida', 'repetir el estado es idempotente');
select pruebas.afirmar((cuidared_api.api_indicacion_estado(:cta, :'ind1_id', 'activa')->>'estado') = 'activa', 'reactiva');
select pruebas.error(format('select cuidared_api.api_indicacion_estado(%s, %L, %L)', :cta, :'ind1_id', 'vigente'), '22023');
select pruebas.afirmar((cuidared_api.api_indicacion_estado(:cta, :'ind2_id', 'finalizada')->>'actualizado_por') = :'coord', 'finaliza y registra al autor');
select pruebas.error(format('select cuidared_api.api_indicacion_estado(%s, %L, %L)', :cta, :'ind2_id', 'activa'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta, :'ind2_id', '{"titulo": "Histórica"}'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.afirmar((cuidared_api.api_indicacion_estado(:cta, :'ind2_id', 'finalizada')->>'estado') = 'finalizada', 'repetir «finalizada» no falla');
select pruebas.afirmar((cuidared_api.api_indicaciones_listar(:cta, :'adulto', 'finalizada')->>'total') = '1'
  and (cuidared_api.api_indicaciones_listar(:cta, :'adulto', 'activa')->>'total') = '3', 'filtro por estado');
reset role;
-- Una indicación de otra cuenta se trata como inexistente.
select pruebas.como(:'otra');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_indicacion_editar(%s, %L, %L::jsonb)', :cta_otra, :'ind1_id', '{"titulo": "Robo"}'), 'P0002');
select pruebas.error(format('select cuidared_api.api_indicacion_estado(%s, %L, %L)', :cta_otra, :'ind1_id', 'finalizada'), 'P0002');
reset role;
select pruebas.afirmar((select titulo from cuidared.indicacion_medica where indicacion_medica_id = :'ind1_id'::uuid) = 'Metformina 1000 mg', 'la indicación ajena no cambió');

-- El familiar autorizado consulta; el no autorizado, no.
select pruebas.como(:'fami');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_indicaciones_listar(:cta, :'adulto')->>'total') = '4', 'el familiar autorizado consulta las indicaciones');
reset role;
select pruebas.como(:'fami2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L)', :cta, :'adulto'), '42501');
reset role;

/* ───────────── Historial consolidado ───────────── */
select cuidared_interno.hoy() as hoy \gset
select pruebas.visita_3b(:'adulto', 'completada', cuidared_interno.hoy() - 10, 'Control mensual', 'Se ve decaída', 'requiere_atencion') as v1 \gset
select pruebas.visita_3b(:'adulto', 'cancelada', cuidared_interno.hoy() - 5, null, 'No hubo acceso a la vivienda') as v2 \gset
select pruebas.visita_3b(:'adulto', 'programada', cuidared_interno.hoy() + 5, 'Próxima visita', null) as v3 \gset
select pruebas.visita_3b(:'adulto2', 'completada', cuidared_interno.hoy() - 3, 'Otro adulto', 'No debe aparecer') as v4 \gset
select pruebas.visita_3b(:'adulto_org', 'completada', cuidared_interno.hoy() - 2, 'Visita voluntaria', 'Estuvo animada', 'estable') as v5 \gset
select pruebas.necesidad_3b(:'adulto', 'Compra de pañales') as n1 \gset
select pruebas.necesidad_3b(:'adulto', 'Medicamento agotado', true) as n2 \gset
select pruebas.alerta_3b(:'adulto', 'Más de 15 días sin visitas', true) as al1 \gset
-- Evaluación, factor manual (resuelto) e indicación actualizada.
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_riesgo_evaluar(:cta, :'adulto',
  '{"ingresos_fijos":true,"vivienda":"propia","vive_solo":true,"cronica":true,"movilidad":"independiente","medicamentos":false,"familiares":true,"frecuencia":"ocasional","cuidador":true}'::jsonb) as ev \gset
select (cuidared_api.api_riesgo_registrar(:cta, :'adulto', :f_caidas, 'alto', 'Dos caídas el último mes')->'factor'->>'envejeciente_riesgo_id')::bigint as factor_id \gset
select cuidared_api.api_riesgo_resolver(:cta, :factor_id, 'Se instalaron barandas') as resuelto \gset
reset role;
update cuidared.indicacion_medica set fecha_actualizacion = fecha_creacion + interval '1 day' where indicacion_medica_id = :'ind1_id'::uuid;

select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 100, 0)::text as hist \gset
select pruebas.afirmar((:'hist'::jsonb->>'total') = '15' and jsonb_array_length(:'hist'::jsonb->'items') = 15,
  'coordinador: 2 visitas, 3 de necesidades, 2 alertas, 2 de riesgo, 1 evaluación y 5 de indicaciones');
select pruebas.afirmar((select array_agg(distinct t->>'tipo' order by t->>'tipo') from jsonb_array_elements(:'hist'::jsonb->'items') t)
  = array['alerta', 'evaluacion', 'indicacion', 'necesidad', 'riesgo', 'visita'], 'seis tipos de evento');
select pruebas.afirmar((select array_agg(k order by k) from jsonb_object_keys(:'hist'::jsonb->'items'->0) k)
  = array['detalle', 'fecha', 'referencia_id', 'tipo', 'titulo'], 'cada evento es {tipo, fecha, titulo, detalle, referencia_id}');
select pruebas.afirmar((select array_agg(t->>'fecha' order by ord) = array_agg(t->>'fecha' order by t->>'fecha' desc)
  from jsonb_array_elements(:'hist'::jsonb->'items') with ordinality as x(t, ord)), 'orden por fecha descendente');
select pruebas.afirmar(not exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t where t->>'detalle' = 'No debe aparecer' or t->>'titulo' like '%Próxima%'),
  'ni visitas de otros adultos ni programadas');
select pruebas.afirmar(exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t
  where t->>'tipo' = 'visita' and t->>'referencia_id' = :'v1' and t->>'titulo' = 'Visita realizada: Control mensual'
    and t->>'detalle' = 'Estado general: requiere atencion · Se ve decaída'
    and t->>'fecha' = to_char(:'hoy'::date - 10, 'YYYY-MM-DD') || 'T14:00:00.000Z'), 'visita realizada con observación y fecha UTC');
select pruebas.afirmar(exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t
  where t->>'tipo' = 'evaluacion' and t->>'titulo' = 'Evaluación de riesgo: 30 de 100 puntos (nivel medio)'), 'evaluación con puntaje y nivel');
select pruebas.afirmar((select count(*) from jsonb_array_elements(:'hist'::jsonb->'items') t where t->>'tipo' = 'riesgo') = 2
  and exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t where t->>'titulo' = 'Factor de riesgo resuelto: Riesgo de caídas 3b'),
  'el factor de la evaluación no se duplica; el factor manual y su resolución sí aparecen');
select pruebas.afirmar(exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t
  where t->>'tipo' = 'alerta' and t->>'detalle' = 'Se llamó al contacto') and exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t
  where t->>'tipo' = 'necesidad' and t->>'detalle' = 'Se entregó el medicamento'), 'alertas y necesidades con su resolución');
select pruebas.afirmar(exists (select 1 from jsonb_array_elements(:'hist'::jsonb->'items') t
  where t->>'tipo' = 'indicacion' and t->>'titulo' = 'Indicación médica actualizada: Metformina 1000 mg (activa)'), 'indicación actualizada');
-- Paginación y orden ascendente.
select pruebas.afirmar((cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 10, 0)->>'total') = '15'
  and jsonb_array_length(cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 10, 0)->'items') = 10
  and jsonb_array_length(cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 10, 10)->'items') = 5, 'paginación: 10 + 5 de 15');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 10, 200)->'items') = 0
  and (cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 10, 200)->>'total') = '15', 'una página fuera del conjunto devuelve vacío');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 20, 5000000000)->'items') = 0, 'un desplazamiento enorme no desborda');
select pruebas.afirmar((cuidared_api.api_historial_listar(:cta, :'adulto', null, false, 1, 0)->'items'->0->>'fecha')
  <= (cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 1, 0)->'items'->0->>'fecha'), 'orden ascendente: el primero es el más antiguo');
-- Las páginas no repiten ni omiten eventos.
select pruebas.afirmar((select count(distinct (t->>'tipo') || (t->>'referencia_id') || (t->>'titulo'))
  from (select jsonb_array_elements(cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 5, o)->'items') t from generate_series(0, 10, 5) o) p) = 15, 'tres páginas de 5 cubren los 15 eventos sin repetir');
-- Filtro por tipo.
select pruebas.afirmar((cuidared_api.api_historial_listar(:cta, :'adulto', 'evaluacion')->>'total') = '1'
  and (cuidared_api.api_historial_listar(:cta, :'adulto', 'visita')->>'total') = '2'
  and (cuidared_api.api_historial_listar(:cta, :'adulto', 'indicacion')->>'total') = '5', 'filtro por tipo de evento');
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L, %L)', :cta, :'adulto', 'foto'), '22023');
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L, null, true, 0)', :cta, :'adulto'), '22023');
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L, null, true, 101)', :cta, :'adulto'), '22023');
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L, null, true, 20, -5)', :cta, :'adulto'), '22023');
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L)', :cta, :'adulto_otra'), '42501');
reset role;

-- El cuidador asignado tiene todos los permisos de consulta.
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_historial_listar(:cta, :'adulto')->>'total') = '15', 'el cuidador asignado ve el historial completo');
reset role;
-- El familiar autorizado solo ve lo que sus permisos permiten (sin riesgo, evaluaciones, alertas ni observaciones).
select pruebas.como(:'fami');
set local role authenticated;
select cuidared_api.api_historial_listar(:cta, :'adulto', null, true, 100, 0)::text as hist_fami \gset
select pruebas.afirmar((select array_agg(distinct t->>'tipo' order by t->>'tipo') from jsonb_array_elements(:'hist_fami'::jsonb->'items') t)
  = array['indicacion', 'necesidad', 'visita'] and (:'hist_fami'::jsonb->>'total') = '10', 'familiar: solo visitas, necesidades e indicaciones');
select pruebas.afirmar(not exists (select 1 from jsonb_array_elements(:'hist_fami'::jsonb->'items') t
  where t->>'tipo' = 'visita' and t->>'detalle' is not null), 'el familiar no recibe observaciones de visita');
select pruebas.afirmar((cuidared_api.api_historial_listar(:cta, :'adulto', 'riesgo')->>'total') = '0'
  and (cuidared_api.api_historial_listar(:cta, :'adulto', 'alerta')->>'total') = '0', 'un tipo sin permiso no devuelve eventos');
reset role;
select pruebas.como(:'fami2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L)', :cta, :'adulto'), '42501');
reset role;
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L)', :cta, :'adulto'), '42501');
reset role;
-- La voluntaria solo ve las visitas del adulto que tiene asignado, sin observaciones.
select pruebas.como(:'vol');
set local role authenticated;
select cuidared_api.api_historial_listar(:cta_org, :'adulto_org')::text as hist_vol \gset
-- El adulto tiene una indicación y una visita; sin indicaciones:ver la voluntaria solo recibe la visita.
select pruebas.afirmar((:'hist_vol'::jsonb->>'total') = '1' and (:'hist_vol'::jsonb->'items'->0->>'tipo') = 'visita'
  and (:'hist_vol'::jsonb->'items'->0->'detalle') = 'null'::jsonb, 'la voluntaria solo ve la visita, sin observación ni estado general ni indicaciones');
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L)', :cta_org, :'adulto'), '42501');
reset role;
-- El administrador de Organización alcanza todos los adultos de su cuenta y ve la visita con su observación.
select pruebas.como(:'adm');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_historial_listar(:cta_org, :'adulto_org')->>'total') = '2'
  and exists (select 1 from jsonb_array_elements(cuidared_api.api_historial_listar(:cta_org, :'adulto_org')->'items') t
              where t->>'tipo' = 'visita' and t->>'detalle' = 'Estado general: estable · Estuvo animada'),
  'el administrador ve la visita con su observación y la indicación');
reset role;

/* ───────────── Sesión y exposición ───────────── */
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L)', :cta, :'adulto'), '28000');
select pruebas.error(format('select cuidared_api.api_indicaciones_listar(%s, %L)', :cta, :'adulto'), '28000');
reset role;
set local role anon;
select pruebas.error(format('select cuidared_api.api_historial_listar(%s, %L)', :cta, :'adulto'), '42501');
reset role;
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.error('select * from cuidared.indicacion_medica', '42501');
select pruebas.error(format('select cuidared_interno.historial_eventos(%L, true, true, true, true, true)', :'adulto'), '42501');
reset role;
rollback;
