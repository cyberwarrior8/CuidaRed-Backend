/* Rutas públicas sin sesión (solicitudes de visita de personas externas) · V2 §Visita. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas /publico/* montadas ANTES de requireSession. Usan gateway.publico().rpc('api_publico_*') y deben aplicar
// su propio límite de peticiones, validación estricta y respuestas que no revelen datos de cuentas ni de adultos.
export function createPublicoRouter(_deps) {
  return Router({ mergeParams: true });
}
