/* Alta de cuenta y datos de la cuenta activa · ID02/RF-11/RF-19/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// POST /cuentas (autorregistro del titular). Montado a nivel de /api/v1.
export function createCuentasRouter(_deps) {
  return Router({ mergeParams: true });
}
