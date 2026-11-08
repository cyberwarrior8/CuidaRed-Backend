/* Agenda de cuidado, tareas y evidencias · ID04/RF-16. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { paginatedResponse } from '../../lib/collection-query.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import './agenda-errors.js';
import {
  actualizarTareaSchema,
  cancelarTareaSchema,
  crearTareaSchema,
  parseBody,
  parseTareasQuery,
  readUuidParam,
  registrarEvidenciaSchema,
  rechazarEvidenciaSchema,
  sinCuerpoSchema,
  subidaEvidenciaSchema,
} from './agenda-schemas.js';
import { createAgendaService } from './agenda-service.js';

/*
 * Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió membresía, rol y permisos). Cada RPC vuelve a
 * autorizar en la base: cuenta, permiso, alcance sobre el adulto y, al ejecutar, que la tarea sea del cuidador
 * asignado. Una tarea o evidencia de otra cuenta se responde como inexistente (404).
 *
 *   GET   /tareas                               agenda:ver        (el Cuidador solo ve las suyas)
 *   POST  /tareas                               agenda:gestionar  (una tarea por ocurrencia, máx. 60)
 *   GET   /tareas/:tareaId                      agenda:ver
 *   PATCH /tareas/:tareaId                      agenda:gestionar  (solo pendientes)
 *   POST  /tareas/:tareaId/cancelar             agenda:gestionar
 *   POST  /tareas/:tareaId/iniciar              agenda:ejecutar   (cuidador asignado)
 *   POST  /tareas/:tareaId/completar            agenda:ejecutar   (D12: evidencia validada si la requiere)
 *   POST  /tareas/:tareaId/evidencias/subida    agenda:ejecutar   (URL firmada de subida al bucket privado)
 *   POST  /tareas/:tareaId/evidencias           agenda:ejecutar   (registra la evidencia pendiente)
 *   GET   /tareas/:tareaId/evidencias           agenda:ver        (URL firmada de descarga de 5 minutos)
 *   POST  /evidencias/:evidenciaId/validar      evidencias:validar
 *   POST  /evidencias/:evidenciaId/rechazar     evidencias:validar (motivo obligatorio)
 */
export function createAgendaRouter({ audit, now }) {
  const router = Router({ mergeParams: true });
  const service = (res) => createAgendaService(res.locals.access.repository, { now });
  const cuentaOf = (res) => res.locals.cuenta.cuentaId;
  const log = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });
  const verTareas = requirePermiso('agenda:ver');
  const gestionar = requirePermiso('agenda:gestionar');
  const ejecutar = requirePermiso('agenda:ejecutar');
  const validar = requirePermiso('evidencias:validar');

  router.get('/tareas', verTareas, async (req, res) => {
    const query = parseTareasQuery(req.query);
    const { rows, total } = await service(res).listTareas(cuentaOf(res), query);
    res.json(paginatedResponse(rows, { ...query, total }));
  });

  router.post('/tareas', gestionar, async (req, res) => {
    const datos = parseBody(crearTareaSchema, req.body);
    const created = await service(res).createTareas(cuentaOf(res), datos);
    log(res, 'agenda.tarea_creada');
    res.status(201).json({ data: created });
  });

  router.get('/tareas/:tareaId', verTareas, async (req, res) => {
    const tarea = await service(res).getTarea(cuentaOf(res), readUuidParam(req.params.tareaId));
    res.json({ data: tarea });
  });

  router.patch('/tareas/:tareaId', gestionar, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    const datos = parseBody(actualizarTareaSchema, req.body);
    const tarea = await service(res).updateTarea(cuentaOf(res), tareaId, datos);
    log(res, 'agenda.tarea_actualizada');
    res.json({ data: tarea });
  });

  router.post('/tareas/:tareaId/cancelar', gestionar, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    const datos = parseBody(cancelarTareaSchema, req.body);
    const result = await service(res).cancelTarea(cuentaOf(res), tareaId, datos);
    log(res, 'agenda.tarea_cancelada');
    res.json({ data: result });
  });

  router.post('/tareas/:tareaId/iniciar', ejecutar, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    parseBody(sinCuerpoSchema, req.body);
    const tarea = await service(res).startTarea(cuentaOf(res), tareaId);
    log(res, 'agenda.tarea_iniciada');
    res.json({ data: tarea });
  });

  router.post('/tareas/:tareaId/completar', ejecutar, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    parseBody(sinCuerpoSchema, req.body);
    const tarea = await service(res).completeTarea(cuentaOf(res), tareaId);
    log(res, 'agenda.tarea_completada');
    res.json({ data: tarea });
  });

  router.post('/tareas/:tareaId/evidencias/subida', ejecutar, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    const datos = parseBody(subidaEvidenciaSchema, req.body);
    const upload = await service(res).requestUpload(cuentaOf(res), tareaId, datos);
    log(res, 'agenda.evidencia_subida_solicitada');
    res.json({ data: upload });
  });

  router.post('/tareas/:tareaId/evidencias', ejecutar, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    const datos = parseBody(registrarEvidenciaSchema, req.body);
    const evidencia = await service(res).registerEvidence(cuentaOf(res), tareaId, datos);
    log(res, 'agenda.evidencia_registrada');
    res.status(201).json({ data: evidencia });
  });

  // Sub-colección acotada por tarea: sin paginar (CR-162 pagina las colecciones de la cuenta).
  router.get('/tareas/:tareaId/evidencias', verTareas, async (req, res) => {
    const tareaId = readUuidParam(req.params.tareaId);
    res.json({ data: await service(res).listEvidences(cuentaOf(res), tareaId) });
  });

  router.post('/evidencias/:evidenciaId/validar', validar, async (req, res) => {
    const evidenciaId = readUuidParam(req.params.evidenciaId);
    parseBody(sinCuerpoSchema, req.body);
    const result = await service(res).validateEvidence(cuentaOf(res), evidenciaId);
    log(res, 'agenda.evidencia_validada');
    res.json({ data: result });
  });

  router.post('/evidencias/:evidenciaId/rechazar', validar, async (req, res) => {
    const evidenciaId = readUuidParam(req.params.evidenciaId);
    const { motivo } = parseBody(rechazarEvidenciaSchema, req.body);
    const result = await service(res).rejectEvidence(cuentaOf(res), evidenciaId, motivo);
    log(res, 'agenda.evidencia_rechazada');
    res.json({ data: result });
  });

  return router;
}
