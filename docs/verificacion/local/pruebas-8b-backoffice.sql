-- Tarifas, cotizaciones y vencimientos · ID08/RF-20. Solo datos sintéticos. © 2026 Equipo CuidaRed – INTEC.
begin;
grant usage on schema pruebas to service_role;
grant execute on function pruebas.error(text,text,text) to service_role;
do $$
declare
  v_titular uuid := pruebas.usuario('p8b-titular@example.test','00881110001');
  v_otra uuid := pruebas.usuario('p8b-otra@example.test','00881110002');
  v_cuidador uuid := pruebas.usuario('p8b-cuidador@example.test','00881110003');
  v_no_titular uuid := pruebas.usuario('p8b-gestor@example.test','00881110004');
  v_admin uuid := pruebas.usuario('p8b-admin@example.test','00881110005');
  v_soporte uuid := pruebas.usuario('p8b-soporte@example.test','00881110006');
  v_sesion uuid := pruebas.como(v_admin);
  v_sesion_soporte uuid := pruebas.como(v_soporte);
  v_cuenta bigint := pruebas.cuenta('organizacion',v_titular,'vencida');
  v_externa bigint := pruebas.cuenta('organizacion',v_otra,'vencida');
  v_cotizacion jsonb;
  v_codigo text := 'gestion_comunitaria_avanzada_mensual';
begin
  perform pruebas.miembro(v_cuenta,v_cuidador,'cuidador');
  perform pruebas.miembro(v_cuenta,v_no_titular,'administrador');
  perform pruebas.envejeciente(v_cuenta);
  perform pruebas.como(v_no_titular);
  perform pruebas.error(format('select cuidared_api.api_stripe_solicitar_cotizacion(%s,%L)', v_cuenta,v_codigo),'42501');
  perform pruebas.como(v_titular);
  set local role authenticated;
  v_cotizacion := cuidared_api.api_stripe_solicitar_cotizacion(v_cuenta,v_codigo);
  perform pruebas.afirmar(v_cotizacion = cuidared_api.api_stripe_solicitar_cotizacion(v_cuenta,v_codigo),
    'reintentar la solicitud no duplica ni altera los volúmenes');
  perform pruebas.afirmar(v_cotizacion->'cotizaciones' @> jsonb_build_array(jsonb_build_object(
    'codigo',v_codigo,'cuidadores',1,'envejecientes',1,'estado','solicitada','importe_centavos',null)),
    'la cotización usa el volumen de la cuenta calculado por el servidor');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_leer(%L,%L,%L,%s)',
    v_admin,v_sesion,'aal2',v_cuenta),'42501');
  reset role;

  insert into cuidared.usuario_backoffice(usuario_id,rol) values(v_admin,'super_admin'),(v_soporte,'soporte');
  perform cuidared_api.api_bo_admitir(v_admin,v_sesion,null,null);
  perform cuidared_api.api_bo_admitir(v_soporte,v_sesion_soporte,null,null);
  perform cuidared_api.api_bo_sesion(v_admin,v_sesion,'aal2','ingreso',null,null);
  perform cuidared_api.api_bo_sesion(v_soporte,v_sesion_soporte,'aal1','ingreso',null,null);
  set local role service_role;
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_leer(%L,%L,%L,%s)',
    v_admin,v_sesion,'aal1',v_cuenta),'42501');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_leer(%L,%L,%L,%s)',
    v_soporte,v_sesion_soporte,'aal1',v_cuenta),'42501');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_preparar_tarifa(%L,%L,%L,%s,%L)',
    v_admin,v_sesion,'aal2',v_externa,v_codigo),'P0002');
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',v_cuenta,v_codigo,
    15000,'price_bo_quote','Cotización de prueba',
    '{"envejecientes":30,"usuarios":40,"cuidadores":20,"familiares":null}');
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',null,'basico_familiar_mensual',
    900,'price_bo_fam','Tarifa de prueba');
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',null,'basico_familiar_mensual',
    950,'price_bo_fam_nueva','Actualiza tarifa de prueba');
  perform pruebas.error(format('select cuidared_api.api_bo_mutar(%L,%L,%L,%L,%L,%L,null,null)',
    v_admin,v_sesion,'aal2','cuenta.cambiar_plan','{}','Prueba de activación directa'),
    'P0001','CR_STRIPE_ACTIVACION_REQUERIDA');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_plan_gratuito(%L,%L,%L,%s,%L)',
    v_admin,v_sesion,'aal2',v_externa,'Asignación gratuita retirada'),'42501');
  reset role;
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(v_externa),
    'una cuenta vencida permanece sin acceso operativo');
  perform pruebas.afirmar(
    not exists (select 1 from cuidared.plan where bo_gratuito and estado = 'activo'),
    'el catálogo no contiene un plan gratuito activo');
  perform pruebas.error(
    format('update cuidared.plan set estado=%L where bo_gratuito','activo'),'23514');
  perform pruebas.error(
    format('update cuidared.cuenta c set plan_id=(select p.plan_id from cuidared.plan p where p.bo_gratuito and p.tipo_cuenta_id=c.tipo_cuenta_id),suscripcion_estado=%L where c.cuenta_id=%s',
      'activa',v_externa),'23514');
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(v_cuenta),
    'aprobar una cotización no equivale a confirmar el pago');
  perform pruebas.afirmar((select not activa from cuidared.stripe_oferta where price_id='price_bo_fam'),
    'actualizar una tarifa conserva el precio anterior para pagos históricos');
  perform pruebas.afirmar((select count(*) = 2 from cuidared.auditoria_backoffice where accion='stripe.tarifa.publicar'),
    'los cambios de tarifa se auditan');

  perform pruebas.como(v_otra);
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_stripe_gestion(v_externa)->'ofertas')=0,
    'ningún precio de otra Organización aparece en gestión');
  perform pruebas.como(v_titular);
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas')=1,
    'la cotización publicada aparece para el titular que puede pagar');
  perform pruebas.afirmar(cuidared_api.api_obtener_suscripcion(v_cuenta)->'planes'='[]'::jsonb,
    'la consulta anterior de suscripción no publica ofertas generales de Organización');
end $$;
rollback;
