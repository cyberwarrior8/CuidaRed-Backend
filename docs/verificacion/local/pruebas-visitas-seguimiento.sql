-- CU-05, CU-06, CU-14 y CU-18. Ejecutar en la base desechable después de pruebas-00-ayudas.sql.
begin;
do $$
declare
  admin uuid := pruebas.usuario('adm@seguimiento.test', '04300200001');
  coord uuid := pruebas.usuario('coord@seguimiento.test', '04300200002');
  cuidador uuid := pruebas.usuario('cuidador@seguimiento.test', '04300200003');
  familiar uuid := pruebas.usuario('familiar@seguimiento.test', '04300200004');
  cuenta bigint := pruebas.cuenta('organizacion', admin);
  familia bigint := pruebas.cuenta('familia', familiar);
  persona uuid := pruebas.envejeciente(cuenta);
  otra_persona uuid := pruebas.envejeciente(cuenta);
  dia date := cuidared_interno.hoy() + 2;
  huella text := repeat('c', 64);
  creada uuid;
  v_visita uuid;
  interna uuid;
  evidencia uuid;
  perfil bigint;
  prioridad smallint;
  horario jsonb;
  operacion jsonb;
  tiempo_captura timestamptz := date_trunc('milliseconds', now()) - interval '5 minutes';
  meta jsonb := '{"nombre_archivo":"visita.pdf", "tipo_mime":"application/pdf", "tamano_bytes":10}';
  datos jsonb;
  fila jsonb;
  ruta_evidencia text;
