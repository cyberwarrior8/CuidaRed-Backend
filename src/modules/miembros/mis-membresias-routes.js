/* Aceptar o rechazar membresías propias · ID02/RF-11. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas /me/membresias/* a nivel de /api/v1.
export function createMisMembresiasRouter(_deps) {
  return Router({ mergeParams: true });
}
