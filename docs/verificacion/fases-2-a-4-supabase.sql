-- Prueba transaccional posterior a las fases 2 a 4. Requiere autorización para el proyecto objetivo.
-- Usa identidades sintéticas y JWT simulados. No envía correos ni sube archivos. Las filas se revierten.
begin;
set local statement_timeout = '25s';

do $$
declare
  v_titular uuid := gen_random_uuid();
  v_cuidador uuid := gen_random_uuid();
  v_sesion_titular uuid := gen_random_uuid();
  v_sesion_cuidador uuid := gen_random_uuid();
  v_correo_titular text := 'cuidared-smoke+' || v_titular || '@example.test';
  v_correo_cuidador text := 'cuidared-smoke+' || v_cuidador || '@example.test';
  v_categoria smallint;
  v_municipio text;
  v_cuenta bigint;
  v_miembro bigint;
  v_perfil bigint;
  v_adulto uuid;
  v_visita uuid;
  v_tarea uuid;
  v_tipo_cuidado smallint;
  v_prioridad smallint;
  v_res jsonb;
  v_op jsonb;
  v_meta jsonb := '{"nombre_archivo":"prueba.png","tipo_mime":"image/png","tamano_bytes":24}';
  v_ruta text;
begin
  insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  values (v_titular, v_correo_titular, now(), '{"cedula":"00109998101","nombres":"Titular","apellidos":"Prueba"}'),
         (v_cuidador, v_correo_cuidador, now(), '{"cedula":"00109998102","nombres":"Cuidador","apellidos":"Prueba"}');
  insert into auth.sessions (id, user_id, created_at)
  values (v_sesion_titular, v_titular, now()), (v_sesion_cuidador, v_cuidador, now());
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_titular, 'session_id', v_sesion_titular, 'role', 'authenticated')::text, true);

  if (cuidared_api.api_mi_perfil()->>'usuario_id')::uuid is distinct from v_titular then
    raise exception 'Acceso: perfil del titular no disponible';
  end if;
  select cat.categoria_cuenta_id into strict v_categoria
  from cuidared.categoria_cuenta cat join cuidared.tipo_cuenta tc using (tipo_cuenta_id)
  where tc.codigo = 'familia' and cat.activo order by cat.categoria_cuenta_id limit 1;
  select municipio_cod into strict v_municipio from cuidared.municipio order by municipio_cod limit 1;

  v_res := cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','familia','nombre','Verificación de CuidaRed',
    'categoria_cuenta_id',v_categoria,'municipio_cod',v_municipio));
  v_cuenta := (v_res->>'cuenta_id')::bigint;
  if (select fecha_fin_prueba - fecha_inicio_prueba from cuidared.cuenta where cuenta_id = v_cuenta)
      is distinct from interval '168 hours' or (v_res->>'acceso_operativo')::boolean is distinct from true then
    raise exception 'Fase 2: la cuenta no tiene una prueba operativa de 168 horas';
  end if;
  v_miembro := (cuidared_api.api_agregar_miembro(v_cuenta, v_correo_cuidador, '00109998102', 'cuidador')->>'membresia_id')::bigint;
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_cuidador, 'session_id', v_sesion_cuidador, 'role', 'authenticated')::text, true);
  if jsonb_array_length(cuidared_api.api_mis_invitaciones()) is distinct from 1 then
    raise exception 'Fase 2: invitación pendiente no disponible';
  end if;
  perform cuidared_api.api_aceptar_membresia(v_miembro);
  if (cuidared_api.api_contexto_cuenta(v_cuenta)->>'rol') is distinct from 'cuidador' then
    raise exception 'Fase 2: membresía del cuidador no activa';
  end if;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_titular, 'session_id', v_sesion_titular, 'role', 'authenticated')::text, true);
  select tipo_cuidado_id into strict v_tipo_cuidado from cuidared.tipo_cuidado where nombre = 'Cuidador remunerado';
  v_perfil := (cuidared_api.api_guardar_cuidador_miembro(v_cuenta, v_miembro, v_tipo_cuidado, false)->>'cuidador_id')::bigint;
  v_adulto := (cuidared_api.api_crear_envejeciente(v_cuenta, jsonb_build_object(
    'nombres','Persona','apellidos','Sintética','cedula','00109998103','fecha_nacimiento','1945-05-06',
    'sexo','F','municipio_cod',v_municipio,'zona','Zona de prueba','autonomia','parcial',
    'consentimiento',jsonb_build_object('otorgado',true,'otorgado_por','adulto'),
    'contactos',jsonb_build_array(jsonb_build_object('nombres','Contacto','apellidos','Prueba',
      'parentesco','Hermana','telefono','8095550100','es_principal',true))
  ))->>'envejeciente_id')::uuid;
  if (cuidared_api.api_riesgo_consultar(v_cuenta, v_adulto)->>'texto') is distinct from 'Sin evaluación vigente' then
    raise exception 'Fase 3: riesgo inicial inesperado';
  end if;
  v_visita := (cuidared_api.api_programar_visita(v_cuenta, jsonb_build_object(
    'fecha',cuidared_interno.hoy(),'hora_programada',cuidared_interno.hhmm(cuidared_interno.hora_local()),
    'razon','Visita de verificación','envejeciente_ids',jsonb_build_array(v_adulto),
    'participante_ids',jsonb_build_array(v_cuidador)
  ))->>'visita_id')::uuid;
  select prioridad_id into strict v_prioridad from cuidared.prioridad where codigo = 'alta';
  v_res := cuidared_api.api_tarea_crear(v_cuenta,jsonb_build_object(
    'titulo','Seguimiento sintético','envejeciente_id',v_adulto,'cuidador_id',v_perfil::text,
    'prioridad_id',v_prioridad,'fecha_programada',cuidared_interno.hoy(),'requiere_evidencia',true,
    'repeticion',jsonb_build_object('frecuencia','diaria','hasta',cuidared_interno.hoy()+2)
  ));
  if jsonb_array_length(v_res->'tareas') is distinct from 3 then
    raise exception 'Fase 4: la serie no tiene tres ocurrencias';
  end if;
  v_tarea := (v_res->'tareas'->0->>'tarea_id')::uuid;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_cuidador, 'session_id', v_sesion_cuidador, 'role', 'authenticated')::text, true);
  perform cuidared_api.api_iniciar_visita(v_cuenta, v_visita);
  v_ruta := cuidared_api.api_visita_preparar_evidencia(v_cuenta, v_visita, v_meta)->>'ruta';
  if v_ruta is null then raise exception 'Fase 4: no se autorizó la ruta de evidencia de visita'; end if;
  v_op := jsonb_build_object('id_cliente',gen_random_uuid(),'entidad','visita','tipo','registrar','registro_id',v_visita,
    'datos',jsonb_build_object('detalles',jsonb_build_array(jsonb_build_object(
      'envejeciente_id',v_adulto,'estado_general','estable','observacion','Observación sintética'))),
    'actualizado_en',cuidared_interno.sync_iso(now()),
    'base_actualizado_en',(select cuidared_interno.sync_iso(fecha_actualizacion) from cuidared.visita where visita_id = v_visita));
  if (cuidared_api.api_sync_aplicar_operacion(v_cuenta,v_op)->>'resultado') is distinct from 'aplicada' then
    raise exception 'Fase 4: falló sincronización de visita autorizada';
  end if;
  if (cuidared_api.api_sync_aplicar_operacion(v_cuenta,v_op)->>'resultado') is distinct from 'duplicada' then
    raise exception 'Fase 4: la sincronización no reconoció el reintento';
  end if;
  begin
    perform cuidared_api.api_tarea_completar(v_cuenta,v_tarea);
    raise exception 'Fase 4: se completó una tarea sin evidencia validada';
  exception when raise_exception then
    if sqlerrm <> 'CR_EVIDENCIA_REQUERIDA' then raise; end if;
  end;
  v_ruta := cuidared_api.api_evidencia_preparar_subida(v_cuenta,v_tarea,v_meta)->>'ruta';
  if cuidared_storage.evidencia_permitida(v_ruta,'subir') is distinct from true
      or cuidared_storage.evidencia_permitida(v_ruta,'ver') is distinct from false then
    raise exception 'Fase 4: permisos de evidencia antes del registro incorrectos';
  end if;
end $$;

rollback;
select 'Fases 2 a 4 verificadas con datos sintéticos revertidos' as verificacion;
