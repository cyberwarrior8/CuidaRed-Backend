-- Prueba de CUIDARED-010 con datos sintéticos. No contacta a un proveedor Web Push.
begin;
set local statement_timeout = '25s';

do $$
declare
  v_usuario uuid := gen_random_uuid();
  v_sesion uuid := gen_random_uuid();
  v_endpoint text := 'https://fcm.googleapis.com/fcm/send/prueba-' || v_usuario;
  v_cuenta bigint;
  v_adulto uuid;
  v_categoria smallint;
  v_municipio text;
  v_entrega record;
begin
  if exists (select from cuidared.push_entrega where estado='pendiente') then
    raise exception 'La cola tiene envíos reales pendientes. Usar una base desechable para esta prueba.';
  end if;
  if has_table_privilege('authenticated','cuidared.push_suscripcion','SELECT')
     or has_function_privilege('authenticated','cuidared_api.api_push_reservar_entregas(integer)','EXECUTE')
     or not has_function_privilege('service_role','cuidared_api.api_push_reservar_entregas(integer)','EXECUTE') then
    raise exception 'Permisos de despacho inesperados';
  end if;

  insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data)
  values (v_usuario,'cuidared-push+' || v_usuario || '@example.test',now(),
    '{"cedula":"00109998621","nombres":"Titular","apellidos":"Sintético"}');
  insert into auth.sessions(id,user_id,created_at) values(v_sesion,v_usuario,now());
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_usuario,'session_id',v_sesion,'role','authenticated')::text,true);
  select cat.categoria_cuenta_id into strict v_categoria
    from cuidared.categoria_cuenta cat join cuidared.tipo_cuenta t using (tipo_cuenta_id)
    where t.codigo='familia' and cat.activo order by cat.categoria_cuenta_id limit 1;
  select municipio_cod into strict v_municipio from cuidared.municipio order by municipio_cod limit 1;
  v_cuenta := (cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','familia','nombre','Prueba Web Push',
    'categoria_cuenta_id',v_categoria,'municipio_cod',v_municipio))->>'cuenta_id')::bigint;
  v_adulto := (cuidared_api.api_crear_envejeciente(v_cuenta,jsonb_build_object(
    'nombres','Persona','apellidos','Sintética','cedula','00109998622','fecha_nacimiento','1945-05-06',
    'sexo','F','municipio_cod',v_municipio,'zona','Zona de prueba','autonomia','parcial',
    'consentimiento',jsonb_build_object('otorgado',true,'otorgado_por','adulto'),
    'contactos',jsonb_build_array(jsonb_build_object('nombres','Contacto','apellidos','Prueba',
      'parentesco','Hermana','telefono','8095550100','es_principal',true))
  ))->>'envejeciente_id')::uuid;
  perform cuidared_api.api_push_registrar_suscripcion(v_endpoint,'BA' || repeat('A',85),repeat('A',22));
  insert into cuidared.envejeciente_riesgo (envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto,r.riesgo_id,n.nivel_riesgo_id,'Prueba Web Push',v_usuario
    from cuidared.riesgo r cross join cuidared.nivel_riesgo n
    where r.codigo='riesgo_caida' and n.codigo='alto';

  select * into strict v_entrega from cuidared_api.api_push_reservar_entregas(1);
  if v_entrega.cuenta_id<>v_cuenta::text or v_entrega.endpoint<>v_endpoint
     or exists (select from cuidared_api.api_push_reservar_entregas(1)) then
    raise exception 'La alerta no generó una reserva única para el dispositivo esperado';
  end if;
  perform cuidared_api.api_push_finalizar_entrega(v_entrega.entrega_id,v_entrega.reserva_id,'enviada');
  if not exists (select from cuidared.push_entrega where entrega_id=v_entrega.entrega_id and estado='enviada') then
    raise exception 'No quedó registrada la finalización';
  end if;
  perform cuidared_api.api_sesion('cerrar');
  if exists(select from cuidared.push_suscripcion where usuario_id=v_usuario) then
    raise exception 'El cierre manual no retiró el dispositivo';
  end if;
end;
$$;

select 'web_push_verificado' as resultado;
rollback;
