-- RF-18. Fuentes reales del motor, permisos y reservas. Base local desechable.
begin;

do $$
declare
  v_titular uuid := pruebas.usuario('push-motor@example.test','00100007634');
  v_cuenta bigint := pruebas.cuenta('familia',v_titular);
  v_adulto uuid := pruebas.envejeciente(v_cuenta);
  v_sesion uuid := pruebas.como(v_titular);
  v_endpoint text := 'https://fcm.googleapis.com/fcm/send/motor-sintetico';
  v_primera record;
  v_segunda record;
begin
  perform pruebas.afirmar(not has_function_privilege('authenticated','cuidared_api.api_push_reservar_entregas(integer)','EXECUTE')
    and has_function_privilege('service_role','cuidared_api.api_push_reservar_entregas(integer)','EXECUTE')
    and not has_table_privilege('service_role','cuidared.push_entrega','SELECT'),'cola privada y RPC del emisor');
  perform cuidared_api.api_push_registrar_suscripcion(v_endpoint,'BA' || repeat('A',85),repeat('A',22));
  insert into cuidared.envejeciente_necesidad(envejeciente_id,necesidad_id,prioridad_id,descripcion,registrado_por)
    select v_adulto,n.necesidad_id,p.prioridad_id,'Prueba Web Push',v_titular
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id)
    cross join cuidared.prioridad p where t.codigo='transporte' and p.codigo='alta';
  perform pruebas.afirmar((select count(*)=1 from cuidared.push_entrega),
    'se encola Web Push para el coordinador de Familia al generar la alerta de transporte');

  update auth.sessions set created_at=now()-interval '2 hours' where id=v_sesion;
  perform pruebas.afirmar((cuidared_api.api_sesion('validar')->>'vigente')::boolean=false,'sesión vencida por inactividad');
  select * into strict v_primera from cuidared_api.api_push_reservar_entregas(8);
  perform pruebas.afirmar(v_primera.cuenta_id=v_cuenta::text and v_primera.endpoint=v_endpoint
    and not exists(select from cuidared_api.api_push_reservar_entregas(8)),
    'la inactividad conserva el dispositivo y la reserva evita que se tome dos veces');
  perform cuidared_api.api_push_finalizar_entrega(v_primera.entrega_id,gen_random_uuid(),'enviada');
  perform pruebas.afirmar((select reserva_id=v_primera.reserva_id from cuidared.push_entrega where entrega_id=v_primera.entrega_id),
    'solo la reserva vigente puede finalizar');
  perform cuidared_api.api_push_finalizar_entrega(v_primera.entrega_id,v_primera.reserva_id,'reintentar');
  perform pruebas.afirmar(not exists(select from cuidared_api.api_push_reservar_entregas(8)),
    'el fallo transitorio se difiere');
  update cuidared.push_entrega set disponible_en=now() where entrega_id=v_primera.entrega_id;
  select * into strict v_segunda from cuidared_api.api_push_reservar_entregas(8);
  perform pruebas.afirmar(v_segunda.entrega_id=v_primera.entrega_id and v_segunda.reserva_id<>v_primera.reserva_id,
    'el reintento toma la misma entrega con una nueva reserva');
  perform cuidared_api.api_push_finalizar_entrega(v_segunda.entrega_id,v_segunda.reserva_id,'enviada');

  insert into cuidared.envejeciente_riesgo(envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto,r.riesgo_id,n.nivel_riesgo_id,'Prueba Web Push',v_titular
    from cuidared.riesgo r cross join cuidared.nivel_riesgo n
    where r.codigo='aislamiento_social' and n.codigo='alto';
  update cuidared.envejeciente set estado='inactivo' where envejeciente_id=v_adulto;
  perform pruebas.afirmar(not exists(select from cuidared_api.api_push_reservar_entregas(8)),
    'el alcance se vuelve a revisar antes de que salgan datos hacia el emisor');
  perform pruebas.afirmar(exists(select from cuidared.push_entrega where estado='omitida'),
    'los avisos excluidos quedan omitidos');

  update auth.sessions set created_at=now() where id=v_sesion;
  update cuidared.envejeciente set estado='activo' where envejeciente_id=v_adulto;
  insert into cuidared.envejeciente_riesgo(envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto,r.riesgo_id,n.nivel_riesgo_id,'Prueba Web Push',v_titular
    from cuidared.riesgo r cross join cuidared.nivel_riesgo n
    where r.codigo='riesgo_nutricional' and n.codigo='alto';
  select * into strict v_primera from cuidared_api.api_push_reservar_entregas(8);
  perform cuidared_api.api_push_finalizar_entrega(v_primera.entrega_id,v_primera.reserva_id,'caducada');
  perform pruebas.afirmar(not exists (select from cuidared.push_suscripcion where endpoint=v_endpoint),
    'un endpoint caducado se retira');

  perform cuidared_api.api_push_registrar_suscripcion(v_endpoint,'BA' || repeat('A',85),repeat('A',22));
  perform cuidared_api.api_sesion('cerrar');
  perform pruebas.afirmar(not exists (select from cuidared.push_suscripcion where endpoint=v_endpoint),
    'el cierre manual revoca el dispositivo');
end;
$$;

rollback;