begin
  perform pruebas.miembro(cuenta, coord, 'coordinador');
  perform pruebas.miembro(cuenta, cuidador, 'cuidador');
  perform pruebas.como(familiar);
  perform pruebas.afirmar(not (cuidared_api.api_contexto_cuenta(familia)->'permisos' ? 'visitas:ver'), 'Módulo fuera de la cuenta familiar');
  perform pruebas.afirmar(cuidared_api.api_contexto_cuenta(familia)->'permisos' ? 'sync:usar', 'Se conserva la sincronización familiar para otras entidades');
  perform pruebas.afirmar(not has_function_privilege('authenticated', 'cuidared_api.api_visita_reclamar_avisos()', 'execute'), 'La cola no es un servicio del cliente');
  perform pruebas.afirmar(has_schema_privilege('service_role', 'cuidared_api', 'usage'), 'El worker puede invocar su esquema');

  perform cuidared_api.api_publico_crear_solicitud(jsonb_build_object('cuenta_id', cuenta, 'nombres', 'Ana', 'apellidos', 'Prueba',
    'cedula', '00123456789', 'telefono', '8095550100', 'correo', 'ana@seguimiento.test', 'persona_a_visitar', 'Persona mayor',
    'fecha_propuesta', dia, 'hora_propuesta', '10:00', 'motivo', 'Visita familiar', 'codigo_hash', huella));
  select solicitud_visita_id into creada from cuidared.solicitud_visita where codigo_hash = huella;
  perform pruebas.como(admin);
  horario := jsonb_build_object('envejeciente_id', persona, 'participante_id', cuidador, 'fecha', dia, 'hora', '10:00', 'hora_fin_programada', '11:00');
  datos := cuidared_api.api_autorizar_solicitud_visita(cuenta, creada, horario);
  v_visita := (datos->>'visita_id')::uuid;
  perform pruebas.afirmar(datos->'participantes'->0->>'usuario_id' = cuidador::text and datos->>'hora_fin_programada' = '11:00', 'El administrador autoriza y asigna');
  perform pruebas.afirmar(exists (select from cuidared.aviso_visita where solicitud_id = creada and evento = 'autorizada'), 'Se encola la autorización');
  perform pruebas.afirmar(exists (select from cuidared.aviso_visita where solicitud_id = creada and evento = 'recordatorio' and cierre is null), 'Se agenda el recordatorio');

  datos := jsonb_build_object('fecha', dia, 'hora_programada', '10:30', 'hora_fin_programada', '11:30',
    'razon', 'Seguimiento de prueba', 'envejeciente_ids', array[otra_persona], 'participante_ids', array[cuidador]);
  perform pruebas.error(format('select cuidared_api.api_programar_visita(%s, %L::jsonb)', cuenta, datos), 'P0001', 'CR_PARTICIPANTE_OCUPADO');
  datos := datos || jsonb_build_object('hora_programada', '11:00', 'hora_fin_programada', '11:30', 'autorizar', false);
  datos := cuidared_api.api_programar_visita(cuenta, datos);
  interna := (datos->>'visita_id')::uuid;
  perform pruebas.afirmar((datos->>'pendiente_autorizacion')::boolean, 'Programar reserva el horario sin autorizar al equipo');
  perform pruebas.como(cuidador);
  perform pruebas.error(format('select cuidared_api.api_iniciar_visita(%s, %L::uuid)', cuenta, interna), 'P0002');
  perform pruebas.como(coord);
  datos := cuidared_api.api_autorizar_visita(cuenta, interna);
  perform pruebas.afirmar(not (datos->>'pendiente_autorizacion')::boolean and datos->'autorizada_por'->>'usuario_id' = coord::text,
    'La autorización queda vinculada a la coordinación');
  perform pruebas.como(admin);
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_visitas(cuenta,
     jsonb_build_object('desde', dia, 'hasta', dia), '[{"campo":"hora_programada","direccion":"asc"}]'::jsonb, 20, 0)->'items') = 2,
    'El calendario devuelve las dos citas en ese día');
  perform cuidared_api.api_reprogramar_visita(cuenta, v_visita, jsonb_build_object('fecha', dia + 1, 'hora', '10:00', 'hora_fin_programada', '11:00'));
  datos := cuidared_api.api_publico_consultar_solicitud(huella);
  perform pruebas.afirmar((datos->>'reprogramada')::boolean and datos->>'fecha' = (dia + 1)::text, 'El seguimiento público muestra el nuevo horario');
  perform pruebas.afirmar((select count(*) from cuidared.aviso_visita where solicitud_id = creada and evento = 'recordatorio' and cierre is null) = 1, 'Solo queda vigente el nuevo recordatorio');
  for fila in select value from jsonb_array_elements(cuidared_api.api_visita_reclamar_avisos()) loop
    perform pruebas.afirmar(fila->>'correo' = 'ana@seguimiento.test' and fila ? 'evento', 'El worker recibe los avisos sin datos del adulto');
    perform cuidared_api.api_visita_cerrar_aviso((fila->>'id')::uuid, (fila->>'reclamo')::uuid, 'enviado');
  end loop;
  perform pruebas.afirmar((select count(*) from cuidared.aviso_visita where solicitud_id = creada and cierre = 'enviado') = 2, 'Se reconocen ambos avisos de estado');

  insert into cuidared.prioridad(nombre, orden) values ('Media', 2) on conflict do nothing;
  select min(prioridad_id) into prioridad from cuidared.prioridad;
  if not exists (select from cuidared.tipo_cuidado) then
    insert into cuidared.tipo_cuidado(nombre) values ('Cuidado en domicilio');
  end if;
  insert into cuidared.cuidador(usuario_id, tipo_cuidado_id, cuidador_independiente)
    values (cuidador, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true) returning cuidador_id into perfil;
  datos := cuidared_api.api_tarea_crear(cuenta, jsonb_build_object('visita_id', v_visita, 'envejeciente_id', persona,
    'cuidador_id', perfil::text, 'titulo', 'Preparar la visita', 'prioridad_id', prioridad, 'fecha_programada', dia, 'requiere_evidencia', false));
  perform pruebas.afirmar(datos->'tareas'->0->>'visita_id' = v_visita::text, 'La agenda enlaza la tarea con la visita');

  -- Simula llegar al día de la cita sin depender de la hora en la que se ejecute la prueba.
  update cuidared.visita set fecha = cuidared_interno.hoy(), estado = 'en_curso' where visita_id = v_visita;
  perform pruebas.como(cuidador);
  ruta_evidencia := cuidared_api.api_visita_preparar_evidencia(cuenta, v_visita, meta)->>'ruta';
  insert into storage.objects(bucket_id, name, owner_id, metadata)
    values('evidencias', ruta_evidencia, cuidador::text, '{"size":10,"mimetype":"application/pdf"}');
  evidencia := (cuidared_api.api_visita_registrar_evidencia(cuenta, v_visita, meta || jsonb_build_object('ruta', ruta_evidencia))->>'evidencia_id')::uuid;
  datos := jsonb_build_object('detalles', jsonb_build_array(jsonb_build_object('envejeciente_id', persona,
    'estado_general', 'estable', 'observacion', 'Conversó con su familia.')), 'checklist', jsonb_build_array('caidas'));
  perform pruebas.error(format('select cuidared_api.api_registrar_visita(%s, %L::uuid, %L::jsonb)', cuenta, v_visita, datos),
    'P0001', 'CR_EVIDENCIA_VISITA_PENDIENTE');
  operacion := jsonb_build_object('id_cliente', gen_random_uuid(), 'entidad', 'visita', 'tipo', 'registrar',
    'registro_id', v_visita, 'datos', datos, 'actualizado_en', cuidared_interno.sync_iso(tiempo_captura),
    'base_actualizado_en', (select cuidared_interno.sync_iso(fecha_actualizacion) from cuidared.visita where visita_id = v_visita));
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta, operacion)->>'motivo' = 'VISIT_EVIDENCE_PENDING',
    'La sincronización conserva el registro pendiente de revisión');
  perform pruebas.como(admin);
  perform pruebas.error(format('select cuidared_api.api_visita_revisar_evidencia(%s, %L::uuid, %L::uuid, null)',
    cuenta, v_visita, evidencia), '42501');
  perform pruebas.como(coord);
  perform cuidared_api.api_visita_revisar_evidencia(cuenta, v_visita, evidencia, null);
  perform pruebas.como(cuidador);
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta, operacion)->>'resultado' = 'aplicada', 'La captura se aplica tras la validación');
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta, operacion)->>'resultado' = 'duplicada', 'La captura se aplica una vez');
  perform pruebas.afirmar((select fecha_realizacion = tiempo_captura and 'caidas' = any(checklist) from cuidared.visita where visita_id = v_visita), 'Se conserva la hora UTC de captura y el checklist');
  perform pruebas.afirmar((cuidared_api.api_publico_consultar_solicitud(huella)->>'puede_registrar_observacion')::boolean, 'La visita completa abre observaciones');

  update cuidared.envejeciente set consentimiento_retirado_en = now() where envejeciente_id = persona;
  perform pruebas.como(admin);
  perform pruebas.error(format('select cuidared_api.api_obtener_visita(%s,%L::uuid)', cuenta, v_visita), 'P0002');
end $$;
rollback;
