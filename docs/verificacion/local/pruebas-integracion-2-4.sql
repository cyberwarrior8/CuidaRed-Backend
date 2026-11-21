-- Regresiones de la integración. Solo para una base desechable con el stub y las propuestas 2a–4d.
begin;
do $$
declare
  titular uuid := pruebas.usuario('titular@integracion.test','00100009001');
  cuidador uuid := pruebas.usuario('cuidador@integracion.test','00100009002');
  gestor uuid := pruebas.usuario('gestor@integracion.test','00100009003');
  ajeno uuid := pruebas.usuario('ajeno@integracion.test','00100009004');
  vencida uuid := pruebas.usuario('vencida@integracion.test','00100009005');
  cuenta bigint;
  otra bigint;
  expirada bigint;
  miembro bigint;
  miembro_otro bigint;
  adulto uuid;
  visita uuid;
  inexistente uuid := gen_random_uuid();
  categoria smallint;
  tipo_cuidado smallint;
  prioridad smallint;
  perfil_cuidador text;
  tarea uuid;
  entrada jsonb;
  respuesta jsonb;
  meta jsonb := '{"nombre_archivo":"prueba.png","tipo_mime":"image/png","tamano_bytes":24}';
  ruta text;
  op jsonb;
  titular_historico uuid := 'a1000000-0000-4000-8000-000000000001';
  adulto_historico uuid := 'a1000000-0000-4000-8000-000000000002';
  visita_identificada uuid := 'a1000000-0000-4000-8000-000000000004';
  visita_ambigua uuid := 'a1000000-0000-4000-8000-000000000005';
  tarea_historica uuid := 'a1000000-0000-4000-8000-000000000006';
  cuenta_historica bigint;
  prueba_historica_id bigint;
  evidencia_historica uuid;
