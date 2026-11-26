-- Flujo completo con datos sintéticos. Sin envíos ni archivos reales. Todo se revierte.
-- © 2026 Equipo CuidaRed – INTEC. Requiere visitas_confirmacion_observaciones_evidencias.
begin;
do $$
declare
 admin uuid:=gen_random_uuid(); coord uuid:=gen_random_uuid(); care uuid:=gen_random_uuid(); familia uuid:=gen_random_uuid();
 sa uuid:=gen_random_uuid(); sc uuid:=gen_random_uuid(); sf uuid:=gen_random_uuid(); sk uuid:=gen_random_uuid();
 cuenta bigint; familiar bigint; categoria smallint; municipio text; adulto uuid:=gen_random_uuid(); otro uuid:=gen_random_uuid();
 hash text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 hg text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 hp text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 v uuid; vg uuid; no_realizada uuid; s uuid; sg uuid; rechazo uuid; foto uuid:=gen_random_uuid(); preparada jsonb; datos jsonb; r jsonb;
begin
 insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
  (admin,'admin-'||admin||'@example.invalid',now(),jsonb_build_object('cedula','99023001001','nombres','Gestor','apellidos','Sintético')),
  (coord,'coord-'||coord||'@example.invalid',now(),jsonb_build_object('cedula','99023001002','nombres','Coordinador','apellidos','Sintético')),
  (care,'care-'||care||'@example.invalid',now(),jsonb_build_object('cedula','99023001003','nombres','Cuidador','apellidos','Sintético')),
  (familia,'familia-'||familia||'@example.invalid',now(),jsonb_build_object('cedula','99023001004','nombres','Familia','apellidos','Sintética'));
 update cuidared.usuario set estado='activo' where usuario_id in (admin,coord,care,familia);
 insert into auth.sessions(id,user_id,created_at,updated_at) values(sa,admin,now(),now()),(sc,coord,now(),now()),(sk,care,now(),now()),(sf,familia,now(),now());
 select municipio_cod into municipio from cuidared.municipio order by municipio_cod limit 1;
 select min(c.categoria_cuenta_id) into categoria from cuidared.categoria_cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id) where t.codigo='organizacion';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'session_id',sa,'role','authenticated')::text,true);
 cuenta:=(cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','organizacion','nombre','Prueba sintética de visitas','categoria_cuenta_id',categoria,'municipio_cod',municipio))->>'cuenta_id')::bigint;
 insert into cuidared.membresia(usuario_id,cuenta_id,rol_id,estado,fecha_inicio) select coord,cuenta,rol_id,'activa',cuidared_interno.hoy() from cuidared.rol where codigo='coordinador';
 insert into cuidared.membresia(usuario_id,cuenta_id,rol_id,estado,fecha_inicio) select care,cuenta,rol_id,'activa',cuidared_interno.hoy() from cuidared.rol where codigo='cuidador';
 insert into cuidared.cuidador(usuario_id,tipo_cuidado_id,cuidador_independiente) select care,min(tipo_cuidado_id),true from cuidared.tipo_cuidado;
 insert into cuidared.envejeciente(envejeciente_id,cuenta_id,usuario_registrador_id,nombres,apellidos,cedula,fecha_nacimiento,sexo,municipio_cod,direccion,estado,consentimiento_otorgado,consentimiento_otorgado_por,consentimiento_fecha,consentimiento_registrado_por)
 values(adulto,cuenta,admin,'Persona','Sintética','99023001991','1945-05-05','F',municipio,'Dirección de prueba','activo',true,'adulto',now(),admin);

 -- Programación administrativa: visitante externo sin una identidad Auth ficticia.
 r:=cuidared_api.api_programar_visita(cuenta,jsonb_build_object('fecha',cuidared_interno.hoy()+2,'hora_programada','10:00','hora_fin_programada','11:00','razon','Acompañamiento sintético',
  'envejeciente_ids',jsonb_build_array(adulto),'participante_ids',jsonb_build_array(care),
  'visitante_externo',jsonb_build_object('tipo','personal','nombre','Visitante Sintético','correo','visitante@example.invalid','cantidad',1),'codigo_hash',hash,'referencia_codigo',gen_random_uuid()));
 v:=(r->>'visita_id')::uuid;
 select solicitud_visita_id into s from cuidared.solicitud_visita where codigo_hash=hash;
 if s is null or r->>'estado'<>'programada' or r->>'pendiente_autorizacion'<>'false' then raise exception 'Programación administrativa incompleta'; end if;
 if (select visitante_cedula is not null from cuidared.solicitud_visita where solicitud_visita_id=s) then raise exception 'Se inventó una cédula para el visitante'; end if;
 if cuidared_interno.solicitud_json(s)->>'hora_fin_propuesta'<>'11:00' then raise exception 'Se perdió la hora de fin'; end if;
 if cuidared_api.api_publico_consultar_solicitud(hash)->>'puede_registrar_observacion'<>'false' then raise exception 'Aportes habilitados antes de la cita'; end if;
 begin perform cuidared_api.api_publico_registrar_observacion_posterior(hash,'Observación demasiado temprana.');raise exception 'Se aceptó una observación temprana';
 exception when sqlstate 'P0001' then if sqlerrm<>'CR_SOLICITUD_NO_DISPONIBLE' then raise;end if;end;
 begin perform cuidared_api.api_confirmar_realizacion_visita(cuenta,v,'{"realizada":true,"nota":"Realizada según revisión"}');raise exception 'Se confirmó antes del horario';
 exception when sqlstate 'P0001' then if sqlerrm<>'CR_VISITA_CONFIRMACION_ANTICIPADA' then raise;end if;end;
 if not exists(select from cuidared.aviso_visita where solicitud_id=s and evento='autorizada') or not exists(select from cuidared.aviso_visita where solicitud_id=s and evento='observaciones') then raise exception 'Faltan avisos al visitante';end if;

 r:=cuidared_api.api_programar_visita(cuenta,jsonb_build_object('fecha',cuidared_interno.hoy()+4,'hora_programada','15:00','hora_fin_programada','16:00','razon','Visita no realizada sintética',
  'envejeciente_ids',jsonb_build_array(adulto),'participante_ids',jsonb_build_array(admin)));
 no_realizada:=(r->>'visita_id')::uuid;
 update cuidared.visita set fecha=cuidared_interno.hoy()-2 where visita_id=no_realizada;
 r:=cuidared_api.api_confirmar_realizacion_visita(cuenta,no_realizada,'{"realizada":false,"nota":"El visitante no pudo asistir."}');
 if r->>'estado'<>'cancelada' or (select fecha_realizacion is not null from cuidared.visita where visita_id=no_realizada) then raise exception 'Una visita no realizada contó como efectiva';end if;
 perform cuidared_api.api_confirmar_realizacion_visita(cuenta,no_realizada,'{"realizada":false,"nota":"El visitante no pudo asistir."}');

 -- Solicitud pública: correo y fin obligatorios; reintentos consistentes; rechazo conservado.
 datos:=jsonb_build_object('cuenta_id',cuenta,'nombres','Contacto','apellidos','Sintético','cedula','99023001990','telefono','8095550100','correo','grupo@example.invalid',
   'tipo_visita','institucional','entidad_visitante','Fundación Sintética','tipo_entidad','fundacion','cantidad_visitantes',8,
   'fecha_propuesta',cuidared_interno.hoy()+3,'hora_propuesta','13:00','hora_fin_propuesta','14:30','motivo','Actividad de acompañamiento','codigo_hash',hg,'referencia_codigo',gen_random_uuid());
 begin perform cuidared_api.api_publico_crear_solicitud(datos-'correo');raise exception 'Se aceptó sin correo';exception when invalid_parameter_value then null;end;
 begin perform cuidared_api.api_publico_crear_solicitud(datos-'hora_fin_propuesta');raise exception 'Se aceptó sin fin';exception when invalid_parameter_value then null;end;
 perform cuidared_api.api_publico_crear_solicitud(datos);perform cuidared_api.api_publico_crear_solicitud(datos);
 if (select count(*) from cuidared.solicitud_visita where codigo_hash=hg)<>1 then raise exception 'Se duplicó una solicitud';end if;
 select solicitud_visita_id into sg from cuidared.solicitud_visita where codigo_hash=hg;
 r:=cuidared_api.api_autorizar_solicitud_visita(cuenta,sg,jsonb_build_object('fecha',cuidared_interno.hoy()+3,'hora','13:00','hora_fin_programada','14:30','participante_id',admin));
 vg:=(r->>'visita_id')::uuid;
 if not cuidared_interno.es_visita_institucional(vg) or jsonb_array_length(r->'adultos')<>0 then raise exception 'La actividad institucional exige un expediente ficticio';end if;
 perform cuidared_api.api_publico_crear_solicitud(datos||jsonb_build_object('codigo_hash',hp,'referencia_codigo',gen_random_uuid(),'hora_propuesta','15:00','hora_fin_propuesta','16:00'));
 select solicitud_visita_id into rechazo from cuidared.solicitud_visita where codigo_hash=hp;
 perform cuidared_api.api_rechazar_solicitud_visita(cuenta,rechazo,'La organización no tiene disponibilidad.');
 if cuidared_api.api_publico_consultar_solicitud(hp)->>'estado'<>'rechazada' or not exists(select from cuidared.aviso_visita where solicitud_id=rechazo and evento='rechazada') then raise exception 'No se conserva el rechazo o su aviso';end if;

 -- Simula que ha pasado el horario, modificando exclusivamente las visitas sintéticas.
 update cuidared.visita set fecha=cuidared_interno.hoy()-1 where visita_id in(v,vg);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',care,'session_id',sk,'role','authenticated')::text,true);
 perform cuidared_api.api_iniciar_visita(cuenta,v);
 perform cuidared_api.api_registrar_visita(cuenta,v,jsonb_build_object('detalles',jsonb_build_array(jsonb_build_object('envejeciente_id',adulto,'estado_general','estable','observacion','Registro de campo sintético.'))));
 if (select estado from cuidared.visita where visita_id=v)<>'en_curso' or (select registro_campo_en from cuidared.visita where visita_id=v) is null then raise exception 'El campo cerró la visita sin confirmación';end if;
 if exists(select from cuidared.visita vv join cuidared.detalle_visita d using(visita_id) where d.envejeciente_id=adulto and vv.estado='completada') then raise exception 'La última visita cambió antes de confirmar';end if;
 perform cuidared_api.api_publico_registrar_observacion_posterior(hash,'Observaciones de la persona visitante, separadas del registro interno.');
 if cuidared_api.api_publico_consultar_solicitud(hash)->>'estado'<>'autorizada' then raise exception 'El visitante confirmó por su cuenta la realización';end if;
 preparada:=cuidared_api.api_publico_preparar_evidencia(hash,foto,'foto.jpg',12,repeat('a',64));
 insert into storage.objects(bucket_id,name,metadata) values('visitas-visitantes',preparada->>'ruta','{"size":12,"mimetype":"image/jpeg"}');
 r:=cuidared_api.api_publico_adjuntar_evidencia(hash,foto);
 if jsonb_array_length(r->'evidencias')<>1 then raise exception 'No se adjuntó la evidencia';end if;
 begin perform cuidared_api.api_publico_evidencia_descarga(hg,foto);raise exception 'Una solicitud pudo leer la foto de otra';exception when no_data_found then null;end;
 if jsonb_array_length(cuidared_api.api_visita_evidencias_visitante(cuenta,v))<>1 then raise exception 'El responsable no recibe la evidencia';end if;
 begin perform cuidared_api.api_confirmar_realizacion_visita(cuenta,v,'{"realizada":true,"nota":"Revisión no autorizada"}');raise exception 'Cuidador confirmó la realización';exception when insufficient_privilege then null;end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'session_id',sa,'role','authenticated')::text,true);
 r:=cuidared_api.api_confirmar_realizacion_visita(cuenta,v,'{"realizada":true,"nota":"La organización comprobó la realización."}');
 if r->>'estado'<>'completada' or cuidared_api.api_publico_consultar_solicitud(hash)->>'estado'<>'realizada' then raise exception 'La confirmación no actualizó el seguimiento público';end if;
 if (select (fecha_realizacion at time zone 'America/Santo_Domingo')::date from cuidared.visita where visita_id=v)<>cuidared_interno.hoy()-1 then raise exception 'Se usó la fecha de revisión en vez de la fecha efectiva';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',coord,'session_id',sc,'role','authenticated')::text,true);
 perform cuidared_api.api_confirmar_realizacion_visita(cuenta,vg,jsonb_build_object('realizada',true,'nota','Participantes comprobados por coordinación.','envejeciente_ids',jsonb_build_array(adulto)));
 if not exists(select from cuidared.detalle_visita where visita_id=vg and envejeciente_id=adulto) then raise exception 'No se identificaron los participantes institucionales';end if;
 if not exists(select from cuidared.aviso_visita where solicitud_id=s and evento='realizada') then raise exception 'Falta el aviso de confirmación';end if;

 -- Cuenta Familia: ningún acceso de visitas, ni siquiera mediante la RPC nueva.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',familia,'session_id',sf,'role','authenticated')::text,true);
 select min(c.categoria_cuenta_id) into categoria from cuidared.categoria_cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id) where t.codigo='familia';
 familiar:=(cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','familia','nombre','Familia sintética','categoria_cuenta_id',categoria,'municipio_cod',municipio))->>'cuenta_id')::bigint;
 begin perform cuidared_api.api_confirmar_realizacion_visita(familiar,v,'{"realizada":true,"nota":"No debe permitirse"}');raise exception 'Familia accedió a confirmar';exception when insufficient_privilege then null;end;
 if has_table_privilege('anon','cuidared.evidencia_solicitud_visita','select') or has_function_privilege('authenticated','cuidared_api.api_publico_preparar_evidencia(text,uuid,text,integer,text)','execute') then raise exception 'Se expuso el acceso privilegiado';end if;
end $$;
rollback;
select 'Visitas: programación, horario, correo, rechazo, aportes privados, confirmación, seguimiento y exclusión de Familia: OK. Datos revertidos.' resultado;
