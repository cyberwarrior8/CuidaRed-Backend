-- pruebas-3b-riesgo.sql — Cuestionario de 100 puntos, factores vigentes y nivel agregado (RF-14, D11).
-- © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('coord.rg3b@x.test', '00131000001', 'Patricia') as coord \gset
select pruebas.usuario('cuid.rg3b@x.test', '00131000002', 'Carla') as cuid \gset
select pruebas.usuario('cuid2.rg3b@x.test', '00131000003', 'Camila') as cuid2 \gset
select pruebas.usuario('fami.rg3b@x.test', '00131000004', 'Fabio') as fami \gset
select pruebas.usuario('adm.rg3b@x.test', '00131000005', 'Andrea') as adm \gset
select pruebas.usuario('vol.rg3b@x.test', '00131000006', 'Vera') as vol \gset
select pruebas.cuenta('familia', :'coord') as cta \gset
select pruebas.miembro(:cta, :'cuid', 'cuidador');
select pruebas.miembro(:cta, :'cuid2', 'cuidador');
select pruebas.miembro(:cta, :'fami', 'familiar');
select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as cta_org \gset
select pruebas.miembro(:cta_org, :'vol', 'voluntario');
select pruebas.adulto_3b(:cta, '93100000001') as adulto \gset
select pruebas.adulto_3b(:cta, '93100000002') as adulto2 \gset
select pruebas.adulto_3b(:cta_org, '93100000003') as adulto_org \gset
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'adulto', :'cuid', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'adulto', :'fami', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'familiar_responsable';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'adulto_org', :'vol', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'voluntario_asignado';
-- Catálogos de factores de prueba (el catálogo oficial está pendiente, D14).
insert into cuidared.riesgo (nombre, descripcion) values ('Riesgo de caídas 3b', 'Prueba') returning riesgo_id as f_caidas \gset
insert into cuidared.riesgo (nombre, descripcion) values ('Aislamiento social 3b', 'Prueba') returning riesgo_id as f_aislamiento \gset
select riesgo_id as f_eval from cuidared.riesgo where codigo = 'evaluacion' \gset

/* ───────────── Catálogos sembrados y umbrales ───────────── */
select pruebas.afirmar((select count(*) from cuidared.nivel_riesgo where codigo in ('bajo', 'medio', 'alto')) = 3, 'niveles bajo, medio y alto');
select pruebas.afirmar((select count(*) from cuidared.riesgo where codigo = 'evaluacion') = 1, 'factor «Evaluación de riesgo» sembrado');
select pruebas.afirmar(cuidared_interno.nivel_desde_puntaje(0) = 'bajo' and cuidared_interno.nivel_desde_puntaje(29) = 'bajo'
  and cuidared_interno.nivel_desde_puntaje(30) = 'medio' and cuidared_interno.nivel_desde_puntaje(54) = 'medio'
  and cuidared_interno.nivel_desde_puntaje(55) = 'alto' and cuidared_interno.nivel_desde_puntaje(100) = 'alto', 'umbrales 0–29 / 30–54 / 55–100');

