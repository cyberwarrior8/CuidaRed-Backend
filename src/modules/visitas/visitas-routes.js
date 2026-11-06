/* Visitas: programar, autorizar, registrar y consultar · ID04/RF-02. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas relativas a /cuentas/:cuentaId (/visitas…, /solicitudes-visita…).
export function createVisitasRouter(_deps) {
  return Router({ mergeParams: true });
}
