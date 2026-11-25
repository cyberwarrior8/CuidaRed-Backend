-- CUIDARED-017 · Tarifas de Base y cupos pactados en Avanzada. Solo datos sintéticos.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('p8f-admin@example.test','00881600001');
  v_uno uuid := pruebas.usuario('p8f-titular@example.test','00881600002');
  v_dos uuid := pruebas.usuario('p8f-otra@example.test','00881600003');
  v_cuidador uuid := pruebas.usuario('p8f-cuidador@example.test','00881600004');
  v_familiar uuid := pruebas.usuario('p8f-familiar@example.test','00881600005');
  v_equipo uuid := pruebas.usuario('p8f-equipo@example.test','00881600006');
  v_sesion uuid := pruebas.como(v_admin);
  v_cuenta bigint := pruebas.cuenta('organizacion',v_uno,'vencida');
  v_otra bigint := pruebas.cuenta('organizacion',v_dos,'vencida');
  v_codigo text := 'gestion_comunitaria_avanzada_mensual';
  v_cupos jsonb := '{"envejecientes":1,"usuarios":3,"cuidadores":1,"familiares":1}';
  v_segunda jsonb := '{"envejecientes":8,"usuarios":null,"cuidadores":4,"familiares":2}';
  v_otro jsonb := '{"envejecientes":30,"usuarios":12,"cuidadores":6,"familiares":10}';
  v_version uuid;
  v_version_nueva uuid;
  v_checkout jsonb;
  v_cambio jsonb;
  v_ahora timestamptz := date_trunc('second',clock_timestamp());
  v_corte timestamptz := v_ahora + interval '1 month';
  v_factura jsonb;
  v_ofertas jsonb;
