/* Asignaciones, permisos familiares, riesgos e indicaciones · ID03/RF-12/RF-13/RF-14/RF-15. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas relativas a /cuentas/:cuentaId (/envejecientes/:envejecienteId/…).
export function createSeguimientoRouter(_deps) {
  return Router({ mergeParams: true });
}
