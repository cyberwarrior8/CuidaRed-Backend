-- Verificación transaccional de CUIDARED-009. Requiere autorización para el proyecto objetivo.
-- Identidades y expedientes sintéticos, con reversión. No usa correos ni credenciales reales.
begin;
set local statement_timeout = '25s';

do $$
declare
  v_usuario uuid := gen_random_uuid();
  v_sesion uuid := gen_random_uuid();
  v_categoria smallint;
  v_municipio text;
  v_cuenta bigint;
  v_adulto uuid;
  v_item smallint;
  v_prioridad smallint;
  v_necesidad uuid := gen_random_uuid();
  v_alerta uuid;
  v_aviso uuid;
  v_resultado jsonb;
  v_op jsonb;
begin
  if has_table_privilege('authenticated','cuidared.necesidad_evento','SELECT')
     or has_table_privilege('authenticated','cuidared.alerta_envejeciente','SELECT')
     or has_function_privilege('anon','cuidared_api.api_necesidad_obtener(bigint,uuid)','EXECUTE')
     or has_function_privilege('authenticated','cuidared_interno.alertas_evaluar_diario()','EXECUTE') then
    raise exception 'Se detectó un permiso directo fuera del contrato';
  end if;

  insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  values (v_usuario, 'cuidared-smoke+' || v_usuario || '@example.test', now(),
    '{"cedula":"00109998561","nombres":"Titular","apellidos":"Sintético"}');
  insert into auth.sessions (id,user_id,created_at) values (v_sesion,v_usuario,now());
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_usuario,'session_id',v_sesion,'role','authenticated')::text,true);

  select cat.categoria_cuenta_id into strict v_categoria
    from cuidared.categoria_cuenta cat join cuidared.tipo_cuenta t using (tipo_cuenta_id)
    where t.codigo = 'familia' and cat.activo order by cat.categoria_cuenta_id limit 1;
  select municipio_cod into strict v_municipio from cuidared.municipio order by municipio_cod limit 1;
  v_cuenta := (cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','familia',
    'nombre','Verificación Necesidades y Alertas','categoria_cuenta_id',v_categoria,
    'municipio_cod',v_municipio))->>'cuenta_id')::bigint;
  v_adulto := (cuidared_api.api_crear_envejeciente(v_cuenta,jsonb_build_object(
    'nombres','Persona','apellidos','Sintética','cedula','00109998562','fecha_nacimiento','1945-05-06',
    'sexo','F','municipio_cod',v_municipio,'zona','Zona de prueba','autonomia','parcial',
    'consentimiento',jsonb_build_object('otorgado',true,'otorgado_por','adulto'),
    'contactos',jsonb_build_array(jsonb_build_object('nombres','Contacto','apellidos','Prueba',
      'parentesco','Hermana','telefono','8095550100','es_principal',true))
  ))->>'envejeciente_id')::uuid;
  select n.necesidad_id into strict v_item from cuidared.necesidad n
    join cuidared.tipo_necesidad t using (tipo_necesidad_id)
    where t.codigo='medicamentos' and n.nombre=t.nombre || ' (general)';
  select prioridad_id into strict v_prioridad from cuidared.prioridad where codigo='alta';

  v_op := jsonb_build_object('id_cliente',gen_random_uuid(),'entidad','necesidad','tipo','registrar',
    'registro_id',v_necesidad,'actualizado_en',cuidared_interno.sync_iso(now()),
    'datos',jsonb_build_object('envejeciente_id',v_adulto,'necesidad_id',v_item,
      'prioridad_id',v_prioridad,'descripcion','Necesidad sintética','cantidad',0.004,'unidad_medida',repeat('u',64)));
  if cuidared_api.api_sync_aplicar_operacion(v_cuenta,v_op)->>'resultado' is distinct from 'aplicada' then
    raise exception 'La sincronización no registró el alta';
  end if;
  if cuidared_api.api_sync_aplicar_operacion(v_cuenta,v_op)->>'resultado' is distinct from 'duplicada' then
    raise exception 'La sincronización no reconoció el reintento';
  end if;
  v_resultado := cuidared_api.api_necesidad_obtener(v_cuenta,v_necesidad);
  if (v_resultado->>'cantidad')::numeric is distinct from 0.004
     or length(v_resultado->>'unidad_medida') is distinct from 64 then
    raise exception 'La necesidad perdió precisión o longitud';
  end if;
  select alerta_envejeciente_id into strict v_alerta from cuidared.alerta_envejeciente
    where fuente_necesidad_id = v_necesidad and estado='pendiente';
  insert into cuidared.envejeciente_riesgo (envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto,r.riesgo_id,n.nivel_riesgo_id,'Riesgo sintético',v_usuario
    from cuidared.riesgo r cross join cuidared.nivel_riesgo n where r.codigo='riesgo_caida' and n.codigo='alto';
  v_resultado := cuidared_api.api_casos_prioritarios_listar(v_cuenta,'{}',array['-fecha_alerta'],20,0);
  if (v_resultado->>'total')::integer is distinct from 1
     or (v_resultado#>>'{items,0,total_alertas}')::integer is distinct from 2 then
    raise exception 'El caso prioritario no agrupó sus dos fuentes';
  end if;
  select notificacion_id into strict v_aviso from cuidared.notificacion
    where alerta_envejeciente_id=v_alerta and usuario_id=v_usuario;
  if cuidared_api.api_notificacion_alerta_leer(v_cuenta,v_aviso)->>'fecha_lectura' is null then
    raise exception 'El aviso personal no registró la lectura';
  end if;
  perform cuidared_api.api_necesidad_estado(v_cuenta,v_necesidad,'{"estado":"resuelta","motivo":"Entrega verificada"}');
  if not exists (select from cuidared.alerta_envejeciente
    where alerta_envejeciente_id=v_alerta and estado='resuelta' and cierre_automatico) then
    raise exception 'La alerta no se cerró al resolver su necesidad';
  end if;
  if not exists (select from cuidared.auditoria where tabla='envejeciente_necesidad'
    and registro_id=v_necesidad::text and datos_nuevos=jsonb_build_object('envejeciente_id',v_adulto)) then
    raise exception 'La auditoría de la necesidad no registró la referencia';
  end if;
end;
$$;

select 'fases_5_y_6_verificadas' as resultado;
rollback;
