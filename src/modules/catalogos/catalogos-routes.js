/* Catálogos con caché para formularios · CR-165/RF-06. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';

// Rutas /catalogos/* (requieren sesión, no cuenta).
export function createCatalogosRouter(_deps) {
  return Router({ mergeParams: true });
}
