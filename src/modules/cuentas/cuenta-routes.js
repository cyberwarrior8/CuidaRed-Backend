/* Detalle, configuración y suscripción de la cuenta · ID02/RF-11/RF-19/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas relativas a /cuentas/:cuentaId (contexto ya resuelto en res.locals.cuenta).
export function createCuentaRouter(_deps) {
  return Router({ mergeParams: true });
}