begin
  select cuenta_id into cuenta_historica from cuidared.cuenta where nombre = 'Cuenta histórica';
  select cuenta_id into prueba_historica_id from cuidared.cuenta where nombre = 'Prueba histórica';
  perform pruebas.afirmar((select prueba_historica and fecha_inicio_prueba_historica = date '2025-01-01'
    and fecha_fin_prueba_historica = date '2025-01-08' and fecha_inicio_prueba is null and fecha_fin_prueba is null
    from cuidared.cuenta where cuenta_id = prueba_historica_id), 'se conservan las fechas históricas sin inferir hora');
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(prueba_historica_id), 'la prueba histórica no concede acceso operativo');
  perform pruebas.miembro(prueba_historica_id, titular_historico, 'coordinador');
  perform pruebas.miembro(cuenta_historica, titular_historico, 'coordinador');
  perform pruebas.como(titular_historico);
  perform pruebas.afirmar((cuidared_api.api_contexto_cuenta(prueba_historica_id)->>'acceso_operativo')::boolean = false,
    'el gestor conserva la consulta de su cuenta histórica');
  update cuidared.cuenta set fecha_fin_vigencia = cuidared_interno.hoy() + 1 where cuenta_id = cuenta_historica;
  perform pruebas.afirmar((select cuenta_id = cuenta_historica from cuidared.visita where visita_id = visita_identificada),
    'identifica una visita de una sola cuenta');
  perform pruebas.afirmar((select cuenta_id is null from cuidared.visita where visita_id = visita_ambigua), 'conserva visita ambigua sin cuenta');
  perform pruebas.afirmar(not cuidared_interno.visita_visible(cuenta_historica, visita_ambigua, titular_historico), 'oculta visita ambigua');
  perform pruebas.error(format('update cuidared.detalle_visita set observacion = null where visita_id = %L',visita_ambigua),'23514');
  perform pruebas.afirmar((select count(*) = 1 from cuidared_interno.historial_eventos(adulto_historico, true, false, true, false, false)),
    'el historial solo devuelve la visita identificada');
  perform pruebas.afirmar((cuidared_api.api_tarea_obtener(cuenta_historica, tarea_historica)->>'es_historica')::boolean,
    'la tarea histórica se puede consultar');
  select evidencia_id, archivo_url into evidencia_historica, ruta from cuidared.evidencia where tarea_agenda_id = tarea_historica;
  respuesta := cuidared_api.api_evidencias_listar(cuenta_historica, tarea_historica)->0;
  perform pruebas.afirmar((respuesta->>'es_historica')::boolean and not (respuesta ? 'ruta'), 'metadatos históricos sin ruta');
  perform pruebas.afirmar(not cuidared_storage.evidencia_permitida(ruta, 'ver'), 'Storage rechaza incluso una ruta histórica conocida');
  perform pruebas.error(format('update cuidared.tarea_agenda set estado = ''pendiente'' where tarea_agenda_id = %L',tarea_historica),'23514');
  perform pruebas.error(format('delete from cuidared.evidencia where evidencia_id = %L',evidencia_historica),'23514');

  insert into cuidared.provincia values ('01','Distrito Nacional') on conflict do nothing;
  insert into cuidared.municipio values ('0101','Santo Domingo de Guzmán','01') on conflict do nothing;
  select cat.categoria_cuenta_id into categoria from cuidared.categoria_cuenta cat
  join cuidared.tipo_cuenta t using (tipo_cuenta_id) where t.codigo = 'familia' order by 1 limit 1;
  entrada := jsonb_build_object('tipo','familia','nombre','Cuenta de integración','categoria_cuenta_id',categoria,'municipio_cod','0101');
  perform pruebas.como(titular);
  respuesta := cuidared_api.api_registrar_cuenta(entrada);
  cuenta := (respuesta->>'cuenta_id')::bigint;
  perform pruebas.afirmar((select fecha_fin_prueba - fecha_inicio_prueba = interval '168 hours'
    and fecha_inicio_prueba = now() and plan_id is null from cuidared.cuenta c where c.cuenta_id = cuenta), 'prueba automática exacta sin plan');
  perform pruebas.error(format('select cuidared_api.api_registrar_cuenta(%L)',entrada), 'P0001','CR_PRUEBA_EN_CURSO');
  perform pruebas.afirmar((cuidared_api.api_mis_cuentas('{}','[]',0,20)->>'total')::int = 1, 'lista cuenta activa');
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_mis_cuentas('{}','[]',20,20)->'items') = 0, 'página vacía conserva el contrato');
  perform pruebas.afirmar((cuidared_api.api_mis_cuentas('{"tipo_cuenta":"organizacion"}','[]',0,20)->>'total')::int = 0, 'filtro de tipo');
  perform pruebas.error(format('update cuidared.cuenta set fecha_fin_prueba = fecha_fin_prueba + interval ''1 hour'' where cuenta_id = %s',cuenta),'23514');

  miembro := pruebas.miembro(cuenta,cuidador,'cuidador','pendiente');
  perform pruebas.como(cuidador);
  perform pruebas.afirmar((cuidared_api.api_mis_cuentas('{}','[]',0,20)->>'total')::int = 0, 'pendiente fuera del listado activo');
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_mis_invitaciones()) = 1, 'pendiente propia aparte');
  perform cuidared_api.api_aceptar_membresia(miembro);
  perform pruebas.afirmar((cuidared_api.api_mis_cuentas('{}','[]',0,20)->>'total')::int = 1, 'activación de membresía');

  select tipo_cuidado_id into tipo_cuidado from cuidared.tipo_cuidado where nombre = 'Cuidador remunerado';
  perform pruebas.como(titular);
  respuesta := cuidared_api.api_guardar_cuidador_miembro(cuenta,miembro,tipo_cuidado,false);
  perfil_cuidador := respuesta->>'cuidador_id';
  otra := pruebas.cuenta('familia',ajeno);
  miembro_otro := pruebas.miembro(otra,cuidador,'cuidador');
  perform pruebas.como(ajeno);
  perform pruebas.afirmar((cuidared_api.api_obtener_cuidador_miembro(otra,miembro_otro)->>'cuidador_id') = (respuesta->>'cuidador_id'), 'mismo perfil entre cuentas');
  perform pruebas.afirmar(cuidared_api.api_obtener_cuidador_miembro(otra,miembro_otro)->>'usuario_empleador_id' is null, 'no expone empleador ajeno');
  perform pruebas.como(titular);

  adulto := (cuidared_api.api_crear_envejeciente(cuenta, jsonb_build_object(
    'nombres','Adulto','apellidos','Integración','cedula','00100009006','fecha_nacimiento','1945-05-06',
    'sexo','F','municipio_cod','0101','zona','Zona de prueba','autonomia','parcial',
    'consentimiento',jsonb_build_object('otorgado',true,'otorgado_por','adulto'),
    'contactos',jsonb_build_array(jsonb_build_object('nombres','Contacto','apellidos','Prueba','parentesco','Hermana','telefono','8095550100','es_principal',true))
  ))->>'envejeciente_id')::uuid;
  perform pruebas.afirmar((cuidared_api.api_riesgo_consultar(cuenta,adulto)->>'texto') = 'Sin evaluación vigente', 'sin riesgo inventado');
  visita := (cuidared_api.api_programar_visita(cuenta, jsonb_build_object(
    'fecha',cuidared_interno.hoy(),'hora_programada',cuidared_interno.hhmm(cuidared_interno.hora_local()),
    'razon','Visita sintética','envejeciente_ids',jsonb_build_array(adulto),'participante_ids',jsonb_build_array(cuidador)
  ))->>'visita_id')::uuid;
  entrada := jsonb_build_object('detalles',jsonb_build_array(jsonb_build_object(
    'envejeciente_id',adulto,'estado_general','estable','observacion','Observación sintética')));
  perform pruebas.error(format('select cuidared_api.api_registrar_visita(%s,%L,%L)',cuenta,visita,entrada),'P0001','CR_NO_PARTICIPA');
  perform pruebas.como(cuidador);
  op := jsonb_build_object('id_cliente',gen_random_uuid(),'entidad','visita','tipo','registrar',
    'registro_id',inexistente,'datos',entrada,'actualizado_en',cuidared_interno.sync_iso(now()));
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta,op)->>'motivo' = 'NOT_FOUND', 'offline no crea visitas');
  perform cuidared_api.api_iniciar_visita(cuenta,visita);
  ruta := cuidared_api.api_visita_preparar_evidencia(cuenta,visita,meta)->>'ruta';
  insert into storage.objects(bucket_id,name,owner_id,metadata)
  values ('evidencias',ruta,cuidador::text,'{"size":24,"mimetype":"image/png"}');
  perform cuidared_api.api_visita_registrar_evidencia(cuenta,visita,meta || jsonb_build_object('ruta',ruta));
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_visita_listar_evidencias(cuenta,visita)) = 1, 'archivo de participante autorizado');
  perform pruebas.como(ajeno);
  perform pruebas.error(format('select cuidared_api.api_visita_listar_evidencias(%s,%L)',cuenta,visita),'42501');
  perform pruebas.como(cuidador);
  op := op || jsonb_build_object('id_cliente',gen_random_uuid(),'registro_id',visita,
    'base_actualizado_en',(select cuidared_interno.sync_iso(fecha_actualizacion) from cuidared.visita v where v.visita_id = visita));
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta,op)->>'resultado' = 'aplicada','sincroniza visita autorizada');
  perform pruebas.afirmar(cuidared_api.api_sync_aplicar_operacion(cuenta,op)->>'resultado' = 'duplicada','reintento idempotente');
  perform pruebas.afirmar(not has_function_privilege('anon','cuidared_api.api_publico_consultar_solicitud(text)','EXECUTE'),'sin RPC anónima');
  perform pruebas.afirmar(not has_table_privilege('authenticated','cuidared.evidencia_visita','SELECT'),'sin lectura directa de evidencias');

  perform pruebas.como(titular);
  select prioridad_id into prioridad from cuidared.prioridad where codigo = 'alta';
  respuesta := cuidared_api.api_tarea_crear(cuenta,jsonb_build_object(
    'titulo','Seguimiento sintético','envejeciente_id',adulto,'cuidador_id',perfil_cuidador,
    'prioridad_id',prioridad,'fecha_programada',cuidared_interno.hoy(),'requiere_evidencia',true,
    'repeticion',jsonb_build_object('frecuencia','diaria','hasta',cuidared_interno.hoy()+2)
  ));
  perform pruebas.afirmar(jsonb_array_length(respuesta->'tareas') = 3,'serie diaria con tres ocurrencias');
  tarea := (respuesta->'tareas'->0->>'tarea_id')::uuid;
  perform pruebas.como(cuidador);
  perform pruebas.error(format('select cuidared_api.api_tarea_completar(%s,%L)',cuenta,tarea),'P0001','CR_EVIDENCIA_REQUERIDA');
  ruta := cuidared_api.api_evidencia_preparar_subida(cuenta,tarea,meta)->>'ruta';
  perform pruebas.afirmar(cuidared_storage.evidencia_permitida(ruta, 'subir'), 'la evidencia operativa admite subida');
  perform pruebas.afirmar(not cuidared_storage.evidencia_permitida(ruta, 'ver'), 'una ruta sin evidencia registrada no permite lectura');
  insert into storage.objects(bucket_id,name,owner_id,metadata)
  values ('evidencias',ruta,cuidador::text,'{"size":24,"mimetype":"image/png"}');
  perform cuidared_api.api_evidencia_registrar(cuenta,tarea,meta || jsonb_build_object('ruta',ruta));
  perform pruebas.afirmar(cuidared_storage.evidencia_permitida(ruta, 'ver'), 'la evidencia operativa registrada conserva su descarga');
  perform pruebas.como(titular);
  select membresia_id into miembro from cuidared_interno.membresia_activa(cuenta, cuidador);
  perform cuidared_api.api_cambiar_rol_miembro(cuenta, miembro, 'familiar');
  perform pruebas.afirmar(exists(select 1 from cuidared.vinculo where envejeciente_id = adulto and usuario_id = cuidador
    and fecha_revocacion is not null and motivo_revocacion = 'Cambio de rol' and autorizado_por_usuario_id = titular),
    'el cambio de rol conserva el vínculo y su autoría');
  perform pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(cuenta, adulto, cuidador), 'el nuevo rol no hereda acceso');
  perform cuidared_api.api_familiar_autorizar(cuenta, adulto, cuidador);
  perform pruebas.afirmar((select count(*) = 2 and count(*) filter (where fecha_revocacion is null) = 1
    from cuidared.vinculo where envejeciente_id = adulto and usuario_id = cuidador), 'una autorización nueva conserva el periodo cerrado');
  miembro := pruebas.miembro(cuenta,gestor,'coordinador');
  perform cuidared_api.api_transferir_titularidad(cuenta,miembro);
  perform pruebas.afirmar((select c.usuario_titular_id = gestor from cuidared.cuenta c where c.cuenta_id = cuenta),'transferencia confirmada');
  expirada := pruebas.cuenta('familia',vencida,'prueba',null,cuidared_interno.hoy());
  perform pruebas.como(vencida);
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(expirada),'prueba vencida');
  perform pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s,%L)',expirada,'{"nombre":"Cambio"}'),'P0001','CR_CUENTA_SIN_ACCESO');
end $$;
rollback;
