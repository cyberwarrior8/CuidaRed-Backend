-- Pruebas transaccionales del backoffice con datos sintéticos. Ejecutar en una base local desechable.
begin;
do $$
declare
  administrador uuid:='a5027ba5-9a17-47fa-8872-1221f994a6be';
  soporte uuid:='b388bec3-178a-4458-822e-f0e77260a408';
  auditor uuid:='cf481a95-4114-45dd-898c-b4aa15cee168';
  titular uuid:='d8708677-f7b7-46da-ad96-1e8537c74088';
  admin_sesion uuid:='73b4218e-be00-4325-a873-cd7e43df0edd';
  soporte_sesion uuid:='e227fa64-67a0-4957-a542-8d115da17556';
  auditor_sesion uuid:='ce278f2e-9115-4031-90ac-96d265139485';
  titular_sesion uuid:='612ed6a2-fef4-47aa-b2a8-7dd8c6abd4ec';
  v_cuenta bigint; expirada bigint; organizacion bigint; prueba_fin timestamptz; log_id bigint; detalle jsonb;
  categoria smallint; pago_metodo smallint; plan_pago smallint; v_count int; historial jsonb; marca jsonb;
  codigo_cedula text:='00123456781';
begin
  if has_function_privilege('authenticated','cuidared_api.api_bo_leer(uuid,uuid,text,text,jsonb)','EXECUTE')
    or has_table_privilege('anon','cuidared.log_sistema','SELECT')
    or not has_schema_privilege('service_role','cuidared_api','USAGE') then raise exception 'ACL incorrecta'; end if;
  insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
    (administrador,'admin@backoffice.test',now(),jsonb_build_object('cedula','00123456782','nombres','Ana','apellidos','Prueba')),
    (soporte,'soporte@backoffice.test',now(),jsonb_build_object('cedula','00123456783','nombres','Silvia','apellidos','Prueba')),
    (auditor,'auditor@backoffice.test',now(),jsonb_build_object('cedula','00123456784','nombres','Adriana','apellidos','Prueba')),
    (titular,'titular@backoffice.test',now(),jsonb_build_object('cedula',codigo_cedula,'nombres','Teresa','apellidos','Prueba'));
  insert into auth.sessions(id,user_id) values (admin_sesion,administrador),(soporte_sesion,soporte),(auditor_sesion,auditor),(titular_sesion,titular);
  insert into cuidared.usuario_backoffice(usuario_id,rol) values(administrador,'super_admin'),(soporte,'soporte'),(auditor,'auditor');
  if cuidared_api.api_bo_sesion(administrador,admin_sesion,'aal2','validar',null,null)->>'estado'<>'denegado'
    then raise exception 'Sesión sin pasar por el ingreso administrativo'; end if;
  if cuidared_api.api_bo_admitir(titular,titular_sesion,'127.0.0.1','prueba')
    then raise exception 'PWA ingresó al backoffice'; end if;
  perform cuidared_api.api_bo_admitir(administrador,admin_sesion,'127.0.0.1','prueba');
  perform cuidared_api.api_bo_admitir(soporte,soporte_sesion,'127.0.0.1','prueba');
  perform cuidared_api.api_bo_admitir(auditor,auditor_sesion,'127.0.0.1','prueba');
  if cuidared_api.api_bo_sesion(administrador,admin_sesion,'aal1','validar',null,null)->>'estado'<>'mfa'
    then raise exception 'MFA no exigido'; end if;
  if cuidared_api.api_bo_sesion(administrador,admin_sesion,'aal2','ingreso',null,null)->>'estado'<>'ok'
    then raise exception 'Sesión AAL2 inválida'; end if;
  insert into cuidared.provincia(provincia_cod,nombre) values('01','Distrito Nacional') on conflict do nothing;
  insert into cuidared.municipio(municipio_cod,nombre,provincia_cod) values('0101','Distrito Nacional','01') on conflict do nothing;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',titular,'session_id',titular_sesion)::text,true);
  select min(c.categoria_cuenta_id) into categoria from cuidared.categoria_cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id) where t.codigo='familia';
  select (cuidared_api.api_registrar_cuenta(jsonb_build_object('tipo','familia','nombre','Familia de prueba',
    'categoria_cuenta_id',categoria,'municipio_cod','0101','correo','familia@backoffice.test'))->>'cuenta_id')::bigint into v_cuenta;
  perform set_config('request.jwt.claims','{}',true);
  select fecha_fin_prueba into prueba_fin from cuidared.cuenta where cuenta_id=v_cuenta and fecha_fin_prueba-fecha_inicio_prueba=interval '14 days';
  if prueba_fin is null then raise exception 'Alta no respeta duración configurable'; end if;
  detalle:=cuidared_api.api_bo_leer(soporte,soporte_sesion,'aal1','detalle',jsonb_build_object('cuenta',v_cuenta));
  if detalle->>'cuenta_id'<>v_cuenta::text or detalle->>'envejecientes_count'<>'0' or detalle::text like '%'||codigo_cedula||'%'
    then raise exception 'Ficha inválida o expone cédula'; end if;
  if (cuidared_api.api_bo_leer(soporte,soporte_sesion,'aal1','cuentas','{"search":"familia@backoffice.test"}')->'meta'->>'total')::int<>1
    then raise exception 'Búsqueda de cuentas'; end if;
  perform cuidared_api.api_bo_mutar(soporte,soporte_sesion,'aal1','prueba.extender',jsonb_build_object('cuenta',v_cuenta,'dias',7),'Caso de prueba',null,null);
  if not exists(select 1 from cuidared.extension_prueba where cuenta_id=v_cuenta and fin_anterior=prueba_fin and fin_nuevo=prueba_fin+interval '7 days')
    then raise exception 'Extensión no persistida'; end if;
  begin
    perform cuidared_api.api_bo_mutar(auditor,auditor_sesion,'aal1','cuenta.estado',jsonb_build_object('cuenta',v_cuenta,'estado','deshabilitada'),'Caso de prueba',null,null);
    raise exception 'Auditor modificó una cuenta';
  exception when insufficient_privilege then null;
  end;
  perform cuidared_api.api_bo_mutar(soporte,soporte_sesion,'aal1','cuenta.estado',jsonb_build_object('cuenta',v_cuenta,'estado','deshabilitada'),'Caso de prueba',null,null);
  if not exists(select 1 from cuidared.sesion_acceso where sesion_id=titular_sesion and revocada_en is not null)
    or cuidared_interno.acceso_operativo(v_cuenta) then raise exception 'Deshabilitación sin revocación'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',titular,'session_id',titular_sesion)::text,true);
  if cuidared_api.api_sesion('validar')->>'motivo'<>'cuenta_deshabilitada' then
    raise exception 'La interfaz PWA no recibe la causa de bloqueo';
  end if;
  perform set_config('request.jwt.claims','{}',true);
  historial:=cuidared_api.api_bo_leer(soporte,soporte_sesion,'aal1','auditoria',jsonb_build_object('cuenta',v_cuenta));
  if not exists(select 1 from jsonb_array_elements(historial->'data') r where r->>'accion'='cuenta.estado'
    and r->'valor_anterior'->>'estado'='activa' and r->'valor_nuevo'->>'estado'='deshabilitada') then raise exception 'Falta auditoría atómica'; end if;
  begin
    update cuidared.auditoria_backoffice set motivo='cambiado';
    raise exception 'La auditoría se pudo alterar';
  exception when insufficient_privilege then null;
  end;
  perform cuidared_api.api_bo_mutar(soporte,soporte_sesion,'aal1','cuenta.estado',jsonb_build_object('cuenta',v_cuenta,'estado','activa'),'Caso de prueba',null,null);
  perform cuidared_api.api_bo_mutar(soporte,soporte_sesion,'aal1','usuario.estado',jsonb_build_object('cuenta',v_cuenta,'usuario',titular,'estado','deshabilitado'),'Caso de prueba',null,null);
  perform cuidared_api.api_bo_mutar(soporte,soporte_sesion,'aal1','usuario.estado',jsonb_build_object('cuenta',v_cuenta,'usuario',titular,'estado','activo'),'Caso de prueba',null,null);
  insert into cuidared.cuenta(nombre,tipo_cuenta_id,categoria_cuenta_id,municipio_cod,suscripcion_estado,prueba_gratuita,fecha_inicio_prueba,fecha_fin_prueba,usuario_titular_id)
  select 'Prueba expirada',c.tipo_cuenta_id,c.categoria_cuenta_id,'0101','prueba',true,now()-interval '20 days',now()-interval '6 days',titular
  from cuidared.cuenta c where cuenta_id=v_cuenta returning cuenta_id into expirada;
  perform cuidared_interno.bo_mantenimiento();
  if not exists(select 1 from cuidared.cuenta c join cuidared.plan p using(plan_id) where c.cuenta_id=expirada and p.bo_gratuito)
    or not cuidared_interno.acceso_operativo(expirada) then raise exception 'No hubo degradación operativa'; end if;
  insert into cuidared.cuenta(nombre,tipo_cuenta_id,categoria_cuenta_id,municipio_cod,suscripcion_estado,prueba_gratuita,fecha_inicio_prueba,fecha_fin_prueba,usuario_titular_id)
  select 'Organización un solo gestor',t.tipo_cuenta_id,c.categoria_cuenta_id,'0101','prueba',true,now(),now()+interval '1 day',titular
  from cuidared.tipo_cuenta t join cuidared.categoria_cuenta c using(tipo_cuenta_id) where t.codigo='organizacion' limit 1 returning cuenta_id into organizacion;
  insert into cuidared.membresia(usuario_id,cuenta_id,rol_id,estado,fecha_inicio) select titular,organizacion,rol_id,'activa',cuidared_interno.hoy()
  from cuidared.rol where codigo='administrador';
  begin
    perform cuidared_api.api_bo_mutar(soporte,soporte_sesion,'aal1','usuario.estado',jsonb_build_object('cuenta',v_cuenta,'usuario',titular,'estado','deshabilitado'),'Caso de prueba',null,null);
    raise exception 'Último gestor sin protección';
  exception when raise_exception then
    if sqlerrm<>'CR_BO_ULTIMO_GESTOR' then raise; end if;
  end;
  insert into cuidared.plan(nombre,plan_categoria_id,tipo_cuenta_id,precio,periodicidad,duracion_dias,estado,limite_envejecientes)
  select 'Plan pagado de prueba',plan_categoria_id,tipo_cuenta_id,650,'mensual',30,'activo',5 from cuidared.plan where bo_gratuito and tipo_cuenta_id=
    (select tipo_cuenta_id from cuidared.cuenta where cuenta_id=v_cuenta) returning plan_id into plan_pago;
  perform cuidared_api.api_bo_mutar(administrador,admin_sesion,'aal2','cuenta.cambiar_plan',jsonb_build_object('cuenta',v_cuenta,'planId',plan_pago),'Caso de prueba',null,null);
  insert into cuidared.metodo_pago(nombre) values('Método de prueba') returning metodo_pago_id into pago_metodo;
  perform cuidared_api.api_bo_mutar(administrador,admin_sesion,'aal2','pago.registrar',jsonb_build_object('cuenta',v_cuenta,'monto',650,'metodoId',pago_metodo,'fecha',cuidared_interno.hoy()),'Caso de prueba',null,null);
  if (cuidared_api.api_bo_leer(auditor,auditor_sesion,'aal1','pagos',jsonb_build_object('cuenta',v_cuenta))->'meta'->>'total')::int<>1
    then raise exception 'Pago no registrado'; end if;
  perform cuidared_api.api_bo_mutar(administrador,admin_sesion,'aal2','plan.limites',jsonb_build_object('id',plan_pago,'adultos',2,'usuarios',null),'Caso de prueba',null,null);
  if (cuidared_interno.limites(v_cuenta)->>'envejecientes')::int<>2 then raise exception 'La PWA no recibe los límites'; end if;
  perform cuidared_api.api_bo_mutar(administrador,admin_sesion,'aal2','configuracion.actualizar','{"id":"dias_sin_visita_alerta","valor":17}','Caso de prueba',null,null);
  if not exists(select 1 from cuidared.parametro where nombre='dias_sin_visita_alerta' and valor='17') then raise exception 'Umbral desconectado'; end if;
  insert into cuidared.prioridad(codigo,nombre,orden) values('media','Media',2) on conflict do nothing;
  insert into cuidared.envejeciente(cuenta_id,usuario_registrador_id,nombres,apellidos,cedula,
    fecha_nacimiento,sexo,municipio_cod,direccion,fecha_creacion,consentimiento_otorgado,
    consentimiento_otorgado_por,consentimiento_fecha,consentimiento_registrado_por)
  values(expirada,titular,'Persona','Sintética','00123456789','1950-01-01','F','0101','Dirección sintética',
    now()-interval '20 days',true,'adulto',now(),titular);
  if cuidared_interno.bo_alertas_seguimiento()<>1 or cuidared_interno.bo_alertas_seguimiento()<>0 then
    raise exception 'El umbral familiar no genera una alerta idempotente';
  end if;
  perform cuidared_api.api_bo_log('{"nivel":"error","origen":"api","mensaje":"Error de prueba","stack_sanitizado":"src/app.js:1:1"}');
  select id into log_id from cuidared.log_sistema where nivel='error' order by id desc limit 1;
  if cuidared_api.api_bo_leer(auditor,auditor_sesion,'aal1','log',jsonb_build_object('id',log_id))?'stack_sanitizado'
    or not (cuidared_api.api_bo_leer(administrador,admin_sesion,'aal2','log',jsonb_build_object('id',log_id))?'stack_sanitizado')
    then raise exception 'La traza no está aislada por rol'; end if;
  for i in 1..6 loop
    perform cuidared_api.api_bo_mutar(administrador,admin_sesion,'aal2','logo.restaurar','{"variante":"isotipo"}','Caso de prueba',null,null);
  end loop;
  select count(*) into v_count from cuidared.marca_logo where variante='isotipo';
  marca:=cuidared_api.api_publico_bo_marca();
  if v_count<>5 or (marca->'isotipo'->>'version')::int<>6 then raise exception 'El historial no conserva cinco versiones'; end if;
  if (cuidared_api.api_bo_leer(administrador,admin_sesion,'aal2','resumen','{}')->>'cuentas_totales')::int<3
    then raise exception 'Métricas inexistentes'; end if;
end $$;
rollback;
