/* Catálogo, Checkout, historial y eventos de Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import express, { Router } from 'express';
import { z } from 'zod';
import { createCollectionQuery, paginatedResponse } from '../../lib/collection-query.js';
import { AppError, unavailable } from '../../lib/errors.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import { parseInput } from '../cuentas/cuentas-schemas.js';
import {
  iniciarCheckout,
  procesarEventoStripe,
  programarCancelacion,
  solicitarCambioPlan,
} from './suscripciones-service.js';
import { codigoCotizacion, limitesPlan, versionOferta } from './suscripciones-schemas.js';
import './suscripciones-repository.js';

const permiso = 'cuenta:suscripcion';
const periodicidad = z.enum(['mensual', 'anual']);
const importe = z.int().nonnegative();
const moneda = z.string().regex(/^[A-Z]{3}$/);
const oferta = z.string().regex(/^[a-z][a-z0-9_-]{1,63}$/);
const estado = z.enum(['prueba', 'activa', 'vencida', 'cancelada', 'suspendida']);
const instante = z.iso.datetime({ offset: true });
const contratarOferta = z.strictObject({ oferta, version: versionOferta.optional() });
const catalogo = z.array(
  z.object({
    codigo: oferta,
    nombre: z.string(),
    limites: limitesPlan,
    funcionalidades: z.array(z.string()),
    cotizado: z.boolean().optional(),
    precios_referencia: z
      .object({ mensual: importe.positive(), anual: importe.positive() })
      .nullable(),
  }),
);
const gestion = z.object({
  es_titular: z.boolean(),
  estado,
  acceso_operativo: z.boolean(),
  limites: limitesPlan.nullable().default(null),
  vigencia_hasta: instante.nullable(),
  cancelacion_programada: z.boolean(),
  suscripcion_stripe: z.boolean(),
  puede_modificar: z.boolean(),
  checkout_en_curso: oferta.nullish(),
  cambio_en_curso: z
    .object({
      codigo: oferta,
      modo: z.enum(['inmediato', 'proximo_corte']),
      efectivo_en: instante.nullable(),
    })
    .nullish(),
  ofertas: z.array(
    z.object({
      codigo: oferta,
      nombre: z.string(),
      periodicidad,
      importe_centavos: importe.positive(),
      moneda,
      limites: limitesPlan,
      version: versionOferta.nullable().default(null),
      funcionalidades: z.array(z.string()),
      actual: z.boolean(),
      en_curso: z.boolean().default(false),
      publicada: z.boolean().default(true),
    }),
  ),
});
const historial = z.object({
  items: z.array(
    z.object({
      pago_id: z.string().regex(/^[1-9]\d*$/),
      plan: z.string(),
      periodicidad,
      importe_centavos: importe,
      moneda,
      estado: z.enum(['pendiente', 'completado', 'fallido', 'reembolsado']),
      fecha: instante,
      importe_reembolsado_centavos: importe,
    }),
  ),
  total: z.int().nonnegative(),
});
const cotizaciones = z.object({
  cotizaciones: z.array(
    z.object({
      codigo: oferta,
      nombre: z.string(),
      periodicidad,
      estado: z.enum(['sin_cotizar', 'solicitada', 'cotizada']),
      importe_centavos: importe.nullable(),
      moneda: z.literal('USD'),
      cuidadores: z.int().nonnegative(),
      envejecientes: z.int().nonnegative(),
      usuarios: z.int().nonnegative().nullable().default(null),
      familiares: z.int().nonnegative().nullable().default(null),
      limites: limitesPlan.nullable().default(null),
      version: versionOferta.nullable().default(null),
    }),
  ),
});
const paginar = createCollectionQuery({
  sortableFields: ['fecha'],
  defaultSort: '-fecha',
  tieBreaker: 'fecha',
});

function fromDatabase(schema, data) {
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw unavailable();
  return parsed.data;
}

function exigirTitular(_req, res, next) {
  if (!res.locals.cuenta.esTitular)
    throw new AppError(403, 'FORBIDDEN', 'Solo el titular puede gestionar pagos.');
  next();
}

function pagosNoDisponibles() {
  return new AppError(503, 'SANDBOX_UNAVAILABLE', 'Los pagos de prueba no están disponibles.');
}

export function createSuscripcionesRouter({ env, stripe, stripeSystemRpc, audit, now }) {
  const router = Router({ mergeParams: true });
  const configurado = !!(stripe && stripeSystemRpc);
  const acceso = requirePermiso(permiso);
  const registrar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.actorId,
      action,
      result: 'success',
    });

  router.get('/suscripcion/gestion', acceso, async (_req, res) => {
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const data = fromDatabase(gestion, await rpc('api_stripe_gestion', { p_cuenta_id: cuentaId }));
    const cambio = data.cambio_en_curso;
    res.json({
      data: {
        ...data,
        sandbox: true,
        pagos_disponibles: configurado,
        checkout_en_curso: data.checkout_en_curso ?? null,
        cambio_programado:
          cambio?.modo === 'proximo_corte' && cambio.efectivo_en
            ? { codigo: cambio.codigo, fecha: cambio.efectivo_en }
            : null,
      },
    });
  });

  router.get('/suscripcion/catalogo', acceso, async (_req, res) => {
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const data = await rpc('api_stripe_catalogo_cuenta', { p_cuenta_id: cuentaId });
    res.json({ data: fromDatabase(catalogo, data) });
  });
  router.get('/suscripcion/cotizaciones', acceso, async (_req, res) => {
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const data = await rpc('api_stripe_cotizaciones', { p_cuenta_id: cuentaId });
    res.json({ data: fromDatabase(cotizaciones, data) });
  });
  router.post('/suscripcion/cotizaciones', acceso, exigirTitular, async (req, res) => {
    const { codigo } = parseInput(z.strictObject({ codigo: codigoCotizacion }), req.body);
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const data = fromDatabase(
      cotizaciones,
      await rpc('api_stripe_solicitar_cotizacion', {
        p_cuenta_id: cuentaId,
        p_codigo: codigo,
      }),
    );
    registrar(res, 'stripe.quote_requested');
    res.status(201).json({ data });
  });

  router.get('/suscripcion/pagos', acceso, async (req, res) => {
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const query = paginar(req.query);
    const data = fromDatabase(
      historial,
      await rpc('api_stripe_pagos', {
        p_cuenta_id: cuentaId,
        p_limite: query.limit,
        p_desplazamiento: query.offset,
        p_desc: query.sort[0].direction === 'desc',
      }),
    );
    res.json(paginatedResponse(data.items, { ...query, total: data.total }));
  });

  router.post('/suscripcion/checkout', acceso, exigirTitular, async (req, res) => {
    if (!configurado) throw pagosNoDisponibles();
    const datos = parseInput(contratarOferta, req.body);
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const data = await iniciarCheckout({
      stripe,
      stripeSystemRpc,
      rpc,
      cuentaId,
      oferta: datos.oferta,
      version: datos.version,
      origen: env.PWA_ORIGIN,
      now,
    });
    registrar(res, 'stripe.checkout_started');
    res.status(201).json({ data });
  });
  router.post('/suscripcion/cambio-plan', acceso, exigirTitular, async (req, res) => {
    if (!configurado) throw pagosNoDisponibles();
    const { oferta: codigo, version } = parseInput(contratarOferta, req.body);
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    const data = await solicitarCambioPlan({
      stripe,
      stripeSystemRpc,
      rpc,
      cuentaId,
      oferta: codigo,
      version,
    });
    registrar(res, 'stripe.plan_change_requested');
    res.status(202).json({ data });
  });
  router.post('/suscripcion/cancelacion', acceso, exigirTitular, async (req, res) => {
    if (!configurado) throw pagosNoDisponibles();
    if (req.body !== undefined) parseInput(z.strictObject({}), req.body);
    const { cuentaId } = res.locals.cuenta;
    const { rpc } = res.locals.access.repository;
    await programarCancelacion({ stripe, stripeSystemRpc, rpc, cuentaId });
    registrar(res, 'stripe.cancellation_scheduled');
    res.status(204).end();
  });
  return router;
}

export function createStripeWebhookRouter({ stripe, stripeSystemRpc }) {
  const router = Router();
  // No se acepta un cuerpo ya interpretado ni descompresión que cambie los bytes firmados.
  const raw = express.raw({ type: 'application/json', limit: '256kb', inflate: false });
  router.post('/', raw, async (req, res) => {
    if (!stripe || !stripeSystemRpc) throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
    const signature = req.get('Stripe-Signature');
    if (!signature || !Buffer.isBuffer(req.body))
      throw new AppError(400, 'INVALID_STRIPE_SIGNATURE', 'No se pudo verificar el evento.');
    const event = stripe.verifyEvent(req.body, signature);
    await procesarEventoStripe({ stripe, stripeSystemRpc, event });
    res.status(204).end();
  });
  return router;
}
