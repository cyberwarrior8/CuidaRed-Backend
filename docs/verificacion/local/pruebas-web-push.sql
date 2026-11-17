-- RF-18. Registro y aislamiento de dispositivos. Solo para base local desechable.
begin;

do $$
declare
  v_titular uuid := pruebas.usuario('push-titular@example.test','00100007631');
  v_ajeno uuid := pruebas.usuario('push-otro@example.test','00100007632');
  v_endpoint text := 'https://fcm.googleapis.com/fcm/send/registro-sintetico';
  v_p256dh text := 'BA' || repeat('A',85);
  v_auth text := repeat('A',22);
begin
  perform pruebas.afirmar(not has_table_privilege('authenticated','cuidared.push_suscripcion','SELECT')
    and not has_function_privilege('anon','cuidared_api.api_push_estado_suscripcion(text)','EXECUTE'),
    'sin lectura directa ni RPC anónima');
  perform pruebas.error(format('select cuidared_api.api_push_estado_suscripcion(%L)',v_endpoint),'28000');

  perform pruebas.como(v_titular);
  perform cuidared_api.api_push_registrar_suscripcion(v_endpoint,v_p256dh,v_auth);
  perform cuidared_api.api_push_registrar_suscripcion(v_endpoint,v_p256dh,v_auth);
  perform pruebas.afirmar((select count(*) = 1 from cuidared.push_suscripcion where endpoint=v_endpoint),
    'el reintento de registro conserva una sola suscripción');
  perform pruebas.afirmar(cuidared_api.api_push_estado_suscripcion(v_endpoint) = '{"activa":true}',
    'el titular consulta solo su estado');
  perform pruebas.error(format('select cuidared_api.api_push_registrar_suscripcion(%L,%L,%L)',
    'https://fcm.googleapis.com.ejemplo.test/fcm/send/prueba',v_p256dh,v_auth),'22023');
  perform pruebas.error(format('select cuidared_api.api_push_registrar_suscripcion(%L,%L,%L)',
    v_endpoint,v_p256dh,repeat('A',21) || 'B'),'22023');

  perform pruebas.como(v_ajeno);
  perform pruebas.afirmar(cuidared_api.api_push_estado_suscripcion(v_endpoint) = '{"activa":false}',
    'el endpoint ajeno queda oculto');
  perform pruebas.error(format('select cuidared_api.api_push_registrar_suscripcion(%L,%L,%L)',
    v_endpoint,v_p256dh,v_auth),'23505');
  perform cuidared_api.api_push_revocar_suscripcion(v_endpoint);
  perform pruebas.afirmar((select usuario_id=v_titular from cuidared.push_suscripcion where endpoint=v_endpoint),
    'otra identidad no puede reemplazar ni revocar la suscripción');

  perform pruebas.como(v_titular);
  perform cuidared_api.api_push_revocar_suscripcion(v_endpoint);
  perform cuidared_api.api_push_revocar_suscripcion(v_endpoint);
  perform pruebas.afirmar(cuidared_api.api_push_estado_suscripcion(v_endpoint) = '{"activa":false}',
    'la revocación elimina la suscripción y admite reintentos');
end;
$$;

rollback;
