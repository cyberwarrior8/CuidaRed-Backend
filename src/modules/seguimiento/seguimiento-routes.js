/* Asignaciones, permisos familiares, riesgos, indicaciones e historial · ID03/RF-12/RF-13/RF-14/RF-15. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { AppError, unavailable } from '../../lib/errors.js';
import { DESCARGA_SEGUNDOS, EVIDENCIAS_BUCKET } from '../agenda/agenda-service.js';
import {
  parseBody as parseEvidence,
  registrarEvidenciaSchema,
  subidaEvidenciaSchema,
} from '../agenda/agenda-schemas.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import { ERRORES_SEGUIMIENTO } from './seguimiento-errors.js';
import { createSeguimientoRepository } from './seguimiento-repository.js';
import {
  asignarSchema,
  autorizarFamiliarSchema,
  bigintParam,
  crearIndicacionSchema,
  editarIndicacionSchema,
  estadoIndicacionSchema,
  evaluarSchema,
  historialQuery,
  indicacionesQuery,
  ordenUnico,
  parseBody,
  registrarRiesgoSchema,
  resolverRiesgoSchema,
  respuestasFaltantes,
  revocarSchema,
  uuidParam,
} from './seguimiento-schemas.js';

/*
 * Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió res.locals.cuenta). En cada una primero se exige el
 * permiso de la matriz (respuesta temprana y clara) y después se valida la entrada y se llama a la RPC, que vuelve a
 * autorizar con la membresía real y el alcance sobre el adulto. Un adulto de otra cuenta, inexistente o fuera del
 * alcance del usuario produce la misma respuesta. Contrato: docs/contratos/seguimiento.md.
 */
