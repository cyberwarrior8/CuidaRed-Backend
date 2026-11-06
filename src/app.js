/* Aplicación Express y defensas HTTP · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
/*
 * /api/v1 exige sesión válida (requireSession, una vez por petición). Las rutas de una cuenta cuelgan de
 * /api/v1/cuentas/:cuentaId y pasan por requireCuenta, que resuelve rol, permisos y acceso operativo en la base.
 */
import { randomUUID } from 'node:crypto';
import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import { rateLimit } from 'express-rate-limit';
import { AppError } from './lib/errors.js';
import { createAccessRouter } from './modules/access/access-routes.js';
import { requireSession } from './modules/access/require-session.js';
import { createAgendaRouter } from './modules/agenda/agenda-routes.js';
import { createCatalogosRouter } from './modules/catalogos/catalogos-routes.js';
import { createCuentaRouter } from './modules/cuentas/cuenta-routes.js';
import { createCuentasRouter } from './modules/cuentas/cuentas-routes.js';
import { requireCuenta } from './modules/cuentas/require-cuenta.js';
import { createEnvejecientesRouter } from './modules/envejecientes/envejecientes-routes.js';
import { createMiembrosRouter } from './modules/miembros/miembros-routes.js';
import { createPublicoRouter } from './modules/publico/publico-routes.js';
import { createMisMembresiasRouter } from './modules/miembros/mis-membresias-routes.js';
import { createSeguimientoRouter } from './modules/seguimiento/seguimiento-routes.js';
import { createSyncRouter } from './modules/sync/sync-routes.js';
import { createVisitasRouter } from './modules/visitas/visitas-routes.js';

export function createApp({ env, gateway, audit, adminGateway = null, now = () => new Date() }) {
  const deps = { env, gateway, audit, adminGateway, now };
  const app = express();
  app.disable('x-powered-by');
  // No confiar en X-Forwarded-For sin conocer y configurar el proxy de despliegue.
  app.set('trust proxy', false);
  // CR-162: conservar filter[campo] como clave literal y detectar valores repetidos.
  app.set('query parser', 'simple');
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
  const api = express.Router();
  // Únicas rutas sin sesión: /publico/* (cada ruta aplica su propio límite y validación).
  api.use('/publico', createPublicoRouter(deps));
  api.use(requireSession(gateway));
  api.use(createAccessRouter(deps));
  api.use(createCatalogosRouter(deps));
  api.use(createCuentasRouter(deps));
  api.use(createMisMembresiasRouter(deps));
  // Rutas de una cuenta: el contexto (rol, permisos, vigencia) se resuelve una vez y lo usan todos los módulos.
  const enCuenta = express.Router({ mergeParams: true });
  enCuenta.use(requireCuenta());
  enCuenta.use(createCuentaRouter(deps));
  enCuenta.use(createMiembrosRouter(deps));
  enCuenta.use(createEnvejecientesRouter(deps));
  enCuenta.use(createSeguimientoRouter(deps));
  enCuenta.use(createVisitasRouter(deps));
  enCuenta.use(createAgendaRouter(deps));
  enCuenta.use(createSyncRouter(deps));
  api.use('/cuentas/:cuentaId', enCuenta);
  app.use('/api/v1', api);
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
