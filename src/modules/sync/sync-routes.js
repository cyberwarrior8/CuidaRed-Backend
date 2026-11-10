/* Sincronización de visitas sin conexión (LWW, idempotencia) · ID04/RF-10. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { AppError } from '../../lib/errors.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import { createSyncRepository } from './sync-repository.js';
import { leerLote, uuidParam } from './sync-schemas.js';
import { createSyncService } from './sync-service.js';

/*
 * Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió membresía, rol y permisos en res.locals.cuenta). Las reglas
 * viven en las RPC, que vuelven a autorizar cada operación (membresía, sync:usar, acceso operativo, permiso, alcance sobre
 * cada adulto y participación): una captura sin conexión no autoriza a quien perdió el acceso.
 *
 *   POST /sync               sync:usar   lote de 1 a 25 operaciones; 200 con un resultado por operación
 *   GET  /sync/:idCliente    sync:usar   resultado de una operación propia (para quien perdió la respuesta)
 *
 * Contrato y decisiones (D16, propuesta): docs/contratos/sync.md.
 */

// POST no usa requirePermiso: en una cuenta vencida no se corta la petición, cada operación se rechaza con
// SUBSCRIPTION_INACTIVE (D07) y queda registrada, de modo que el cliente conserva su cola y reintenta al renovar.
function requireSyncUsar(_req, res, next) {
  if (!res.locals.cuenta.permisos.has('sync:usar')) {
    throw new AppError(403, 'FORBIDDEN', 'No tienes permiso para realizar esta acción.');
  }
  next();
}

export function createSyncRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const service = (res) =>
    createSyncService(createSyncRepository(res.locals.access.repository.rpc), { audit });

  router.post('/sync', requireSyncUsar, async (req, res) => {
    const operaciones = leerLote(req.body);
    const resultados = await service(res).procesar(res.locals.cuenta.cuentaId, operaciones, {
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
    });
    res.json({ data: { resultados } });
  });

  router.get('/sync/:idCliente', requirePermiso('sync:usar'), async (req, res) => {
    const resultado = await service(res).obtener(
      res.locals.cuenta.cuentaId,
      uuidParam(req.params.idCliente),
    );
    res.json({ data: resultado });
  });

  return router;
}
