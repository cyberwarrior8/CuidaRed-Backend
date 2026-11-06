/* Alta de cuenta por autorregistro del titular · ID02/RF-11/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import './cuentas-errors.js';
import { contextoDto } from './cuentas-dto.js';
import { createCuentasRepository } from './cuentas-repository.js';
import { crearCuentaSchema, parseInput } from './cuentas-schemas.js';

// POST /cuentas (autorregistro del titular). Montado a nivel de /api/v1: exige sesión, no membresía.
export function createCuentasRouter({ audit }) {
  const router = Router({ mergeParams: true });

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
