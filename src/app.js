/* Aplicación Express y defensas HTTP · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
import { randomUUID } from 'node:crypto';
import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import { rateLimit } from 'express-rate-limit';
import { AppError } from './lib/errors.js';
import { createAccessRouter } from './modules/access/access-routes.js';

export function createApp({ env, gateway, audit }) {
  const app = express();
  app.disable('x-powered-by');
  // No confiar en X-Forwarded-For sin conocer y configurar el proxy de despliegue.
  app.set('trust proxy', false);
  app.use((req, res, next) => {
    res.locals.requestId = randomUUID();
    res.set('X-Request-Id', res.locals.requestId);
    res.set('Cache-Control', 'no-store');
    next();
  });
  app.use(helmet());
  app.use(
    cors({
      origin(origin, callback) {
        if (!origin || env.origins.includes(origin)) return callback(null, true);
        callback(new AppError(403, 'ORIGIN_DENIED', 'Origen no permitido.'));
      },
      methods: ['GET', 'POST', 'PATCH', 'OPTIONS'],
      allowedHeaders: ['Authorization', 'Content-Type'],
      exposedHeaders: ['X-Request-Id'],
      credentials: false,
    }),
  );
  app.use(
    rateLimit({
      windowMs: 60_000,
      limit: 120,
      standardHeaders: 'draft-8',
      legacyHeaders: false,
      handler: (_req, _res, next) =>
        next(new AppError(429, 'RATE_LIMITED', 'Espera un momento antes de intentar de nuevo.')),
    }),
  );
  app.use(express.json({ limit: '16kb', strict: true }));
  app.get('/health/live', (_req, res) => res.json({ status: 'ok' }));
  app.use('/api/v1', createAccessRouter({ gateway, audit }));
  app.use((_req, _res, next) => next(new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.')));
  app.use((err, req, res, _next) => {
    let error = err;
    if (err.type === 'entity.parse.failed')
      error = new AppError(400, 'INVALID_JSON', 'JSON inválido.');
    if (err.type === 'entity.too.large')
      error = new AppError(413, 'BODY_TOO_LARGE', 'Solicitud demasiado grande.');
    const known = error instanceof AppError;
    const status = known ? error.status : 500;
    const code = known ? error.code : 'INTERNAL_ERROR';
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.actorId,
      action: 'api.request',
      result: status < 500 ? 'denied' : 'error',
      code,
    });
    res.status(status).json({
      error: { code, message: known ? error.message : 'No se pudo completar la operación.' },
      requestId: res.locals.requestId,
    });
  });
  return app;
}