/* ───────────── Cuestionario portado de riesgo.ts ───────────── */
select '{"ingresos_fijos":true,"vivienda":"propia","vive_solo":false,"cronica":false,"movilidad":"independiente","medicamentos":false,"familiares":true,"frecuencia":"diaria","cuidador":true}'::jsonb as base \gset
select (cuidared_interno.calcular_riesgo_v1(:'base'::jsonb)->>'puntaje')::int = 0 and (cuidared_interno.calcular_riesgo_v1(:'base'::jsonb)->>'nivel') = 'bajo' as ok \gset
select pruebas.afirmar(:'ok', 'respuestas de menor vulnerabilidad: 0 puntos, bajo');
select cuidared_interno.calcular_riesgo_v1('{"ingresos_fijos":false,"vivienda":"precaria","vive_solo":true,"cronica":true,"movilidad":"encamado","medicamentos":true,"familiares":false,"frecuencia":"nunca","cuidador":false}'::jsonb)::text as maximo \gset
select pruebas.afirmar((:'maximo'::jsonb->>'puntaje')::int = 100 and (:'maximo'::jsonb->>'nivel') = 'alto', 'respuestas de mayor vulnerabilidad: 100 puntos, alto');
select pruebas.afirmar((select array_agg((s->>'max')::int order by ord) from jsonb_array_elements(:'maximo'::jsonb->'desglose') with ordinality as t(s, ord)) = array[30, 40, 30], 'máximos por sección 30/40/30');
select pruebas.afirmar((select array_agg((s->>'puntos')::int order by ord) from jsonb_array_elements(:'maximo'::jsonb->'desglose') with ordinality as t(s, ord)) = array[30, 40, 30], 'desglose por sección del máximo');
select pruebas.afirmar((:'maximo'::jsonb->'desglose'->0->'detalle'->1) = '{"clave":"vivienda","respuesta":"precaria","puntos":10}'::jsonb, 'el desglose conserva clave, respuesta y puntos');
-- Umbrales exactos del cuestionario (29 bajo, 30 medio, 54 medio, 55 alto).
select pruebas.afirmar((cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"movilidad":"encamado","frecuencia":"semanal"}')->>'puntaje') = '29'
  and (cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"movilidad":"encamado","frecuencia":"semanal"}')->>'nivel') = 'bajo', '29 puntos: bajo');
select pruebas.afirmar((cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"cronica":true,"frecuencia":"ocasional"}')->>'puntaje') = '30'
  and (cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"cronica":true,"frecuencia":"ocasional"}')->>'nivel') = 'medio', '30 puntos: medio');
select pruebas.afirmar((cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"cronica":true,"medicamentos":true,"frecuencia":"nunca","cuidador":false}')->>'puntaje') = '54'
  and (cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"cronica":true,"medicamentos":true,"frecuencia":"nunca","cuidador":false}')->>'nivel') = 'medio', '54 puntos: medio');
select pruebas.afirmar((cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"cronica":true,"movilidad":"apoyo","medicamentos":true,"frecuencia":"mensual","cuidador":false}')->>'puntaje') = '55'
  and (cuidared_interno.calcular_riesgo_v1(:'base'::jsonb || '{"vive_solo":true,"cronica":true,"movilidad":"apoyo","medicamentos":true,"frecuencia":"mensual","cuidador":false}')->>'nivel') = 'alto', '55 puntos: alto');
-- Respuestas incompletas (D11): se rechazan.
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb - %L)', :'base', 'vivienda'), 'P0001', 'CR_EVALUACION_INCOMPLETA');
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb || %L)', :'base', '{"vivienda":""}'), 'P0001', 'CR_EVALUACION_INCOMPLETA');
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb || %L)', :'base', '{"cronica":null}'), 'P0001', 'CR_EVALUACION_INCOMPLETA');
select pruebas.error('select cuidared_interno.calcular_riesgo_v1(''{}''::jsonb)', 'P0001', 'CR_EVALUACION_INCOMPLETA');
-- Valores o claves fuera del cuestionario: entrada inválida.
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb || %L)', :'base', '{"vivienda":"castillo"}'), '22023');
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb || %L)', :'base', '{"cronica":"si"}'), '22023');
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb || %L)', :'base', '{"vivienda":4}'), '22023');
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb || %L)', :'base', '{"puntaje":0}'), '22023');
select pruebas.error('select cuidared_interno.calcular_riesgo_v1(''[]''::jsonb)', '22023');

