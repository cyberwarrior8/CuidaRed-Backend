-- Fase 8 · Stripe Sandbox, datos sintéticos · RF-20 y RF-21. © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_titular uuid := pruebas.usuario('stripe-titular@example.test', '00880000001');
  v_gestor uuid := pruebas.usuario('stripe-gestor@example.test', '00880000002');
  v_externo uuid := pruebas.usuario('stripe-externo@example.test', '00880000003');
  v_org_externa uuid := pruebas.usuario('stripe-org-externa@example.test', '00880000004');
  v_cuenta bigint := pruebas.cuenta('familia', v_titular, 'prueba', null, cuidared_interno.hoy() - 1);
  v_membresia bigint := pruebas.miembro(v_cuenta, v_gestor, 'coordinador');
  v_destinataria bigint := pruebas.cuenta('organizacion', v_externo, 'vencida');
  v_org bigint := pruebas.cuenta('organizacion', v_org_externa, 'vencida');
  v_catalogo jsonb;
  v_checkout jsonb;
  v_cambio jsonb;
  v_base jsonb;
  v_factura jsonb;
  v_prorrateo jsonb;
  v_programada jsonb;
  v_pagos jsonb;
  v_intento uuid;
  v_ahora timestamptz := date_trunc('second', clock_timestamp());
  v_fin timestamptz := v_ahora + interval '1 month';
  v_fin_anual timestamptz := v_fin + interval '1 year';
  v_fin_anterior timestamptz;
