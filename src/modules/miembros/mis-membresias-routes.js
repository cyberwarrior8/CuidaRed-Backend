/* Aceptar o rechazar membresías propias · ID02/RF-11. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import './miembros-errors.js';
import { createMiembrosRepository } from './miembros-repository.js';
import { readRouteId, requireEmptyBody } from './miembros-schemas.js';

/*
 * Rutas /me/membresias/* a nivel de /api/v1 (solo requireSession: la persona invitada aún no tiene membresía activa
 * en esa cuenta, así que no hay contexto de cuenta). La RPC solo actúa sobre una membresía PENDIENTE de quien llama
 * (auth.uid()): la de otra persona, o una que no existe, es 404. Cubre también la invitación de una persona nueva
 * que activó su cuenta por el flujo de la fase 1: al entrar, `GET /me` y api_mis_cuentas muestran sus pendientes.
 */
export function createMisMembresiasRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const registrar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });
  const repoDe = (res) => createMiembrosRepository(res.locals.access.repository);

  router.post('/me/membresias/:membresiaId/aceptar', async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    requireEmptyBody(req.body);
    const data = await repoDe(res).aceptarPropia(membresiaId);
    registrar(res, 'membresia.aceptada');
    res.json({ data });
  });

  router.post('/me/membresias/:membresiaId/rechazar', async (req, res) => {
    const membresiaId = readRouteId(req.params.membresiaId);
    requireEmptyBody(req.body);
    await repoDe(res).rechazarPropia(membresiaId);
    registrar(res, 'membresia.rechazada');
    res.status(204).end();
  });

  return router;
}
