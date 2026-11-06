/* Miembros, roles, invitaciones y cuidadores · ID02/RF-11/RF-12. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas relativas a /cuentas/:cuentaId (/miembros…).
export function createMiembrosRouter(_deps) {
  return Router({ mergeParams: true });
}
