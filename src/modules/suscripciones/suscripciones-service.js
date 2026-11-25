/* Orquestación de Checkout y conciliación de Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { AppError, unavailable } from '../../lib/errors.js';

const metadataKey = 'cuidared_intento_id';
const identifier = /^evt_[a-zA-Z0-9]+$/;
const ventanaMinimaCheckoutMs = 30 * 60 * 1000;
const uuid = z.uuid();
const intentoSchema = z.object({
  intento_id: uuid,
  price_id: z.string().regex(/^price_[a-zA-Z0-9]+$/),
  customer_id: z
    .string()
    .regex(/^cus_[a-zA-Z0-9]+$/)
    .nullable(),
  session_id: z
    .string()
    .regex(/^cs_test_[a-zA-Z0-9]+$/)
    .nullable(),
  importe_centavos: z.int().positive(),
  moneda: z.string().regex(/^[A-Z]{3}$/),
  periodicidad: z.enum(['mensual', 'anual']),
  vence_en: z.iso.datetime({ offset: true }),
});
const subscriptionId = z.string().regex(/^sub_[a-zA-Z0-9]+$/);
const cancelacionSchema = z.object({ subscription_id: subscriptionId });
const cambioSchema = intentoSchema
  .pick({ price_id: true, importe_centavos: true, moneda: true, periodicidad: true })
  .extend({
    cambio_id: uuid,
    subscription_id: subscriptionId,
    price_id_actual: z.string().regex(/^price_[A-Za-z0-9]+$/),
    modo: z.enum(['inmediato', 'proximo_corte']),
    efectivo_en: z.iso.datetime({ offset: true }),
    schedule_id: z
      .string()
      .regex(/^sub_sched_[A-Za-z0-9]+$/)
      .nullable(),
    vigencia_hasta: z.iso.datetime({ offset: true }),
  });
const checkoutPendiente = () =>
  new AppError(409, 'CHECKOUT_IN_PROGRESS', 'Ya hay un pago de prueba en proceso de confirmación.');

const id = (value, prefix) => {
  const raw = typeof value === 'string' ? value : value?.id;
  return typeof raw === 'string' &&
    raw.startsWith(prefix) &&
    /^[a-zA-Z0-9]+$/.test(raw.slice(prefix.length))
    ? raw
    : null;
};
const instante = (value) =>
  Number.isSafeInteger(value) && value > 0 && value < 253402300800
    ? new Date(value * 1000).toISOString()
    : null;
const importe = (value) => Number.isSafeInteger(value) && value > 0 && value <= 99999999;
const monedaValida = (value) => typeof value === 'string' && /^[a-zA-Z]{3}$/.test(value);

export function precioCompatible(price, esperado) {
  return (
    price.livemode === false &&
    price.active &&
    price.type === 'recurring' &&
    price.billing_scheme === 'per_unit' &&
    price.recurring?.usage_type === 'licensed' &&
    price.recurring.interval_count === 1 &&
    price.unit_amount === esperado.importe_centavos &&
    price.currency?.toUpperCase() === esperado.moneda &&
    price.recurring.interval === (esperado.periodicidad === 'mensual' ? 'month' : 'year') &&
    price.custom_unit_amount == null &&
    !price.transform_quantity
  );
}

export async function iniciarCheckout({
  stripe,
  stripeSystemRpc,
  rpc,
  cuentaId,
  oferta,
  version,
  origen,
  now = () => new Date(),
}) {
  const parsed = intentoSchema.safeParse(
    await rpc('api_stripe_preparar_checkout', {
      p_cuenta_id: cuentaId,
      p_oferta: oferta,
      ...(version ? { p_version: version } : {}),
    }),
  );
  if (!parsed.success) throw unavailable();
  const intento = parsed.data;
  let session;
  if (intento.session_id) {
    session = await stripe.retrieveCheckout(intento.session_id);
  } else {
    const precio = await stripe.retrievePrice(intento.price_id);
    if (precio.id !== intento.price_id || !precioCompatible(precio, intento)) throw unavailable();
    const retorno = new URL(`/operacion/${cuentaId}/suscripcion`, origen);
    const cancelacion = new URL(retorno);
    retorno.searchParams.set('checkout', 'retorno');
    cancelacion.searchParams.set('checkout', 'cancelado');
    const metadata = { [metadataKey]: intento.intento_id };
    const vencimiento = Date.parse(intento.vence_en);
    try {
      session = await stripe.createCheckout(
        {
          mode: 'subscription',
          integration_identifier: 'cuidared-sandbox-qxzkswta',
          client_reference_id: intento.intento_id,
          metadata,
          subscription_data: { metadata },
          line_items: [{ price: intento.price_id, quantity: 1 }],
          ...(intento.customer_id && { customer: intento.customer_id }),
          success_url: retorno.toString(),
          cancel_url: cancelacion.toString(),
          expires_at: Math.floor(vencimiento / 1000),
        },
        `cuidared:checkout:${intento.intento_id}`,
      );
    } catch (error) {
      // Un intento previo pudo llegar a Stripe. Conserva sus parámetros y su clave hasta que venza.
      if (
        error instanceof AppError &&
        error.dependency === 'stripe' &&
        vencimiento - now().getTime() < ventanaMinimaCheckoutMs
      )
        throw new AppError(
          409,
          'CHECKOUT_RETRY_LATER',
          'No se pudo reabrir este intento de pago. Cuando venza, actualiza el estado para intentar de nuevo.',
        );
      throw error;
    }
  }
  if (
    !id(session.id, 'cs_test_') ||
    (intento.session_id && session.id !== intento.session_id) ||
    session.livemode !== false ||
    session.mode !== 'subscription' ||
    session.client_reference_id !== intento.intento_id ||
    session.metadata?.[metadataKey] !== intento.intento_id
  )
    throw unavailable();
  if (!intento.session_id) {
    await stripeSystemRpc('api_stripe_asociar_checkout', {
      p_intento_id: intento.intento_id,
      p_session_id: session.id,
    });
  }
  if (session.status === 'expired')
    throw new AppError(
      409,
      'CHECKOUT_EXPIRED',
      'La sesión de pago de prueba venció. Consulta el estado para poder iniciar otra.',
    );
  if (session.status !== 'open' || !session.url) throw checkoutPendiente();
  const url = URL.parse(session.url);
  if (url?.origin !== 'https://checkout.stripe.com' || url.username || url.password)
    throw unavailable();
  return { url: url.href };
}

async function cancelarRenovacionStripe(stripe, stripeSystemRpc, cuentaId, subId) {
  let actual = await stripe.retrieveSubscription(subId);
  if (actual.id !== subId || !contextoSuscripcion(actual)) throw unavailable();
  const programa = id(actual.schedule, 'sub_sched_');
  if (programa) {
    const agenda = await stripe.retrieveSchedule(programa);
    if (id(agenda.subscription, 'sub_') !== subId) throw unavailable();
    await stripe.releaseSchedule(programa, `cuidared:liberar:${programa}`);
    actual = await stripe.retrieveSubscription(subId);
    if (actual.id !== subId || !contextoSuscripcion(actual) || actual.schedule)
      throw unavailable();
  }
  const resultado =
    actual.cancel_at_period_end === true || actual.status === 'canceled'
      ? actual
      : await stripe.updateSubscription(
          subId,
          { cancel_at_period_end: true },
          `cuidared:cancelar:${randomUUID()}`,
        );
  if (
    resultado.id !== subId ||
    resultado.livemode !== false ||
    (resultado.cancel_at_period_end !== true && resultado.status !== 'canceled')
  )
    throw unavailable();
  await stripeSystemRpc('api_stripe_confirmar_cancelacion', {
    p_cuenta_id: cuentaId,
    p_subscription_id: subId,
  });
}

export async function cancelarRenovacionPorTransferencia({
  stripe,
  stripeSystemRpc,
  rpc,
  cuentaId,
  membresiaId,
}) {
  const parsed = z.object({ subscription_id: subscriptionId.nullable() }).safeParse(
    await rpc('api_stripe_preparar_transferencia', {
      p_cuenta_id: cuentaId,
      p_membresia_id: membresiaId,
    }),
  );
  if (!parsed.success) throw unavailable();
  if (parsed.data.subscription_id) {
    await cancelarRenovacionStripe(stripe, stripeSystemRpc, cuentaId, parsed.data.subscription_id);
  }
}

export async function programarCancelacion({ stripe, stripeSystemRpc, rpc, cuentaId }) {
  const parsed = cancelacionSchema.safeParse(
    await rpc('api_stripe_preparar_cancelacion', {
      p_cuenta_id: cuentaId,
    }),
  );
  if (!parsed.success) throw unavailable();
  await cancelarRenovacionStripe(stripe, stripeSystemRpc, cuentaId, parsed.data.subscription_id);
}

export async function solicitarCambioPlan({
  stripe,
  stripeSystemRpc,
  rpc,
  cuentaId,
  oferta,
  version,
}) {
  const parsed = cambioSchema.safeParse(
    await rpc('api_stripe_preparar_cambio', {
      p_cuenta_id: cuentaId,
      p_oferta: oferta,
      ...(version ? { p_version: version } : {}),
    }),
  );
  if (!parsed.success) throw unavailable();
  const cambio = parsed.data;
  const [precio, actual] = await Promise.all([
    stripe.retrievePrice(cambio.price_id),
    stripe.retrieveSubscription(cambio.subscription_id),
  ]);
  if (
    precio.id !== cambio.price_id ||
    !precioCompatible(precio, cambio) ||
    actual.id !== cambio.subscription_id ||
    !contextoSuscripcion(actual) ||
    actual.items?.has_more !== false ||
    actual.items.data?.length !== 1
  )
    throw unavailable();
  const [item] = actual.items.data;
  const itemId = id(item.id, 'si_');
  if (!itemId || item.price?.currency !== precio.currency) throw unavailable();
  if (item.price.id === cambio.price_id && !actual.pending_update)
    return { url: null, modo: cambio.modo };
  if (item.price.id !== cambio.price_id_actual || actual.cancel_at_period_end) throw unavailable();
  if (cambio.modo === 'proximo_corte') {
    return programarCambioStripe(stripe, stripeSystemRpc, cambio, actual, item);
  }
  return aplicarCambioStripe(stripe, stripeSystemRpc, cambio, actual, itemId);
}

async function programarCambioStripe(stripe, stripeSystemRpc, cambio, actual, item) {
  const corte = Math.floor(Date.parse(cambio.efectivo_en) / 1000);
  if (item.current_period_end !== corte || cambio.efectivo_en !== cambio.vigencia_hasta)
    throw new AppError(
      409,
      'PLAN_CHANGE_NOT_ALLOWED',
      'El ciclo de pago cambió. Actualiza la suscripción.',
    );
  const vigente = id(actual.schedule, 'sub_sched_');
  const idempotencia = `cuidared:cambiar:${cambio.cambio_id}`;
  if (cambio.schedule_id && vigente !== cambio.schedule_id) throw unavailable();
  const schedule = cambio.schedule_id
    ? await stripe.retrieveSchedule(cambio.schedule_id)
    : await stripe.createScheduleFromSubscription(cambio.subscription_id, `${idempotencia}:crear`);
  const scheduleId = id(schedule.id, 'sub_sched_');
  const fase = schedule.current_phase;
  if (
    !scheduleId ||
    schedule.livemode !== false ||
    id(schedule.subscription, 'sub_') !== cambio.subscription_id ||
    (vigente && scheduleId !== vigente) ||
    !fase ||
    !instante(fase.start_date) ||
    fase.start_date >= corte
  )
    throw unavailable();

  // Una fase termina exactamente al corte pagado. La siguiente factura usa el nuevo precio completo.
  const confirmada = await stripe.updateSchedule(
    scheduleId,
    {
      end_behavior: 'release',
      proration_behavior: 'none',
      phases: [
        {
          start_date: fase.start_date,
          end_date: corte,
          proration_behavior: 'none',
          items: [{ price: cambio.price_id_actual, quantity: 1 }],
        },
        {
          start_date: corte,
          duration: {
            interval: cambio.periodicidad === 'mensual' ? 'month' : 'year',
            interval_count: 1,
          },
          proration_behavior: 'none',
          items: [{ price: cambio.price_id, quantity: 1 }],
        },
      ],
    },
    `${idempotencia}:programar`,
  );
  if (
    confirmada.id !== scheduleId ||
    confirmada.livemode !== false ||
    id(confirmada.subscription, 'sub_') !== cambio.subscription_id
  )
    throw unavailable();
  await stripeSystemRpc('api_stripe_asociar_programacion', {
    p_cambio_id: cambio.cambio_id,
    p_schedule_id: scheduleId,
  });
  return { url: null, modo: cambio.modo };
}

async function aplicarCambioStripe(stripe, stripeSystemRpc, cambio, actual, itemId) {
  const ultimoPagoPendiente = actual.pending_update?.subscription_items?.find(
    (item) => id(item.price, 'price_') === cambio.price_id,
  );
  if (ultimoPagoPendiente) {
    const facturaId = id(actual.latest_invoice, 'in_');
    if (!facturaId) throw unavailable();
    await stripeSystemRpc('api_stripe_asociar_cambio', {
      p_cambio_id: cambio.cambio_id,
      p_factura_id: facturaId,
    });
    return { url: await invoiceUrl(stripe, facturaId), modo: cambio.modo };
  }
  if (actual.pending_update || actual.schedule) throw unavailable();
  const prorationDate = Math.floor(Date.parse(cambio.efectivo_en) / 1000);
  const detalles = {
    proration_behavior: 'always_invoice',
    proration_date: prorationDate,
    items: [{ id: itemId, price: cambio.price_id, quantity: 1 }],
  };
  const preview = await stripe.createInvoicePreview({
    subscription: cambio.subscription_id,
    subscription_details: detalles,
  });
  const lineas = preview.lines;
  const cargo = lineas?.data
    ?.filter((linea) => linea.parent?.subscription_item_details?.proration === true)
    .reduce((total, linea) => total + linea.amount, 0);
  if (
    preview.livemode !== false ||
    preview.currency !== 'usd' ||
    !importe(preview.amount_due) ||
    lineas?.has_more !== false ||
    !importe(cargo)
  ) {
    await stripeSystemRpc('api_stripe_descartar_prevision', { p_cambio_id: cambio.cambio_id });
    throw new AppError(
      409,
      'PLAN_CHANGE_NOT_ALLOWED',
      'Stripe no confirmó un cargo adicional. Actualiza la suscripción.',
    );
  }

  const actualizada = await stripe.updateSubscription(
    cambio.subscription_id,
    { ...detalles, payment_behavior: 'pending_if_incomplete' },
    `cuidared:cambiar:${cambio.cambio_id}`,
  );
  if (actualizada.id !== cambio.subscription_id || actualizada.livemode !== false)
    throw unavailable();
  const facturaId = id(actualizada.latest_invoice, 'in_');
  if (!facturaId) throw unavailable();
  if (facturaId === id(actual.latest_invoice, 'in_')) throw unavailable();
  await stripeSystemRpc('api_stripe_asociar_cambio', {
    p_cambio_id: cambio.cambio_id,
    p_factura_id: facturaId,
  });
  return {
    url: actualizada.pending_update ? await invoiceUrl(stripe, facturaId) : null,
    modo: cambio.modo,
  };
}

async function invoiceUrl(stripe, facturaId) {
  const factura = await stripe.retrieveInvoice(facturaId);
  const url =
    typeof factura.hosted_invoice_url === 'string' ? URL.parse(factura.hosted_invoice_url) : null;
  if (url?.origin !== 'https://invoice.stripe.com' || url.username || url.password) return null;
  return url.href;
}

function contextoSuscripcion(sub) {
  const intento = uuid.safeParse(sub.metadata?.[metadataKey]);
  if (!intento.success) return null;
  const suscripcionId = id(sub.id, 'sub_');
  const clienteId = id(sub.customer, 'cus_');
  if (!suscripcionId || !clienteId || sub.livemode !== false || typeof sub.status !== 'string')
    throw unavailable();
  return {
    intento_id: intento.data,
    suscripcion_id: suscripcionId,
    cliente_id: clienteId,
    estado_proveedor: sub.status,
    cancelacion_programada: sub.cancel_at_period_end === true || sub.cancel_at != null,
    subscription_price_id:
      sub.items?.data?.length === 1 ? id(sub.items.data[0].price, 'price_') : null,
    latest_invoice_id: id(sub.latest_invoice, 'in_'),
    schedule_id: id(sub.schedule, 'sub_sched_'),
    pending_price_id:
      sub.pending_update?.subscription_items?.length === 1
        ? id(sub.pending_update.subscription_items[0].price, 'price_')
        : null,
  };
}

async function datosFactura(stripe, factura, event) {
  const suscripcionId = id(factura.parent?.subscription_details?.subscription, 'sub_');
  if (!suscripcionId || factura.collection_method !== 'charge_automatically') return null;
  const sub = await stripe.retrieveSubscription(suscripcionId);
  const contexto = contextoSuscripcion(sub);
  if (!contexto) return null;
  if (contexto.cliente_id !== id(factura.customer, 'cus_')) throw unavailable();
  const pagada = event.type === 'invoice.paid';
  if (pagada ? factura.status !== 'paid' : factura.status !== 'open') return null;
  const lineas = await stripe.listInvoiceLines(factura.id);
  const cambio = factura.billing_reason === 'subscription_update';
  const validas = lineas.filter(
    (x) =>
      x.livemode === false &&
      x.parent?.type === 'subscription_item_details' &&
      x.currency === factura.currency &&
      x.quantity === 1 &&
      id(x.pricing?.price_details?.price, 'price_') &&
      Number.isSafeInteger(x.amount),
  );
  if (validas.length !== lineas.length) return null;
  const objetivo = cambio ? validas.filter((x) => x.amount > 0) : validas;
  if (objetivo.length !== 1) return null;
  const [linea] = objetivo;
  const priceId = id(linea.pricing?.price_details?.price, 'price_');
  const periodoInicio = instante(linea.period?.start);
  const periodoFin = instante(linea.period?.end);
  const monto = pagada ? factura.amount_paid : factura.amount_due;
  if (
    !priceId ||
    !periodoInicio ||
    !periodoFin ||
    periodoFin <= periodoInicio ||
    !monedaValida(factura.currency) ||
    !Number.isSafeInteger(monto) ||
    monto <= 0 ||
    monto > 99999999 ||
    (!cambio &&
      (linea.parent.subscription_item_details?.proration !== false ||
        !importe(monto) ||
        linea.amount !== monto))
  )
    return null;

  let cargoId = null;
  let fechaPago = instante(event.created);
  if (pagada && monto > 0) {
    const pagos = await stripe.listInvoicePayments(factura.id);
    // Un pago marcado manualmente en Stripe o cubierto por saldo no activa la cuenta.
    const confirmado = pagos.find(
      (pago) =>
        pago.livemode === false &&
        pago.status === 'paid' &&
        id(pago.invoice, 'in_') === factura.id &&
        pago.amount_paid === monto &&
        pago.currency === factura.currency &&
        pago.payment?.type === 'payment_intent' &&
        pago.payment.payment_intent?.status === 'succeeded',
    );
    if (!confirmado) return null;
    cargoId = id(confirmado.payment.payment_intent.latest_charge, 'ch_');
    if (!cargoId) throw unavailable();
  }
  if (pagada) fechaPago = instante(factura.status_transitions?.paid_at);
  if (!fechaPago) throw unavailable();
  return {
    ...contexto,
    factura_id: factura.id,
    price_id: priceId,
    importe_centavos: monto,
    moneda: factura.currency.toUpperCase(),
    periodo_inicio: periodoInicio,
    periodo_fin: periodoFin,
    fecha_pago: fechaPago,
    cargo_id: cargoId,
    es_prorrateo: cambio,
  };
}

async function datosReembolso(stripe, cargo) {
  const intent = id(cargo.payment_intent, 'pi_');
  if (!intent) return null;
  const pagos = await stripe.listInvoicePaymentsByIntent(intent);
  const ids = [
    ...new Set(
      pagos
        .filter((pago) => pago.status === 'paid')
        .map((pago) => id(pago.invoice, 'in_'))
        .filter(Boolean),
    ),
  ];
  if (ids.length !== 1) return null;
  const [facturaId] = ids;
  const factura = await stripe.retrieveInvoice(facturaId);
  const suscripcionId = id(factura.parent?.subscription_details?.subscription, 'sub_');
  if (!suscripcionId) return null;
  const contexto = contextoSuscripcion(await stripe.retrieveSubscription(suscripcionId));
  if (!contexto) return null;
  if (
    contexto.cliente_id !== id(cargo.customer, 'cus_') ||
    contexto.cliente_id !== id(factura.customer, 'cus_')
  )
    throw unavailable();
  const reembolsos = await stripe.listChargeRefunds(cargo.id);
  const reembolsado = reembolsos
    .filter((refund) => refund.status === 'succeeded' && refund.currency === cargo.currency)
    .reduce((total, refund) => total + refund.amount, 0);
  if (!importe(reembolsado)) return null;
  return {
    ...contexto,
    factura_id: facturaId,
    cargo_id: cargo.id,
    importe_reembolsado_centavos: reembolsado,
  };
}

async function datosEvento(stripe, event) {
  const object = event.data?.object;
  switch (event.type) {
    case 'invoice.paid':
    case 'invoice.payment_failed':
      if (id(object, 'in_'))
        return datosFactura(stripe, await stripe.retrieveInvoice(object.id), event);
      break;
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted':
    case 'customer.subscription.pending_update_applied':
    case 'customer.subscription.pending_update_expired':
      if (id(object, 'sub_'))
        return contextoSuscripcion(await stripe.retrieveSubscription(object.id));
      break;
    case 'subscription_schedule.released': {
      const suscripcionId = id(object?.released_subscription, 'sub_');
      if (suscripcionId)
        return contextoSuscripcion(await stripe.retrieveSubscription(suscripcionId));
      break;
    }
    case 'charge.refunded':
      if (id(object, 'ch_')) return datosReembolso(stripe, await stripe.retrieveCharge(object.id));
      break;
    case 'refund.created':
    case 'refund.updated': {
      const cargoId = id(object?.charge, 'ch_');
      if (cargoId) return datosReembolso(stripe, await stripe.retrieveCharge(cargoId));
      break;
    }
    case 'checkout.session.expired': {
      const intento = uuid.safeParse(object?.metadata?.[metadataKey]);
      const sessionId = id(object, 'cs_test_');
      if (
        intento.success &&
        sessionId &&
        object.livemode === false &&
        object.status === 'expired'
      ) {
        return { intento_id: intento.data, session_id: sessionId };
      }
      break;
    }
  }
  return null;
}

export async function procesarEventoStripe({ stripe, stripeSystemRpc, event }) {
  const fecha = instante(event.created);
  if (event.livemode !== false || !identifier.test(event.id) || !fecha)
    throw new AppError(400, 'INVALID_STRIPE_EVENT', 'El evento de pago de prueba no es válido.');
  const datos = await datosEvento(stripe, event);
  if (datos) {
    const tipo = event.type.startsWith('refund.')
      ? 'charge.refunded'
      : event.type === 'subscription_schedule.released'
        ? 'customer.subscription.updated'
        : event.type;
    await stripeSystemRpc('api_stripe_procesar_evento', {
      p_evento_id: event.id,
      p_tipo: tipo,
      p_fecha: fecha,
      p_datos: datos,
    });
    if (event.type === 'invoice.paid' && datos.schedule_id) {
      const yaAplicado = await stripeSystemRpc('api_stripe_programacion_completada', {
        p_subscription_id: datos.suscripcion_id,
        p_schedule_id: datos.schedule_id,
      });
      if (yaAplicado === true) {
        const schedule = await stripe.retrieveSchedule(datos.schedule_id);
        if (
          id(schedule.subscription, 'sub_') === datos.suscripcion_id &&
          schedule.status === 'active'
        )
          await stripe.releaseSchedule(datos.schedule_id, `cuidared:liberar:${datos.schedule_id}`);
      }
    }
  }
}
