-- CUIDARED-018 · Protección contra tarifas directas desactualizadas. Datos sintéticos.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('p8g-admin@example.test', '00881700001');
  v_titular uuid := pruebas.usuario('p8g-titular@example.test', '00881700002');
  v_otro uuid := pruebas.usuario('p8g-otro@example.test', '00881700003');
  v_sesion uuid := pruebas.como(v_admin);
  v_cuenta bigint := pruebas.cuenta('organizacion', v_titular, 'vencida');
  v_otra bigint := pruebas.cuenta('organizacion', v_otro, 'vencida');
  v_mensual text := 'operacion_base_mensual';
  v_anual text := 'operacion_base_anual';
  v_version uuid;
  v_version_anterior uuid;
  v_attempt jsonb;
  v_ahora timestamptz := date_trunc('second', clock_timestamp());
begin
  insert into cuidared.usuario_backoffice(usuario_id, rol) values (v_admin, 'super_admin');
  perform cuidared_api.api_bo_admitir(v_admin, v_sesion, null, null);
  perform cuidared_api.api_bo_sesion(v_admin, v_sesion, 'aal2', 'ingreso', null, null);
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin, v_sesion, 'aal2', null,
    v_mensual, 3500, 'price_p8g_m1', 'Tarifa mensual sintética');
  perform pruebas.como(v_titular);
  select (dato->>'version')::uuid into strict v_version_anterior
  from jsonb_array_elements(cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas') dato
  where dato->>'codigo' = v_mensual;
  perform pruebas.afirmar(v_version_anterior::text ~ '^[0-9a-f-]{14}8[0-9a-f]{3}-a',
    'la tarifa directa expone una versión opaca y válida');

  v_attempt := cuidared_api.api_stripe_preparar_checkout(v_cuenta, v_mensual, v_version_anterior);
  perform cuidared_api.api_stripe_asociar_checkout((v_attempt->>'intento_id')::uuid, 'cs_test_p8g');
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin, v_sesion, 'aal2', null,
    v_mensual, 3900, 'price_p8g_m2', 'Tarifa mensual revisada');
  perform pruebas.afirmar(cuidared_api.api_stripe_preparar_checkout(v_cuenta, v_mensual, v_version_anterior)
    @> '{"price_id":"price_p8g_m1","importe_centavos":3500,"session_id":"cs_test_p8g"}',
    'retomar conserva la oferta ya reservada');

  perform pruebas.como(v_otro);
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%s,%L,%L)',
    v_otra, v_mensual, v_version_anterior), 'P0001', 'CR_STRIPE_COTIZACION_ACTUALIZADA');
  select (dato->>'version')::uuid into strict v_version
  from jsonb_array_elements(cuidared_api.api_stripe_gestion(v_otra)->'ofertas') dato
  where dato->>'codigo' = v_mensual;
  perform pruebas.afirmar(v_version <> v_version_anterior
    and cuidared_api.api_stripe_preparar_checkout(v_otra, v_mensual, v_version)->>'price_id' = 'price_p8g_m2',
    'el nuevo checkout usa la versión recién mostrada');

  perform pruebas.como(v_titular);
  perform cuidared_api.api_stripe_procesar_evento('evt_p8g', 'invoice.paid', v_ahora + interval '1 second',
    jsonb_build_object('intento_id',v_attempt->>'intento_id','suscripcion_id','sub_p8g',
      'cliente_id','cus_p8g','estado_proveedor','active','cancelacion_programada',false,'factura_id','in_p8g',
      'price_id','price_p8g_m1','periodo_inicio',v_ahora,'periodo_fin',v_ahora + interval '1 month',
      'fecha_pago',v_ahora,'moneda','USD','importe_centavos',3500));
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin, v_sesion, 'aal2', null,
    v_anual, 35000, 'price_p8g_a1', 'Tarifa anual sintética');
  select (dato->>'version')::uuid into strict v_version_anterior
  from jsonb_array_elements(cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas') dato
  where dato->>'codigo' = v_anual;
  perform cuidared_api.api_bo_stripe_publicar_tarifa(v_admin, v_sesion, 'aal2', null,
    v_anual, 39000, 'price_p8g_a2', 'Tarifa anual revisada');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_cambio(%s,%L,%L)',
    v_cuenta, v_anual, v_version_anterior), 'P0001', 'CR_STRIPE_COTIZACION_ACTUALIZADA');
  select (dato->>'version')::uuid into strict v_version
  from jsonb_array_elements(cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas') dato
  where dato->>'codigo' = v_anual;
  perform pruebas.afirmar(cuidared_api.api_stripe_preparar_cambio(v_cuenta, v_anual, v_version)
    @> '{"price_id":"price_p8g_a2","modo":"proximo_corte"}', 'el cambio confirma la revisión consultada');
end $$;

rollback;
