/* API de sesión y perfil propio · ID01, RF-09/RF-21. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { AppError } from '../../lib/errors.js';
import { requireSession } from './require-session.js';
import { updateProfileSchema, publicProfile } from './profile-schema.js';

function parse(schema, body) {
  const result = schema.safeParse(body);
  if (!result.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return result.data;
}

export function createAccessRouter({ gateway, audit }) {
  const router = Router();
  router.use(requireSession(gateway));
  const log = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  router.get('/me', (_req, res) => {
    const { identity, profile } = res.locals.access;
    res.json({ data: { identity, profile: publicProfile(profile) } });
  });
  router.patch('/me', async (req, res) => {
    const input = parse(updateProfileSchema, req.body);
    const { repository } = res.locals.access;
    const updated = await repository.updateProfile(input);
    log(res, 'profile.updated');
    res.json({ data: publicProfile(updated) });
  });
  router.post('/session/activity', async (_req, res) => {
    const result = await res.locals.access.repository.session('actividad');
    if (!result?.vigente) throw new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');
    res.status(204).end();
  });
  router.post('/session/logout', async (_req, res) => {
    await res.locals.access.repository.session('cerrar');
    log(res, 'session.closed');
    res.status(204).end();
  });
  return router;
}
