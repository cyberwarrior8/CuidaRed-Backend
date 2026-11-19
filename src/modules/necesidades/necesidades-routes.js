/* Rutas de necesidades del adulto mayor · ID05/RF-03. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import { parseBody, uuidParam } from '../seguimiento/seguimiento-schemas.js';
import './necesidades-errors.js';
import { createNecesidadesRepository } from './necesidades-repository.js';
import {
  actualizarNecesidadSchema,
  cambiarEstadoNecesidadSchema,
  crearNecesidadSchema,
  leerCandidatosNecesidadQuery,
  leerHistorialNecesidadQuery,
  leerNecesidadesQuery,
} from './necesidades-schemas.js';

export function createNecesidadesRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const ver = requirePermiso('necesidades:ver');
  const registrar = requirePermiso('necesidades:registrar');
  const actualizar = requirePermiso('necesidades:actualizar');
  const cambiar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.actorId,
      action,
      result: 'success',
    });
  const repo = (res) => {
    const { access, cuenta } = res.locals;
    return createNecesidadesRepository(access.repository.rpc, cuenta.cuentaId);
  };

  router.get('/necesidades', ver, async (req, res) => {
    const query = leerNecesidadesQuery(req.query);
    res.json(await repo(res).listar(query));
  });

  router.get('/necesidades/:necesidadId', ver, async (req, res) => {
    const data = await repo(res).obtener(uuidParam(req.params.necesidadId));
    res.json({ data });
  });

  router.get('/necesidades/:necesidadId/historial', ver, async (req, res) => {
    const query = leerHistorialNecesidadQuery(req.query);
    res.json(await repo(res).historial(uuidParam(req.params.necesidadId), query));
  });

  router.get(
    '/envejecientes/:envejecienteId/necesidades/candidatos',
    requirePermiso('necesidades:registrar', 'necesidades:actualizar'),
    async (req, res) => {
      const query = leerCandidatosNecesidadQuery(req.query);
      res.json(await repo(res).candidatos(uuidParam(req.params.envejecienteId), query));
    },
  );

  router.post('/envejecientes/:envejecienteId/necesidades', registrar, async (req, res) => {
    const datos = parseBody(crearNecesidadSchema, req.body);
    const data = await repo(res).crear(uuidParam(req.params.envejecienteId), datos);
    cambiar(res, 'necesidad.creada');
    res.status(201).json({ data });
  });

  router.patch('/necesidades/:necesidadId', actualizar, async (req, res) => {
    const datos = parseBody(actualizarNecesidadSchema, req.body);
    const data = await repo(res).actualizar(uuidParam(req.params.necesidadId), datos);
    cambiar(res, 'necesidad.actualizada');
    res.json({ data });
  });

  router.post('/necesidades/:necesidadId/estado', actualizar, async (req, res) => {
    const datos = parseBody(cambiarEstadoNecesidadSchema, req.body);
    const data = await repo(res).cambiarEstado(uuidParam(req.params.necesidadId), datos);
    cambiar(res, 'necesidad.estado');
    res.json({ data });
  });

  return router;
}
