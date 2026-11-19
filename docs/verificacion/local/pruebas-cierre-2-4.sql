-- Casos de cierre para una base local desechable con las ayudas de 00. Revierten sus datos.
begin;
do $$
declare
  titular uuid := pruebas.usuario('titular@cierre.test','00100008001','Titular');
  cuidador uuid := pruebas.usuario('cuidador@cierre.test','00100008002','Cuidador');
  voluntario uuid := pruebas.usuario('voluntario@cierre.test','00100008003','Voluntario');
  ajeno uuid := pruebas.usuario('ajeno@cierre.test','00100008004','Ajeno');
  cuenta bigint := pruebas.cuenta('familia',titular);
  otra bigint := pruebas.cuenta('organizacion',ajeno);
  adulto uuid := pruebas.envejeciente(cuenta,'Expediente','De prueba');
  adulto2 uuid := pruebas.envejeciente(cuenta,'Otro','Adulto');
  env_org uuid := pruebas.envejeciente(otra,'Expediente','Organización');
  miembro bigint := pruebas.miembro(cuenta,cuidador,'cuidador');
  tipo_cuidado smallint := (select min(tipo_cuidado_id) from cuidared.tipo_cuidado);
  tipo_indicacion smallint := (select min(tipo_indicacion_id) from cuidared.tipo_indicacion);
  hoy date := cuidared_interno.hoy();
  fecha date := hoy + 1;
  payload jsonb := jsonb_build_object(
    'fecha',fecha, 'hora_programada','09:00', 'razon','Seguimiento comunitario',
    'envejeciente_ids',jsonb_build_array(adulto,adulto2), 'participante_ids',jsonb_build_array(titular));
  visita_grupal uuid;
  visita_vol uuid;
  solicitud uuid;
  tarea uuid;
  indicacion uuid;
  evidencia uuid;
  datos jsonb;
  meta jsonb := '{"nombre_archivo":"prueba.pdf","tipo_mime":"application/pdf","tamano_bytes":19}';
  ruta text;
  esperado jsonb;
  entrada_vol jsonb;
  perfil bigint;
  codigo_riesgo text[];