begin
  insert into cuidared.usuario_backoffice(usuario_id,rol) values (v_admin,'super_admin');
  perform cuidared_api.api_bo_admitir(v_admin,v_sesion,null,null);
  perform cuidared_api.api_bo_sesion(v_admin,v_sesion,'aal2','ingreso',null,null);
  perform pruebas.miembro(v_cuenta,v_cuidador,'cuidador');
  perform pruebas.miembro(v_cuenta,v_familiar,'familiar');
  perform pruebas.envejeciente(v_cuenta);

  perform pruebas.como(v_uno);
  perform pruebas.error(format('select cuidared_api.api_stripe_solicitar_cotizacion(%s,%L)',
    v_cuenta,'operacion_base_mensual'),'22023');
  perform pruebas.afirmar(cuidared_api.api_stripe_solicitar_cotizacion(v_cuenta,v_codigo)->'cotizaciones'
    @> jsonb_build_array(jsonb_build_object('codigo',v_codigo,'estado','solicitada','usuarios',2,
      'cuidadores',1,'envejecientes',1,'familiares',1,'limites',null)), 'la cotización separa uso y términos');
  perform pruebas.como(v_dos);
  perform cuidared_api.api_stripe_solicitar_cotizacion(v_otra,v_codigo);

  perform pruebas.afirmar(cuidared_api.api_bo_stripe_leer(v_admin,v_sesion,'aal2',null)->'tarifas'
    @> '[{"codigo":"operacion_base_mensual","tipo":"organizacion","importe_centavos":null},
      {"codigo":"operacion_base_anual","tipo":"organizacion","importe_centavos":null}]',
    'Backoffice puede publicar las tarifas de Base y la propuesta no inventa precios');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_preparar_tarifa(%L,%L,%L,null,%L)',
    v_admin,v_sesion,'aal2',v_codigo),'P0002');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_preparar_tarifa(%L,%L,%L,%s,%L,%L)',
    v_admin,v_sesion,'aal2',v_cuenta,v_codigo,'{"envejecientes":4,"usuarios":0}'),'22023');
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',null,'operacion_base_mensual',
    2900,'price_p8f_base','Tarifa de prueba Base');
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',v_cuenta,v_codigo,
    9200,'price_p8f_av1','Primera cotización sintética',v_cupos);
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',v_otra,v_codigo,
    19000,'price_p8f_otra','Cotización de otra cuenta',v_otro);
  v_version := (select version_cotizacion from cuidared.stripe_oferta where price_id = 'price_p8f_av1');

  perform pruebas.afirmar(cuidared_api.api_bo_stripe_preparar_tarifa(
    v_admin,v_sesion,'aal2',v_cuenta,v_codigo,v_cupos,9200)->'sin_cambios' = 'true',
    'publicar los mismos términos es un reintento');
  perform pruebas.como(v_dos);
  v_ofertas := cuidared_api.api_stripe_gestion(v_otra)->'ofertas';
  perform pruebas.afirmar(v_ofertas @> jsonb_build_array(jsonb_build_object('codigo',v_codigo,'limites',v_otro))
    and not (v_ofertas @> jsonb_build_array(jsonb_build_object('codigo',v_codigo,'limites',v_cupos))),
    'otra organización tiene su propio precio y cupos');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%s,%L,%L)',
    v_otra,v_codigo,v_version),'P0001','CR_STRIPE_COTIZACION_ACTUALIZADA');
  perform pruebas.afirmar(cuidared_api.api_stripe_preparar_checkout(v_otra,'operacion_base_mensual')
    @> '{"price_id":"price_p8f_base"}', 'cualquier titular de Organización puede contratar el precio general');

  perform pruebas.como(v_uno);
  v_ofertas := cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas';
  perform pruebas.afirmar(v_ofertas @> '[{"codigo":"operacion_base_mensual",
    "limites":{"envejecientes":15,"usuarios":20},"funcionalidades":["registro_visitas",
      "tablon_notificaciones","dashboard_metricas","necesidades_diarias"]}]', 'Base conserva cupos y funciones');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%s,%L)',
    v_cuenta,v_codigo),'P0001','CR_STRIPE_COTIZACION_ACTUALIZADA');
  v_checkout := cuidared_api.api_stripe_preparar_checkout(v_cuenta,v_codigo,v_version);
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin,v_sesion,'aal2',v_cuenta,v_codigo,
    9200,'price_p8f_av2','Revisión de cupos con el mismo importe',v_segunda,v_version);
  v_version_nueva := (select version_cotizacion from cuidared.stripe_oferta where price_id = 'price_p8f_av2');
  perform pruebas.error(format('select cuidared_api.api_bo_stripe_publicar_tarifa(%L,%L,%L,%s,%L,9200,%L,%L,%L,%L)',
    v_admin,v_sesion,'aal2',v_cuenta,v_codigo,'price_p8f_race','Publicación desactualizada',v_cupos,v_version),
    'P0001','CR_STRIPE_COTIZACION_ACTUALIZADA');
  perform pruebas.afirmar(v_version is distinct from v_version_nueva and
    cuidared_api.api_stripe_preparar_checkout(v_cuenta,v_codigo,v_version) = v_checkout,
    'el Checkout ya abierto conserva su versión');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%s,%L,%L)',
    v_cuenta,v_codigo,v_version_nueva),'P0001','CR_STRIPE_COTIZACION_ACTUALIZADA');
  v_ofertas := cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas';
  perform pruebas.afirmar(v_ofertas @> jsonb_build_array(
    jsonb_build_object('codigo',v_codigo,'version',v_version,'limites',v_cupos,'en_curso',true,'publicada',false),
    jsonb_build_object('codigo',v_codigo,'version',v_version_nueva,'limites',v_segunda,'en_curso',false,'publicada',true)),
    'gestión distingue el intento abierto y la nueva versión del mismo plan');
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(v_cuenta),
    'el acceso operativo permanece bloqueado antes de pagar');

  perform cuidared_api.api_stripe_asociar_checkout((v_checkout->>'intento_id')::uuid,'cs_test_p8f');
  v_factura := jsonb_build_object('intento_id',v_checkout->>'intento_id','suscripcion_id','sub_p8f',
    'cliente_id','cus_p8f','estado_proveedor','active','cancelacion_programada',false,'factura_id','in_p8f',
    'price_id',v_checkout->>'price_id','periodo_inicio',v_ahora,'periodo_fin',v_corte,
    'fecha_pago',v_ahora,'moneda','USD','importe_centavos',9200);
  perform cuidared_api.api_stripe_procesar_evento('evt_p8f','invoice.paid',v_ahora + interval '1 second',v_factura);
  perform pruebas.afirmar(cuidared_interno.limites(v_cuenta) = v_cupos
    and cuidared_api.api_stripe_gestion(v_cuenta)->'limites' = v_cupos
    and cuidared_api.api_contexto_cuenta(v_cuenta)->'limites' = v_cupos,
    'el pago aplica los cupos comprados, aunque la cotización se haya actualizado');
  perform pruebas.afirmar(cuidared_api.api_bo_leer(v_admin,v_sesion,'aal2','detalle',
    jsonb_build_object('cuenta',v_cuenta))->'plan'
      @> '{"max_envejecientes":1,"max_usuarios":3,"max_cuidadores":1,"max_familiares":1}',
    'Backoffice muestra los cupos efectivos de la organización');
  perform pruebas.error(format('select cuidared_interno.env_exigir_cupo(%s)',v_cuenta),
    'P0001','CR_LIMITE_PLAN');
  perform pruebas.error(format('select cuidared_interno.exigir_cupo_miembro(%s,%L)',v_cuenta,'cuidador'),
    'P0001','CR_LIMITE_PLAN');
  perform pruebas.error(format('select cuidared_interno.exigir_cupo_miembro(%s,%L)',v_cuenta,'familiar'),
    'P0001','CR_LIMITE_PLAN');
  perform pruebas.miembro(v_cuenta,v_equipo,'coordinador');
  perform pruebas.error(format('select cuidared_interno.exigir_cupo_miembro(%s,%L)',v_cuenta,'administrador'),
    'P0001','CR_LIMITE_PLAN');
  perform cuidared_interno.exigir_cupo_miembro(v_cuenta,'voluntario');

  v_cambio := cuidared_api.api_stripe_preparar_cambio(v_cuenta,v_codigo,v_version_nueva);
  perform pruebas.afirmar(v_cambio @> '{"modo":"proximo_corte","price_id":"price_p8f_av2"}'
    and cuidared_interno.limites(v_cuenta) = v_cupos, 'la revisión de cupos conserva las condiciones hasta el corte');
  perform cuidared_api.api_stripe_asociar_programacion((v_cambio->>'cambio_id')::uuid,'sub_sched_p8f');
  v_factura := v_factura || jsonb_build_object('factura_id','in_p8f_corte','price_id',v_cambio->>'price_id',
    'subscription_price_id',v_cambio->>'price_id','periodo_inicio',v_corte,'periodo_fin',v_corte + interval '1 month',
    'fecha_pago',v_corte,'schedule_id','sub_sched_p8f');
  perform cuidared_api.api_stripe_procesar_evento('evt_p8f_corte','invoice.paid',v_corte + interval '1 second',v_factura);
  perform pruebas.afirmar(cuidared_interno.limites(v_cuenta) = v_segunda,
    'la factura del corte activa los cupos de la nueva versión');
end $$;

rollback;
