/* Alta de cuenta por autorregistro del titular · ID02/RF-11/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { z } from 'zod';
import { createCollectionQuery, paginatedResponse } from '../../lib/collection-query.js';
import './cuentas-errors.js';
import { contextoDto, estadoSuscripcion, paginaCuentasDto } from './cuentas-dto.js';
import { createCuentasRepository } from './cuentas-repository.js';
import { crearCuentaSchema, parseInput } from './cuentas-schemas.js';
import { TIPOS_CUENTA } from './permisos.js';

const readQuery = createCollectionQuery({
  sortableFields: ['nombre', 'fecha_creacion', 'cuenta_id'],
  defaultSort: 'nombre',
  tieBreaker: 'cuenta_id',
  filterSchemas: { tipo_cuenta: z.enum(TIPOS_CUENTA), suscripcion_estado: estadoSuscripcion },
});

// POST /cuentas (autorregistro del titular). Montado a nivel de /api/v1: exige sesión, no membresía.
export function createCuentasRouter({ audit }) {
  const router = Router({ mergeParams: true });

  router.get('/cuentas', async (req, res) => {
    const query = readQuery(req.query);
    const repo = createCuentasRepository(res.locals.access.repository.rpc);
    const { items, total } = paginaCuentasDto(await repo.listarPropias(query));
    res.json(paginatedResponse(items, { ...query, total }));
  });

  router.post('/cuentas', async (req, res) => {
    const datos = parseInput(crearCuentaSchema, req.body);
    // La RPC hace titular a auth.uid() con el rol según el tipo, abre la prueba de 7 días y evita dos pruebas
    // vigentes a la vez (CR_PRUEBA_EN_CURSO → 409). Ni el titular ni el rol ni las fechas vienen del cliente.
    const cuenta = contextoDto(
      await createCuentasRepository(res.locals.access.repository.rpc).registrar(datos),
    );
    audit({
      requestId: res.locals.requestId,
      actorId: res.locals.actorId,
      action: 'cuenta.created',
      result: 'success',
    });
    res.status(201).location(`/api/v1/cuentas/${cuenta.cuenta_id}`).json({ data: cuenta });
  });

  return router;
}