begin
  perform pruebas.miembro(otra,voluntario,'voluntario');
  perform pruebas.como(titular);
  select array_agg(codigo order by codigo) into codigo_riesgo from cuidared.riesgo where codigo not in ('evaluacion');
  perform pruebas.afirmar(codigo_riesgo @> array['riesgo_caida','aislamiento_social','riesgo_nutricional','abandono_desatencion','acceso_medicamentos'], 'cinco factores aprobados');
  perform pruebas.error(format('select cuidared_interno.seg_vincular(%s,%L,%L,%L,%L)',cuenta,adulto,cuidador,'cuidador_asignado',titular),'P0001','CR_PERFIL_CUIDADOR_REQUERIDO');
  datos := cuidared_api.api_guardar_cuidador_miembro(cuenta,miembro,tipo_cuidado,false);
  perfil := (datos->>'cuidador_id')::bigint;
  perform cuidared_api.api_guardar_cuidador_miembro(cuenta,miembro,tipo_cuidado,true,true);
  perform pruebas.afirmar((select usuario_empleador_id = titular from cuidared.cuidador where cuidador_id = perfil),'conserva empleador al cambiar tipo');

  datos := cuidared_api.api_programar_visitas_recurrentes(cuenta,payload || jsonb_build_object('repeticion',jsonb_build_object('frecuencia','diaria','hasta',fecha + 1)));
  visita_grupal := (datos->'visitas'->0->>'visita_id')::uuid;
  perform pruebas.afirmar(jsonb_array_length(datos->'visitas') = 2,'serie diaria completa');
  perform pruebas.afirmar((select count(*) = 2 from cuidared.visita where serie_id = (datos->>'serie_id')::uuid),'id de serie compartido');
  perform pruebas.afirmar((select count(*) = 2 from cuidared.registro_visita r join cuidared.visita v using (visita_id)
    where v.serie_id = (datos->>'serie_id')::uuid and r.autorizada_por_usuario_id = titular),'autorización en todas las ocurrencias');
  perform pruebas.error(format('select cuidared_api.api_programar_visitas_recurrentes(%s,%L)',
    cuenta,payload || jsonb_build_object('fecha',hoy,'repeticion',jsonb_build_object('frecuencia','diaria','hasta',fecha + 1),
      'hora_programada','23:59','participante_ids',jsonb_build_array(titular),'envejeciente_ids',jsonb_build_array(adulto2))
  || jsonb_build_object('repeticion',jsonb_build_object('frecuencia','diaria','hasta',hoy + 60))),'P0001','CR_SERIE_VISITA_INVALIDA');
  perform cuidared_api.api_programar_visita(cuenta,payload || jsonb_build_object('fecha',fecha + 4,'hora_programada','11:00','envejeciente_ids',jsonb_build_array(adulto2)));
  perform pruebas.error(format('select cuidared_api.api_programar_visitas_recurrentes(%s,%L)',cuenta,payload ||
    jsonb_build_object('fecha',fecha + 3,'hora_programada','11:00','repeticion',jsonb_build_object('frecuencia','diaria','hasta',fecha + 4))),
    'P0001','CR_PARTICIPANTE_OCUPADO');
  perform pruebas.afirmar(not exists (select from cuidared.visita v where v.cuenta_id = cuenta and v.fecha = hoy + 4 and v.hora_programada = time '11:00'),'revierte la serie al fallar una ocurrencia');
  datos := cuidared_api.api_programar_visitas_recurrentes(cuenta,payload || jsonb_build_object('hora_programada','10:00',
    'repeticion',jsonb_build_object('frecuencia','semanal','hasta',fecha + 7,'dias_semana',jsonb_build_array(extract(isodow from fecha)::integer))));
  perform pruebas.afirmar(jsonb_array_length(datos->'visitas') = 2,'serie semanal con días ISO');

  datos := cuidared_api.api_indicacion_crear(cuenta,adulto,jsonb_build_object('tipo_indicacion_id',tipo_indicacion,
    'titulo','Indicación de prueba','fecha_inicio',hoy));
  indicacion := (datos->>'indicacion_medica_id')::uuid;
  ruta := cuidared_api.api_indicacion_preparar_evidencia(cuenta,indicacion,meta)->>'ruta';
  perform pruebas.afirmar(cuidared_storage.evidencia_indicacion_permitida(ruta,true),'gestor puede subir');
  perform pruebas.afirmar(not cuidared_storage.evidencia_indicacion_permitida(ruta,false),'objeto sin registro no es descargable');
  insert into storage.objects(bucket_id,name,owner_id,metadata) values
    ('evidencias',ruta,titular::text,'{"size":19,"mimetype":"application/pdf"}');
  datos := meta || jsonb_build_object('ruta',ruta);
  evidencia := (cuidared_api.api_indicacion_registrar_evidencia(cuenta,indicacion,datos)->>'evidencia_id')::uuid;
  perform pruebas.afirmar((cuidared_api.api_indicacion_registrar_evidencia(cuenta,indicacion,datos)->>'evidencia_id')::uuid = evidencia,'registro idempotente del adjunto');
  perform pruebas.afirmar(cuidared_storage.evidencia_indicacion_permitida(ruta,false),'descarga del adjunto registrado');
  perform pruebas.error(format('select cuidared_api.api_indicacion_preparar_evidencia(%s,%L,%L)',cuenta,indicacion,meta || '{"tamano_bytes":5242881}'),'P0001','CR_ARCHIVO_INVALIDO');
  perform pruebas.como(ajeno);
  perform pruebas.error(format('select cuidared_api.api_indicacion_listar_evidencias(%s,%L)',otra,indicacion),'42501');
  perform pruebas.afirmar(not cuidared_storage.evidencia_indicacion_permitida(ruta,false),'otra cuenta no abre adjunto');
  perform pruebas.error(format('select cuidared_api.api_programar_visitas_recurrentes(%s,%L)',otra,payload),'42501');

  insert into cuidared.solicitud_visita(cuenta_id, visitante_nombres, visitante_apellidos, visitante_cedula,
    visitante_telefono, persona_a_visitar, fecha_propuesta, hora_propuesta, motivo, codigo_hash)
  values (otra,'Persona','Visitante','00000000001','8095550101','Adulto de prueba',fecha,time '09:00',
    'Petición comunitaria',repeat('a',64)) returning solicitud_visita_id into solicitud;
  esperado := cuidared_api.api_autorizar_solicitud_visita(otra,solicitud,jsonb_build_object(
    'envejeciente_id',env_org,'fecha',fecha,'hora','09:00','participante_id',voluntario));
  perform pruebas.afirmar(esperado->>'origen' = 'solicitud' and esperado#>>'{participantes,0,usuario_id}' = voluntario::text
    and esperado#>>'{autorizada_por,usuario_id}' = ajeno::text,'administrador autoriza a participante que puede registrar');

  entrada_vol := payload || jsonb_build_object('fecha',hoy,'hora_programada','23:59',
    'envejeciente_ids',jsonb_build_array(env_org),'participante_ids',jsonb_build_array(voluntario));
  visita_vol := (cuidared_api.api_programar_visita(otra,entrada_vol)->>'visita_id')::uuid;
  perform pruebas.como(voluntario);
  perform cuidared_api.api_iniciar_visita(otra,visita_vol);
  entrada_vol := jsonb_build_object('detalles',jsonb_build_array(jsonb_build_object('envejeciente_id',env_org,'observacion','Visita confirmada.')));
  perform pruebas.error(format('select cuidared_api.api_registrar_visita(%s,%L,%L)',otra,visita_vol,
    entrada_vol || '{"checklist":["higiene"]}'),'22023');
  perform pruebas.error(format('select cuidared_api.api_registrar_visita(%s,%L,%L)',otra,visita_vol,
    jsonb_set(entrada_vol,'{detalles,0,estado_general}','"estable"')),'22023');
  perform pruebas.afirmar(cuidared_api.api_visita_preparar_evidencia(otra,visita_vol,meta)->>'bucket' = 'evidencias',
    'voluntario autorizado puede adjuntar');
  perform cuidared_api.api_registrar_visita(otra,visita_vol,entrada_vol);
  perform pruebas.error(format('select cuidared_api.api_auditoria_cuenta(%s,20,0,true)',otra),'42501');

  perform pruebas.como(titular);
  insert into cuidared.tarea_agenda(envejeciente_id,cuidador_id,prioridad_id,usuario_creador_id,titulo,fecha_programada)
    values(adulto,perfil,(select min(prioridad_id) from cuidared.prioridad),titular,'Seguimiento',fecha)
    returning tarea_agenda_id into tarea;
  perform cuidared_api.api_retirar_consentimiento(cuenta,adulto,'Petición recibida');
  perform pruebas.afirmar((select estado = 'cancelada' from cuidared.visita where visita_id = visita_grupal),'cierra la visita grupal');
  perform pruebas.afirmar((select estado = 'cancelada' from cuidared.tarea_agenda where tarea_agenda_id = tarea),'cierra tarea');
  perform pruebas.afirmar((select consentimiento_otorgado from cuidared.envejeciente where envejeciente_id = adulto),'conserva el consentimiento original');
  perform pruebas.afirmar((cuidared_api.api_listar_envejecientes(cuenta,null,null,'["envejeciente_id"]',20,0)->>'total')::int = 1,'excluye expediente retirado del listado');
  perform pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s,%L)',cuenta,adulto),'P0002');
  perform pruebas.error(format('select cuidared_api.api_estado_envejeciente(%s,%L,%L,null)',cuenta,adulto,'activo'),'P0002');
  perform pruebas.error(format('select cuidared_api.api_obtener_visita(%s,%L)',cuenta,visita_grupal),'P0002');
  perform pruebas.afirmar(not exists (select from cuidared_interno.historial_eventos(adulto2,true,true,true,false,false)
    where referencia_id = visita_grupal::text),'historial operativo no revela visita grupal archivada');
  perform pruebas.afirmar(not cuidared_storage.evidencia_indicacion_permitida(ruta,false),'retiro revoca descarga');
  esperado := cuidared_api.api_consentimientos_retirados(cuenta,20,0,true);
  perform pruebas.afirmar(esperado#>>'{items,0,motivo}' = 'Petición recibida','conserva constancia de retiro');
  perform pruebas.como(ajeno);
  perform pruebas.afirmar((cuidared_api.api_consentimientos_retirados(otra,20,0,true)->>'total')::int = 0,'archivo aislado por cuenta');

  insert into cuidared.auditoria(tabla,operacion,registro_id,usuario_id,datos_nuevos) values
    ('envejeciente','U',adulto::text,titular,jsonb_build_object('cuenta_id',cuenta,'observacion','Sensible')),
    ('envejeciente','U',env_org::text,ajeno,jsonb_build_object('cuenta_id',otra));
  perform pruebas.como(titular);
  esperado := cuidared_api.api_auditoria_cuenta(cuenta,20,0,true);
  perform pruebas.afirmar((esperado->>'total')::int = 2
    and exists (select from jsonb_array_elements(esperado->'items') e where e->>'entidad' = 'evidencia_indicacion')
    and not exists (select from jsonb_array_elements(esperado->'items') e where e->>'actor' not like 'Titular%')
    and esperado::text not like '%Sensible%' and esperado::text not like '%prueba.pdf%', 'auditoría mínima y aislada');
end;
$$;
rollback;
