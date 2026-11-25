/* Pruebas de firma, modo sandbox y normalización del SDK · RF-20. © 2026 Equipo CuidaRed – INTEC. */
import Stripe from 'stripe';
import { describe, expect, it, vi } from 'vitest';
import { createStripeGateway } from '../src/modules/suscripciones/stripe-gateway.js';

const env = {
  STRIPE_SANDBOX_ENABLED: true,
  STRIPE_SECRET_KEY: ['rk', 'test', 'FixtureStripeInexistente'].join('_'),
  STRIPE_WEBHOOK_SECRET: ['whsec', 'FixtureWebhookInexistente'].join('_'),
};
const sandbox = { livemode: false };
const checkoutUrl = 'https://checkout.stripe.com/c/pay/session-fixture';
const idempotencyKey = 'cuidared:prueba:123';

describe('gateway Stripe Sandbox', () => {
  it('construye el SDK solo para claves de prueba y fija la versión', () => {
    const createClient = vi.fn(() => ({}));
    const live = { ...env, STRIPE_SECRET_KEY: ['sk', 'live', 'EjemploInexistente'].join('_') };
    expect(
      createStripeGateway({ ...live, STRIPE_SANDBOX_ENABLED: false }, { createClient }),
    ).toBeNull();
    expect(() => createStripeGateway(live, { createClient })).toThrow('Stripe Sandbox');
    expect(createClient).not.toHaveBeenCalled();
    createStripeGateway(env, { createClient });
    expect(createClient).toHaveBeenCalledWith(env.STRIPE_SECRET_KEY, {
      apiVersion: '2026-11-18.endive',
      timeout: 8000,
      maxNetworkRetries: 1,
      telemetry: false,
    });
  });

  it('verifica la firma con el SDK sobre los bytes originales y rechaza eventos live', () => {
    const stripe = new Stripe(env.STRIPE_SECRET_KEY);
    const gateway = createStripeGateway(env, { createClient: () => stripe });
    const event = {
      id: 'evt_fixture',
      type: 'invoice.paid',
      livemode: false,
      data: { object: { id: 'in_fixture', livemode: false } },
    };
    const sign = (payload, timestamp) =>
      stripe.webhooks.generateTestHeaderString({
        payload,
        secret: env.STRIPE_WEBHOOK_SECRET,
        ...(timestamp && { timestamp }),
      });
    const raw = JSON.stringify(event);
    const signature = sign(raw);

    expect(gateway.verifyEvent(Buffer.from(raw), signature)).toEqual(event);
    expect(() => gateway.verifyEvent(Buffer.from(raw + ' '), signature)).toThrow(
      'No se pudo verificar el evento.',
    );
    expect(() => gateway.verifyEvent(Buffer.from(raw), sign(raw, 100))).toThrow(
      'No se pudo verificar el evento.',
    );
    const live = JSON.stringify({ ...event, livemode: true });
    expect(() => gateway.verifyEvent(Buffer.from(live), sign(live))).toThrow(
      'El evento de pago de prueba no es válido.',
    );
  });

  it('conserva idempotencia y entrega enlaces Checkout del dominio oficial', async () => {
    const create = vi.fn().mockResolvedValue({ ...sandbox, url: checkoutUrl });
    const retrieve = vi
      .fn()
      .mockResolvedValueOnce({ ...sandbox, url: null })
      .mockResolvedValueOnce({ ...sandbox, url: 'https://checkout.stripe.com.ejemplo.test/pago' });
    const gateway = createStripeGateway(env, {
      createClient: () => ({ checkout: { sessions: { create, retrieve } } }),
    });

    await expect(
      gateway.createCheckout({ mode: 'subscription' }, idempotencyKey),
    ).resolves.toMatchObject({
      url: checkoutUrl,
    });
    expect(create).toHaveBeenCalledWith(
      { mode: 'subscription', ui_mode: 'hosted_page', adaptive_pricing: { enabled: false } },
      { idempotencyKey },
    );
    await expect(gateway.createCheckout({}, undefined)).rejects.toMatchObject({ status: 503 });
    expect(create).toHaveBeenCalledTimes(1);
    await expect(gateway.retrieveCheckout('cs_test_fixture')).resolves.toMatchObject({ url: null });
    await expect(gateway.retrieveCheckout('cs_test_fixture')).rejects.toMatchObject({
      status: 503,
    });
  });

  it('rechaza objetos live y sanitiza los errores de la pasarela', async () => {
    const retrieve = vi
      .fn()
      .mockResolvedValueOnce({ livemode: true })
      .mockRejectedValueOnce(new Error('Respuesta sensible de ejemplo'));
    const gateway = createStripeGateway(env, { createClient: () => ({ prices: { retrieve } }) });

    await expect(gateway.retrievePrice('price_fixture')).rejects.toMatchObject({
      status: 503,
      dependency: 'stripe',
      code: 'DEPENDENCY_UNAVAILABLE',
    });
    await expect(gateway.retrievePrice('price_fixture')).rejects.toThrow(
      'El servicio no está disponible. Intenta de nuevo.',
    );
  });

  it('consulta la factura por intención de pago y recorre todas las páginas de reembolsos', async () => {
    const payment = { ...sandbox, id: 'inpay_fixture' };
    const paymentList = vi.fn().mockResolvedValue({ has_more: false, data: [payment] });
    const refunds = [
      { id: 're_uno', charge: 'ch_fixture', status: 'succeeded' },
      { id: 're_dos', charge: 'ch_fixture', status: 'pending' },
    ];
    const refundList = vi
      .fn()
      .mockResolvedValueOnce({ has_more: true, data: [refunds[0]] })
      .mockResolvedValueOnce({ has_more: false, data: [refunds[1]] });
    const gateway = createStripeGateway(env, {
      createClient: () => ({
        invoicePayments: { list: paymentList },
        refunds: { list: refundList },
      }),
    });

    await expect(gateway.listInvoicePaymentsByIntent('pi_fixture')).resolves.toEqual([payment]);
    expect(paymentList).toHaveBeenCalledWith({
      payment: { type: 'payment_intent', payment_intent: 'pi_fixture' },
      limit: 100,
      expand: ['data.payment.payment_intent'],
    });
    await expect(gateway.listChargeRefunds('ch_fixture')).resolves.toEqual(refunds);
    expect(refundList).toHaveBeenLastCalledWith({
      charge: 'ch_fixture',
      limit: 100,
      starting_after: 're_uno',
    });
  });
});