/* ───────────── Evaluar (adultos:evaluar) ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.afirmar(cuidared_api.api_riesgo_consultar(:cta, :'adulto')->>'nivel_vigente' is null, 'sin factores vigentes: nivel null');
select pruebas.afirmar((cuidared_api.api_riesgo_consultar(:cta, :'adulto')->>'texto') = 'Sin evaluación vigente', 'sin factores vigentes: «Sin evaluación vigente»');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_riesgo_consultar(:cta, :'adulto')->'factores_vigentes') = 0
  and (cuidared_api.api_riesgo_consultar(:cta, :'adulto')->'ultima_evaluacion') = 'null'::jsonb, 'sin factores ni evaluaciones');
select cuidared_api.api_riesgo_evaluar(:cta, :'adulto', :'base'::jsonb || '{"vive_solo":true,"cronica":true,"frecuencia":"ocasional"}')::text as evaluacion \gset
select pruebas.afirmar((:'evaluacion'::jsonb->>'puntaje') = '30' and (:'evaluacion'::jsonb->>'nivel') = 'medio'
  and (:'evaluacion'::jsonb->>'nivel_vigente') = 'medio' and (:'evaluacion'::jsonb->>'version_cuestionario') = 'v1'
  and (:'evaluacion'::jsonb->>'usuario_id') = :'coord', 'el servidor calcula y registra al evaluador');
select pruebas.afirmar((:'evaluacion'::jsonb->'factor'->>'estado') = 'activo' and (:'evaluacion'::jsonb->'factor'->>'es_evaluacion')::boolean, 'genera el factor de evaluación activo');
select pruebas.error(format('select cuidared_api.api_riesgo_evaluar(%s, %L, %L::jsonb)', :cta, :'adulto', :'base'::jsonb - 'cuidador'), 'P0001', 'CR_EVALUACION_INCOMPLETA');
select pruebas.error(format('select cuidared_api.api_riesgo_evaluar(%s, %L, %L::jsonb)', :cta, :'adulto', :'base'::jsonb || '{"vivienda":"x"}'), '22023');
reset role;
select pruebas.afirmar((select count(*) from cuidared.evaluacion_riesgo where envejeciente_id = :'adulto') = 1, 'una evaluación guardada; las rechazadas no dejan rastro');
select pruebas.afirmar((select puntaje = 30 and version_cuestionario = 'v1' and jsonb_typeof(desglose) = 'array' and respuestas ? 'vive_solo'
  from cuidared.evaluacion_riesgo where envejeciente_id = :'adulto'), 'se guardan respuestas, puntaje, desglose y versión');

-- Reevaluar: el factor anterior pasa a reemplazado y la evaluación nueva queda vigente.
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_riesgo_evaluar(:cta, :'adulto', :'base'::jsonb)::text as reevaluacion \gset
select pruebas.afirmar((:'reevaluacion'::jsonb->>'puntaje') = '0' and (:'reevaluacion'::jsonb->>'nivel_vigente') = 'bajo', 'la reevaluación sustituye el nivel vigente');
reset role;
select pruebas.afirmar((select count(*) from cuidared.envejeciente_riesgo er join cuidared.riesgo r using (riesgo_id)
  where er.envejeciente_id = :'adulto' and r.codigo = 'evaluacion' and er.estado = 'activo') = 1, 'un solo factor de evaluación activo');
select pruebas.afirmar((select count(*) from cuidared.envejeciente_riesgo er join cuidared.riesgo r using (riesgo_id)
  where er.envejeciente_id = :'adulto' and r.codigo = 'evaluacion' and er.estado = 'reemplazado') = 1, 'el factor anterior queda reemplazado');
select pruebas.afirmar((select count(*) from cuidared.evaluacion_riesgo where envejeciente_id = :'adulto') = 2, 'las evaluaciones anteriores se conservan como historial');
select pruebas.afirmar((select count(*) from cuidared.evaluacion_riesgo where envejeciente_id = :'adulto2') = 0, 'otro adulto no recibe evaluaciones');

/* ───────────── Factores: máximo de los vigentes y «Sin evaluación vigente» ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select cuidared_api.api_riesgo_registrar(:cta, :'adulto', :f_caidas, 'alto', 'Dos caídas el último mes', 'Vive en un segundo piso')::text as factor_alto \gset
select pruebas.afirmar((:'factor_alto'::jsonb->>'nivel_vigente') = 'alto', 'el nivel agregado es el máximo de los vigentes');
select pruebas.afirmar((:'factor_alto'::jsonb->'factor'->>'registrado_por') = :'coord' and (:'factor_alto'::jsonb->'factor'->>'observacion') = 'Vive en un segundo piso', 'registra autor y observación');
select cuidared_api.api_riesgo_registrar(:cta, :'adulto', :f_aislamiento, 'medio', 'Sin visitas de familiares')::text as factor_medio \gset
select pruebas.afirmar((:'factor_medio'::jsonb->>'nivel_vigente') = 'alto', 'un factor medio no baja el máximo');
select cuidared_api.api_riesgo_consultar(:cta, :'adulto')::text as consulta \gset
select pruebas.afirmar(jsonb_array_length(:'consulta'::jsonb->'factores_vigentes') = 3 and (:'consulta'::jsonb->'factores_vigentes'->0->>'nivel') = 'alto'
  and (:'consulta'::jsonb->>'texto') = 'Riesgo alto', 'factores vigentes, el más alto primero');
select pruebas.afirmar(jsonb_array_length(:'consulta'::jsonb->'historial') = 1 and (:'consulta'::jsonb->'historial'->0->>'estado') = 'reemplazado'
  and (:'consulta'::jsonb->'ultima_evaluacion'->>'puntaje') = '0' and (:'consulta'::jsonb->'ultima_evaluacion'->>'vigente')::boolean, 'historial con la evaluación reemplazada y última evaluación vigente');
-- Registrar otro nivel del mismo factor reemplaza al activo.
select cuidared_api.api_riesgo_registrar(:cta, :'adulto', :f_caidas, 'bajo', 'Se instalaron barandas')::text as factor_bajo \gset
select pruebas.afirmar((:'factor_bajo'::jsonb->>'nivel_vigente') = 'medio', 'reemplazar el factor alto por uno bajo deja el máximo en medio');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, %s, %L, %L)', :cta, :'adulto', :f_eval, 'alto', 'Intento manual'), '22023');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, 999, %L, %L)', :cta, :'adulto', 'alto', 'Factor inexistente'), '22023');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, %s, %L, %L)', :cta, :'adulto', :f_caidas, 'critico', 'Nivel inválido'), '22023');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, %s, %L, %L)', :cta, :'adulto', :f_caidas, 'alto', 'no'), '22023');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, %s, %L, %L, %L)', :cta, :'adulto', :f_caidas, 'alto', 'Motivo válido', repeat('x', 301)), '22023');
reset role;
select pruebas.afirmar((select count(*) from cuidared.envejeciente_riesgo where envejeciente_id = :'adulto' and riesgo_id = :f_caidas and estado = 'activo') = 1, 'un solo factor activo por tipo');
select pruebas.error(format('insert into cuidared.envejeciente_riesgo (envejeciente_id, riesgo_id, nivel_riesgo_id) select %L, %s, nivel_riesgo_id from cuidared.nivel_riesgo limit 1', :'adulto', :f_caidas), '23505');

-- Resolver factores.
select pruebas.como(:'coord');
set local role authenticated;
select (select (f->>'envejeciente_riesgo_id')::bigint from jsonb_array_elements(cuidared_api.api_riesgo_consultar(:cta, :'adulto')->'factores_vigentes') f
        where f->>'riesgo' = 'Riesgo de caídas 3b') as id_caidas \gset
select (select (f->>'envejeciente_riesgo_id')::bigint from jsonb_array_elements(cuidared_api.api_riesgo_consultar(:cta, :'adulto')->'factores_vigentes') f
        where f->>'riesgo' = 'Aislamiento social 3b') as id_aislamiento \gset
select (select (f->>'envejeciente_riesgo_id')::bigint from jsonb_array_elements(cuidared_api.api_riesgo_consultar(:cta, :'adulto')->'factores_vigentes') f
        where (f->>'es_evaluacion')::boolean) as id_evaluacion \gset
select cuidared_api.api_riesgo_resolver(:cta, :id_aislamiento, 'El familiar retomó las visitas')::text as resuelto \gset
select pruebas.afirmar((:'resuelto'::jsonb->'factor'->>'estado') = 'resuelto' and (:'resuelto'::jsonb->'factor'->>'resuelto_por') = :'coord'
  and (:'resuelto'::jsonb->'factor'->>'observacion') like '%Resolución: El familiar retomó las visitas', 'resuelve un factor con autor, fecha y nota');
select pruebas.error(format('select cuidared_api.api_riesgo_resolver(%s, %s)', :cta, :id_aislamiento), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_riesgo_resolver(%s, %s)', :cta, 987654321), 'P0002');
select pruebas.error(format('select cuidared_api.api_riesgo_resolver(%s, 0)', :cta), '22023');
select pruebas.afirmar((cuidared_api.api_riesgo_resolver(:cta, :id_caidas)->>'nivel_vigente') = 'bajo', 'resolver los factores altos baja el máximo');
-- Resolver el último factor vigente: «Sin evaluación vigente», sin conservar el nivel anterior ni asumir «bajo».
select pruebas.afirmar((cuidared_api.api_riesgo_resolver(:cta, :id_evaluacion)->>'nivel_vigente') is null, 'sin factores vigentes: nivel null');
select cuidared_api.api_riesgo_consultar(:cta, :'adulto')::text as consulta2 \gset
select pruebas.afirmar((:'consulta2'::jsonb->>'texto') = 'Sin evaluación vigente' and (:'consulta2'::jsonb->'nivel_vigente') = 'null'::jsonb
  and jsonb_array_length(:'consulta2'::jsonb->'factores_vigentes') = 0, '«Sin evaluación vigente» al resolver todos los factores');
select pruebas.afirmar((:'consulta2'::jsonb->'ultima_evaluacion'->>'vigente')::boolean = false
  and (:'consulta2'::jsonb->'ultima_evaluacion'->>'puntaje') = '0', 'la última evaluación se conserva como historia, no como clasificación vigente');
select pruebas.afirmar(jsonb_array_length(:'consulta2'::jsonb->'historial') = 5, 'el historial conserva todos los factores anteriores');
reset role;

/* ───────────── Permisos: el cuidador consulta, pero no modifica ───────────── */
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_riesgo_consultar(:cta, :'adulto')->>'texto') = 'Sin evaluación vigente', 'el cuidador asignado consulta el riesgo');
select pruebas.error(format('select cuidared_api.api_riesgo_evaluar(%s, %L, %L::jsonb)', :cta, :'adulto', :'base'), '42501');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, %s, %L, %L)', :cta, :'adulto', :f_caidas, 'alto', 'Intento del cuidador'), '42501');
select pruebas.error(format('select cuidared_api.api_riesgo_resolver(%s, %s)', :cta, :id_caidas), '42501');
select pruebas.error(format('select cuidared_api.api_riesgo_consultar(%s, %L)', :cta, :'adulto2'), '42501');
reset role;
-- La cuidadora sin asignación no alcanza al adulto.
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_riesgo_consultar(%s, %L)', :cta, :'adulto'), '42501');
reset role;
-- El familiar autorizado no ve datos sensibles; la voluntaria tampoco.
select pruebas.como(:'fami');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_riesgo_consultar(%s, %L)', :cta, :'adulto'), '42501');
select pruebas.error(format('select cuidared_api.api_riesgo_evaluar(%s, %L, %L::jsonb)', :cta, :'adulto', :'base'), '42501');
reset role;
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_riesgo_consultar(%s, %L)', :cta_org, :'adulto_org'), '42501');
reset role;
-- Un factor de otra cuenta responde igual que uno inexistente.
select pruebas.como(:'adm');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_riesgo_resolver(%s, %s)', :cta_org, :id_caidas), 'P0002');
select pruebas.error(format('select cuidared_api.api_riesgo_consultar(%s, %L)', :cta_org, :'adulto'), '42501');
reset role;

