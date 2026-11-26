/* API de administración de CuidaRed · BO-01 a BO-34. © 2026 Equipo CuidaRed – INTEC. */
import { createHash } from 'node:crypto';
import express, { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { z } from 'zod';
import { AppError, unavailable } from '../../lib/errors.js';
import { brandUrl, prepareLogo } from './backoffice-brand.js';
import { createBackofficeRepository } from './backoffice-repository.js';
import { backofficeClaims, requireBackoffice, requireRole } from './require-backoffice.js';
import { montarPreciosStripe } from '../suscripciones/suscripciones-backoffice.js';
import { correoVisitaConfigurado } from '../../config/env.js';
import { streamSignals as stream } from '../../lib/event-stream.js';
import { createBackofficeSoporteRouter } from '../soporte/soporte-routes.js';
import {
  credenciales,
  edit,
  frontendEvent,
  id,
  motivo as reasonSchema,
  parse,
  planId,
  query,
  usuario,
  variante,
} from './backoffice-schemas.js';

const all = ['super_admin', 'soporte', 'auditor'];
const operators = ['super_admin', 'soporte'];
const auditRoles = ['super_admin', 'auditor'];
const frontendMessages = {
  'javascript.error': 'Error de JavaScript en la PWA',
  'javascript.rejection': 'Operación no controlada en la PWA',
  'api.error': 'Respuesta de servidor fallida en la PWA',
  'api.network': 'Fallo de red de la PWA',
};

export function createBackofficeRouter({ env, gateway, adminGateway, recordLog, stripe }) {
  const router = Router();
  const repository = createBackofficeRepository(adminGateway);
  const limited = rateLimit({
    windowMs: 60_000,
    limit: 20,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    handler: (_req, _res, next) =>
      next(new AppError(429, 'RATE_LIMITED', 'Espera un momento antes de intentar de nuevo.')),
  });
  router.get('/marca', async (_req, res) => {
    const brand = await gateway.publico().rpc('api_publico_bo_marca');
    res.json({
      data: Object.fromEntries(
        Object.entries(brand).map(([variant, item]) => [
          variant,
          brandUrl(env, item.ruta, item.version),
        ]),
      ),
    });
  });
  router.get('/marca/eventos', (_req, res) =>
    stream(res, adminGateway, new Set(['marca', 'conexion', 'recuperado']), 120000),
  );
  router.get('/marca/correo.png', async (_req, res) => {
    const brand = await gateway.publico().rpc('api_publico_bo_marca');
    const image = brand.completo_claro;
    const url = brandUrl(env, image?.ruta, image?.version);
    if (url) return res.redirect(302, url);
    if (!env.PWA_ORIGIN) throw unavailable();
    return res.redirect(302, env.PWA_ORIGIN + '/brand/logo.png');
  });
  // Login bajo control de Express para que el bloqueo y el registro abarquen todas las instancias.
  router.post('/login', limited, async (req, res) => {
    const { email, password } = parse(credenciales, req.body);
    const key = createHash('sha256')
      .update(email.toLowerCase() + '\0' + req.ip)
      .digest('hex');
    const blocked = () =>
      new AppError(429, 'LOGIN_LOCKED', 'Demasiados intentos. Vuelve a intentar en 15 minutos.');
    if (await repository.attempt(key, 'validar')) {
      await repository.audit(null, 'login.bloqueado', 'Límite temporal de intentos', req);
      throw blocked();
    }
    try {
      const { actorId, ...session } = await gateway.passwordSession(email, password);
      const { sessionId } = backofficeClaims(session.access_token, actorId);
      if (!(await repository.admit(actorId, sessionId, req))) {
        throw new AppError(403, 'FORBIDDEN', 'Tu cuenta no tiene acceso al Backoffice.');
      }
      res.locals.actorId = actorId;
      await repository.attempt(key, 'exito');
      res.json({ data: session });
    } catch (error) {
      if (!(error instanceof AppError) || ![401, 429].includes(error.status)) throw error;
      const locked = await repository.attempt(key, 'fallo');
      await repository.audit(null, 'login.fallido', 'Credenciales rechazadas', req);
      if (locked) throw blocked();
      throw error;
    }
  });
  router.post('/telemetria', limited, async (req, res) => {
    const { evento, requestId } = parse(frontendEvent, req.body);
    let identity;
    const header = req.get('authorization');
    if (header && header.length <= 8192 && /^Bearer [^\s]+$/i.test(header)) {
      identity = await gateway.authenticate(header.slice(7));
    }
    const recorded = await recordLog({
      p_evento: {
        nivel: 'error',
        origen: 'frontend',
        request_id: requestId ?? res.locals.requestId,
        usuario_id: identity?.id,
        ruta: '/pwa',
        mensaje: frontendMessages[evento],
        detalle_sanitizado: { code: evento },
      },
    });
    if (!recorded) throw unavailable();
    res.status(204).end();
  });

  router.use(requireBackoffice(gateway, repository));
  router.use(createBackofficeSoporteRouter({ adminGateway }));
  const context = (res) => res.locals.backoffice;
  const account = (req, res) => {
    const cuenta = parse(id, req.params.cuentaId);
    res.locals.logCuenta = cuenta;
    return cuenta;
  };
  router.get('/me', (_req, res) => res.json({ data: context(res).profile }));
  montarPreciosStripe(router, { env, adminGateway, stripe, repository });
  for (const [path, action] of [
    ['ingreso', 'ingreso'],
    ['actividad', 'actividad'],
    ['salida', 'salida'],
  ]) {
    router.post('/sesion/' + path, async (req, res) => {
      const result = await repository.session(context(res), action, req);
      if (result.estado !== 'ok')
        throw new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');
      res.status(204).end();
    });
  }

  const read = (path, resource, roles = all, parameters = () => ({}), paged = false) => {
    router.get(path, requireRole(repository, ...roles), async (req, res) => {
      const filters = { ...parse(query, req.query), ...parameters(req, res) };
      const result = await repository.read(context(res), resource, filters);
      res.json(paged ? result : { data: result });
    });
  };
  read('/resumen', 'resumen');
  router.get('/supervision', requireRole(repository, ...all), async (req, res) => {
    const { meses } = parse(z.strictObject({ meses: z.enum(['6', '12']).default('6') }), req.query);
    const data = await repository.supervision(context(res), Number(meses));
    res.json({
      data: {
        ...data,
        servicios: {
          solicitudes_publicas: Boolean(env.VISITAS_PUBLICAS_HABILITADAS),
          correo: {
            habilitado: env.VISITAS_CORREO_HABILITADO !== false,
            configurado: correoVisitaConfigurado(env),
            proveedor: env.VISITAS_CORREO_PROVEEDOR === 'smtp' ? 'smtp' : 'resend',
          },
          web_push: Boolean(env.WEB_PUSH_ENABLED),
        },
      },
    });
  });
  read('/cuentas', 'cuentas', all, undefined, true);
  read('/cuentas/:cuentaId', 'detalle', all, (req, res) => ({ cuenta: account(req, res) }));
  read(
    '/cuentas/:cuentaId/pagos',
    'pagos',
    all,
    (req, res) => ({ cuenta: account(req, res) }),
    true,
  );
  read('/pruebas', 'pruebas', all, undefined, true);
  read('/planes', 'planes');
  read('/metodos', 'metodos');
  read('/configuracion', 'configuracion', auditRoles);
  read('/logs', 'logs', all, undefined, true);
  read('/logs/sync', 'logs', operators, () => ({ origen: 'sync', vista: 'sync' }), true);
  read(
    '/logs/exportacion',
    'logs',
    auditRoles,
    (req) => ({
      ...(req.query.origen === 'sync' && req.query.vista === 'sync'
        ? { vista: 'sync_exportacion' }
        : {}),
    }),
    true,
  );
  read('/logs/:id', 'log', all, (req) => ({ id: parse(id, req.params.id) }));
  read('/auditoria', 'auditoria', auditRoles, undefined, true);
  read('/auditoria/exportacion', 'auditoria', auditRoles, undefined, true);
  read(
    '/cuentas/:cuentaId/auditoria',
    'auditoria',
    all,
    (req, res) => ({ cuenta: account(req, res) }),
    true,
  );

  const mutate = (method, path, action, roles, schema, parameters) => {
    router[method](path, requireRole(repository, ...roles), async (req, res) => {
      const { motivo, ...body } = parse(schema, req.body);
      const result = await repository.mutate(
        context(res),
        action,
        { ...body, ...parameters(req, res) },
        motivo,
        req,
      );
      res.json({ data: result });
    });
  };
  const cuenta = (req, res) => ({ cuenta: account(req, res) });
  const miembro = (req, res) => ({
    ...cuenta(req, res),
    usuario: parse(usuario, req.params.usuarioId),
  });
  mutate(
    'post',
    '/cuentas/:cuentaId/estado',
    'cuenta.estado',
    operators,
    edit({ estado: z.enum(['activa', 'deshabilitada']) }),
    cuenta,
  );
  mutate(
    'patch',
    '/cuentas/:cuentaId',
    'cuenta.editar',
    operators,
    edit({
      nombre: z.string().trim().min(2).max(120),
      correo: z.email().max(120).nullable(),
      telefono: z
        .string()
        .regex(/^\+?\d{10,15}$/)
        .nullable(),
    }),
    cuenta,
  );
  mutate(
    'post',
    '/cuentas/:cuentaId/usuarios/:usuarioId/estado',
    'usuario.estado',
    operators,
    edit({ estado: z.enum(['activo', 'deshabilitado']) }),
    miembro,
  );
  mutate(
    'post',
    '/cuentas/:cuentaId/usuarios/:usuarioId/revocar',
    'usuario.revocar',
    operators,
    edit({}),
    miembro,
  );
  mutate(
    'post',
    '/cuentas/:cuentaId/extender-prueba',
    'prueba.extender',
    operators,
    edit({ dias: z.literal([7, 14, 30]) }),
    cuenta,
  );
  mutate(
    'post',
    '/cuentas/:cuentaId/cambiar-plan',
    'cuenta.cambiar_plan',
    ['super_admin'],
    edit({ planId, fechaFin: z.iso.date().optional() }),
    cuenta,
  );
  mutate(
    'post',
    '/cuentas/:cuentaId/pagos',
    'pago.registrar',
    ['super_admin'],
    edit({ monto: z.number().min(0.01).max(9999999), metodoId: planId, fecha: z.iso.date() }),
    cuenta,
  );
  mutate(
    'patch',
    '/configuracion/:id',
    'configuracion.actualizar',
    ['super_admin'],
    edit({ valor: z.int().min(0).max(3650) }),
    (req) => ({ id: parse(z.string().regex(/^[a-z_]+$/), req.params.id) }),
  );
  mutate(
    'patch',
    '/planes/:id',
    'plan.limites',
    ['super_admin'],
    edit({
      adultos: z.int().min(1).max(100000).nullable(),
      usuarios: z.int().min(1).max(100000).nullable(),
      cuidadores: z.int().min(1).max(100000).optional(),
    }),
    (req) => ({ id: parse(id, req.params.id) }),
  );
  mutate(
    'post',
    '/logos/:variante/restaurar',
    'logo.restaurar',
    ['super_admin'],
    edit({ id: z.uuid().nullable() }),
    (req) => ({ variante: parse(variante, req.params.variante) }),
  );

  router.post(
    '/cuentas/:cuentaId/usuarios/:usuarioId/recuperacion',
    requireRole(repository, ...operators),
    limited,
    async (req, res) => {
      const { motivo } = parse(edit({}), req.body);
      const scope = miembro(req, res);
      const detail = await repository.read(context(res), 'detalle', cuenta(req, res));
      const target = detail.usuarios.find((user) => user.usuario_id === scope.usuario);
      if (!target?.email)
        throw new AppError(404, 'NOT_FOUND', 'Usuario no encontrado en la cuenta.');
      await repository.mutate(context(res), 'usuario.recuperacion', scope, motivo, req);
      try {
        await repository.resetPassword(target.email);
      } catch {
        await repository.audit(
          context(res),
          'recuperacion.fallida',
          'El proveedor no pudo enviar el correo',
          req,
        );
        throw unavailable();
      }
      res.status(204).end();
    },
  );
  router.get('/logos', requireRole(repository, 'super_admin'), async (_req, res) => {
    const logos = await repository.read(context(res), 'logos');
    res.json({
      data: logos.map((logo) => ({ ...logo, url_storage: brandUrl(env, logo.ruta, logo.version) })),
    });
  });
  router.post(
    '/logos/:variante/validar',
    requireRole(repository, 'super_admin'),
    express.raw({ type: ['image/png', 'image/svg+xml'], limit: '2mb' }),
    async (req, res) => {
      const variant = parse(variante, req.params.variante);
      const { data } = await prepareLogo(req.body, req.get('content-type')?.split(';')[0], variant);
      res.set('Cache-Control', 'no-store').type('image/png').send(data);
    },
  );
  router.post(
    '/logos/:variante/publicar',
    requireRole(repository, 'super_admin'),
    express.raw({ type: ['image/png', 'image/svg+xml'], limit: '2mb' }),
    async (req, res) => {
      const variant = parse(variante, req.params.variante);
      let reason;
      try {
        reason = decodeURIComponent(req.get('X-Change-Reason') ?? '');
      } catch {
        throw new AppError(422, 'INVALID_INPUT', 'Revisa el motivo de la publicación.');
      }
      const motivo = parse(reasonSchema, reason);
      const { path, data } = await prepareLogo(
        req.body,
        req.get('content-type')?.split(';')[0],
        variant,
      );
      await repository.uploadLogo(path, data);
      const logo = await repository.mutate(
        context(res),
        'logo.publicar',
        { variante: variant, ruta: path },
        motivo,
        req,
      );
      res
        .status(201)
        .json({ data: { ...logo, url_storage: brandUrl(env, logo.ruta, logo.version) } });
    },
  );

  router.get('/eventos', async (req, res) => {
    const current = context(res);
    stream(
      res,
      adminGateway,
      new Set([
        'conexion',
        'degradado',
        'recuperado',
        'operacion',
        'soporte',
        'logs',
        'marca',
        ...(current.rol === 'soporte' ? [] : ['auditoria', 'configuracion']),
      ]),
      45000,
    );
  });
  return router;
}
