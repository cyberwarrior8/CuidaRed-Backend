/* API de suscripciones personales Web Push · RF-18/RF-21. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { AppError } from '../../lib/errors.js';
import { createWebPushRepository } from './web-push-repository.js';
import { dispositivoSchema, leerSuscripcion, registroSchema } from './web-push-schemas.js';

export function createWebPushRouter({ env, audit }) {
  const router = Router();
  const clavePublica = env.WEB_PUSH_ENABLED ? (env.WEB_PUSH_PUBLIC_KEY ?? null) : null;
  const repo = (res) => createWebPushRepository(res.locals.access.repository.rpc);
  const registrarAuditoria = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  router.get('/configuracion', (_req, res) => {
    res.json({ data: { habilitado: clavePublica !== null, clave_publica: clavePublica } });
  });
  router.post('/suscripciones', async (req, res) => {
    if (clavePublica === null) {
      throw new AppError(503, 'PUSH_DISABLED', 'Las notificaciones Web Push no están disponibles.');
    }
    await repo(res).registrar(leerSuscripcion(registroSchema, req.body));
    registrarAuditoria(res, 'web_push.suscripcion_registrada');
    res.status(204).end();
  });
  router.post('/suscripciones/estado', async (req, res) => {
    const { endpoint } = leerSuscripcion(dispositivoSchema, req.body);
    const data = await repo(res).estado(endpoint);
    res.json({ data });
  });
  router.post('/suscripciones/revocar', async (req, res) => {
    const { endpoint } = leerSuscripcion(dispositivoSchema, req.body);
    await repo(res).revocar(endpoint);
    registrarAuditoria(res, 'web_push.suscripcion_revocada');
    res.status(204).end();
  });
  return router;
}
