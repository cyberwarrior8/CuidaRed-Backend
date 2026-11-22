-- Fase 7 · exportaciones auditadas (CSV y registro previo de PDF/Excel) e informe médico V2: alcance del Cuidador,
-- omisión de secciones sensibles, topes de historial y visitas, auditoría por cuenta. Base desechable de `--solo=reportes`.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('r7d-admin@example.test', '00700000301', 'Alba', 'Gestora');
  v_coord uuid := pruebas.usuario('r7d-coord@example.test', '00700000302', 'Laura', 'Mejía');
  v_k1 uuid := pruebas.usuario('r7d-k1@example.test', '00700000303', 'Ana', 'Gómez');
  v_k2 uuid := pruebas.usuario('r7d-k2@example.test', '00700000304', 'Beto', 'Sin Asignar');
  v_k3 uuid := pruebas.usuario('r7d-k3@example.test', '00700000305', 'Carlos', 'Perfil Vencido');
  v_familiar uuid := pruebas.usuario('r7d-familiar@example.test', '00700000306');
  v_otro uuid := pruebas.usuario('r7d-otro@example.test', '00700000307');
  v_vacia_admin uuid := pruebas.usuario('r7d-vacia@example.test', '00700000308');
  v_cuenta bigint := pruebas.cuenta('organizacion', v_admin);
  v_otra bigint := pruebas.cuenta('organizacion', v_otro);
  v_vacia bigint := pruebas.cuenta('organizacion', v_vacia_admin);
  v_hoy date := cuidared_interno.hoy();
  x uuid := pruebas.envejeciente(v_cuenta, 'Juana', 'Pérez');
  y uuid := pruebas.envejeciente(v_cuenta, 'Yolanda', 'Otra');
  w uuid := pruebas.envejeciente(v_cuenta, 'Walter', 'Inactivo', 'M', 'inactivo');
  z uuid := pruebas.envejeciente(v_cuenta, 'Zoila', 'Retirada');
  v_ajeno uuid := pruebas.envejeciente(v_otra, 'Ajeno', 'Otra');
  v_cuidador_vinculo smallint := (select tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado');
  v_rol_cuidador smallint := (select rol_id from cuidared.rol where codigo = 'cuidador');
  v_tipo_org smallint := (select tipo_cuenta_id from cuidared.tipo_cuenta where codigo = 'organizacion');
  v_visita uuid;
  v_r jsonb;
  v_e jsonb;
  v_a cuidared.auditoria;
  v_antes integer;
  i integer;
begin
  perform pruebas.miembro(v_cuenta, v_coord, 'coordinador');
  perform pruebas.miembro(v_cuenta, v_k1, 'cuidador');
  perform pruebas.miembro(v_cuenta, v_k2, 'cuidador');
  perform pruebas.miembro(v_cuenta, v_k3, 'cuidador');
  perform pruebas.miembro(v_cuenta, v_familiar, 'familiar');
  if not exists (select from cuidared.tipo_cuidado) then
    insert into cuidared.tipo_cuidado(nombre) values ('Cuidado en domicilio');
  end if;
  insert into cuidared.cuidador(usuario_id, tipo_cuidado_id, cuidador_independiente, fecha_inicio, fecha_fin)
    select u, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true, v_hoy - 60, f
    from (values (v_k1, null::date), (v_k2, null::date), (v_k3, v_hoy - 1)) t(u, f);
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id) values
    (x, v_k1, v_cuidador_vinculo), (x, v_k3, v_cuidador_vinculo), (w, v_k1, v_cuidador_vinculo), (z, v_k1, v_cuidador_vinculo);
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id, autorizado_por_usuario_id, fecha_autorizacion)
    select x, v_familiar, tipo_vinculo_id, v_admin, now() from cuidared.tipo_vinculo where codigo = 'familiar_responsable';
  update cuidared.envejeciente set estado = 'inactivo', consentimiento_retirado_en = now(), consentimiento_retirado_por = v_admin
    where envejeciente_id = z;

  -- Riesgo de x: 16 registros resueltos y uno vigente (alto) = 17 en el historial.
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo, estado, fecha_riesgo,
      fecha_resolucion, resuelto_por)
    select x, r.riesgo_id, n.nivel_riesgo_id, 'Histórico ' || g, 'resuelto', now() - make_interval(days => 100 + g),
      now() - make_interval(days => 90 + g), v_coord
    from generate_series(1, 16) g cross join cuidared.riesgo r cross join cuidared.nivel_riesgo n
    where r.codigo = 'aislamiento_social' and n.codigo = 'medio';
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo, fecha_riesgo)
    select x, r.riesgo_id, n.nivel_riesgo_id, 'Caída reciente', now() - interval '1 day'
    from cuidared.riesgo r, cuidared.nivel_riesgo n where r.codigo = 'riesgo_caida' and n.codigo = 'alto';
  -- El inicio y el fin son inclusivos. Las futuras, vencidas y suspendidas quedan fuera.
  insert into cuidared.indicacion_medica(envejeciente_id, tipo_indicacion_id, titulo, descripcion, frecuencia_horario,
      fecha_inicio, fecha_fin, estado, registrado_por) values
    (x, 1, 'Losartán 50 mg', 'Una tableta en la mañana.', 'Diaria, 8:00', v_hoy - 10, null, 'activa', v_coord),
    (x, 2, 'Consulta de hoy', null, null, v_hoy, v_hoy, 'activa', v_coord),
    (x, 2, 'Consulta futura', null, null, v_hoy + 7, null, 'activa', v_coord),
    (x, 1, 'Antibiótico', 'Cada 8 horas.', 'Cada 8 horas', v_hoy - 40, v_hoy - 1, 'activa', v_coord),
    (x, 2, 'Fisioterapia', 'Ejercicios de movilidad.', 'Semanal', v_hoy - 20, null, 'suspendida', v_coord);
  -- Doce visitas completadas de x, una de y y una programada de x.
  for i in 1..12 loop
    insert into cuidared.visita(cuenta_id, fecha, hora_programada, hora_inicio, hora_fin, razon, estado, creada_por)
      values (v_cuenta, v_hoy - i, '09:00', '09:00', '09:40', 'Seguimiento ' || i, 'completada', v_coord)
      returning visita_id into v_visita;
    insert into cuidared.detalle_visita(visita_id, envejeciente_id, estado_general, observacion)
      values (v_visita, x, 'requiere_atencion', 'Obs ' || i);
    insert into cuidared.registro_visita(visita_id, usuario_id, autorizada_por_usuario_id) values (v_visita, v_k1, v_coord);
  end loop;
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, v_hoy, '08:00', 'Solo y', 'completada', v_coord) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id, observacion) values (v_visita, y, 'Obs de y');
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, v_hoy + 2, '08:00', 'Próxima', 'programada', v_coord) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, x);

  /* CSV auditado: la exportación devuelve el mismo reporte que la consulta y deja un registro minimizado. */
  perform pruebas.como(v_coord);
  v_r := cuidared_api.api_exportar_reporte_csv(v_cuenta, 'visitas', '{"desde":"2026-01-01"}');
  v_e := v_r->'exportacion';
  perform pruebas.afirmar(v_e @> jsonb_build_object('tipo', 'visitas', 'formato', 'csv',
      'generado_por', jsonb_build_object('nombres', 'Laura', 'apellidos', 'Mejía', 'rol', 'coordinador'),
      'cuenta', jsonb_build_object('nombre', 'Cuenta organizacion'))
    and v_e->'filtros'->>'desde' = '2026-01-01' and v_e ? 'exportacion_id' and v_e ? 'fecha',
    'constancia de la exportación CSV');
  perform pruebas.afirmar((v_r->'reporte') - 'generado_en'
      = cuidared_api.api_reporte(v_cuenta, 'visitas', '{"desde":"2026-01-01"}') - 'generado_en'
    and (v_r->'reporte'->'indicadores'->>'visitas_realizadas')::int = 13,
    'el CSV usa exactamente el reporte de la consulta');
  select * into strict v_a from cuidared.auditoria a
    where a.tabla = 'exportacion_reporte' and a.registro_id = v_e->>'exportacion_id';
  perform pruebas.afirmar(v_a.operacion = 'I' and v_a.usuario_id = v_coord
    and (select array_agg(k order by k) from jsonb_object_keys(v_a.datos_nuevos) k) = array['cuenta_id', 'filtros', 'formato', 'tipo']
    and v_a.datos_nuevos->>'cuenta_id' = v_cuenta::text and v_a.datos_anteriores is null,
    'auditoría con referencias, sin filas del reporte');

  -- Registro previo del PDF; el Excel sin reportes_avanzados no deja rastro.
  select count(*) into v_antes from cuidared.auditoria a
    where a.tabla = 'exportacion_reporte' and a.datos_nuevos->>'cuenta_id' = v_cuenta::text;
  v_e := cuidared_api.api_registrar_exportacion_reporte(v_cuenta,
    '{"tipo":"casos_prioritarios","formato":"pdf","filtros":{"desde":"2026-11-01","hasta":null}}');
  perform pruebas.afirmar(v_e @> '{"tipo":"casos_prioritarios","formato":"pdf"}'::jsonb
    and v_e->'filtros' = '{"desde":"2026-11-01","hasta":null,"municipio_cod":null,"zona":null,"riesgo":null,"tipo_necesidad_id":null}'::jsonb,
    'registro del PDF con filtros normalizados');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_cuenta,
    '{"tipo":"adultos","formato":"xlsx"}'), '42501');
  perform pruebas.afirmar((select count(*) from cuidared.auditoria a
    where a.tabla = 'exportacion_reporte' and a.datos_nuevos->>'cuenta_id' = v_cuenta::text) = v_antes + 1,
    'solo la exportación autorizada se registra');
  -- Los filtros normalizados de una respuesta (con claves en null) se pueden reenviar tal cual.
  v_e := cuidared_api.api_reporte(v_cuenta, 'adultos', '{"desde":"2026-01-01"}')->'filtros';
  perform pruebas.afirmar(v_e ? 'tipo_necesidad_id' and v_e->'tipo_necesidad_id' = 'null'::jsonb
    and (cuidared_api.api_registrar_exportacion_reporte(v_cuenta, jsonb_build_object('tipo', 'adultos', 'formato', 'pdf',
      'filtros', v_e))->'filtros') = v_e
    and (cuidared_api.api_reporte(v_cuenta, 'visitas', v_e)->'filtros') = v_e
    and (cuidared_api.api_exportar_reporte_csv(v_cuenta, 'casos_prioritarios', v_e || '{"otro":null}')
      ->'exportacion'->'filtros') = v_e,
    'una clave con valor null equivale a omitirla en todas las RPC de reportes');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_cuenta, 'adultos',
    '{"tipo_necesidad_id":1}'), '22023');
  perform pruebas.como(v_vacia_admin);
  v_r := cuidared_api.api_exportar_reporte_csv(v_vacia, 'necesidades', '{}');
  perform pruebas.afirmar((v_r->'reporte'->>'vacio')::boolean and exists (select from cuidared.auditoria a
      where a.tabla = 'exportacion_reporte' and a.registro_id = v_r->'exportacion'->>'exportacion_id'),
    'un reporte vacío también se exporta y se audita');

  /* Informe médico del Coordinador: contenido completo, topes y auditoría. */
  perform pruebas.como(v_coord);
  v_r := cuidared_api.api_informe_medico(v_cuenta, x);
  perform pruebas.afirmar(v_r->'secciones_omitidas' = '[]'::jsonb
    and v_r->>'aviso' = 'CuidaRed no diagnostica ni sustituye al médico tratante.'
    and v_r->'generado_por' = '{"nombres":"Laura","apellidos":"Mejía","rol":"coordinador"}'::jsonb
    and v_r ? 'generado_en' and v_r->'cuenta'->>'nombre' = 'Cuenta organizacion',
    'cabecera del informe: quién, cuándo y aviso');
  perform pruebas.afirmar(v_r->'identificacion' @> jsonb_build_object('envejeciente_id', x, 'nombres', 'Juana',
      'apellidos', 'Pérez', 'sexo', 'F', 'estado', 'activo', 'fecha_nacimiento', '1945-05-05',
      'municipio', jsonb_build_object('codigo', '0101'), 'provincia', jsonb_build_object('codigo', '01'))
    and (v_r->'identificacion'->>'cedula') ~ '^[0-9]{11}$'
    and (v_r->'identificacion'->>'edad')::int = extract(year from age(v_hoy, date '1945-05-05'))
    and not (v_r->'identificacion' ?| array['direccion', 'telefono', 'contactos']),
    'identificación mínima');
  perform pruebas.afirmar(v_r->'riesgo'->>'nivel_vigente' = 'alto' and jsonb_array_length(v_r->'riesgo'->'vigentes') = 1
    and v_r->'riesgo'->'vigentes'->0->'factor'->>'codigo' = 'riesgo_caida'
    and jsonb_array_length(v_r->'riesgo'->'historial') = 15 and (v_r->'riesgo'->>'historial_total')::int = 17
    and v_r->'riesgo'->'historial'->0->>'estado' = 'activo' and v_r->'riesgo'->'historial'->14->>'motivo' = 'Histórico 14',
    'riesgo vigente e historial de 15 de 17, del más reciente al más antiguo');
  perform pruebas.afirmar(jsonb_array_length(v_r->'indicaciones'->'vigentes') = 2
    and (v_r->'indicaciones'->>'no_vigentes')::int = 3
    and v_r->'indicaciones'->'vigentes'->0->>'titulo' = 'Consulta de hoy'
    and v_r->'indicaciones'->'vigentes'->1 @> '{"titulo":"Losartán 50 mg","fecha_fin":null,
      "tipo":{"tipo_indicacion_id":1},"registrada_por":{"nombres":"Laura","apellidos":"Mejía"}}'::jsonb,
    'solo indicaciones activas y no vencidas');
  perform pruebas.afirmar((v_r->'visitas'->>'realizadas_total')::int = 12 and jsonb_array_length(v_r->'visitas'->'recientes') = 10
    and (v_r->'visitas'->>'ultima_fecha')::date = v_hoy - 1
    and v_r->'visitas'->'recientes'->0 @> jsonb_build_object('fecha', v_hoy - 1, 'hora_inicio', '09:00', 'hora_fin', '09:40',
      'origen', 'interna', 'estado_general', 'requiere_atencion', 'observacion', 'Obs 1',
      'responsables', jsonb_build_array(jsonb_build_object('nombres', 'Ana', 'apellidos', 'Gómez')))
    and v_r->'visitas'->'recientes'->9->>'observacion' = 'Obs 10'
    and not exists (select from jsonb_array_elements(v_r->'visitas'->'recientes') r where r->>'observacion' = 'Obs de y'),
    'últimas 10 visitas completadas del adulto con sus observaciones');
  select * into strict v_a from cuidared.auditoria a where a.tabla = 'informe_medico' and a.registro_id = v_r->>'informe_id';
  perform pruebas.afirmar(v_a.usuario_id = v_coord and v_a.datos_nuevos = jsonb_build_object('cuenta_id', v_cuenta,
      'envejeciente_id', x, 'secciones_omitidas', '[]'::jsonb),
    'el informe queda auditado sin su contenido');

  v_r := cuidared_api.api_informe_medico(v_cuenta, y);
  perform pruebas.afirmar(v_r->'riesgo' = '{"nivel_vigente":null,"vigentes":[],"historial":[],"historial_total":0}'::jsonb
    and v_r->'indicaciones' = '{"vigentes":[],"no_vigentes":0}'::jsonb
    and (v_r->'visitas'->>'realizadas_total')::int = 1,
    'adulto sin riesgo ni indicaciones: secciones vacías válidas');
  perform pruebas.afirmar(cuidared_api.api_informe_medico(v_cuenta, w)->'identificacion'->>'estado' = 'inactivo',
    'expediente inactivo consultable');
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, z), 'P0002');
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, v_ajeno), 'P0002');
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, gen_random_uuid()), 'P0002');

  /* Alcance del Cuidador: asignado con perfil vigente sí; sin asignación o con perfil vencido, 404. */
  perform pruebas.como(v_k1);
  perform pruebas.afirmar((cuidared_api.api_informe_medico(v_cuenta, x)->'visitas'->>'realizadas_total')::int = 12
    and cuidared_api.api_informe_medico(v_cuenta, w) ? 'identificacion', 'cuidador asignado');
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, y), 'P0002');
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, z), 'P0002');
  perform pruebas.como(v_k2);
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, x), 'P0002');
  perform pruebas.como(v_k3);
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, x), 'P0002');
  perform pruebas.como(v_familiar);
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, x), '42501');
  perform pruebas.como(v_admin);
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_cuenta, x), '42501');

  /* Catálogos heredados sin código: el informe publica el código como null en lugar de fallar. */
  insert into cuidared.riesgo(nombre) values ('Factor heredado') returning riesgo_id into i;
  insert into cuidared.nivel_riesgo(nombre, orden) values ('Nivel heredado', 0) returning nivel_riesgo_id into v_antes;
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    values (y, i, v_antes, 'Registro heredado');
  perform pruebas.como(v_coord);
  v_r := cuidared_api.api_informe_medico(v_cuenta, y);
  perform pruebas.afirmar(v_r->'riesgo'->'vigentes'->0 @> '{"factor":{"codigo":null,"nombre":"Factor heredado"},
      "nivel":{"codigo":null,"nombre":"Nivel heredado"}}'::jsonb
    and v_r->'riesgo'->'historial'->0->'factor'->'codigo' = 'null'::jsonb,
    'factor y nivel heredados sin código');

  /* Omisión de secciones según la matriz (cambio sintético y transaccional de rol_permiso). */
  delete from cuidared.rol_permiso
    where rol_id = v_rol_cuidador and tipo_cuenta_id = v_tipo_org and accion = 'adultos:ver-sensible';
  perform pruebas.como(v_k1);
  v_r := cuidared_api.api_informe_medico(v_cuenta, x);
  perform pruebas.afirmar(v_r->'secciones_omitidas' = '["riesgo"]'::jsonb and v_r->'riesgo' = 'null'::jsonb
    and jsonb_array_length(v_r->'indicaciones'->'vigentes') = 2
    and v_r->'visitas'->'recientes'->0->'observacion' = 'null'::jsonb
    and v_r->'visitas'->'recientes'->0->'estado_general' = 'null'::jsonb
    and v_r->'visitas'->'recientes'->0->>'fecha' = (v_hoy - 1)::text,
    'sin adultos:ver-sensible: sin riesgo ni observaciones, con fechas y responsables');
  delete from cuidared.rol_permiso
    where rol_id = v_rol_cuidador and tipo_cuenta_id = v_tipo_org and accion = 'indicaciones:ver';
  v_r := cuidared_api.api_informe_medico(v_cuenta, x);
  perform pruebas.afirmar(v_r->'secciones_omitidas' = '["indicaciones","riesgo"]'::jsonb and v_r->'indicaciones' = 'null'::jsonb,
    'sin indicaciones:ver: sin indicaciones');
  perform pruebas.afirmar((select a.datos_nuevos->'secciones_omitidas' from cuidared.auditoria a
      where a.tabla = 'informe_medico' and a.registro_id = v_r->>'informe_id') = '["indicaciones","riesgo"]'::jsonb,
    'la auditoría conserva las secciones omitidas');

  /* Auditoría de la cuenta: las exportaciones e informes aparecen solo en su cuenta. */
  perform pruebas.como(v_admin);
  v_r := cuidared_api.api_auditoria_cuenta(v_cuenta, 100, 0, true);
  perform pruebas.afirmar((select count(*) from jsonb_array_elements(v_r->'items') e
      where e->>'entidad' = 'exportacion_reporte' and e->>'accion' = 'exportacion' and e->>'actor' = 'Laura Mejía') = 4
    and (select count(*) from jsonb_array_elements(v_r->'items') e
         where e->>'entidad' = 'informe_medico' and e->>'accion' = 'exportacion') >= 4
    and (select count(*) from jsonb_array_elements(v_r->'items') e where e->>'accion' = 'alta') > 0,
    'Auditoría de la cuenta muestra exportaciones e informes');
  perform pruebas.como(v_otro);
  v_r := cuidared_api.api_auditoria_cuenta(v_otra, 100, 0, true);
  perform pruebas.afirmar(not exists (select from jsonb_array_elements(v_r->'items') e
      where e->>'entidad' in ('exportacion_reporte', 'informe_medico')), 'otra cuenta no ve esos registros');
end $$;

rollback;
