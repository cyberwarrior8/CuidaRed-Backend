/* API y conciliación de Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { readEnv } from '../src/config/env.js';
import { unavailable } from '../src/lib/errors.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { conSesion, cuentaCon, perfil, usuarioId } from './cuentas-support.js';

const origen = 'http://localhost:5173';
const base = '/api/v1/cuentas/7/suscripcion';
const webhooks = '/api/v1/webhooks/stripe';
const intento = '6ff0ded4-f690-47da-b5fb-73f4c29b2cb2';
const oferta = 'basico_familiar_mensual';
const date = new Date('2030-11-21T12:00:00Z');
const timestamp = date.getTime() / 1000;
const price = {
  id: 'price_Basico',
  livemode: false,
  active: true,
  type: 'recurring',
  unit_amount: 950,
  currency: 'usd',
  billing_scheme: 'per_unit',
  recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' },
};
const meta = { cuidared_intento_id: intento };
const session = {
  id: 'cs_test_CuidaRed',
  livemode: false,
  mode: 'subscription',
  status: 'open',
  metadata: meta,
  client_reference_id: intento,
  url: 'https://checkout.stripe.com/c/pay/cs_test_CuidaRed',
};
const subscription = {
  id: 'sub_CuidaRed',
  livemode: false,
  customer: 'cus_CuidaRed',
  metadata: meta,
  status: 'active',
  items: { has_more: false, data: [{ id: 'si_CuidaRed', price }] },
};
const invoice = {
  id: 'in_CuidaRed',
  status: 'paid',
  livemode: false,
  customer: subscription.customer,
  parent: { subscription_details: { subscription: subscription.id } },
  amount_due: 950,
  amount_paid: 950,
  currency: 'usd',
  collection_method: 'charge_automatically',
  billing_reason: 'subscription_create',
  status_transitions: { paid_at: timestamp },
};
const linea = {
  id: 'il_CuidaRed',
  livemode: false,
  amount: 950,
  currency: 'usd',
  quantity: 1,
  parent: { type: 'subscription_item_details', subscription_item_details: { proration: false } },
  pricing: { price_details: { price: price.id } },
  period: { start: timestamp, end: timestamp + 2592000 },
};
const invoicePayment = {
  livemode: false,
  status: 'paid',
  amount_paid: 950,
  currency: 'usd',
  invoice: invoice.id,
  payment: {
    type: 'payment_intent',
    payment_intent: { status: 'succeeded', latest_charge: 'ch_CuidaRed' },
  },
};

function app({
  rol = 'coordinador',
  tipo = 'familia',
  titular = true,
  enabled = true,
  operativa = false,
  handlers = {},
  now,
} = {}) {
  const rpc = cuentaCon(
    rol,
    tipo,
    {
      api_stripe_gestion: () => ({
        es_titular: titular,
        estado: 'vencida',
        acceso_operativo: false,
        vigencia_hasta: null,
        cancelacion_programada: false,
        suscripcion_stripe: false,
        puede_modificar: false,
        ofertas: [],
      }),
      api_stripe_pagos: () => ({ items: [], total: 0 }),
      api_stripe_preparar_checkout: () => ({
        intento_id: intento,
        customer_id: null,
        price_id: price.id,
        session_id: null,
        importe_centavos: 950,
        moneda: 'USD',
        periodicidad: 'mensual',
        vence_en: date.toISOString(),
      }),
      ...handlers,
    },
    {
      es_titular: titular,
      acceso_operativo: operativa,
      suscripcion_estado: operativa ? 'activa' : 'vencida',
    },
  );
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: usuarioId }),
    forToken: () => ({
      session: async () => ({ vigente: true }),
      getProfile: async () => perfil,
      rpc,
    }),
  };
  const audit = vi.fn();
  const stripeSystemRpc = vi.fn();
  const stripe = {
    verifyEvent: vi.fn(),
    retrievePrice: vi.fn().mockResolvedValue(price),
    createCheckout: vi.fn().mockResolvedValue(session),
    retrieveCheckout: vi.fn().mockResolvedValue(session),
    retrieveInvoice: vi.fn().mockResolvedValue(invoice),
    retrieveSubscription: vi.fn().mockResolvedValue(subscription),
    updateSubscription: vi.fn(),
    createInvoicePreview: vi.fn().mockResolvedValue({
      livemode: false,
      amount_due: 100,
      currency: 'usd',
      lines: {
        has_more: false,
        data: [{ amount: 100, parent: { subscription_item_details: { proration: true } } }],
      },
    }),
    createScheduleFromSubscription: vi.fn(),
    updateSchedule: vi.fn(),
    listInvoiceLines: vi.fn().mockResolvedValue([linea]),
    listInvoicePayments: vi.fn().mockResolvedValue([invoicePayment]),
  };
  return {
    http: createApp({
      env: { origins: [origen], PWA_ORIGIN: origen },
      gateway,
      audit,
      now,
      ...(enabled ? { stripe, stripeSystemRpc } : {}),
    }),
    stripe,
    stripeSystemRpc,
    rpc,
    audit,
  };
}

const checkout = (http, body = { oferta }) =>
  conSesion(request(http).post(`${base}/checkout`)).send(body);
const recibido = (http, contenido = '{ "evento": "prueba" }') =>
  request(http)
    .post(webhooks)
    .set('content-type', 'application/json')
    .set('Stripe-Signature', 'firma-simulada')
    .send(contenido);
const evento = (type, object, livemode = false) => ({
  id: 'evt_Prueba',
  type,
  created: timestamp,
  livemode,
  data: { object },
});

describe('API de suscripción', () => {
  it('entrega el catálogo de la cuenta vencida con el cupo del servidor aunque Stripe esté desactivado', async () => {
    const plan = {
      codigo: 'basico_familiar',
      nombre: 'Básico Familiar',
      limites: { envejecientes: 2, usuarios: null, familiares: 3, cuidadores: 5 },
      funcionalidades: ['necesidades_diarias'],
      precios_referencia: { mensual: 900, anual: 9000 },
      cotizado: false,
    };
    const { http, rpc } = app({
      enabled: false,
      handlers: { api_stripe_catalogo_cuenta: () => [plan] },
    });
    const respuesta = await conSesion(request(http).get(`${base}/catalogo`)).expect(200);
    expect(respuesta.body.data).toEqual([plan]);
    expect(rpc).toHaveBeenCalledWith('api_stripe_catalogo_cuenta', { p_cuenta_id: '7' });
  });

  it('conserva la modalidad de cotización de la oferta del catálogo sin publicar claves internas', async () => {
    const cuotas = { envejecientes: null, usuarios: null, familiares: null, cuidadores: null };
    const plan = {
      codigo: 'gestion_comunitaria_avanzada',
      nombre: 'Gestión Comunitaria Avanzada',
      limites: cuotas,
      funcionalidades: ['reportes_avanzados'],
      precios_referencia: null,
      cotizado: true,
    };
    const { http } = app({
      tipo: 'organizacion',
      rol: 'administrador',
      handlers: { api_stripe_catalogo_cuenta: () => [{ ...plan, price_id: price.id }] },
    });
    const respuesta = await conSesion(request(http).get(`${base}/catalogo`)).expect(200);
    expect(respuesta.body.data).toEqual([plan]);
  });

  it('mantiene gestión e historial para una cuenta vencida y pagina con CR-162', async () => {
    const { http, rpc } = app({ enabled: false });
    const gestion = await conSesion(request(http).get(`${base}/gestion`)).expect(200);
    expect(gestion.body.data).toMatchObject({
      estado: 'vencida',
      sandbox: true,
      pagos_disponibles: false,
    });
    const historial = await conSesion(
      request(http).get(`${base}/pagos?page=2&limit=5&sort=fecha`),
    ).expect(200);
    expect(historial.body).toEqual({
      data: [],
      meta: { page: 2, limit: 5, total: 0, totalPages: 0 },
    });
    expect(rpc).toHaveBeenCalledWith('api_stripe_pagos', {
      p_cuenta_id: '7',
      p_limite: 5,
      p_desplazamiento: 5,
      p_desc: false,
    });
    await checkout(http).expect(503);
  });

  it('deniega Checkout al no titular y restringe el historial al permiso comercial', async () => {
    const { http, stripe } = app({ titular: false });
    await checkout(http).expect(403);
    expect(stripe.createCheckout).not.toHaveBeenCalled();
    await conSesion(
      request(app({ rol: 'cuidador', titular: false }).http).get(`${base}/pagos`),
    ).expect(403);
  });

  it('rechaza montos suministrados por el navegador y crea Checkout con el precio autorizado', async () => {
    const { http, stripe, stripeSystemRpc } = app();
    await checkout(http, { oferta, importe_centavos: 1 }).expect(422);
    const res = await checkout(http).expect(201);
    expect(res.body.data).toEqual({ url: session.url });
    expect(stripe.createCheckout).toHaveBeenCalledWith(
      expect.objectContaining({
        mode: 'subscription',
        line_items: [{ price: price.id, quantity: 1 }],
        subscription_data: { metadata: meta },
        success_url: `${origen}/operacion/7/suscripcion?checkout=retorno`,
        cancel_url: `${origen}/operacion/7/suscripcion?checkout=cancelado`,
      }),
      `cuidared:checkout:${intento}`,
    );
    expect(stripeSystemRpc.mock.calls.map(([nombre]) => nombre)).toEqual([
      'api_stripe_asociar_checkout',
    ]);
  });

  it('rechaza un Price live aun si está configurado en la base', async () => {
    const { http, stripe } = app();
    stripe.retrievePrice.mockResolvedValue({ ...price, livemode: true });
    await checkout(http).expect(503);
    expect(stripe.createCheckout).not.toHaveBeenCalled();
  });

  it('rechaza un Price distinto al seleccionado aunque coincidan su monto y período', async () => {
    const { http, stripe } = app();
    stripe.retrievePrice.mockResolvedValue({ ...price, id: 'price_Distinto' });
    await checkout(http).expect(503);
    expect(stripe.createCheckout).not.toHaveBeenCalled();
  });

  it('muestra un vencimiento confirmado por Stripe sin abrir una sesión de pago adicional', async () => {
    const { http, stripe, stripeSystemRpc } = app({
      handlers: {
        api_stripe_preparar_checkout: () => ({
          intento_id: intento,
          customer_id: null,
          price_id: price.id,
          session_id: session.id,
          importe_centavos: 950,
          moneda: 'USD',
          periodicidad: 'mensual',
          vence_en: date.toISOString(),
        }),
      },
    });
    stripe.retrieveCheckout.mockResolvedValue({ ...session, id: 'cs_test_Distinta' });
    await checkout(http).expect(503);
    stripe.retrieveCheckout.mockResolvedValue({ ...session, status: 'expired', url: null });
    const response = await checkout(http).expect(409);
    expect(response.body.error.code).toBe('CHECKOUT_EXPIRED');
    expect(stripe.retrieveCheckout).toHaveBeenCalledWith(session.id);
    expect(stripe.createCheckout).not.toHaveBeenCalled();
    expect(stripeSystemRpc).not.toHaveBeenCalled();
  });

  it('permite recuperar un Checkout incierto con su clave original y explica si queda por vencer', async () => {
    const { http, stripe, stripeSystemRpc } = app({
      now: () => new Date(date.getTime() - 20 * 60 * 1000),
    });
    stripe.createCheckout.mockRejectedValueOnce(
      Object.assign(unavailable(), { dependency: 'stripe' }),
    );
    const response = await checkout(http).expect(409);
    expect(response.body.error.code).toBe('CHECKOUT_RETRY_LATER');
    expect(stripeSystemRpc).not.toHaveBeenCalled();
    await checkout(http).expect(201);
    expect(stripe.createCheckout.mock.calls).toEqual([
      stripe.createCheckout.mock.calls[0],
      stripe.createCheckout.mock.calls[0],
    ]);
    expect(stripe.createCheckout).toHaveBeenCalledWith(
      expect.objectContaining({ expires_at: timestamp }),
      `cuidared:checkout:${intento}`,
    );
    expect(stripeSystemRpc).toHaveBeenCalledOnce();
  });

  it('rechaza claves live en el entorno', () => {
    expect(() =>
      readEnv({
        SUPABASE_URL: 'https://ejemplo.test',
        SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_EJEMPLO',
        FRONTEND_ORIGINS: origen,
        STRIPE_SECRET_KEY: 'sk_live_EJEMPLO',
      }),
    ).toThrow('STRIPE_SECRET_KEY');
  });

  it('acepta claves de Sandbox y un retorno permitido por el entorno', () => {
    const env = readEnv({
      SUPABASE_URL: 'https://ejemplo.test',
      SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_EJEMPLO',
      SUPABASE_SECRET_KEY: 'sb_secret_EJEMPLO',
      FRONTEND_ORIGINS: origen,
      PWA_ORIGIN: origen,
      STRIPE_SANDBOX_ENABLED: 'true',
      STRIPE_SECRET_KEY: 'rk_test_EJEMPLO',
      STRIPE_WEBHOOK_SECRET: 'whsec_EJEMPLO',
    });
    expect(env.STRIPE_SANDBOX_ENABLED).toBe(true);
  });

  it('permite cotizar únicamente Avanzada y distingue los cupos pactados del uso actual', async () => {
    const codigo = 'gestion_comunitaria_avanzada_mensual';
    const version = 'fec2b7de-7100-40dc-9c47-36fef30a8a0c';
    const cotizaciones = [
      {
        codigo,
        nombre: 'Gestión Comunitaria Avanzada',
        periodicidad: 'mensual',
        estado: 'solicitada',
        importe_centavos: null,
        moneda: 'USD',
        cuidadores: 3,
        envejecientes: 4,
        usuarios: null,
        familiares: null,
        limites: null,
        version: null,
      },
      {
        codigo: 'gestion_comunitaria_avanzada_anual',
        nombre: 'Gestión Comunitaria Avanzada',
        periodicidad: 'anual',
        estado: 'cotizada',
        importe_centavos: 95000,
        moneda: 'USD',
        cuidadores: 3,
        envejecientes: 4,
        usuarios: 5,
        familiares: 1,
        limites: { envejecientes: 30, usuarios: 40, cuidadores: 25, familiares: null },
        version,
      },
    ];
    const { http, rpc } = app({
      tipo: 'organizacion',
      rol: 'administrador',
      handlers: {
        api_stripe_solicitar_cotizacion: () => ({ cotizaciones }),
        api_stripe_cotizaciones: () => ({ cotizaciones }),
      },
    });
    await conSesion(request(http).post(`${base}/cotizaciones`))
      .send({ codigo: 'operacion_base_mensual' })
      .expect(422);
    expect(rpc.mock.calls.some(([nombre]) => nombre === 'api_stripe_solicitar_cotizacion')).toBe(
      false,
    );
    await conSesion(request(http).post(`${base}/cotizaciones`))
      .send({ codigo, cuidadores: 100 })
      .expect(422);
    const res = await conSesion(request(http).post(`${base}/cotizaciones`))
      .send({ codigo })
      .expect(201);
    expect(res.body.data.cotizaciones).toEqual(cotizaciones);
    expect(rpc).toHaveBeenCalledWith('api_stripe_solicitar_cotizacion', {
      p_cuenta_id: '7',
      p_codigo: codigo,
    });
    const consulta = await conSesion(request(http).get(`${base}/cotizaciones`)).expect(200);
    expect(consulta.body.data.cotizaciones).toEqual(cotizaciones);
  });

  it('distingue los términos de la cotización publicada de los de un trámite anterior', async () => {
    const codigo = 'gestion_comunitaria_avanzada_anual';
    const vigente = { envejecientes: 30, usuarios: 40, cuidadores: 25, familiares: null };
    const ofertaActual = {
      codigo,
      nombre: 'Gestión Comunitaria Avanzada',
      periodicidad: 'anual',
      importe_centavos: 95000,
      moneda: 'USD',
      funcionalidades: ['reportes_avanzados'],
      limites: vigente,
      version: 'fec2b7de-7100-40dc-9c47-36fef30a8a0c',
      en_curso: true,
      publicada: false,
      actual: false,
    };
    const ofertaPublicada = {
      ...ofertaActual,
      limites: { ...vigente, cuidadores: 30 },
      version: '783ae9ab-9ce2-4da5-90c1-98dad6a1e73b',
      en_curso: false,
      publicada: true,
    };
    const { http } = app({
      tipo: 'organizacion',
      rol: 'administrador',
      handlers: {
        api_stripe_gestion: () => ({
          es_titular: true,
          estado: 'vencida',
          limites: vigente,
          acceso_operativo: false,
          vigencia_hasta: null,
          cancelacion_programada: false,
          suscripcion_stripe: false,
          puede_modificar: false,
          checkout_en_curso: codigo,
          ofertas: [{ ...ofertaActual, price_id: 'price_Interno' }, ofertaPublicada],
        }),
      },
    });
    const res = await conSesion(request(http).get(`${base}/gestion`)).expect(200);
    expect(res.body.data).toMatchObject({
      limites: vigente,
      checkout_en_curso: codigo,
      ofertas: [
        {
          limites: ofertaActual.limites,
          version: ofertaActual.version,
          publicada: false,
          en_curso: true,
        },
        {
          limites: ofertaPublicada.limites,
          version: ofertaPublicada.version,
          publicada: true,
          en_curso: false,
        },
      ],
    });
    expect(res.body.data.ofertas[0]).not.toHaveProperty('price_id');
  });

  it('contrata Operación Base con Checkout y el precio general verificado', async () => {
    const codigo = 'operacion_base_mensual';
    const { http, rpc, stripe } = app({ tipo: 'organizacion', rol: 'administrador' });
    await checkout(http, { oferta: codigo }).expect(201);
    expect(rpc).toHaveBeenCalledWith('api_stripe_preparar_checkout', {
      p_cuenta_id: '7',
      p_oferta: codigo,
    });
    expect(stripe.createCheckout).toHaveBeenCalledWith(
      expect.objectContaining({ line_items: [{ price: price.id, quantity: 1 }] }),
      expect.any(String),
    );
  });

  it('reenvía la versión de una tarifa directa para que el servidor detecte cambios', async () => {
    const codigo = 'operacion_base_mensual';
    const version = 'fec2b7de-7100-40dc-9c47-36fef30a8a0c';
    const { http, rpc, stripe } = app({
      tipo: 'organizacion',
      rol: 'administrador',
      handlers: {
        api_stripe_preparar_cambio: () => {
          throw mapRpcError({ code: 'P0001', message: 'CR_STRIPE_COTIZACION_ACTUALIZADA' });
        },
      },
    });
    await checkout(http, { oferta: codigo, version }).expect(201);
    const res = await conSesion(request(http).post(`${base}/cambio-plan`))
      .send({ oferta: codigo, version })
      .expect(409);
    expect(res.body.error.code).toBe('QUOTE_UPDATED');
    for (const rpcNombre of ['api_stripe_preparar_checkout', 'api_stripe_preparar_cambio']) {
      expect(rpc).toHaveBeenCalledWith(rpcNombre, {
        p_cuenta_id: '7',
        p_oferta: codigo,
        p_version: version,
      });
    }
    expect(stripe.updateSubscription).not.toHaveBeenCalled();
  });

  it('verifica la versión de Avanzada antes de abrir Stripe o cambiar la suscripción', async () => {
    const codigo = 'gestion_comunitaria_avanzada_mensual';
    const version = 'fec2b7de-7100-40dc-9c47-36fef30a8a0c';
    const cotizacionActualizada = () => {
      throw mapRpcError({ code: 'P0001', message: 'CR_STRIPE_COTIZACION_ACTUALIZADA' });
    };
    const { http, rpc, stripe } = app({
      tipo: 'organizacion',
      rol: 'administrador',
      handlers: {
        api_stripe_preparar_checkout: cotizacionActualizada,
        api_stripe_preparar_cambio: cotizacionActualizada,
      },
    });
    await checkout(http, { oferta: codigo, version: 'Price de Stripe' }).expect(422);
    for (const [ruta, funcion] of [
      ['checkout', 'api_stripe_preparar_checkout'],
      ['cambio-plan', 'api_stripe_preparar_cambio'],
    ]) {
      const res = await conSesion(request(http).post(`${base}/${ruta}`))
        .send({ oferta: codigo, version })
        .expect(409);
      expect(res.body.error.code).toBe('QUOTE_UPDATED');
      expect(rpc).toHaveBeenCalledWith(funcion, {
        p_cuenta_id: '7',
        p_oferta: codigo,
        p_version: version,
      });
    }
    expect(stripe.retrievePrice).not.toHaveBeenCalled();
    expect(stripe.createCheckout).not.toHaveBeenCalled();
  });
});

describe('webhook de Stripe', () => {
  it('comprueba los bytes originales antes de conciliar una factura pagada', async () => {
    const { http, stripe, stripeSystemRpc, audit } = app();
    stripe.verifyEvent.mockReturnValue(evento('invoice.paid', invoice));
    const crudo = '{  "evento": "prueba"  }\n';
    await recibido(http, crudo).expect(204);
    expect(stripe.verifyEvent).toHaveBeenCalledWith(Buffer.from(crudo), 'firma-simulada');
    expect(stripeSystemRpc).toHaveBeenCalledWith('api_stripe_procesar_evento', {
      p_evento_id: 'evt_Prueba',
      p_tipo: 'invoice.paid',
      p_fecha: date.toISOString(),
      p_datos: expect.objectContaining({
        intento_id: intento,
        suscripcion_id: subscription.id,
        factura_id: invoice.id,
        cargo_id: 'ch_CuidaRed',
        price_id: price.id,
        importe_centavos: 950,
        moneda: 'USD',
      }),
    });
    expect(JSON.stringify(audit.mock.calls)).not.toContain('firma-simulada');
  });

  it('ignora la redirección de Checkout y facturas sin pago verificable', async () => {
    const { http, stripe, stripeSystemRpc } = app();
    stripe.verifyEvent.mockReturnValueOnce(evento('checkout.session.completed', session));
    await recibido(http).expect(204);
    stripe.verifyEvent.mockReturnValueOnce(evento('invoice.paid', invoice));
    stripe.listInvoicePayments.mockResolvedValueOnce([]);
    await recibido(http).expect(204);
    expect(stripeSystemRpc).not.toHaveBeenCalled();
  });

  it('rechaza un evento live y no consulta al proveedor', async () => {
    const { http, stripe, stripeSystemRpc } = app();
    stripe.verifyEvent.mockReturnValueOnce(evento('invoice.paid', invoice, true));
    await recibido(http).expect(400);
    expect(stripe.retrieveInvoice).not.toHaveBeenCalled();
    expect(stripeSystemRpc).not.toHaveBeenCalled();
  });

  it('procesa una factura de cambio con cargo y crédito sin extenderse según los importes del cliente', async () => {
    const { http, stripe, stripeSystemRpc } = app();
    const nuevo = 'price_Integral';
    stripe.verifyEvent.mockReturnValueOnce(evento('invoice.paid', invoice));
    stripe.retrieveInvoice.mockResolvedValueOnce({
      ...invoice,
      billing_reason: 'subscription_update',
      amount_paid: 200,
      amount_due: 200,
    });
    stripe.listInvoiceLines.mockResolvedValueOnce([
      { ...linea, amount: -600 },
      { ...linea, amount: 800, pricing: { price_details: { price: nuevo } } },
    ]);
    stripe.listInvoicePayments.mockResolvedValueOnce([{ ...invoicePayment, amount_paid: 200 }]);
    await recibido(http).expect(204);
    expect(stripeSystemRpc).toHaveBeenCalledWith(
      'api_stripe_procesar_evento',
      expect.objectContaining({
        p_datos: expect.objectContaining({
          price_id: nuevo,
          es_prorrateo: true,
          importe_centavos: 200,
        }),
      }),
    );
  });
});

describe('gestión del titular', () => {
  const precioNuevo = { ...price, id: 'price_Integral' };
  const cambioDto = {
    cambio_id: intento,
    subscription_id: subscription.id,
    price_id: precioNuevo.id,
    price_id_actual: price.id,
    importe_centavos: 950,
    moneda: 'USD',
    periodicidad: 'mensual',
    modo: 'inmediato',
    efectivo_en: date.toISOString(),
    vigencia_hasta: date.toISOString(),
    schedule_id: null,
  };
  it('cambia el precio con prorrateo pendiente hasta que Stripe confirme', async () => {
    const invoiceUrl = 'https://invoice.stripe.com/i/confirmar';
    const { http, stripe, stripeSystemRpc } = app({
      handlers: {
        api_stripe_preparar_cambio: () => cambioDto,
      },
    });
    stripe.retrievePrice.mockResolvedValueOnce(precioNuevo);
    stripe.updateSubscription.mockResolvedValueOnce({
      ...subscription,
      latest_invoice: invoice.id,
      pending_update: {},
    });
    stripe.retrieveInvoice.mockResolvedValueOnce({ ...invoice, hosted_invoice_url: invoiceUrl });
    const res = await conSesion(request(http).post(`${base}/cambio-plan`))
      .send({ oferta })
      .expect(202);
    expect(res.body).toEqual({ data: { url: invoiceUrl, modo: 'inmediato' } });
    expect(stripe.updateSubscription).toHaveBeenCalledWith(
      subscription.id,
      {
        items: [{ id: 'si_CuidaRed', price: precioNuevo.id, quantity: 1 }],
        payment_behavior: 'pending_if_incomplete',
        proration_behavior: 'always_invoice',
        proration_date: timestamp,
      },
      `cuidared:cambiar:${intento}`,
    );
    expect(stripeSystemRpc.mock.calls).toEqual([
      [
        'api_stripe_asociar_cambio',
        {
          p_cambio_id: intento,
          p_factura_id: invoice.id,
        },
      ],
    ]);
  });

  it('rechaza un cambio inmediato que no genera un cargo prorrateado', async () => {
    const { http, stripe, stripeSystemRpc } = app({
      handlers: { api_stripe_preparar_cambio: () => cambioDto },
    });
    stripe.retrievePrice.mockResolvedValueOnce(precioNuevo);
    stripe.createInvoicePreview.mockResolvedValueOnce({
      livemode: false,
      amount_due: 1900,
      currency: 'usd',
      lines: {
        has_more: false,
        data: [{ amount: -50, parent: { subscription_item_details: { proration: true } } }],
      },
    });
    await conSesion(request(http).post(`${base}/cambio-plan`))
      .send({ oferta })
      .expect(409);
    expect(stripe.updateSubscription).not.toHaveBeenCalled();
    expect(stripeSystemRpc).toHaveBeenCalledWith('api_stripe_descartar_prevision', {
      p_cambio_id: intento,
    });
  });

  it('programa un cambio al corte con prorrateo deshabilitado en ambas fases', async () => {
    const { http, stripe, stripeSystemRpc } = app({
      handlers: { api_stripe_preparar_cambio: () => ({ ...cambioDto, modo: 'proximo_corte' }) },
    });
    const schedule = {
      id: 'sub_sched_CuidaRed',
      livemode: false,
      subscription: subscription.id,
      current_phase: { start_date: timestamp - 10, end_date: timestamp },
    };
    stripe.retrievePrice.mockResolvedValueOnce(precioNuevo);
    stripe.retrieveSubscription.mockResolvedValueOnce({
      ...subscription,
      items: {
        has_more: false,
        data: [{ ...subscription.items.data[0], current_period_end: timestamp }],
      },
    });
    stripe.createScheduleFromSubscription.mockResolvedValueOnce(schedule);
    stripe.updateSchedule.mockResolvedValueOnce(schedule);
    const res = await conSesion(request(http).post(`${base}/cambio-plan`))
      .send({ oferta })
      .expect(202);
    expect(res.body.data).toEqual({ url: null, modo: 'proximo_corte' });
    expect(stripe.updateSubscription).not.toHaveBeenCalled();
    const [, params] = stripe.updateSchedule.mock.calls[0];
    expect(params.proration_behavior).toBe('none');
    expect(params.phases.map(({ proration_behavior }) => proration_behavior)).toEqual([
      'none',
      'none',
    ]);
    expect(params.phases[1]).toMatchObject({
      start_date: timestamp,
      items: [{ price: precioNuevo.id, quantity: 1 }],
    });
    expect(stripeSystemRpc).toHaveBeenCalledWith('api_stripe_asociar_programacion', {
      p_cambio_id: intento,
      p_schedule_id: schedule.id,
    });
  });

  it('confirma en Stripe el fin de la renovación antes de transferir la cuenta', async () => {
    const pasos = [];
    const { http, stripe, stripeSystemRpc } = app({
      operativa: true,
      handlers: {
        api_stripe_preparar_transferencia: () => {
          pasos.push('validar titular y destino');
          return { subscription_id: subscription.id };
        },
        api_transferir_titularidad: () => {
          pasos.push('transferir titularidad');
          return { cuenta_id: '7', membresia_id: '12', usuario_titular_id: usuarioId };
        },
      },
    });
    stripe.updateSubscription.mockImplementationOnce(async () => {
      pasos.push('cancelar renovación');
      return { ...subscription, cancel_at_period_end: true };
    });
    stripeSystemRpc.mockImplementationOnce(async () => {
      pasos.push('guardar cancelación');
    });
    await conSesion(request(http).post('/api/v1/cuentas/7/titularidad'))
      .send({ membresia_id: '12' })
      .expect(200);
    expect(pasos).toEqual([
      'validar titular y destino',
      'cancelar renovación',
      'guardar cancelación',
      'transferir titularidad',
    ]);
  });
});
