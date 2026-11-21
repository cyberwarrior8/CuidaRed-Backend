-- Fase 7 · reportes estadísticos (RF-08, CU-12) y análisis avanzado: totales conciliados con las filas fuente,
-- alertas frente a adultos prioritarios, semántica de fechas (medianoche de Santo Domingo, límites inclusivos),
-- filtros, vacíos y aislamiento. Base desechable de `--solo=reportes`. © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('r7c-admin@example.test', '00700000201');
  v_otro uuid := pruebas.usuario('r7c-otro@example.test', '00700000202');
  v_cuenta bigint := pruebas.cuenta('organizacion', v_admin, 'activa', 'Gestión Comunitaria Avanzada');
  v_otra bigint := pruebas.cuenta('organizacion', v_otro, 'activa', 'Gestión Comunitaria Avanzada');
  v_fam_coord uuid := pruebas.usuario('r7c-familia@example.test', '00700000203');
  v_fam bigint;
  v_adulto_fam uuid;
  v_hoy date := cuidared_interno.hoy();
  r1 uuid := pruebas.envejeciente(v_cuenta, 'Rosa', 'Arias');
  r2 uuid := pruebas.envejeciente(v_cuenta, 'Pedro', 'Batista', 'M');
  r3 uuid := pruebas.envejeciente(v_cuenta, 'Lucía', 'Castro');
  r4 uuid := pruebas.envejeciente(v_cuenta, 'Retirada', 'Consentimiento');
  v_ajeno uuid := pruebas.envejeciente(v_otra, 'Ajeno', 'Otra');
  v_alta smallint := (select prioridad_id from cuidared.prioridad where codigo = 'alta');
  v_media smallint := (select prioridad_id from cuidared.prioridad where codigo = 'media');
  v_baja smallint := (select prioridad_id from cuidared.prioridad where codigo = 'baja');
  v_medicamentos smallint := (select tipo_necesidad_id from cuidared.tipo_necesidad where codigo = 'medicamentos');
  v1 uuid;
  v2 uuid;
  v3 uuid;
  v_visita uuid;
  v_r jsonb;
  v_fila jsonb;
  v_tipo text;
  v_edad numeric;
