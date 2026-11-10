/* Perfiles de adultos mayores, consentimiento y contactos · ID03/RF-01/RF-17. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { z } from 'zod';
import { isBigintId } from '../../lib/bigint-id.js';
import { paginatedResponse } from '../../lib/collection-query.js';
import { AppError } from '../../lib/errors.js';
import { requirePermiso } from '../cuentas/require-cuenta.js';
import './envejecientes-errors.js';
import { envejecientesRepository } from './envejecientes-repository.js';
import {
  cambiarEstadoSchema,
  contactoCrearSchema,
  contactoEditarSchema,
  crearEnvejecienteSchema,
  editarEnvejecienteSchema,
  exigirConsentimiento,
  exigirContactos,
  leerListado,
  nivelDe,
  serializeAdulto,
  serializeContacto,
  serializeEstado,
  serializeItem,
} from './envejecientes-schema.js';

const notFound = () => new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');

function parse(schema, body) {
  const result = schema.safeParse(body);
  if (!result.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return result.data;
}

// Un identificador mal formado equivale a un recurso inexistente: no llega a la base ni revela nada.
function adultoId(req) {
  const result = z.uuid().safeParse(req.params.envejecienteId);
  if (!result.success) throw notFound();
  return result.data;
}
function contactoId(req) {
  if (!isBigintId(req.params.contactoId)) throw notFound();
  return req.params.contactoId;
}

// Rutas relativas a /cuentas/:cuentaId (contexto ya resuelto en res.locals.cuenta).
export function createEnvejecientesRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const repo = (res) => envejecientesRepository(res.locals.access.repository.rpc);
  // La cuenta efectiva sale del contexto verificado por requireCuenta, nunca del cuerpo ni de la consulta.
  const cuentaId = (res) => res.locals.cuenta.cuentaId;
  // Sin datos personales: solo quién, qué y cuándo (el sumidero de auditoría conserva una lista cerrada).
  const log = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.access.identity.id,
      action,
      result: 'success',
    });

  /* ───────────── Perfiles ───────────── */

  router.get('/envejecientes', requirePermiso('adultos:ver'), async (req, res) => {
    const query = leerListado(req.query);
    const nivel = nivelDe(res.locals.cuenta);
    const { items, total } = await repo(res).listar(cuentaId(res), query);
    res.json(
      paginatedResponse(
        items.map((item) => serializeItem(item, nivel)),
        { ...query, total },
      ),
    );
  });

  router.post('/envejecientes', requirePermiso('adultos:crear'), async (req, res) => {
    const input = parse(crearEnvejecienteSchema, req.body);
    exigirConsentimiento(input.consentimiento);
    exigirContactos(input.contactos);
    const fila = await repo(res).crear(cuentaId(res), input);
    log(res, 'adulto.created');
    res.status(201).json({ data: serializeAdulto(fila, nivelDe(res.locals.cuenta)) });
  });

  router.get('/envejecientes/:envejecienteId', requirePermiso('adultos:ver'), async (req, res) => {
    const fila = await repo(res).ver(cuentaId(res), adultoId(req));
    log(res, 'adulto.viewed');
    res.json({ data: serializeAdulto(fila, nivelDe(res.locals.cuenta)) });
  });

  router.patch(
    '/envejecientes/:envejecienteId',
    requirePermiso('adultos:editar'),
    async (req, res) => {
      const id = adultoId(req);
      const input = parse(editarEnvejecienteSchema, req.body);
      if (input.consentimiento) exigirConsentimiento(input.consentimiento);
      const fila = await repo(res).editar(cuentaId(res), id, input);
      log(res, 'adulto.updated');
      res.json({ data: serializeAdulto(fila, nivelDe(res.locals.cuenta)) });
    },
  );

  // Inactivar o registrar el fallecimiento cancela tareas, resuelve alertas y cancela visitas de ese único adulto.
  router.post(
    '/envejecientes/:envejecienteId/estado',
    requirePermiso('adultos:desactivar'),
    async (req, res) => {
      const id = adultoId(req);
      const { estado, motivo } = parse(cambiarEstadoSchema, req.body);
      const fila = await repo(res).cambiarEstado(cuentaId(res), id, estado, motivo);
      log(res, 'adulto.state_changed');
      res.json({ data: serializeEstado(fila) });
    },
  );

  /* ───────────── Contactos de emergencia ───────────── */

  router.get(
    '/envejecientes/:envejecienteId/contactos',
    requirePermiso('adultos:ver'),
    async (req, res) => {
      const contactos = await repo(res).listarContactos(cuentaId(res), adultoId(req));
      res.json({ data: contactos.map(serializeContacto) });
    },
  );

  router.post(
    '/envejecientes/:envejecienteId/contactos',
    requirePermiso('adultos:editar'),
    async (req, res) => {
      const id = adultoId(req);
      const input = parse(contactoCrearSchema, req.body);
      const contacto = await repo(res).crearContacto(cuentaId(res), id, input);
      log(res, 'adulto.contact_created');
      res.status(201).json({ data: serializeContacto(contacto) });
    },
  );

  router.patch('/contactos/:contactoId', requirePermiso('adultos:editar'), async (req, res) => {
    const id = contactoId(req);
    const input = parse(contactoEditarSchema, req.body);
    const contacto = await repo(res).editarContacto(cuentaId(res), id, input);
    log(res, 'adulto.contact_updated');
    res.json({ data: serializeContacto(contacto) });
  });

  // Cambia el principal de forma atómica: el anterior deja de serlo en la misma transacción.
  router.post(
    '/contactos/:contactoId/principal',
    requirePermiso('adultos:editar'),
    async (req, res) => {
      const contacto = await repo(res).contactoPrincipal(cuentaId(res), contactoId(req));
      log(res, 'adulto.contact_principal_changed');
      res.json({ data: serializeContacto(contacto) });
    },
  );

  // No deja al perfil sin contactos (CR_ULTIMO_CONTACTO) ni sin principal (CR_CONTACTO_PRINCIPAL).
  router.post(
    '/contactos/:contactoId/eliminar',
    requirePermiso('adultos:editar'),
    async (req, res) => {
      await repo(res).eliminarContacto(cuentaId(res), contactoId(req));
      log(res, 'adulto.contact_deleted');
      res.status(204).end();
    },
  );

  return router;
}
