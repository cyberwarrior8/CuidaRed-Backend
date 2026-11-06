/* Sincronización de visitas sin conexión (LWW, idempotencia) · ID04/RF-10. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas relativas a /cuentas/:cuentaId (/sync).
export function createSyncRouter(_deps) {
  return Router({ mergeParams: true });
}
