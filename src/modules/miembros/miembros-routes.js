/* Miembros, roles, invitaciones, titularidad y cuidadores · ID02/RF-11/RF-12. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { businessError } from '../../lib/business-errors.js';
import { paginatedResponse } from '../../lib/collection-query.js';
import { AppError } from '../../lib/errors.js';
import { ROLES_POR_TIPO } from '../cuentas/permisos.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import './miembros-errors.js';
import { createMiembrosRepository } from './miembros-repository.js';
import {
  cambiarRolSchema,
  cuidadorSchema,
  invitarSchema,
  listarMiembrosQuery,
  parse,
  readRouteId,
  requireEmptyBody,
  titularidadSchema,
} from './miembros-schemas.js';
import { invitarMiembro } from './miembros-service.js';

const sinPermiso = () =>
  new AppError(403, 'FORBIDDEN', 'No tienes permiso para realizar esta acción.');

/** El rol debe existir en el tipo de cuenta (la RPC lo vuelve a comprobar contra la matriz sembrada). */
function requireRolDelTipo(res, rol) {
  if (!ROLES_POR_TIPO[res.locals.cuenta.tipo]?.includes(rol)) {
    throw businessError('CR_ROL_NO_PERMITIDO');
  }
}

// Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió res.locals.cuenta con el JWT del usuario).
export function createMiembrosRouter({ audit, adminGateway = null }) {
  const router = Router({ mergeParams: true });
  // Primero se corta temprano con el permiso del contexto; la RPC de cada operación vuelve a autorizar.
  const gestionarMiembros = requirePermiso('usuarios:gestionar');
  const gestionarCuidadores = requirePermiso('cuidadores:gestionar');
  // Cada invitación puede enviar un correo y confirma si un correo ya tiene perfil: se limita por persona que invita.
  const limitarInvitaciones = rateLimit({
    windowMs: 15 * 60_000,
    limit: 30,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    keyGenerator: (_req, res) => res.locals.actorId ?? 'anonimo',
    handler: (_req, _res, next) =>
      next(new AppError(429, 'RATE_LIMITED', 'Espera un momento antes de intentar de nuevo.')),
  });

  const repoDe = (res) => createMiembrosRepository(res.locals.access.repository);
  const cuentaDe = (res) => Number(res.locals.cuenta.cuentaId);
  // Auditoría técnica sin datos personales: actor, acción y resultado (RF-21).
  const registrar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  /* ───── Miembros ───── */

  router.get('/miembros', gestionarMiembros, async (req, res) => {
    const query = listarMiembrosQuery(req.query);
    const { items, total } = await repoDe(res).listar(cuentaDe(res), query);
    res.json(paginatedResponse(items, { ...query, total }));
  });

  router.post('/miembros', gestionarMiembros, limitarInvitaciones, async (req, res) => {
    const input = parse(invitarSchema, req.body);
    requireRolDelTipo(res, input.rol);
    const { miembro, usuarioExistente } = await invitarMiembro(
      { repository: repoDe(res), adminGateway },
      cuentaDe(res),
      input,
    );
    registrar(res, 'miembro.invitado');
    res.status(201).json({ data: { ...miembro, usuario_existente: usuarioExistente } });
  });

  router.get('/miembros/:membresiaId', gestionarMiembros, async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    res.json({ data: await repoDe(res).detalle(cuentaDe(res), membresiaId) });
  });

  // Cambio de rol: cierra la membresía actual y abre otra (historial); devuelve la nueva.
  router.patch('/miembros/:membresiaId', gestionarMiembros, async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    const { rol } = parse(cambiarRolSchema, req.body);
    requireRolDelTipo(res, rol);
    const data = await repoDe(res).cambiarRol(cuentaDe(res), membresiaId, rol);
    registrar(res, 'miembro.rol_cambiado');
    res.json({ data });
  });

  router.post('/miembros/:membresiaId/desactivar', gestionarMiembros, async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    requireEmptyBody(req.body);
    const data = await repoDe(res).desactivar(cuentaDe(res), membresiaId);
    registrar(res, 'miembro.desactivado');
    res.json({ data });
  });

  router.post('/miembros/:membresiaId/reactivar', gestionarMiembros, async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    requireEmptyBody(req.body);
    const data = await repoDe(res).reactivar(cuentaDe(res), membresiaId);
    registrar(res, 'miembro.reactivado');
    res.json({ data });
  });

  /* ───── Titularidad: solo el titular actual ───── */

  router.post('/titularidad', gestionarMiembros, async (req, res) => {
    if (!res.locals.cuenta.esTitular) throw sinPermiso();
    const { membresia_id: membresiaId } = parse(titularidadSchema, req.body);
    const data = await repoDe(res).transferirTitularidad(cuentaDe(res), membresiaId);
    registrar(res, 'cuenta.titularidad_transferida');
    res.json({ data });
  });

  /* ───── Perfil Cuidador (RF-12) ───── */

  // `data` es el perfil vigente de la persona en esta cuenta o null si todavía no tiene.
  router.get('/miembros/:membresiaId/cuidador', gestionarCuidadores, async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    res.json({ data: await repoDe(res).obtenerCuidador(cuentaDe(res), membresiaId) });
  });

  router.post('/miembros/:membresiaId/cuidador', gestionarCuidadores, async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    const input = parse(cuidadorSchema, req.body);
    const data = await repoDe(res).guardarCuidador(cuentaDe(res), membresiaId, input);
    registrar(res, 'cuidador.guardado');
    res.json({ data });
  });

  router.post(
    '/miembros/:membresiaId/cuidador/finalizar',
    gestionarCuidadores,
    async (req, res) => {
      const membresiaId = readRouteId(req.params.membresiaId);
      requireEmptyBody(req.body);
      const data = await repoDe(res).finalizarCuidador(cuentaDe(res), membresiaId);
      registrar(res, 'cuidador.finalizado');
      res.json({ data });
    },
  );

  return router;
}
