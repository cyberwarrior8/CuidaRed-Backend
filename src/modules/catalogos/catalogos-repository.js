/* Persistencia de catálogos mediante la RPC api_catalogo · CR-165. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { unavailable } from '../../lib/errors.js';

const resultado = z.object({
  items: z.array(z.record(z.string(), z.unknown())),
  total: z.number().int().min(0),
});

/**
 * `rpc` es la del repositorio del usuario (JWT propio). La RPC solo exige sesión y devuelve {items, total}; un
 * contrato roto de la base es indisponibilidad, no una respuesta vacía.
 */
export function createCatalogosRepository(rpc) {
  return {
    async catalogo(nombre, filtro) {
      const leido = resultado.safeParse(
        await rpc('api_catalogo', { p_nombre: nombre, p_filtro: filtro }),
      );
      if (!leido.success) throw unavailable();
      return leido.data;
    },
  };
}
