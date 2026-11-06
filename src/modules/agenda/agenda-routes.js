/* Agenda de cuidado, tareas y evidencias · ID04/RF-16. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas relativas a /cuentas/:cuentaId (/tareas…, /evidencias…).
export function createAgendaRouter(_deps) {
  return Router({ mergeParams: true });
}