export function createSeguimientoRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const repo = (res) => createSeguimientoRepository(res.locals.access.repository.rpc);
  const cuentaDe = (res) => res.locals.cuenta.cuentaId;
  // La auditoría técnica registra actor, acción y resultado; nunca datos de salud ni identificadores del adulto.
  const log = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  /* ───────────── Asignaciones y permiso familiar (RF-12, RF-13) ───────────── */

  router.get(
    '/envejecientes/:envejecienteId/asignaciones',
    requirePermiso('adultos:ver'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      res.json({ data: await repo(res).listarAsignaciones(cuentaDe(res), envejecienteId) });
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/asignaciones',
    requirePermiso('adultos:asignar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const datos = parseBody(asignarSchema, req.body);
      const data = await repo(res).asignar(cuentaDe(res), envejecienteId, datos);
      log(res, 'asignacion.creada');
      res.status(201).json({ data });
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/asignaciones/:usuarioId/revocar',
    requirePermiso('adultos:asignar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const usuarioId = uuidParam(req.params.usuarioId);
      const datos = parseBody(revocarSchema, req.body);
      await repo(res).revocarAsignacion(cuentaDe(res), envejecienteId, usuarioId, datos);
      log(res, 'asignacion.revocada');
      res.status(204).end();
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/familiares',
    requirePermiso('familiares:autorizar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const datos = parseBody(autorizarFamiliarSchema, req.body);
      const data = await repo(res).autorizarFamiliar(cuentaDe(res), envejecienteId, datos);
      log(res, 'familiar.autorizado');
      res.status(201).json({ data });
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/familiares/:usuarioId/revocar',
    requirePermiso('familiares:autorizar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const usuarioId = uuidParam(req.params.usuarioId);
      const datos = parseBody(revocarSchema, req.body);
      await repo(res).revocarFamiliar(cuentaDe(res), envejecienteId, usuarioId, datos);
      log(res, 'familiar.revocado');
      res.status(204).end();
    },
  );

  /* ───────────── Riesgo (RF-14) ───────────── */

  router.get(
    '/envejecientes/:envejecienteId/riesgo',
    requirePermiso('adultos:ver-sensible'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const data = await repo(res).consultarRiesgo(cuentaDe(res), envejecienteId);
      log(res, 'riesgo.consultado');
      res.json({ data });
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/evaluaciones',
    requirePermiso('adultos:evaluar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const datos = parseBody(evaluarSchema, req.body);
      if (respuestasFaltantes(datos.respuestas).length > 0) {
        const { status, publicCode, message } = ERRORES_SEGUIMIENTO.CR_EVALUACION_INCOMPLETA;
        throw new AppError(status, publicCode, message);
      }
      const data = await repo(res).evaluarRiesgo(cuentaDe(res), envejecienteId, datos);
      log(res, 'riesgo.evaluado');
      res.status(201).json({ data });
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/riesgos',
    requirePermiso('adultos:evaluar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const datos = parseBody(registrarRiesgoSchema, req.body);
      const data = await repo(res).registrarRiesgo(cuentaDe(res), envejecienteId, datos);
      log(res, 'riesgo.factor_registrado');
      res.status(201).json({ data });
    },
  );

  router.post(
    '/riesgos/:envejecienteRiesgoId/resolver',
    requirePermiso('adultos:evaluar'),
    async (req, res) => {
      const envejecienteRiesgoId = bigintParam(req.params.envejecienteRiesgoId);
      const datos = parseBody(resolverRiesgoSchema, req.body);
      const data = await repo(res).resolverRiesgo(cuentaDe(res), envejecienteRiesgoId, datos);
      log(res, 'riesgo.factor_resuelto');
      res.json({ data });
    },
  );

  /* ───────────── Indicaciones médicas (RF-15) ───────────── */

  router.get(
    '/envejecientes/:envejecienteId/indicaciones',
    requirePermiso('indicaciones:ver'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const query = indicacionesQuery(req.query);
      const orden = ordenUnico(query, 'indicacion_medica_id');
      const respuesta = await repo(res).listarIndicaciones(
        cuentaDe(res),
        envejecienteId,
        query,
        orden,
      );
      log(res, 'indicaciones.consultadas');
      res.json(respuesta);
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/indicaciones',
    requirePermiso('indicaciones:gestionar'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const datos = parseBody(crearIndicacionSchema, req.body);
      const data = await repo(res).crearIndicacion(cuentaDe(res), envejecienteId, datos);
      log(res, 'indicacion.creada');
      res.status(201).json({ data });
    },
  );

  router.patch(
    '/indicaciones/:indicacionId',
    requirePermiso('indicaciones:gestionar'),
    async (req, res) => {
      const indicacionId = uuidParam(req.params.indicacionId);
      const datos = parseBody(editarIndicacionSchema, req.body);
      const data = await repo(res).editarIndicacion(cuentaDe(res), indicacionId, datos);
      log(res, 'indicacion.editada');
      res.json({ data });
    },
  );

  router.post(
    '/indicaciones/:indicacionId/estado',
    requirePermiso('indicaciones:gestionar'),
    async (req, res) => {
      const indicacionId = uuidParam(req.params.indicacionId);
      const datos = parseBody(estadoIndicacionSchema, req.body);
      const data = await repo(res).cambiarEstadoIndicacion(cuentaDe(res), indicacionId, datos);
      log(res, 'indicacion.estado_cambiado');
      res.json({ data });
    },
  );

  const evidenciaRpc = (res, req, name, body) =>
    res.locals.access.repository.rpc(name, {
      p_cuenta_id: cuentaDe(res),
      p_indicacion_id: uuidParam(req.params.indicacionId),
      ...(body ? { p_datos: body } : {}),
    });

  router.post(
    '/indicaciones/:indicacionId/evidencias/subida',
    requirePermiso('indicaciones:gestionar'),
    async (req, res) => {
      const datos = parseEvidence(subidaEvidenciaSchema, req.body);
      res.json({ data: await evidenciaRpc(res, req, 'api_indicacion_preparar_evidencia', datos) });
    },
  );

  router.post(
    '/indicaciones/:indicacionId/evidencias',
    requirePermiso('indicaciones:gestionar'),
    async (req, res) => {
      const datos = parseEvidence(registrarEvidenciaSchema.omit({ observacion: true }), req.body);
      const data = await evidenciaRpc(res, req, 'api_indicacion_registrar_evidencia', datos);
      log(res, 'indicacion.evidencia_registrada');
      res.status(201).json({ data });
    },
  );

  router.get(
    '/indicaciones/:indicacionId/evidencias',
    requirePermiso('indicaciones:ver'),
    async (req, res) => {
      const rows = await evidenciaRpc(res, req, 'api_indicacion_listar_evidencias');
      if (!Array.isArray(rows)) throw unavailable();
      const storage = res.locals.access.repository.storage(EVIDENCIAS_BUCKET);
      const data = await Promise.all(
        rows.map(async ({ evidencia_id, nombre_archivo, ruta }) => {
          if (typeof ruta !== 'string') throw unavailable();
          try {
            const url_descarga = await storage.signedDownloadUrl(ruta, DESCARGA_SEGUNDOS);
            return { evidencia_id, nombre_archivo, url_descarga };
          } catch (error) {
            if (!(error instanceof AppError) || error.status !== 404) throw error;
            return { evidencia_id, nombre_archivo, url_descarga: null };
          }
        }),
      );
      res.json({ data });
    },
  );

  /* ───────────── Historial consolidado (RF-3.4 / CU-06) ───────────── */

  router.get(
    '/envejecientes/:envejecienteId/historial',
    requirePermiso('adultos:ver'),
    async (req, res) => {
      const envejecienteId = uuidParam(req.params.envejecienteId);
      const query = historialQuery(req.query);
      const orden = ordenUnico(query, 'fecha');
      const respuesta = await repo(res).listarHistorial(
        cuentaDe(res),
        envejecienteId,
        query,
        orden,
      );
      log(res, 'historial.consultado');
      res.json(respuesta);
    },
  );

  return router;
}