/* ───────────── Adulto inactivo y exposición ───────────── */
select pruebas.adulto_3b(:cta, '93100000004', 'fallecido') as adulto_inactivo \gset
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_riesgo_evaluar(%s, %L, %L::jsonb)', :cta, :'adulto_inactivo', :'base'), 'P0001', 'CR_ADULTO_INACTIVO');
select pruebas.error(format('select cuidared_api.api_riesgo_registrar(%s, %L, %s, %L, %L)', :cta, :'adulto_inactivo', :f_caidas, 'alto', 'Adulto fallecido'), 'P0001', 'CR_ADULTO_INACTIVO');
select pruebas.error('select * from cuidared.evaluacion_riesgo', '42501');
select pruebas.error(format('select cuidared_interno.calcular_riesgo_v1(%L::jsonb)', :'base'), '42501');
reset role;
set local role anon;
select pruebas.error(format('select cuidared_api.api_riesgo_consultar(%s, %L)', :cta, :'adulto'), '42501');
reset role;
select pruebas.afirmar((select relrowsecurity from pg_class where oid = 'cuidared.evaluacion_riesgo'::regclass), 'RLS activada en evaluacion_riesgo');
select pruebas.error('insert into cuidared.evaluacion_riesgo (envejeciente_id, respuestas, puntaje, desglose, nivel_riesgo_id, version_cuestionario, usuario_id)
  select envejeciente_id, ''{}''::jsonb, 101, ''[]''::jsonb, 1, ''v1'', usuario_registrador_id from cuidared.envejeciente limit 1', '23514');
rollback;
