/* Visitas: programar, autorizar, registrar y consultar · ID04/RF-02. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { paginatedResponse } from '../../lib/collection-query.js';
import { AppError, unavailable } from '../../lib/errors.js';
import { DESCARGA_SEGUNDOS, EVIDENCIAS_BUCKET } from '../agenda/agenda-service.js';
import {
  parseBody as parseEvidence,
  registrarEvidenciaSchema,
  subidaEvidenciaSchema,
} from '../agenda/agenda-schemas.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import './visitas-errors.js';
import { createVisitasRepository } from './visitas-repository.js';
import {
  autorizarSolicitudSchema,
  cancelarVisitaSchema,
  parseBody,
  programarVisitaSchema,
  readSolicitudesQuery,
  readVisitasQuery,
  registrarVisitaSchema,
  rechazarSolicitudSchema,
  sinCuerpoSchema,
  uuidParam,
} from './visitas-schemas.js';

/*
 * Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió membresía, rol y permisos en res.locals.cuenta).
 * El middleware solo responde antes y con errores claros: cada RPC vuelve a autorizar (membresía, permiso, alcance sobre
 * cada adulto y participación en la visita) y trata una visita, solicitud o adulto de otra cuenta como inexistente.
 *
 *   GET  /visitas                              visitas:ver          historial paginado, con el alcance del usuario
 *   GET  /visitas/:visitaId                    visitas:ver          detalle (adultos y observaciones según alcance)
 *   POST /visitas                              visitas:programar + visitas:autorizar   programa y autoriza
 *   POST /visitas/:visitaId/iniciar            visitas:registrar    programada → en curso (participante o gestor)
 *   POST /visitas/:visitaId/registrar          visitas:registrar    en curso → completada (participante o gestor)
 *   POST /visitas/:visitaId/cancelar           visitas:programar    programada | en curso → cancelada
 *   GET  /solicitudes-visita                   visitas:autorizar    solicitudes de personas externas (pendientes primero)
 *   POST /solicitudes-visita/:id/autorizar     visitas:autorizar    crea la visita programada
 *   POST /solicitudes-visita/:id/rechazar      visitas:autorizar
 */
export function createVisitasRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const repo = (res) => createVisitasRepository(res.locals.access.repository.rpc);
  const cuentaId = (res) => res.locals.cuenta.cuentaId;
  const log = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  router.get('/visitas', requirePermiso('visitas:ver'), async (req, res) => {
    const query = readVisitasQuery(req.query);
    const { items, total } = await repo(res).listar(cuentaId(res), query);
    res.json(paginatedResponse(items, { ...query, total }));
  });

  router.post(
    '/visitas',
    requirePermiso('visitas:programar'),
    requirePermiso('visitas:autorizar'),
    async (req, res) => {
      const datos = parseBody(programarVisitaSchema, req.body);
      const visita = await repo(res).programar(cuentaId(res), datos);
      log(res, 'visita.programada');
      res.status(201).json({ data: visita });
    },
  );

  router.get('/visitas/:visitaId', requirePermiso('visitas:ver'), async (req, res) => {
    const visita = await repo(res).obtener(cuentaId(res), uuidParam(req.params.visitaId));
    res.json({ data: visita });
  });

  router.post(
    '/visitas/:visitaId/iniciar',
    requirePermiso('visitas:registrar'),
    async (req, res) => {
      parseBody(sinCuerpoSchema, req.body);
      const visita = await repo(res).iniciar(cuentaId(res), uuidParam(req.params.visitaId));
      log(res, 'visita.iniciada');
      res.json({ data: visita });
    },
  );

  router.post(
    '/visitas/:visitaId/registrar',
    requirePermiso('visitas:registrar'),
    async (req, res) => {
      const visitaId = uuidParam(req.params.visitaId);
      const datos = parseBody(registrarVisitaSchema, req.body);
      const visita = await repo(res).registrar(cuentaId(res), visitaId, datos);
      log(res, 'visita.registrada');
      res.json({ data: visita });
    },
  );

  router.post(
    '/visitas/:visitaId/cancelar',
    requirePermiso('visitas:programar'),
    async (req, res) => {
      const visitaId = uuidParam(req.params.visitaId);
      const { motivo } = parseBody(cancelarVisitaSchema, req.body);
      const visita = await repo(res).cancelar(cuentaId(res), visitaId, motivo);
      log(res, 'visita.cancelada');
      res.json({ data: visita });
    },
  );

  const evidenciaRpc = (res, req, name, body) =>
    res.locals.access.repository.rpc(name, {
      p_cuenta_id: cuentaId(res),
      p_visita_id: uuidParam(req.params.visitaId),
      ...(body ? { p_datos: body } : {}),
    });

  router.post(
    '/visitas/:visitaId/evidencias/subida',
    requirePermiso('visitas:registrar'),
    async (req, res) => {
      const data = await evidenciaRpc(
        res,
        req,
        'api_visita_preparar_evidencia',
        parseEvidence(subidaEvidenciaSchema, req.body),
      );
      res.json({ data });
    },
  );

  router.post(
    '/visitas/:visitaId/evidencias',
    requirePermiso('visitas:registrar'),
    async (req, res) => {
      const data = await evidenciaRpc(
        res,
        req,
        'api_visita_registrar_evidencia',
        parseEvidence(registrarEvidenciaSchema, req.body),
      );
      log(res, 'visita.evidencia_registrada');
      res.status(201).json({ data });
    },
  );

  router.get('/visitas/:visitaId/evidencias', requirePermiso('visitas:ver'), async (req, res) => {
    const rows = await evidenciaRpc(res, req, 'api_visita_listar_evidencias');
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
  });

  router.get('/solicitudes-visita', requirePermiso('visitas:autorizar'), async (req, res) => {
    const query = readSolicitudesQuery(req.query);
    const { items, total } = await repo(res).listarSolicitudes(cuentaId(res), query);
    res.json(paginatedResponse(items, { ...query, total }));
  });

  router.post(
    '/solicitudes-visita/:solicitudId/autorizar',
    requirePermiso('visitas:autorizar'),
    async (req, res) => {
      const solicitudId = uuidParam(req.params.solicitudId);
      const datos = parseBody(autorizarSolicitudSchema, req.body);
      const visita = await repo(res).autorizarSolicitud(cuentaId(res), solicitudId, datos);
      log(res, 'solicitud_visita.autorizada');
      res.status(201).json({ data: visita });
    },
  );

  router.post(
    '/solicitudes-visita/:solicitudId/rechazar',
    requirePermiso('visitas:autorizar'),
    async (req, res) => {
      const solicitudId = uuidParam(req.params.solicitudId);
      const { motivo } = parseBody(rechazarSolicitudSchema, req.body);
      const solicitud = await repo(res).rechazarSolicitud(cuentaId(res), solicitudId, motivo);
      log(res, 'solicitud_visita.rechazada');
      res.json({ data: solicitud });
    },
  );

  return router;
}
