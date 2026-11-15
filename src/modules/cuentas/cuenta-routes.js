/* Detalle, configuración y suscripción de la cuenta · ID02/RF-11/RF-19/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { z } from 'zod';
import { createCollectionQuery, paginatedResponse } from '../../lib/collection-query.js';
import { unavailable } from '../../lib/errors.js';
import './cuentas-errors.js';
import { configuracionDto, contextoDto, detalleCuentaDto, suscripcionDto } from './cuentas-dto.js';
import { createCuentasRepository } from './cuentas-repository.js';
import {
  actualizarConfiguracionSchema,
  actualizarCuentaSchema,
  parseInput,
} from './cuentas-schemas.js';
import { requireAccesoOperativo, requirePermiso } from './require-cuenta.js';

const queryAuditoria = createCollectionQuery({
  sortableFields: ['fecha'],
  defaultSort: '-fecha',
  tieBreaker: 'fecha',
});
const eventoAuditoria = z.object({
  auditoria_id: z.string(),
  actor: z.string().nullable(),
  accion: z.enum(['alta', 'actualizacion', 'baja']),
  entidad: z.string(),
  fecha: z.iso.datetime({ offset: true }),
  resultado: z.literal('confirmado'),
});

/*
 * Rutas relativas a /cuentas/:cuentaId (requireCuenta ya resolvió el contexto en res.locals.cuenta).
 * Lectura: cualquier miembro activo, incluso con la cuenta vencida (V2: se conserva el acceso a la cuenta y a la
 * suscripción). Configuración y escrituras requieren acceso operativo. Cada RPC vuelve a autorizar.
 */
export function createCuentaRouter({ audit }) {
  const router = Router({ mergeParams: true });
  const repositorio = (res) => createCuentasRepository(res.locals.access.repository.rpc);
  // El id sale del contexto devuelto por la base (no del parámetro de ruta sin más).
  const cuentaId = (res) => res.locals.cuenta.cuentaId;
  const registrar = (res, action) =>
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.actorId,
      action,
      result: 'success',
    });

  router.get('/', async (_req, res) => {
    res.json({ data: detalleCuentaDto(await repositorio(res).obtener(cuentaId(res))) });
  });

  router.get('/contexto', (_req, res) => {
    res.json({ data: contextoDto(res.locals.contextoCuenta) });
  });

  router.patch('/', requirePermiso('organizacion:configurar'), async (req, res) => {
    const datos = parseInput(actualizarCuentaSchema, req.body);
    const actualizada = detalleCuentaDto(await repositorio(res).actualizar(cuentaId(res), datos));
    registrar(res, 'cuenta.updated');
    res.json({ data: actualizada });
  });

  router.get('/configuracion', requireAccesoOperativo(), async (_req, res) => {
    res.json({ data: configuracionDto(await repositorio(res).configuracion(cuentaId(res))) });
  });

  router.patch('/configuracion', requirePermiso('organizacion:configurar'), async (req, res) => {
    const { valores } = parseInput(actualizarConfiguracionSchema, req.body);
    const efectiva = configuracionDto(
      await repositorio(res).actualizarConfiguracion(cuentaId(res), valores),
    );
    registrar(res, 'cuenta.config_updated');
    res.json({ data: efectiva });
  });

  router.get('/suscripcion', async (_req, res) => {
    const conPlanes = res.locals.cuenta.permisos.has('cuenta:suscripcion');
    res.json({
      data: suscripcionDto(await repositorio(res).suscripcion(cuentaId(res)), { conPlanes }),
    });
  });

  router.get('/auditoria', requirePermiso('auditoria:ver'), async (req, res) => {
    const query = queryAuditoria(req.query);
    const raw = await res.locals.access.repository.rpc('api_auditoria_cuenta', {
      p_cuenta_id: cuentaId(res),
      p_limite: query.limit,
      p_desplazamiento: query.offset,
      p_desc: query.sort[0].direction === 'desc',
    });
    const eventos = z
      .object({ items: z.array(eventoAuditoria), total: z.int().min(0) })
      .safeParse(raw);
    if (!eventos.success) throw unavailable();
    res.json(paginatedResponse(eventos.data.items, { ...query, total: eventos.data.total }));
  });

  return router;
}
