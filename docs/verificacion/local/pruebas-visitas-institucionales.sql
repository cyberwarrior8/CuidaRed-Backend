-- Solicitud institucional sin expediente individual, autorización, campo, evidencia y observación.
-- Datos sintéticos. Las filas y los metadatos de archivos se revierten.
begin;
do $$
declare
  admin uuid := pruebas.usuario('admin@institucional.test', '04300300001');
  coord uuid := pruebas.usuario('coord@institucional.test', '04300300002');
  cuidador uuid := pruebas.usuario('cuidador@institucional.test', '04300300003');
  ajeno uuid := pruebas.usuario('ajeno@institucional.test', '04300300004');
  cuenta bigint := pruebas.cuenta('organizacion', admin);
  huella text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  solicitud uuid;
  v_visita uuid;
  evidencia uuid;
  ruta text;
  datos jsonb;
  operacion jsonb;
  meta jsonb := '{"nombre_archivo":"actividad.pdf","tipo_mime":"application/pdf","tamano_bytes":10}';
begin
  perform pruebas.miembro(cuenta, coord, 'coordinador');
  perform pruebas.miembro(cuenta, cuidador, 'cuidador');
  perform pruebas.miembro(cuenta, ajeno, 'voluntario');
  if not exists (select from cuidared.tipo_cuidado) then
    insert into cuidared.tipo_cuidado(nombre) values ('Cuidado institucional');
  end if;
  insert into cuidared.cuidador(usuario_id, tipo_cuidado_id, cuidador_independiente)
    values(cuidador, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true);

  datos := jsonb_build_object(
    'cuenta_id', cuenta, 'nombres', 'Ana', 'apellidos', 'Prueba', 'cedula', '00123456789', 'telefono', '8095550100', 'correo', 'ana@institucional.test',
    'tipo_visita', 'institucional', 'entidad_visitante', 'Fundación Sintética', 'tipo_entidad', 'fundacion',
    'cantidad_visitantes', 12, 'aporte_previsto', 'Actividad musical y entrega de alimentos.',
    'fecha_propuesta', cuidared_interno.hoy() + 2, 'hora_propuesta', '10:00', 'hora_fin_propuesta', '11:00', 'motivo', 'Actividad comunitaria', 'codigo_hash', huella);
  perform cuidared_api.api_publico_crear_solicitud(datos);
  perform cuidared_api.api_publico_crear_solicitud(datos);
  perform pruebas.afirmar((select count(*) from cuidared.solicitud_visita where codigo_hash = huella) = 1, 'El reintento no duplica la solicitud');
  perform pruebas.error(format('select cuidared_api.api_publico_crear_solicitud(%L::jsonb)', datos || '{"cantidad_visitantes":13}'::jsonb), 'P0001', 'CR_CONFLICTO');
  select solicitud_visita_id into solicitud from cuidared.solicitud_visita where codigo_hash = huella;
  perform pruebas.afirmar((select persona_a_visitar is null and cantidad_visitantes = 12 from cuidared.solicitud_visita where solicitud_visita_id = solicitud), 'La solicitud institucional no inventa una persona visitada');
  perform pruebas.como(admin);
  datos := cuidared_api.api_autorizar_solicitud_visita(cuenta, solicitud, jsonb_build_object(
    'participante_id', cuidador, 'fecha', cuidared_interno.hoy() + 2, 'hora', '10:00', 'hora_fin_programada', '11:00'));
  v_visita := (datos->>'visita_id')::uuid;
  perform pruebas.afirmar(datos->>'tipo_visita' = 'institucional' and jsonb_array_length(datos->'adultos') = 0, 'Se agenda la organización con un responsable');
  perform pruebas.afirmar(cuidared_interno.solicitud_json(solicitud)->>'entidad_visitante' = 'Fundación Sintética', 'Coordinación recibe los datos del grupo');
  perform cuidared_api.api_reprogramar_visita(cuenta, v_visita, jsonb_build_object('fecha', cuidared_interno.hoy() + 3, 'hora', '11:00', 'hora_fin_programada', '12:00'));
  perform pruebas.como(ajeno);
  perform pruebas.error(format('select cuidared_api.api_obtener_visita(%s,%L::uuid)', cuenta, v_visita), 'P0002');
  perform pruebas.como(cuidador);
  perform pruebas.afirmar(cuidared_api.api_obtener_visita(cuenta, v_visita)->>'visita_id' = v_visita::text, 'El responsable asignado puede abrir la visita institucional');
  update cuidared.visita set fecha = cuidared_interno.hoy() - 1 where visita_id = v_visita;
  perform cuidared_api.api_iniciar_visita(cuenta, v_visita);
  ruta := cuidared_api.api_visita_preparar_evidencia(cuenta, v_visita, meta)->>'ruta';
  insert into storage.objects(bucket_id, name, owner_id, metadata) values ('evidencias', ruta, cuidador::text, '{"size":10,"mimetype":"application/pdf"}');
  evidencia := (cuidared_api.api_visita_registrar_evidencia(cuenta, v_visita, meta || jsonb_build_object('ruta', ruta))->>'evidencia_id')::uuid;
  perform pruebas.como(coord);
  perform cuidared_api.api_visita_revisar_evidencia(cuenta, v_visita, evidencia, null);
  perform pruebas.como(cuidador);
  operacion := jsonb_build_object('id_cliente', gen_random_uuid(), 'entidad', 'visita', 'tipo', 'registrar', 'registro_id', v_visita,
    'datos', jsonb_build_object('detalles', '[]'::jsonb, 'observacion_general', 'Actividad completada con doce participantes.'),
    'actualizado_en', cuidared_interno.sync_iso(now()),
    'base_actualizado_en', (select cuidared_interno.sync_iso(fecha_actualizacion) from cuidared.visita where visita_id = v_visita));
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta, operacion)->>'resultado' = 'aplicada', 'La captura institucional se sincroniza');
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta, operacion)->>'resultado' = 'duplicada', 'El reintento es idempotente');
  perform pruebas.afirmar(cuidared_api.api_publico_consultar_solicitud(huella)->>'estado' = 'autorizada', 'El registro de campo espera confirmación');
  perform pruebas.como(coord);
  perform cuidared_api.api_confirmar_realizacion_visita(cuenta, v_visita, '{"realizada":true,"nota":"La coordinación comprobó la actividad."}');
  perform pruebas.afirmar(cuidared_api.api_publico_consultar_solicitud(huella)->>'estado' = 'realizada', 'El visitante puede consultar el cierre confirmado');
  datos := cuidared_api.api_publico_registrar_observacion_posterior(huella, 'Gracias por recibir a nuestro grupo.');
  perform pruebas.afirmar(datos->>'observacion' = 'Gracias por recibir a nuestro grupo.', 'Se guarda la observación del contacto del grupo');
end $$;
rollback;
