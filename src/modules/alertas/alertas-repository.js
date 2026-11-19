/* Acceso de alertas y notificaciones mediante RPC de cuenta. © 2026 Equipo CuidaRed – INTEC. Todos los derechos reservados. */
import { z } from 'zod';
import { paginatedResponse } from '../../lib/collection-query.js';
import { alertaDto, avisoDto, casoDto, leerSalida } from './alertas-schemas.js';

const pagina = (item) => z.object({ items: z.array(item), total: z.int().min(0) });
const alertasPagina = pagina(alertaDto);
const casosPagina = pagina(casoDto);
const avisosPagina = pagina(avisoDto);

export function createAlertasRepository(rpc) {
  async function listar(nombre, schema, cuentaId, query) {
    const raw = await rpc(nombre, {
      p_cuenta_id: cuentaId,
      p_filtros: query.filters,
      p_orden: query.sort.map(({ field, direction }) => (direction === 'desc' ? '-' : '') + field),
      p_limite: query.limit,
      p_desplazamiento: query.offset,
    });
    const { items, total } = leerSalida(schema, raw);
    return paginatedResponse(items, { ...query, total });
  }

  return {
    listar: (cuentaId, query) => listar('api_alertas_listar', alertasPagina, cuentaId, query),
    casos: (cuentaId, query) =>
      listar('api_casos_prioritarios_listar', casosPagina, cuentaId, query),
    avisos: (cuentaId, query) =>
      listar('api_notificaciones_alerta_listar', avisosPagina, cuentaId, query),
    async detalle(cuentaId, alertaId) {
      const raw = await rpc('api_alerta_obtener', {
        p_cuenta_id: cuentaId,
        p_alerta_id: alertaId,
      });
      return leerSalida(alertaDto, raw);
    },
    async resolver(cuentaId, alertaId, accion) {
      const raw = await rpc('api_alerta_resolver', {
        p_cuenta_id: cuentaId,
        p_alerta_id: alertaId,
        p_accion: accion,
      });
      return leerSalida(alertaDto, raw);
    },
    async enAtencion(cuentaId, alertaId) {
      const raw = await rpc('api_alerta_en_atencion', {
        p_cuenta_id: cuentaId,
        p_alerta_id: alertaId,
      });
      return leerSalida(alertaDto, raw);
    },
    async marcarLeida(cuentaId, notificacionId) {
      const raw = await rpc('api_notificacion_alerta_leer', {
        p_cuenta_id: cuentaId,
        p_notificacion_id: notificacionId,
      });
      return leerSalida(avisoDto, raw);
    },
  };
}