begin
  select jsonb_agg(jsonb_build_object(
    'codigo', m.codigo || '_' || ciclo,
    'price_id', 'price_fixture_' || m.codigo || '_' || ciclo,
    'periodicidad', ciclo,
    'importe_centavos', (case when m.codigo = 'cuidado_integral' then 2400 else 1200 end)
      * (case when ciclo = 'anual' then 10 else 1 end),
    'moneda', 'USD', 'divisor_moneda', 100
  )) into v_catalogo from cuidared_interno.stripe_catalogo_modelo() m cross join unnest(array['mensual', 'anual']) ciclo
    where m.tipo = 'familia';

  perform cuidared_interno.actualizar_vencimientos();
  perform pruebas.afirmar((select suscripcion_estado = 'vencida' and plan_id is null from cuidared.cuenta
    where cuenta_id = v_cuenta), 'el vencimiento no otorga un plan gratuito nuevo');

  set local role service_role;
  perform cuidared_api.api_stripe_catalogo_importar(v_catalogo);
  perform cuidared_api.api_stripe_catalogo_importar(v_catalogo);
  reset role;
  perform pruebas.afirmar((select count(*) = 4 from cuidared.stripe_oferta where activa),
    'la importación familiar es atómica e idempotente y no publica importes de Organización');
  perform pruebas.error(format('select cuidared_api.api_stripe_catalogo_importar(%L)', v_catalogo - 0),
    '22023');
  delete from cuidared.plan_funcionalidad where plan_id in (
    select plan_id from cuidared.plan where nombre = 'Gestión Comunitaria Avanzada');
  delete from cuidared.plan where nombre = 'Gestión Comunitaria Avanzada';
  perform cuidared_interno.stripe_catalogo_sembrar('gestion_comunitaria_avanzada_mensual', 'price_cotizacion_unica',
    'mensual', 15000, 'USD', 100, v_destinataria,
    '{"envejecientes":30,"usuarios":40,"cuidadores":20,"familiares":null}');
  perform pruebas.afirmar((select precio = 0 from cuidared.plan where nombre = 'Gestión Comunitaria Avanzada'),
    'crear el plan de organización no copia el importe de una cotización privada al precio general');
  perform pruebas.como(v_externo);
  perform pruebas.afirmar((select jsonb_array_length(cuidared_api.api_stripe_gestion(v_destinataria)->'ofertas')) = 1,
    'una oferta cotizada se muestra solo a la organización destinataria');
  perform pruebas.como(v_org_externa);
  perform pruebas.afirmar((select jsonb_array_length(cuidared_api.api_stripe_gestion(v_org)->'ofertas')) = 0,
    'la cotización no se publica como un precio de organización general');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%L, %L)',
    v_org, 'gestion_comunitaria_avanzada_mensual'), 'P0002');

  perform pruebas.como(v_externo);
  set local role authenticated;
  perform pruebas.error(format('select cuidared_api.api_stripe_pagos(%L, 20, 0, true)', v_cuenta), '42501');
  perform pruebas.error('select count(*) from cuidared.stripe_evento', '42501');
  perform pruebas.error('select cuidared_api.api_stripe_catalogo_planes()', '42501');
  reset role;

  perform pruebas.como(v_gestor);
  set local role authenticated;
  perform pruebas.afirmar(cuidared_api.api_stripe_gestion(v_cuenta) @>
    '{"es_titular": false, "estado":"vencida", "acceso_operativo":false}',
    'el gestor ve el estado aunque haya vencido');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%L, %L)',
    v_cuenta, 'basico_familiar_mensual'), '42501');
  reset role;

  perform pruebas.como(v_titular);
  set local role authenticated;
  perform pruebas.afirmar(jsonb_array_length(cuidared_api.api_stripe_gestion(v_cuenta)->'ofertas') = 4,
    'Familia ve dos planes con dos ciclos por plan');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%L, %L)',
    v_cuenta, 'operacion_base_mensual'), 'P0002');
  v_checkout := cuidared_api.api_stripe_preparar_checkout(v_cuenta, 'basico_familiar_mensual');
  v_intento := (v_checkout->>'intento_id')::uuid;
  perform pruebas.afirmar(v_checkout = cuidared_api.api_stripe_preparar_checkout(v_cuenta, 'basico_familiar_mensual'),
    'el propietario recupera exactamente el mismo intento en reintentos');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%L, %L)',
    v_cuenta, 'cuidado_integral_mensual'), 'P0001', 'CR_STRIPE_CHECKOUT_EN_CURSO');
  perform pruebas.error(format('select cuidared_api.api_transferir_titularidad(%L, %L)', v_cuenta, v_membresia),
    'P0001');
  perform pruebas.error(format('select cuidared_api.api_stripe_asociar_checkout(%L, %L)',
    v_intento, 'cs_test_fixture'), '42501');
  reset role;

  v_base := jsonb_build_object('intento_id', v_intento, 'suscripcion_id', 'sub_fixture', 'cliente_id', 'cus_fixture',
    'estado_proveedor', 'active', 'cancelacion_programada', false);
  v_factura := v_base || jsonb_build_object('factura_id', 'in_fixture', 'price_id', v_checkout->>'price_id',
    'periodo_inicio', v_ahora, 'periodo_fin', v_fin, 'fecha_pago', v_ahora, 'moneda', 'USD', 'importe_centavos', 1200);

  set local role service_role;
  perform cuidared_api.api_stripe_asociar_checkout(v_intento, 'cs_test_fixture');
  perform cuidared_api.api_stripe_asociar_checkout(v_intento, 'cs_test_fixture');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_fallo', 'invoice.payment_failed', v_ahora,
    v_factura || '{"estado_proveedor":"incomplete"}');
  reset role;
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(v_cuenta), 'una factura fallida no recupera acceso');
  perform pruebas.afirmar(cuidared_api.api_stripe_preparar_checkout(v_cuenta, 'basico_familiar_mensual')
    @> '{"session_id":"cs_test_fixture"}', 'un fallo conserva el mismo Checkout abierto para reintentar el pago');
  perform pruebas.afirmar(cuidared_api.api_stripe_gestion(v_cuenta)
    @> '{"suscripcion_stripe":true,"puede_modificar":false,"checkout_en_curso":"basico_familiar_mensual"}',
    'la suscripción incompleta ofrece retomar el checkout, sin modificar el contrato');

  perform pruebas.error(format('select cuidared_api.api_stripe_procesar_evento(%L,%L,%L,%L)',
    'evt_fixture_monto', 'invoice.paid', v_ahora, v_factura || '{"importe_centavos":1201}'), '22023');
  perform pruebas.afirmar(not exists(select 1 from cuidared.stripe_evento where evento_id = 'evt_fixture_monto'),
    'el rechazo de la factura revierte el registro del evento');

  set local role service_role;
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_pago', 'invoice.paid',
    v_ahora + interval '1 second', v_factura);
  reset role;
  perform pruebas.afirmar(cuidared_api.api_stripe_procesar_evento('evt_fixture_pago', 'invoice.paid',
    v_ahora + interval '1 second', v_factura) @> '{"duplicado":true}', 'evento ya confirmado deduplicado');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_fallo_tarde', 'invoice.payment_failed',
    v_ahora, v_factura);
  perform pruebas.afirmar(cuidared_interno.acceso_operativo(v_cuenta), 'la factura pagada recupera acceso de inmediato');
  perform pruebas.afirmar((select count(*) = 1 and bool_and(estado = 'completado') from cuidared.pago
    where cuenta_id = v_cuenta and stripe_invoice_id = 'in_fixture'), 'el fallo anterior no revierte un pago');

  perform pruebas.como(v_titular);
  set local role authenticated;
  v_cambio := cuidared_api.api_stripe_preparar_cambio(v_cuenta, 'cuidado_integral_mensual');
  perform pruebas.afirmar(v_cambio->>'modo' = 'inmediato'
    and v_cambio = cuidared_api.api_stripe_preparar_cambio(v_cuenta, 'cuidado_integral_mensual'),
    'se conserva el mismo cambio antes de confirmación');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_transferencia(%L, %L)', v_cuenta, v_membresia),
    'P0001', 'CR_STRIPE_CAMBIO_EN_CURSO');
  reset role;

  set local role service_role;
  perform cuidared_api.api_stripe_asociar_cambio((v_cambio->>'cambio_id')::uuid, 'in_prorrateo');
  reset role;
  v_prorrateo := v_base || jsonb_build_object('factura_id', 'in_prorrateo', 'es_prorrateo', true,
    'cambio_id', v_cambio->>'cambio_id', 'price_id', v_cambio->>'price_id',
    'subscription_price_id', v_checkout->>'price_id', 'pending_price_id', v_cambio->>'price_id',
    'periodo_inicio', v_ahora, 'periodo_fin', v_fin, 'fecha_pago', v_ahora + interval '2 seconds',
    'moneda', 'USD', 'importe_centavos', 900, 'cargo_id', 'ch_prorrateo');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_reembolso', 'charge.refunded',
    v_ahora + interval '3 seconds', v_prorrateo || '{"importe_reembolsado_centavos":200}');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_prorrateo', 'invoice.paid',
    v_ahora + interval '3 seconds', v_prorrateo);
  perform pruebas.afirmar((select p.nombre = 'Básico Familiar'
    from cuidared.cuenta c join cuidared.plan p using(plan_id) where c.cuenta_id = v_cuenta),
    'la factura del cambio se conserva aunque Stripe todavía no confirme el nuevo precio activo');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_cambio_aplicado', 'customer.subscription.pending_update_applied',
    v_ahora + interval '4 seconds', v_base || jsonb_build_object('latest_invoice_id', 'in_prorrateo',
      'subscription_price_id', v_cambio->>'price_id'));
  perform pruebas.afirmar((select p.nombre = 'Cuidado Integral' and c.plan_precio = 24
    from cuidared.cuenta c join cuidared.plan p using(plan_id) where c.cuenta_id = v_cuenta),
    'el cambio confirmado aplica el plan nuevo y mantiene su precio de catálogo');
  perform pruebas.afirmar((select monto = 9 and stripe_reembolsado_centavos = 200 and estado = 'completado'
    from cuidared.pago where stripe_invoice_id = 'in_prorrateo'), 'reembolso adelantado de un cargo prorrateado');

  perform pruebas.como(v_titular);
  set local role authenticated;
  v_pagos := cuidared_api.api_stripe_pagos(v_cuenta, 1, 0, false);
  perform pruebas.afirmar(v_pagos->>'total' = '2' and v_pagos->'items'->0->>'plan' = 'Básico Familiar',
    'historial paginado, orden ascendente');
  v_pagos := cuidared_api.api_stripe_pagos(v_cuenta, 1, 0, true);
  perform pruebas.afirmar(v_pagos->'items'->0->>'plan' = 'Cuidado Integral'
    and v_pagos->'items'->0->>'importe_reembolsado_centavos' = '200', 'historial descendente con reembolso');
  reset role;

  perform pruebas.envejeciente(v_cuenta);
  perform pruebas.envejeciente(v_cuenta);
  v_cambio := cuidared_api.api_stripe_preparar_cambio(v_cuenta, 'basico_familiar_anual');
  perform pruebas.afirmar(v_cambio->>'modo' = 'proximo_corte'
    and (v_cambio->>'efectivo_en')::timestamptz = v_fin,
    'un cambio de frecuencia se programa para el final de la vigencia pagada');
  perform pruebas.envejeciente(v_cuenta);
  perform pruebas.afirmar(cuidared_api.api_stripe_preparar_transferencia(v_cuenta, v_membresia)
    @> '{"subscription_id":"sub_fixture"}', 'una futura reducción no bloquea solicitar la cancelación de la renovación');
  set local role service_role;
  perform cuidared_api.api_stripe_asociar_programacion((v_cambio->>'cambio_id')::uuid, 'sub_sched_fixture');
  reset role;
  v_programada := v_base || jsonb_build_object('factura_id', 'in_programada', 'price_id', v_cambio->>'price_id',
    'subscription_price_id', v_cambio->>'price_id', 'periodo_inicio', v_fin, 'periodo_fin', v_fin_anual,
    'fecha_pago', v_fin, 'moneda', 'USD', 'importe_centavos', 12000, 'schedule_id', 'sub_sched_fixture');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_programada_falla', 'invoice.payment_failed', v_fin,
    v_programada);
  perform pruebas.afirmar((select vigencia_hasta = v_fin from cuidared.stripe_suscripcion
    where subscription_id = 'sub_fixture'), 'un fallo al corte conserva únicamente el período pagado');
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_programada_pago', 'invoice.paid',
    v_fin + interval '1 second', v_programada);
  perform pruebas.afirmar((select vigencia_hasta = v_fin_anual and price_id = v_cambio->>'price_id'
    from cuidared.stripe_suscripcion where subscription_id = 'sub_fixture'),
    'autoriza el cambio programado con la nueva factura pagada');
  perform pruebas.afirmar((select count(*) = 3 and bool_and(estado = 'activo') from cuidared.envejeciente
    where cuenta_id = v_cuenta), 'el plan se reduce sin archivar expedientes creados después de programar');
  perform pruebas.error(format('select cuidared_interno.env_exigir_cupo(%L)', v_cuenta),
    'P0001', 'CR_LIMITE_PLAN');

  set local role authenticated;
  perform pruebas.error(format('select cuidared_api.api_transferir_titularidad(%L, %L)', v_cuenta, v_membresia),
    'P0001', 'CR_STRIPE_CANCELACION_REQUERIDA');
  perform pruebas.afirmar(cuidared_api.api_stripe_preparar_transferencia(v_cuenta, v_membresia)
    @> '{"subscription_id":"sub_fixture"}', 'la transferencia requiere cancelar la renovación de Stripe');
  reset role;

  set local role service_role;
  perform cuidared_api.api_stripe_confirmar_cancelacion(v_cuenta, 'sub_fixture');
  reset role;
  select vigencia_hasta into v_fin_anterior from cuidared.stripe_suscripcion where subscription_id = 'sub_fixture';
  perform cuidared_api.api_transferir_titularidad(v_cuenta, v_membresia);
  perform cuidared_api.api_stripe_procesar_evento('evt_fixture_pago_titular_anterior', 'invoice.paid',
    v_ahora + interval '5 seconds', v_base || jsonb_build_object('factura_id', 'in_factura_anterior',
      'price_id', v_cambio->>'price_id', 'periodo_inicio', v_fin_anual, 'periodo_fin', v_fin_anual + interval '1 year',
      'fecha_pago', v_fin_anual, 'moneda', 'USD', 'importe_centavos', 12000, 'cancelacion_programada', true));
  perform pruebas.afirmar((select vigencia_hasta = v_fin_anterior from cuidared.stripe_suscripcion
    where subscription_id = 'sub_fixture'), 'ni una transferencia ni un cobro del antiguo titular extienden el acceso');

  perform pruebas.como(v_gestor);
  perform pruebas.afirmar(cuidared_api.api_stripe_gestion(v_cuenta) @>
    '{"es_titular":true, "puede_modificar":false, "acceso_operativo":true}',
    'nuevo titular no administra el método de pago anterior y conserva el tiempo pagado');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%L, %L)',
    v_cuenta, 'basico_familiar_mensual'), 'P0001', 'CR_STRIPE_SUSCRIPCION_EN_CURSO');

  update cuidared.stripe_suscripcion set vigencia_hasta = now() where subscription_id = 'sub_fixture';
  perform pruebas.afirmar(not cuidared_interno.acceso_operativo(v_cuenta), 'la fecha civil no extiende el instante exacto');
  perform pruebas.afirmar(cuidared_api.api_stripe_gestion(v_cuenta) @> '{"suscripcion_stripe":false}',
    'la nueva titularidad puede contratar luego de la vigencia aunque se retrase la notificación terminal');
  perform pruebas.error(format('select cuidared_api.api_stripe_preparar_checkout(%L, %L)',
    v_cuenta, 'basico_familiar_mensual'), 'P0001', 'CR_STRIPE_SUPERA_LIMITE');
  v_checkout := cuidared_api.api_stripe_preparar_checkout(v_cuenta, 'cuidado_integral_mensual');
  perform pruebas.afirmar(v_checkout @> '{"customer_id":null}', 'el nuevo titular no hereda el Stripe Customer');
end;
$$;

rollback;