begin
  insert into cuidared.municipio values ('0102', 'Municipio Este', '01') on conflict do nothing;
  -- Altas: r1 el 28/02 a las 23:30 de Santo Domingo (01/03 03:30 UTC), r2 el 01/03 a las 00:30 y r3 el 15/03.
  update cuidared.envejeciente set fecha_creacion = timestamptz '2026-03-01 03:30:00+00', zona = 'Centro' where envejeciente_id = r1;
  update cuidared.envejeciente set fecha_creacion = timestamptz '2026-03-01 04:30:00+00', municipio_cod = '0102' where envejeciente_id = r2;
  update cuidared.envejeciente set fecha_creacion = timestamptz '2026-03-15 15:00:00+00', zona = 'Centro' where envejeciente_id = r3;
  update cuidared.envejeciente set fecha_creacion = timestamptz '2026-03-20 15:00:00+00' where envejeciente_id = r4;

  -- Riesgo alto de r1: el motor genera su alerta prioritaria (A1).
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select r1, r.riesgo_id, n.nivel_riesgo_id, 'Caída' from cuidared.riesgo r, cuidared.nivel_riesgo n
    where r.codigo = 'riesgo_caida' and n.codigo = 'alto';
  update cuidared.alerta_envejeciente set fecha_alerta = timestamptz '2026-03-10 12:00:00+00'
    where envejeciente_id = r1 and fuente_riesgo_id is not null;

  -- Necesidades N1 a N5 (N1 genera A2 y N5 genera A3).
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por, fecha_necesidad)
    select r1, n.necesidad_id, v_media, 'Control mensual', v_admin, timestamptz '2026-03-02 02:00:00+00'
    from cuidared.necesidad n where n.tipo_necesidad_id = v_medicamentos limit 1;
  update cuidared.alerta_envejeciente set fecha_alerta = timestamptz '2026-03-02 03:00:00+00'
    where envejeciente_id = r1 and fuente_necesidad_id is not null;
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por,
      fecha_necesidad, estado, fecha_resolucion, motivo_resolucion, resuelto_por)
    select r1, n.necesidad_id, v_baja, 'Despensa', v_admin, timestamptz '2026-03-10 15:00:00+00', 'resuelta', now(), 'Entregada', v_admin
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'alimentacion' limit 1;
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por,
      fecha_necesidad, estado, es_recurrente)
    select r3, n.necesidad_id, v_alta, 'Almuerzo diario', v_admin, timestamptz '2026-03-20 15:00:00+00', 'en_proceso', true
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'alimentacion' limit 1;
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por,
      fecha_necesidad, estado, fecha_resolucion, motivo_resolucion, resuelto_por)
    select r2, n.necesidad_id, v_baja, 'Traslado', v_admin, timestamptz '2026-04-02 15:00:00+00', 'cancelada', now(), 'Ya no aplica', v_admin
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'transporte' limit 1;
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por, fecha_necesidad)
    select r3, n.necesidad_id, v_alta, 'Acompañamiento', v_admin, timestamptz '2026-04-05 15:00:00+00'
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'compania' limit 1;
  update cuidared.alerta_envejeciente set fecha_alerta = timestamptz '2026-04-05 16:00:00+00', estado = 'resuelta',
      fecha_atencion = timestamptz '2026-04-06 12:00:00+00', accion_tomada = 'Visita de acompañamiento', usuario_atendio_id = v_admin
    where envejeciente_id = r3 and fuente_necesidad_id is not null;
  perform pruebas.afirmar((select count(*) from cuidared.alerta_envejeciente where envejeciente_id in (r1, r3)) = 3,
    'tres alertas prioritarias de partida');

  -- Visitas: v1 compartida (r1 y r3), v2 de r2 el último día de marzo, v3 de r1; una programada y una cancelada no cuentan.
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, hora_inicio, hora_fin, razon, estado, creada_por)
    values (v_cuenta, date '2026-03-05', '09:00', '09:00', '09:45', 'Ronda', 'completada', v_admin) returning visita_id into v1;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id, estado_general, observacion)
    values (v1, r1, 'requiere_atencion', 'Observación privada'), (v1, r3, 'estable', 'Observación privada');
  insert into cuidared.registro_visita(visita_id, usuario_id, autorizada_por_usuario_id) values (v1, v_admin, v_admin);
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, date '2026-03-31', '10:00', 'Control', 'completada', v_admin) returning visita_id into v2;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id, estado_general) values (v2, r2, 'situacion_critica');
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, date '2026-04-01', '11:00', 'Seguimiento', 'completada', v_admin) returning visita_id into v3;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v3, r1);
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, date '2026-03-10', '08:00', 'Programada', 'programada', v_admin) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, r1);
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por, motivo_cancelacion, cancelada_por)
    values (v_cuenta, date '2026-03-11', '08:00', 'Cancelada', 'cancelada', v_admin, 'Sin acceso', v_admin) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, r1);
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_otra, date '2026-03-05', '09:00', 'Ajena', 'completada', v_otro) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, v_ajeno);
  -- Seguimiento de r3 (alerta no prioritaria A4), r2 inactivo y r4 con consentimiento retirado.
  perform cuidared_interno.alertas_reconciliar_adulto(r3, v_hoy, 'ausencia_visitas');
  update cuidared.envejeciente set estado = 'inactivo' where envejeciente_id = r2;
  update cuidared.envejeciente set estado = 'inactivo', consentimiento_retirado_en = now(), consentimiento_retirado_por = v_admin
    where envejeciente_id = r4;
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select v_ajeno, r.riesgo_id, n.nivel_riesgo_id, 'Ajeno' from cuidared.riesgo r, cuidared.nivel_riesgo n
    where r.codigo = 'riesgo_caida' and n.codigo = 'alto';

  perform pruebas.como(v_admin);

  /* adultos (fecha_alta). */
  v_r := cuidared_api.api_reporte(v_cuenta, 'adultos', '{}');
  v_edad := extract(year from age(v_hoy, date '1945-05-05'));
  perform pruebas.afirmar(v_r->>'campo_fecha' = 'fecha_alta' and v_r->>'zona_horaria' = 'America/Santo_Domingo'
    and v_r->'filtros' = '{"desde":null,"hasta":null,"municipio_cod":null,"zona":null,"riesgo":null,"tipo_necesidad_id":null}'::jsonb
    and not (v_r->>'vacio')::boolean, 'envoltura común del reporte');
  perform pruebas.afirmar(v_r->'indicadores' @> jsonb_build_object('registrados', 3, 'activos', 2, 'inactivos', 1,
      'fallecidos', 0, 'riesgo_alto', 1, 'riesgo_medio', 0, 'riesgo_bajo', 0, 'sin_evaluacion', 1, 'sin_personal_asignado', 2)
    and (v_r->'indicadores'->>'edad_promedio')::numeric = v_edad,
    'indicadores de adultos; el consentimiento retirado y la otra cuenta quedan fuera');
  perform pruebas.afirmar((select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_estado') x) = 3
    and (select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_riesgo') x) = 2
    and (select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_mes') x) = 3
    and v_r->'series'->'por_mes'->0->>'clave' = '2026-02'
    and v_r->'series'->'por_riesgo'->0 = '{"clave":"alto","etiqueta":"Alto","valor":1,"porcentaje":50}'::jsonb,
    'series conciliadas con los indicadores');
  perform pruebas.afirmar((v_r->>'detalle_total')::int = 3 and jsonb_array_length(v_r->'detalle') = 3
    and not (v_r->>'detalle_truncado')::boolean and v_r->'detalle'->0->>'apellidos' = 'Arias'
    and not exists (select from jsonb_array_elements(v_r->'detalle') x where x ?| array['cedula', 'telefono', 'direccion'])
    and (v_r->'detalle'->1->>'sexo') = 'M' and (v_r->'detalle'->1->>'estado') = 'inactivo',
    'detalle de adultos sin cédula, teléfono ni dirección');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_cuenta, 'adultos', '{"desde":"2026-03-01"}')->'indicadores'->>'registrados')::int = 2
    and (cuidared_api.api_reporte(v_cuenta, 'adultos', '{"hasta":"2026-02-28"}')->'indicadores'->>'registrados')::int = 1
    and (cuidared_api.api_reporte(v_cuenta, 'adultos', '{"desde":"2026-03-01","hasta":"2026-03-01"}')->'detalle'->0->>'envejeciente_id')::uuid = r2,
    'la fecha de alta se toma en el calendario de Santo Domingo, con límites inclusivos');
  v_r := cuidared_api.api_reporte(v_cuenta, 'adultos', '{"desde":"2026-02-01","hasta":"2026-03-31"}');
  perform pruebas.afirmar(v_r->'series'->'por_mes' = '[{"clave":"2026-02","etiqueta":"2026-02","valor":1,"porcentaje":33},
      {"clave":"2026-03","etiqueta":"2026-03","valor":2,"porcentaje":67}]'::jsonb, 'meses del periodo');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_cuenta, 'adultos', '{"municipio_cod":"0102"}')->'indicadores'->>'registrados')::int = 1
    and (cuidared_api.api_reporte(v_cuenta, 'adultos', '{"zona":"Centro"}')->'indicadores'->>'registrados')::int = 2
    and (cuidared_api.api_reporte(v_cuenta, 'adultos', '{"riesgo":"alto"}')->'indicadores'->>'registrados')::int = 1
    and (cuidared_api.api_reporte(v_cuenta, 'adultos', '{"riesgo":"sin_evaluacion"}')->'indicadores'->>'registrados')::int = 2,
    'filtros de municipio, sector y riesgo vigente');

  /* visitas (fecha_visita). */
  v_r := cuidared_api.api_reporte(v_cuenta, 'visitas', '{}');
  perform pruebas.afirmar(v_r->>'campo_fecha' = 'fecha_visita' and v_r->'indicadores' @> jsonb_build_object(
      'visitas_realizadas', 3, 'atenciones', 4, 'adultos_visitados', 3, 'adultos_activos', 2,
      'requirieron_atencion', 2, 'situaciones_criticas', 1, 'visitas_compartidas', 1)
    and (v_r->'indicadores'->>'promedio_por_adulto')::numeric = 1.33,
    'indicadores de visitas: solo completadas de la cuenta');
  perform pruebas.afirmar((v_r->'indicadores'->>'visitas_realizadas')::int = (
      select count(distinct v.visita_id) from cuidared.visita v join cuidared.detalle_visita d using (visita_id)
      join cuidared.envejeciente e using (envejeciente_id)
      where v.cuenta_id = v_cuenta and v.estado = 'completada' and e.consentimiento_retirado_en is null)
    and (v_r->'indicadores'->>'atenciones')::int = (
      select count(*) from cuidared.visita v join cuidared.detalle_visita d using (visita_id)
      where v.cuenta_id = v_cuenta and v.estado = 'completada'),
    'visitas y atenciones conciliadas con visita y detalle_visita');
  perform pruebas.afirmar((select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_estado_general') x) = 4
    and (select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_mes') x) = 3
    and (v_r->'detalle'->0->>'visita_id')::uuid = v3
    and (select x from jsonb_array_elements(v_r->'detalle') x where (x->>'visita_id')::uuid = v1)
        @> jsonb_build_object('hora_inicio', '09:00', 'hora_fin', '09:45', 'origen', 'interna',
             'responsables', jsonb_build_array(jsonb_build_object('usuario_id', v_admin)))
    and not exists (select from jsonb_array_elements(v_r->'detalle') x, jsonb_array_elements(x->'adultos') y
                    where y ? 'observacion'),
    'series y detalle de visitas sin observaciones');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_cuenta, 'visitas', '{"desde":"2026-03-01","hasta":"2026-03-31"}')
      ->'indicadores'->>'visitas_realizadas')::int = 2
    and (cuidared_api.api_reporte(v_cuenta, 'visitas', '{"hasta":"2026-03-30"}')->'indicadores'->>'visitas_realizadas')::int = 1
    and (cuidared_api.api_reporte(v_cuenta, 'visitas', '{"desde":"2026-04-01"}')->'indicadores'->>'visitas_realizadas')::int = 1,
    'rango de fechas inclusivo sobre visita.fecha');
  v_r := cuidared_api.api_reporte(v_cuenta, 'visitas', '{"riesgo":"alto"}');
  perform pruebas.afirmar((v_r->'indicadores'->>'visitas_realizadas')::int = 2 and (v_r->'indicadores'->>'atenciones')::int = 2
    and jsonb_array_length((select x from jsonb_array_elements(v_r->'detalle') x where (x->>'visita_id')::uuid = v1)->'adultos') = 1
    and (v_r->'indicadores'->>'visitas_compartidas')::int = 1,
    'el detalle de una visita compartida solo lista a los adultos filtrados');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_cuenta, 'visitas', '{"municipio_cod":"0102"}')->'detalle'->0->>'visita_id')::uuid = v2,
    'visitas de un adulto inactivo se conservan como historia');

  /* necesidades (fecha_registro). */
  v_r := cuidared_api.api_reporte(v_cuenta, 'necesidades', '{}');
  perform pruebas.afirmar(v_r->>'campo_fecha' = 'fecha_registro' and v_r->'indicadores' @> jsonb_build_object(
      'registradas', 5, 'activas', 3, 'pendientes', 2, 'en_proceso', 1, 'resueltas', 1, 'canceladas', 1,
      'porcentaje_resueltas', 20, 'prioridad_alta_activas', 2, 'recurrentes', 1, 'adultos_con_necesidades', 3)
    and (v_r->'indicadores'->'mas_frecuente'->>'total')::int = 2
    and v_r->'indicadores'->'mas_frecuente'->>'nombre' = 'Alimentación',
    'indicadores de necesidades con estados del backend');
  perform pruebas.afirmar((v_r->'indicadores'->>'registradas')::int = (
      select count(*) from cuidared.envejeciente_necesidad en join cuidared.envejeciente e using (envejeciente_id)
      where e.cuenta_id = v_cuenta and e.consentimiento_retirado_en is null)
    and (v_r->'indicadores'->>'activas')::int = (
      select count(*) from cuidared.envejeciente_necesidad en join cuidared.envejeciente e using (envejeciente_id)
      where e.cuenta_id = v_cuenta and en.estado in ('pendiente', 'en_proceso')),
    'necesidades conciliadas con envejeciente_necesidad');
  perform pruebas.afirmar(jsonb_array_length(v_r->'series'->'por_tipo') = (select count(*) from cuidared.tipo_necesidad)
    and v_r->'series'->'por_tipo'->0->>'etiqueta' = 'Alimentación'
    and (select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_tipo') x) = 5
    and (select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_estado') x) = 5
    and v_r->'series'->'por_prioridad'->0 @> '{"clave":"alta","valor":2}'::jsonb
    and v_r->'series'->'recurrencia' @> '[{"clave":"recurrente","valor":1},{"clave":"puntual","valor":4}]'::jsonb,
    'series de necesidades');
  perform pruebas.afirmar((v_r->>'detalle_total')::int = 4
    and (select sum((x->>'total')::int) from jsonb_array_elements(v_r->'detalle') x) = 5
    and v_r->'detalle'->0 @> '{"nombre":"Alimentación","total":2,"porcentaje":40,"resueltas":1,"en_proceso":1,"recurrentes":1}'::jsonb,
    'detalle por categoría conciliado');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_cuenta, 'necesidades', '{"desde":"2026-03-02"}')->'indicadores'->>'registradas')::int = 4
    and (cuidared_api.api_reporte(v_cuenta, 'necesidades', '{"hasta":"2026-03-01"}')->'indicadores'->>'registradas')::int = 1,
    'necesidad del 02/03 02:00 UTC cuenta el 01/03 en Santo Domingo');
  v_r := cuidared_api.api_reporte(v_cuenta, 'necesidades', jsonb_build_object('tipo_necesidad_id', v_medicamentos));
  perform pruebas.afirmar((v_r->'indicadores'->>'registradas')::int = 1 and jsonb_array_length(v_r->'series'->'por_tipo') = 1
    and (v_r->'filtros'->>'tipo_necesidad_id')::int = v_medicamentos, 'filtro por categoría');

  /* casos_prioritarios (fecha_alerta): alertas frente a adultos. */
  v_r := cuidared_api.api_reporte(v_cuenta, 'casos_prioritarios', '{}');
  perform pruebas.afirmar(v_r->>'campo_fecha' = 'fecha_alerta' and v_r->'indicadores' = jsonb_build_object(
      'alertas_prioritarias', 3, 'adultos_prioritarios', 2, 'casos_abiertos', 1, 'alertas_pendientes', 2,
      'alertas_en_proceso', 0, 'alertas_resueltas', 1, 'resueltas_automaticamente', 0, 'porcentaje_resueltas', 33),
    'tres alertas prioritarias de dos adultos; la alerta de seguimiento no es prioritaria');
  perform pruebas.afirmar((v_r->'indicadores'->>'alertas_prioritarias')::int = (
      select count(*) from cuidared.alerta_envejeciente ae join cuidared.tipo_alerta t using (tipo_alerta_id)
      join cuidared.envejeciente e using (envejeciente_id)
      where e.cuenta_id = v_cuenta and cuidared_interno.alerta_es_prioritaria(t.codigo))
    and (v_r->'indicadores'->>'adultos_prioritarios')::int = (
      select count(distinct ae.envejeciente_id) from cuidared.alerta_envejeciente ae join cuidared.tipo_alerta t using (tipo_alerta_id)
      join cuidared.envejeciente e using (envejeciente_id)
      where e.cuenta_id = v_cuenta and cuidared_interno.alerta_es_prioritaria(t.codigo))
    and exists (select from cuidared.alerta_envejeciente ae join cuidared.tipo_alerta t using (tipo_alerta_id)
                where ae.envejeciente_id = r3 and t.codigo = 'ausencia_visitas' and ae.estado = 'pendiente'),
    'conciliación con alerta_envejeciente');
  v_fila := v_r->'detalle'->0;
  perform pruebas.afirmar((v_fila->>'envejeciente_id')::uuid = r1 and v_fila @> jsonb_build_object('alertas', 2,
      'alertas_abiertas', 2, 'tipos', jsonb_build_array('medicamento_pendiente', 'riesgo_alto'), 'estado_actual', 'pendiente',
      'riesgo_vigente', 'alto')
    and v_r->'detalle'->1 @> jsonb_build_object('envejeciente_id', r3, 'alertas', 1, 'alertas_abiertas', 0, 'estado_actual', 'resuelta'),
    'detalle por adulto: abiertos primero');
  perform pruebas.afirmar((select sum((x->>'valor')::int) from jsonb_array_elements(v_r->'series'->'por_tipo') x) = 3
    and v_r->'series'->'por_estado' @> '[{"clave":"pendiente","valor":2,"porcentaje":67},{"clave":"resuelta","valor":1,"porcentaje":33}]'::jsonb,
    'series de alertas');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_cuenta, 'casos_prioritarios', '{"desde":"2026-03-02"}')->'indicadores'
      @> '{"alertas_prioritarias":2,"adultos_prioritarios":2}'::jsonb)
    and (cuidared_api.api_reporte(v_cuenta, 'casos_prioritarios', '{"hasta":"2026-03-01"}')->'indicadores'
      @> '{"alertas_prioritarias":1,"adultos_prioritarios":1}'::jsonb),
    'alerta del 02/03 03:00 UTC pertenece al 01/03 de Santo Domingo');

  /* Vacíos válidos: sin coincidencias en cualquier tipo. */
  foreach v_tipo in array array['adultos', 'visitas', 'necesidades', 'casos_prioritarios'] loop
    v_r := cuidared_api.api_reporte(v_cuenta, v_tipo, '{"municipio_cod":"9999"}');
    perform pruebas.afirmar((v_r->>'vacio')::boolean and v_r->'detalle' = '[]'::jsonb and (v_r->>'detalle_total')::int = 0
      and not exists (select from jsonb_each(v_r->'indicadores') i where jsonb_typeof(i.value) = 'number' and (i.value)::text <> '0')
      and not exists (select from jsonb_each(v_r->'series') s, jsonb_array_elements(s.value) x where (x->>'valor')::int <> 0)
      and jsonb_array_length(v_r->'series'->'por_mes') >= 1,
      'reporte ' || v_tipo || ' vacío válido');
  end loop;
  perform pruebas.afirmar(cuidared_api.api_reporte(v_cuenta, 'adultos', '{"municipio_cod":"9999"}')->'indicadores'->'edad_promedio' = 'null'::jsonb
    and cuidared_api.api_reporte(v_cuenta, 'visitas', '{"municipio_cod":"9999"}')->'indicadores'->'promedio_por_adulto' = 'null'::jsonb
    and cuidared_api.api_reporte(v_cuenta, 'necesidades', '{"municipio_cod":"9999"}')->'indicadores'->'mas_frecuente' = 'null'::jsonb,
    'promedios y categoría más frecuente nulos sin registros');

  /* Análisis avanzado. */
  v_r := cuidared_api.api_reporte_avanzado(v_cuenta, '{}');
  perform pruebas.afirmar(not (v_r->>'vacio')::boolean and jsonb_array_length(v_r->'comparativo_zonas') = 1
    and v_r->'comparativo_zonas'->0 @> jsonb_build_object('zona', 'Centro', 'adultos_activos', 2, 'riesgo_alto', 1,
      'visitas_realizadas', 2, 'necesidades_activas', 3, 'alertas_abiertas', 3, 'sin_personal_asignado', 2)
    and (v_r->'comparativo_zonas'->0->>'visitas_por_adulto')::numeric = 1
    and (v_r->'comparativo_zonas'->0->>'dias_sin_visita_promedio')::numeric
        = round(((v_hoy - date '2026-04-01') + (v_hoy - date '2026-03-05')) / 2.0, 1),
    'comparativo por sector con el estado actual de los activos');
  perform pruebas.afirmar(jsonb_array_length(v_r->'comparativo_municipios') = 1
    and v_r->'comparativo_municipios'->0 @> '{"municipio":{"codigo":"0101"},"adultos_activos":2,"visitas_realizadas":2}'::jsonb
    and jsonb_array_length(v_r->'tendencias') = 12 and v_r->'tendencias'->11->>'mes' = to_char(v_hoy, 'YYYY-MM'),
    'comparativo por municipio y 12 meses de tendencia sin desde');
  v_r := cuidared_api.api_reporte_avanzado(v_cuenta, '{"desde":"2026-03-01","hasta":"2026-04-30"}');
  perform pruebas.afirmar(jsonb_array_length(v_r->'tendencias') = 6 and v_r->'tendencias'->0->>'mes' = '2025-11'
    and v_r->'tendencias'->4 = '{"mes":"2026-03","visitas_realizadas":2,"variacion_visitas":null,
      "necesidades_registradas":3,"alertas_prioritarias":2,"perfiles_nuevos":2}'::jsonb
    and v_r->'tendencias'->5 = '{"mes":"2026-04","visitas_realizadas":1,"variacion_visitas":-50,
      "necesidades_registradas":2,"alertas_prioritarias":1,"perfiles_nuevos":0}'::jsonb
    and (v_r->'tendencias'->3->>'perfiles_nuevos')::int = 1,
    'periodo menor de 3 meses: 6 meses de tendencia con variación');
  perform pruebas.afirmar((cuidared_api.api_reporte_avanzado(v_cuenta, '{"municipio_cod":"9999"}')->>'vacio')::boolean,
    'análisis avanzado vacío válido');
  perform pruebas.error(format('select cuidared_api.api_reporte_avanzado(%s, %L)', v_cuenta, '{"tipo_necesidad_id":1}'), '22023');

  -- Tendencias de un periodo de 3 meses o más: los meses de los extremos se recortan a `desde` y `hasta`.
  v_r := cuidared_api.api_reporte_avanzado(v_cuenta, '{"desde":"2026-03-06","hasta":"2026-05-31"}');
  perform pruebas.afirmar(jsonb_array_length(v_r->'tendencias') = 3
    and v_r->'tendencias'->0 = '{"mes":"2026-03","visitas_realizadas":1,"variacion_visitas":null,
      "necesidades_registradas":2,"alertas_prioritarias":1,"perfiles_nuevos":1}'::jsonb
    and v_r->'tendencias'->1 = '{"mes":"2026-04","visitas_realizadas":1,"variacion_visitas":0,
      "necesidades_registradas":2,"alertas_prioritarias":1,"perfiles_nuevos":0}'::jsonb
    and (v_r->'comparativo_zonas'->0->>'visitas_realizadas')::int = 1,
    'el primer mes empieza en desde (06/03): excluye la visita del 05/03 y los registros del 01/03');
  v_r := cuidared_api.api_reporte_avanzado(v_cuenta, '{"desde":"2026-01-01","hasta":"2026-04-01"}');
  perform pruebas.afirmar(jsonb_array_length(v_r->'tendencias') = 4
    and v_r->'tendencias'->3 @> '{"mes":"2026-04","visitas_realizadas":1,"necesidades_registradas":0,"alertas_prioritarias":0}'::jsonb,
    'el último mes termina en hasta (01/04, inclusive)');

  /* Aislamiento: la otra cuenta solo ve su visita y su alerta. */
  perform pruebas.como(v_otro);
  perform pruebas.afirmar((cuidared_api.api_reporte(v_otra, 'visitas', '{}')->'indicadores'->>'visitas_realizadas')::int = 1
    and (cuidared_api.api_reporte(v_otra, 'casos_prioritarios', '{}')->'indicadores'->>'alertas_prioritarias')::int = 1
    and (cuidared_api.api_reporte(v_otra, 'adultos', '{}')->'indicadores'->>'registrados')::int = 1,
    'reportes aislados por cuenta');

  /* Sin visitas:ver (Familia), el análisis avanzado publica las métricas de visitas como null. */
  insert into cuidared.prueba_funcionalidad(tipo_cuenta_id, funcionalidad)
    select t.tipo_cuenta_id, f from cuidared.tipo_cuenta t, unnest(array['dashboard_metricas', 'reportes_avanzados']) f
    where t.codigo = 'familia' on conflict do nothing;
  v_fam := pruebas.cuenta('familia', v_fam_coord);
  v_adulto_fam := pruebas.envejeciente(v_fam, 'Familia', 'Avanzada');
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_fam, v_hoy - 2, '09:00', 'Histórica', 'completada', v_fam_coord) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, v_adulto_fam);
  perform pruebas.como(v_fam_coord);
  v_r := cuidared_api.api_reporte_avanzado(v_fam, '{}');
  perform pruebas.afirmar(v_r->'comparativo_zonas'->0->'visitas_realizadas' = 'null'::jsonb
    and v_r->'comparativo_zonas'->0->'visitas_por_adulto' = 'null'::jsonb
    and v_r->'comparativo_municipios'->0->'visitas_realizadas' = 'null'::jsonb
    and (v_r->'comparativo_zonas'->0->>'adultos_activos')::int = 1
    and not exists (select from jsonb_array_elements(v_r->'tendencias') t
                    where t->'visitas_realizadas' <> 'null'::jsonb or t->'variacion_visitas' <> 'null'::jsonb)
    and (v_r->'tendencias'->11->>'perfiles_nuevos')::int = 1,
    'sin visitas:ver no se exponen métricas de visitas; las demás se conservan');
end $$;

rollback;
