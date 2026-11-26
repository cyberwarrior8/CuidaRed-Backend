/* Solicitudes de soporte por organización y seguimiento interno. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { AppError, unavailable } from '../../lib/errors.js';
import { streamSignals } from '../../lib/event-stream.js';
import { createBackofficeRepository } from '../backoffice/backoffice-repository.js';
import { requireRole } from '../backoffice/require-backoffice.js';
import { id, usuario } from '../backoffice/backoffice-schemas.js';
import { createSoporteRepository, filtros } from './soporte-repository.js';
import { actualizar, crear, eliminar, lista, parse, responder } from './soporte-schemas.js';

export function createSoporteRouter({ adminGateway }) {
  const router = Router({ mergeParams: true });
  const cuenta = (res) => res.locals.cuenta.cuentaId;
  const rpc = (res, name, args = {}) =>
    res.locals.access.repository.rpc(name, { p_cuenta_id: cuenta(res), ...args });
  router.use('/soporte', (_req, res, next) => {
    if (res.locals.cuenta.tipo !== 'organizacion' || res.locals.cuenta.rol !== 'administrador') {
      throw new AppError(
        403,
        'FORBIDDEN',
        'Solo un administrador de la organización puede contactar a soporte.',
      );
    }
    next();
  });
  const limitar = rateLimit({
    windowMs: 15 * 60000,
    limit: 30,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    keyGenerator: (_req, res) => res.locals.actorId,
    handler: (_req, _res, next) =>
      next(new AppError(429, 'RATE_LIMITED', 'Espera unos minutos antes de enviar otro mensaje.')),
  });
  router.get('/soporte/eventos', (_req, res) =>
    streamSignals(res, adminGateway, new Set(['soporte', 'conexion', 'recuperado'])),
  );
  router.get('/soporte', async (req, res) =>
    res.json(await rpc(res, 'api_soporte_listar', filtros(parse(lista, req.query)))),
  );
  router.post('/soporte', limitar, async (req, res) => {
    const body = parse(crear, req.body);
    const data = await rpc(res, 'api_soporte_crear', {
      p_tipo: body.tipo,
      p_asunto: body.asunto,
      p_descripcion: body.descripcion,
      p_usuario_objetivo: body.usuario_objetivo_id,
    });
    res.status(201).json({ data });
  });
  router.get('/soporte/:id', async (req, res) =>
    res.json({ data: await rpc(res, 'api_soporte_detalle', { p_id: parse(id, req.params.id) }) }),
  );
  router.post('/soporte/:id/mensajes', limitar, async (req, res) => {
    const body = parse(responder, req.body);
    res.json({
      data: await rpc(res, 'api_soporte_responder', {
        p_id: parse(id, req.params.id),
        p_mensaje: body.mensaje,
        p_version: body.version,
      }),
    });
  });
  return router;
}

// Se monta después de requireBackoffice: ambas capas revalidan sesión y rol.
export function createBackofficeSoporteRouter({ adminGateway }) {
  const router = Router({ mergeParams: true });
  const auth = createBackofficeRepository(adminGateway);
  const repo = createSoporteRepository(adminGateway);
  const c = (res) => res.locals.backoffice;
  router.get('/soporte', requireRole(auth, 'super_admin', 'soporte', 'auditor'), async (req, res) =>
    res.json(await repo.listar(c(res), parse(lista, req.query))),
  );
  router.get(
    '/soporte/:id',
    requireRole(auth, 'super_admin', 'soporte', 'auditor'),
    async (req, res) => res.json({ data: await repo.detalle(c(res), parse(id, req.params.id)) }),
  );
  router.post(
    '/soporte/:id/responder',
    requireRole(auth, 'super_admin', 'soporte'),
    async (req, res) =>
      res.json({
        data: await repo.responder(c(res), parse(id, req.params.id), parse(actualizar, req.body)),
      }),
  );
  const scope = (req) => ({
    cuenta: parse(id, req.params.cuentaId),
    usuario: parse(usuario, req.params.usuarioId),
  });
  const path = '/cuentas/:cuentaId/usuarios/:usuarioId/eliminacion';
  router.get(path, requireRole(auth, 'super_admin'), async (req, res) => {
    const s = scope(req);
    res.json({ data: await repo.revision(c(res), s.cuenta, s.usuario) });
  });
  router.post(path, requireRole(auth, 'super_admin'), async (req, res) => {
    const s = scope(req);
    const body = parse(eliminar, req.body);
    const job = await repo.preparar(c(res), s.cuenta, s.usuario, body);
    if (job?.estado === 'eliminado') return res.json({ data: { eliminado: true } });
    if (!job?.operacion_id || !adminGateway?.deleteUser) throw unavailable();
    try {
      await adminGateway.deleteUser(s.usuario);
    } catch {
      const status = await repo.estado(c(res), job.operacion_id);
      if (status?.estado !== 'eliminado') throw unavailable();
    }
    const status = await repo.estado(c(res), job.operacion_id);
    if (status?.estado !== 'eliminado') throw unavailable();
    res.json({ data: { eliminado: true } });
  });
  return router;
}
