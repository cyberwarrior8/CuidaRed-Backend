-- Verificación local de la propuesta de solicitudes públicas. Requiere el esquema y pruebas-00-ayudas.sql.
begin;

do $$
declare
  adm uuid := pruebas.usuario('admin@visitas.test', '04300000001');
  coord uuid := pruebas.usuario('coord@visitas.test', '04300000002');
  cuenta bigint := pruebas.cuenta('organizacion', adm);
  adulto uuid := pruebas.envejeciente(cuenta, 'Teresa', 'Prueba');
  hoy date := cuidared_interno.hoy();
  huella text := repeat('b', 64);
  solicitud uuid;
  v_visita uuid;
  resultado jsonb;
  comentario text := 'Conversamos y acordamos una próxima visita.';
  firma text;
begin
  foreach firma in array array['api_publico_listar_organizaciones()', 'api_publico_crear_solicitud(jsonb)',
      'api_publico_consultar_solicitud(text)', 'api_publico_registrar_observacion_posterior(text,text)'] loop
    perform pruebas.afirmar(has_function_privilege('service_role', 'cuidared_api.' || firma, 'execute')
      and not has_function_privilege('anon', 'cuidared_api.' || firma, 'execute')
      and not has_function_privilege('authenticated', 'cuidared_api.' || firma, 'execute'),
      'Solo Express puede invocar ' || firma);
  end loop;
  perform pruebas.afirmar(not has_function_privilege('service_role',
    'cuidared_api.api_publico_registrar_observacion(text,text)', 'execute'), 'RPC anterior deshabilitada');

  perform pruebas.miembro(cuenta, coord, 'coordinador');
  perform cuidared_api.api_publico_crear_solicitud(jsonb_build_object(
    'cuenta_id', cuenta, 'nombres', 'Ana', 'apellidos', 'Prueba', 'cedula', '00123456780',
    'telefono', '8095550100', 'correo', 'ana@visitas.test', 'persona_a_visitar', 'Teresa Prueba', 'fecha_propuesta', hoy + 1,
    'hora_propuesta', '10:30', 'hora_fin_propuesta', '11:00', 'motivo', 'Visita de compañía', 'codigo_hash', huella
  ));
  select solicitud_visita_id into solicitud from cuidared.solicitud_visita where codigo_hash = huella;
  perform pruebas.como(coord);
  resultado := cuidared_api.api_autorizar_solicitud_visita(cuenta, solicitud,
    jsonb_build_object('envejeciente_id', adulto, 'fecha', hoy + 1, 'hora', '10:30'));
  v_visita := (resultado->>'visita_id')::uuid;
  perform set_config('request.jwt.claims', '{}', true);
  resultado := cuidared_api.api_publico_consultar_solicitud(huella);
  perform pruebas.afirmar(resultado->>'estado' = 'autorizada' and not (resultado->>'puede_registrar_observacion')::boolean,
    'No aceptar observaciones tras la mera autorización');
  begin
    perform cuidared_api.api_publico_registrar_observacion_posterior(huella, comentario);
    raise exception 'Se aceptó una observación antes de tiempo';
  exception when raise_exception then
    if sqlerrm <> 'CR_SOLICITUD_NO_DISPONIBLE' then raise; end if;
  end;

  update cuidared.detalle_visita set observacion = 'Informe interno de coordinación.' where visita_id = v_visita;
  update cuidared.visita set estado = 'completada', fecha = hoy - 1, hora_inicio = '10:30', hora_fin = '11:00'
    where visita_id = v_visita;
  resultado := cuidared_api.api_publico_consultar_solicitud(huella);
  perform pruebas.afirmar(resultado->>'estado' = 'realizada' and (resultado->>'puede_registrar_observacion')::boolean,
    'Completar habilita la observación');
  resultado := cuidared_api.api_publico_registrar_observacion_posterior(huella, comentario);
  perform pruebas.afirmar(resultado->>'observacion' = comentario and not (resultado->>'puede_registrar_observacion')::boolean,
    'Solo una observación por visita');
  perform pruebas.afirmar(cuidared_api.api_publico_registrar_observacion_posterior(huella, comentario) = resultado,
    'Reintento idéntico conserva el resultado');
  perform pruebas.afirmar((select observacion from cuidared.detalle_visita where visita_id = v_visita)
    = 'Informe interno de coordinación.', 'La observación pública no sustituye el informe interno');
  perform pruebas.afirmar(not (resultado ?| array['visita_id','persona_a_visitar','envejeciente_id','visitante','cedula']),
    'La consulta pública preserva la privacidad');
end $$;

rollback;
