/* Pasarela exclusiva de Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import Stripe from 'stripe';
import { AppError, unavailable } from '../../lib/errors.js';

const apiVersion = '2026-11-18.endive';
const pageSize = 100;
const maxRefundPages = 10;

function stripeUnavailable() {
  const error = unavailable();
  error.dependency = 'stripe';
  return error;
}

function sandboxObject(value) {
  if (!value || value.livemode !== false) throw stripeUnavailable();
  return value;
}

async function call(operation) {
  try {
    return await operation();
  } catch {
    // El SDK puede incluir detalles del pago, del cliente y de la petición en su error.
    throw stripeUnavailable();
  }
}

function writeOptions(idempotencyKey) {
  if (typeof idempotencyKey !== 'string' || !/^[\w:/.-]{1,255}$/.test(idempotencyKey))
    throw stripeUnavailable();
  return { idempotencyKey };
}

function checkout(session, requiresUrl = false) {
  sandboxObject(session);
  if (session.url == null && !requiresUrl) return session;
  try {
    const url = new URL(session.url);
    if (url.origin === 'https://checkout.stripe.com' && !url.username && !url.password) {
      return session;
    }
  } catch {
    // Si el destino no es Checkout oficial, la aplicación no ofrece la redirección.
  }
  throw stripeUnavailable();
}

function completePage(page) {
  if (page?.has_more !== false || !Array.isArray(page.data)) throw stripeUnavailable();
  return page.data;
}

/**
 * Primitivas del SDK para Checkout, Billing y conciliación. La capa de servicio decide qué
 * recurso corresponde a CuidaRed y qué estado actualizar. Ninguna operación admite modo live.
 */
export function createStripeGateway(
  env,
  { createClient = (key, options) => new Stripe(key, options) } = {},
) {
  if (env.STRIPE_SANDBOX_ENABLED !== true) return null;

  const { STRIPE_SECRET_KEY: key, STRIPE_WEBHOOK_SECRET: signingSecret } = env;
  if (!/^[sr]k_test_[A-Za-z0-9]+$/.test(key) || !/^whsec_[A-Za-z0-9]+$/.test(signingSecret))
    throw new Error('Configuración inválida de Stripe Sandbox.');

  const stripe = createClient(key, {
    apiVersion,
    timeout: 8_000,
    maxNetworkRetries: 1,
    telemetry: false,
  });

  const retrieve = async (operation) => sandboxObject(await call(operation));
  const invoicePayments = async (filters) =>
    completePage(
      await call(() =>
        stripe.invoicePayments.list({
          ...filters,
          limit: pageSize,
          expand: ['data.payment.payment_intent'],
        }),
      ),
    ).map(sandboxObject);

  return {
    verifyEvent(raw, signature) {
      let event;
      try {
        if (!Buffer.isBuffer(raw) || typeof signature !== 'string' || !signature)
          throw new Error('Invalid event');
        event = stripe.webhooks.constructEvent(raw, signature, signingSecret);
      } catch {
        throw new AppError(400, 'INVALID_STRIPE_SIGNATURE', 'No se pudo verificar el evento.');
      }
      if (event?.livemode !== false || event.data?.object?.livemode === true)
        throw new AppError(
          400,
          'INVALID_STRIPE_EVENT',
          'El evento de pago de prueba no es válido.',
        );
      return event;
    },
    retrievePrice: (id) => retrieve(() => stripe.prices.retrieve(id)),
    createPrice: (params, idempotencyKey) =>
      retrieve(() => stripe.prices.create(params, writeOptions(idempotencyKey))),
    async createCheckout(params, idempotencyKey) {
      const session = await call(() =>
        stripe.checkout.sessions.create(
          { ...params, ui_mode: 'hosted_page', adaptive_pricing: { enabled: false } },
          writeOptions(idempotencyKey),
        ),
      );
      return checkout(session, true);
    },
    retrieveCheckout: async (id) =>
      checkout(await call(() => stripe.checkout.sessions.retrieve(id))),
    expireCheckout: async (id, idempotencyKey) =>
      checkout(
        await call(() => stripe.checkout.sessions.expire(id, {}, writeOptions(idempotencyKey))),
      ),
    retrieveSubscription: (id) => retrieve(() => stripe.subscriptions.retrieve(id)),
    updateSubscription: (id, params, idempotencyKey) =>
      retrieve(() => stripe.subscriptions.update(id, params, writeOptions(idempotencyKey))),
    createScheduleFromSubscription: (id, idempotencyKey) =>
      retrieve(() =>
        stripe.subscriptionSchedules.create(
          { from_subscription: id },
          writeOptions(idempotencyKey),
        ),
      ),
    retrieveSchedule: (id) => retrieve(() => stripe.subscriptionSchedules.retrieve(id)),
    updateSchedule: (id, params, idempotencyKey) =>
      retrieve(() => stripe.subscriptionSchedules.update(id, params, writeOptions(idempotencyKey))),
    releaseSchedule: (id, idempotencyKey) =>
      retrieve(() => stripe.subscriptionSchedules.release(id, {}, writeOptions(idempotencyKey))),
    retrieveInvoice: (id) => retrieve(() => stripe.invoices.retrieve(id)),
    createInvoicePreview: (params) => retrieve(() => stripe.invoices.createPreview(params)),
    listInvoiceLines: async (id) =>
      completePage(await call(() => stripe.invoices.listLineItems(id, { limit: pageSize }))),
    listInvoicePayments: (invoice) => invoicePayments({ invoice }),
    listInvoicePaymentsByIntent: (paymentIntent) =>
      invoicePayments({ payment: { type: 'payment_intent', payment_intent: paymentIntent } }),
    retrieveCharge: (id) => retrieve(() => stripe.charges.retrieve(id)),
    async listChargeRefunds(charge) {
      const refunds = [];
      let cursor;
      for (let page = 0; page < maxRefundPages; page += 1) {
        const result = await call(() =>
          stripe.refunds.list({
            charge,
            limit: pageSize,
            ...(cursor && { starting_after: cursor }),
          }),
        );
        if (typeof result?.has_more !== 'boolean' || !Array.isArray(result.data))
          throw stripeUnavailable();
        // Refund no trae `livemode`; pertenece al Charge de Sandbox validado por el servicio.
        for (const refund of result.data) {
          const refundCharge =
            typeof refund?.charge === 'string' ? refund.charge : refund?.charge?.id;
          if (refundCharge !== charge || refund.livemode === true) throw stripeUnavailable();
          refunds.push(refund);
        }
        if (!result.has_more) return refunds;
        const next = result.data.at(-1)?.id;
        if (!next || next === cursor) throw stripeUnavailable();
        cursor = next;
      }
      throw stripeUnavailable();
    },
  };
}
