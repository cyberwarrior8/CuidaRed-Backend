-- Soporte y eliminación: datos sintéticos, sin correo ni archivos. Toda la transacción se revierte.
-- © 2026 Equipo CuidaRed – INTEC. Requiere backoffice_soporte_eliminacion_usuarios aplicado.
begin;
do $$
declare
  op uuid:=gen_random_uuid(); gestor uuid:=gen_random_uuid(); objetivo uuid:=gen_random_uuid(); coordinador uuid:=gen_random_uuid();
  sesion_op uuid:=gen_random_uuid(); sesion_gestor uuid:=gen_random_uuid(); sesion_coord uuid:=gen_random_uuid(); sesion_objetivo uuid:=gen_random_uuid();
  cuenta bigint; otra bigint; categoria smallint; municipio text; ticket jsonb; revision jsonb; trabajo jsonb;
  membresia_activa bigint; nuevo uuid:=gen_random_uuid(); correo_objetivo text := 'borrado-'||gen_random_uuid()::text||'@example.invalid';
  version_inicial timestamptz; creado jsonb;
begin
  insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
    (op,'operador-'||op||'@example.invalid',now(),jsonb_build_object('cedula','99123456001','nombres','Operador','apellidos','Soporte Sintetico')),
    (gestor,'gestor-'||gestor||'@example.invalid',now(),jsonb_build_object('cedula','99123456002','nombres','Administrador','apellidos','Soporte Sintetico')),
    (objetivo,correo_objetivo,now(),jsonb_build_object('cedula','99123456003','nombres','Inactivo','apellidos','Soporte Sintetico')),
    (coordinador,'coordinador-'||coordinador||'@example.invalid',now(),jsonb_build_object('cedula','99123456004','nombres','Coordinador','apellidos','Soporte Sintetico'));
  update cuidared.usuario set estado='activo' where usuario_id in (op,gestor,coordinador);
  update cuidared.usuario set estado='suspendido' where usuario_id=objetivo;
  insert into auth.sessions(id,user_id,created_at,updated_at) values
    (sesion_op,op,now(),now()),(sesion_gestor,gestor,now(),now()),(sesion_coord,coordinador,now(),now()),(sesion_objetivo,objetivo,now(),now());
  insert into cuidared.usuario_backoffice(usuario_id,rol) values(op,'super_admin');
  perform cuidared_api.api_bo_admitir(op,sesion_op,'127.0.0.1','prueba-soporte');
  perform cuidared_api.api_bo_sesion(op,sesion_op,'aal2','ingreso',null,null);
  select min(c.categoria_cuenta_id) into categoria from cuidared.categoria_cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id) where t.codigo='organizacion';
  select municipio_cod into municipio from cuidared.municipio order by municipio_cod limit 1;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',gestor,'session_id',sesion_gestor,'role','authenticated')::text,true);
  creado:=cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','organizacion','nombre','Organización sintética soporte','categoria_cuenta_id',categoria,'municipio_cod',municipio));
  cuenta:=(creado->>'cuenta_id')::bigint;
  insert into cuidared.notificacion(usuario_id,cuenta_id,mensaje) values(objetivo,cuenta,'Notificación personal sintética para verificar su limpieza.');
  insert into cuidared.membresia(usuario_id,cuenta_id,rol_id,estado,fecha_inicio,fecha_fin)
    select objetivo,cuenta,rol_id,'inactiva',current_date-1,current_date from cuidared.rol where codigo='cuidador';
  insert into cuidared.membresia(usuario_id,cuenta_id,rol_id,estado,fecha_inicio)
    select coordinador,cuenta,rol_id,'activa',current_date from cuidared.rol where codigo='coordinador';
  if not exists(select from jsonb_array_elements(cuidared_interno.bo_usuarios_cuenta(cuenta)) u
    where u->>'usuario_id'=objetivo::text and u->>'estado_membresia'='inactiva') then raise exception 'No se muestra el inactivo'; end if;
  ticket:=cuidared_api.api_soporte_crear(cuenta,'eliminar_usuario','Eliminar usuario sintético','Solicitud de eliminación para volver a invitar a la persona.',objetivo);
  version_inicial:=(ticket->>'actualizado_en')::timestamptz;
  begin
    perform cuidared_api.api_soporte_crear(cuenta,'eliminar_usuario','Petición duplicada','Otra solicitud para el mismo usuario inactivo.',objetivo);
    raise exception 'Se aceptó un duplicado';
  exception when sqlstate 'P0001' then if sqlerrm<>'CR_SOPORTE_DUPLICADO' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',coordinador,'session_id',sesion_coord,'role','authenticated')::text,true);
  begin
    perform cuidared_api.api_soporte_listar(cuenta);
    raise exception 'Coordinador accedió a soporte';
  exception when insufficient_privilege then null; end;
  creado:=cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','organizacion','nombre','Otra organización sintética','categoria_cuenta_id',categoria,'municipio_cod',municipio));
  otra:=(creado->>'cuenta_id')::bigint;
  begin
    perform cuidared_api.api_soporte_detalle(otra,(ticket->>'id')::bigint);
    raise exception 'Se filtró una solicitud de otra cuenta';
  exception when no_data_found then null; end;
  ticket:=cuidared_api.api_bo_soporte_actualizar(op,sesion_op,'aal2',(ticket->>'id')::bigint,'esperando_informacion','Confirma el motivo de la eliminación solicitada.',version_inicial);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',gestor,'session_id',sesion_gestor,'role','authenticated')::text,true);
  begin
    perform cuidared_api.api_soporte_responder(cuenta,(ticket->>'id')::bigint,'Respuesta con una versión antigua.',version_inicial);
    raise exception 'Se aceptó una versión antigua';
  exception when sqlstate 'P0001' then if sqlerrm<>'CR_SOPORTE_VERSION' then raise; end if; end;
  ticket:=cuidared_api.api_soporte_responder(cuenta,(ticket->>'id')::bigint,'Confirmamos que ya no tiene acceso y necesitamos invitarlo otra vez.',(ticket->>'actualizado_en')::timestamptz);
  if ticket->>'estado'<>'en_revision' or jsonb_array_length(ticket->'mensajes')<>2 then raise exception 'No se conserva la conversación'; end if;
  revision:=cuidared_api.api_bo_eliminacion_leer(op,sesion_op,'aal2',cuenta,objetivo);
  if not (revision->>'permitida')::boolean then raise exception 'El perfil sintético sin historial debería ser elegible: %',revision->'motivos'; end if;
  begin
    delete from auth.users where id=objetivo;
    raise exception 'Se eliminó sin autorización dedicada';
  exception when insufficient_privilege then null; end;
  begin
    perform cuidared_api.api_bo_eliminacion_preparar(op,sesion_op,'aal1',cuenta,objetivo,correo_objetivo,'Prueba sin MFA');
    raise exception 'Se aceptó sin MFA';
  exception when insufficient_privilege then null; end;
  trabajo:=cuidared_api.api_bo_eliminacion_preparar(op,sesion_op,'aal2',cuenta,objetivo,correo_objetivo,'Solicitud comprobada en prueba sintética',(ticket->>'id')::bigint);
  insert into cuidared.membresia(usuario_id,cuenta_id,rol_id,estado,fecha_inicio)
    select objetivo,cuenta,rol_id,'activa',current_date from cuidared.rol where codigo='cuidador' returning membresia_id into membresia_activa;
  begin
    delete from auth.users where id=objetivo;
    raise exception 'Se ignoró una membresía activada después de preparar';
  exception when sqlstate 'P0001' then if sqlerrm<>'CR_BO_ELIMINACION_BLOQUEADA' then raise; end if; end;
  delete from cuidared.membresia where membresia_id=membresia_activa;
  perform set_config('request.jwt.claims','{}',true);
  delete from auth.users where id=objetivo;
  if exists(select from cuidared.usuario where usuario_id=objetivo) or exists(select from cuidared.membresia where usuario_id=objetivo)
    or exists(select from auth.users where id=objetivo)
    or exists(select from auth.sessions where user_id=objetivo)
    or exists(select from cuidared.notificacion where usuario_id=objetivo) then raise exception 'Quedaron registros de acceso o notificaciones'; end if;
  if cuidared_api.api_bo_eliminacion_estado(op,sesion_op,'aal2',(trabajo->>'operacion_id')::uuid)->>'estado'<>'eliminado' then raise exception 'Falta la confirmación del borrado'; end if;
  if cuidared_interno.soporte_json((ticket->>'id')::bigint,true)->>'estado'<>'resuelta' then raise exception 'No se resolvió la solicitud'; end if;
  if cuidared_api.api_bo_eliminacion_preparar(op,sesion_op,'aal2',cuenta,objetivo,correo_objetivo,'Reintento de confirmación')->>'estado'<>'eliminado' then raise exception 'El resultado no es idempotente'; end if;
  insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
    (nuevo,correo_objetivo,now(),jsonb_build_object('cedula','99123456003','nombres','Recreado','apellidos','Soporte Sintetico'));
  if not exists(select from cuidared.usuario where usuario_id=nuevo and correo=correo_objetivo) then raise exception 'No se liberaron correo y cédula'; end if;
  if has_function_privilege('authenticated','cuidared_api.api_bo_eliminacion_preparar(uuid,uuid,text,bigint,uuid,text,text,bigint)','execute')
    or has_table_privilege('authenticated','cuidared.solicitud_soporte','select') then raise exception 'ACL administrativa expuesta'; end if;
end $$;
rollback;
select 'Soporte, aislamiento, MFA, eliminación atómica, idempotencia y reutilización de correo: OK. Datos revertidos.' resultado;
