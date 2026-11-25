-- Recepción por ambas partes, idempotencia y revocación. Solo datos sintéticos; ROLLBACK.
begin;
do $$
declare
  admin uuid := pruebas.usuario('admin@avisos.test', '04300800001');
  coord uuid := pruebas.usuario('coord@avisos.test', '04300800002');
  voluntario uuid := pruebas.usuario('voluntario@avisos.test', '04300800003');
  sin_confirmar uuid := pruebas.usuario('sinconfirmar@avisos.test', '04300800004');
  ajeno uuid := pruebas.usuario('ajeno@avisos.test', '04300800005');
  cuenta bigint := pruebas.cuenta('organizacion', admin);
  otra bigint := pruebas.cuenta('organizacion', ajeno);
  huella text := repeat('d',64);
  solicitud uuid;
  datos jsonb;
  lote jsonb;
begin
  perform pruebas.miembro(cuenta, coord, 'coordinador');
  perform pruebas.miembro(cuenta, voluntario, 'voluntario');
  perform pruebas.miembro(cuenta, sin_confirmar, 'coordinador');
  update auth.users set email_confirmed_at = null where id = sin_confirmar;
  datos := jsonb_build_object('cuenta_id', cuenta, 'nombres', 'Ana', 'apellidos', 'Prueba',
    'cedula', '00123456780', 'telefono', '8095550100', 'correo', 'visitante@avisos.test',
    'tipo_visita', 'institucional', 'entidad_visitante', 'Grupo sintético', 'tipo_entidad', 'fundacion',
    'fecha_propuesta', cuidared_interno.hoy() + 2, 'hora_propuesta', '10:00', 'hora_fin_propuesta', '11:00',
    'motivo', 'Actividad comunitaria', 'codigo_hash', huella);
  perform cuidared_api.api_publico_crear_solicitud(datos);
  perform cuidared_api.api_publico_crear_solicitud(datos);
  select solicitud_visita_id into solicitud from cuidared.solicitud_visita where codigo_hash = huella;
  perform pruebas.afirmar((select count(*) from cuidared.aviso_visita where solicitud_id = solicitud and evento = 'recibida') = 1, 'Un acuse por solicitud, incluso al reintentar');
  perform pruebas.afirmar((select count(*) from cuidared.aviso_visita where solicitud_id = solicitud and evento = 'nueva_solicitud') = 2, 'Aviso solo para los gestores confirmados de esa cuenta');
  perform pruebas.afirmar(not exists(select from cuidared.aviso_visita where solicitud_id=solicitud and destinatario_usuario_id in (voluntario,sin_confirmar,ajeno)), 'Sin visitantes internos, cuentas ajenas ni correos no confirmados');
  update cuidared.membresia set estado = 'inactiva' where cuenta_id = cuenta and usuario_id = coord;
  lote := cuidared_api.api_visita_reclamar_avisos();
  perform pruebas.afirmar(not exists(select from jsonb_array_elements(lote) e where e->>'correo' = 'coord@avisos.test'), 'Revocar la membresía antes del envío impide recibir el correo');
  perform pruebas.afirmar(exists(select from jsonb_array_elements(lote) e where e->>'correo' = 'admin@avisos.test' and e->>'destinatario' = 'organizacion'), 'El equipo recibe su aviso');
  perform pruebas.afirmar(exists(select from jsonb_array_elements(lote) e where e->>'correo' = 'visitante@avisos.test' and e->>'destinatario' = 'visitante'), 'El visitante recibe el acuse');
  perform pruebas.afirmar(not has_function_privilege('anon','cuidared_api.api_visita_reclamar_avisos()','execute') and not has_function_privilege('authenticated','cuidared_api.api_visita_reclamar_avisos()','execute'), 'La cola sigue siendo exclusiva del servidor');

  update cuidared.cuenta c set correo = 'buzon@organizacion.test' where c.cuenta_id = cuenta;
  update cuidared.cuenta c set correo = 'otra@organizacion.test' where c.cuenta_id = otra;
  datos := datos || jsonb_build_object('codigo_hash',repeat('e',64),'correo','otra-visita@avisos.test');
  perform cuidared_api.api_publico_crear_solicitud(datos);
  perform cuidared_api.api_publico_crear_solicitud(datos);
  select solicitud_visita_id into solicitud from cuidared.solicitud_visita where codigo_hash=repeat('e',64);
  perform pruebas.afirmar((select count(*) from cuidared.aviso_visita where solicitud_id=solicitud and evento='nueva_solicitud')=1, 'Un aviso al buzón configurado, sin duplicarlo por gestores ni reintentos');
  perform pruebas.afirmar((select destinatario_usuario_id is null from cuidared.aviso_visita where solicitud_id=solicitud and evento='nueva_solicitud'), 'El buzón no necesita un usuario de acceso');
  update cuidared.cuenta c set correo = 'buzon-nuevo@organizacion.test' where c.cuenta_id = cuenta;
  lote := cuidared_api.api_visita_reclamar_avisos();
  perform pruebas.afirmar(exists(select from jsonb_array_elements(lote) e where e->>'correo'='buzon-nuevo@organizacion.test' and e->>'destinatario'='organizacion'), 'El aviso usa el contacto vigente de la organización');
  perform pruebas.afirmar(exists(select from jsonb_array_elements(lote) e where e->>'correo'='otra-visita@avisos.test' and e->>'destinatario'='visitante'), 'El visitante conserva el correo que indicó en el formulario');
  perform pruebas.afirmar(not exists(select from jsonb_array_elements(lote) e where e->>'correo' in ('otra@organizacion.test','buzon@organizacion.test')), 'No se envía al contacto anterior ni al de otra cuenta');
  datos := datos || jsonb_build_object('codigo_hash',repeat('f',64),'correo','tercera-visita@avisos.test');
  perform cuidared_api.api_publico_crear_solicitud(datos);
  update cuidared.cuenta c set correo = null where c.cuenta_id = cuenta;
  lote := cuidared_api.api_visita_reclamar_avisos();
  perform pruebas.afirmar(not exists(select from jsonb_array_elements(lote) e where e->>'destinatario'='organizacion'), 'Retirar el contacto antes del envío omite el aviso');
end $$;
rollback;
