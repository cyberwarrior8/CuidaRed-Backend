/* Listados de alertas, casos prioritarios y avisos internos. © 2026 Equipo CuidaRed – INTEC. Todos los derechos reservados. */
import { Router } from 'express';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import { createAlertasRepository } from './alertas-repository.js';
import {
  leerEntrada,
  leerId,
  queryAlertas,
  queryAvisos,
  queryCasos,
  resolverAlerta,
  sinCuerpo,
} from './alertas-schemas.js';

export function createAlertasRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const repo = (res) => createAlertasRepository(res.locals.access.repository.rpc);
  const cuenta = (res) => res.locals.cuenta.cuentaId;
  const ver = requirePermiso('alertas:ver');
  const registrar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  router.get('/alertas', ver, async (req, res) => {
    res.json(await repo(res).listar(cuenta(res), queryAlertas(req.query)));
  });
  router.get('/alertas/:alertaId', ver, async (req, res) => {
    res.json({ data: await repo(res).detalle(cuenta(res), leerId(req.params.alertaId)) });
  });
  router.post(
    '/alertas/:alertaId/resolver',
    requirePermiso('alertas:gestionar', 'alertas:cerrar'),
    async (req, res) => {
      const { accion_tomada } = leerEntrada(resolverAlerta, req.body);
      const data = await repo(res).resolver(
        cuenta(res),
        leerId(req.params.alertaId),
        accion_tomada,
      );
      registrar(res, 'alerta.resuelta');
      res.json({ data });
    },
  );
  router.post(
    '/alertas/:alertaId/en-atencion',
    requirePermiso('alertas:gestionar'),
    async (req, res) => {
      leerEntrada(sinCuerpo, req.body ?? {});
      const data = await repo(res).enAtencion(cuenta(res), leerId(req.params.alertaId));
      registrar(res, 'alerta.en_atencion');
      res.json({ data });
    },
  );
  router.get('/casos-prioritarios', ver, async (req, res) => {
    res.json(await repo(res).casos(cuenta(res), queryCasos(req.query)));
  });
  router.get('/notificaciones-alerta', ver, async (req, res) => {
    res.json(await repo(res).avisos(cuenta(res), queryAvisos(req.query)));
  });
  router.post('/notificaciones-alerta/:notificacionId/leer', ver, async (req, res) => {
    leerEntrada(sinCuerpo, req.body ?? {});
    const data = await repo(res).marcarLeida(cuenta(res), leerId(req.params.notificacionId));
    registrar(res, 'notificacion_alerta.leida');
    res.json({ data });
  });
  return router;
}
