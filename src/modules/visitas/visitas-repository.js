/* Persistencia de visitas y solicitudes de visita mediante RPC · ID04/RF-02. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from '../../lib/errors.js';
import { sinNulos } from './visitas-schemas.js';

const esObjeto = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

// Un contrato roto de la base es indisponibilidad (503), nunca un resultado inventado.
function objeto(data) {
  if (!esObjeto(data)) throw unavailable();
  return data;
}

function pagina(data) {
  if (!esObjeto(data) || !Array.isArray(data.items) || !Number.isSafeInteger(data.total)) {
    throw unavailable();
  }
  return { items: data.items, total: data.total };
}

const orden = (sort) =>
  sort.map(({ field, direction }) => ({ campo: field, direccion: direction }));

/**
 * Cada operación llama una RPC de `cuidared_api` con el JWT del usuario (RLS y auth.uid() activos). La RPC es la que
 * autoriza: valida membresía, permiso, alcance sobre cada adulto y participación; aquí solo se arman los parámetros.
 */
export function createVisitasRepository(rpc) {
  return {
    async listar(cuentaId, { filters, sort, limit, offset }) {
      return pagina(
        await rpc('api_listar_visitas', {
          p_cuenta_id: cuentaId,
          p_filtros: { ...filters },
          p_orden: orden(sort),
          p_limite: limit,
          p_desplazamiento: offset,
        }),
      );
    },
    async obtener(cuentaId, visitaId) {
      return objeto(
        await rpc('api_obtener_visita', { p_cuenta_id: cuentaId, p_visita_id: visitaId }),
      );
    },
    async programar(cuentaId, datos) {
      return objeto(
        await rpc('api_programar_visita', { p_cuenta_id: cuentaId, p_datos: sinNulos(datos) }),
      );
    },
    async iniciar(cuentaId, visitaId) {
      return objeto(
        await rpc('api_iniciar_visita', { p_cuenta_id: cuentaId, p_visita_id: visitaId }),
      );
    },
    async registrar(cuentaId, visitaId, datos) {
      return objeto(
        await rpc('api_registrar_visita', {
          p_cuenta_id: cuentaId,
          p_visita_id: visitaId,
          p_datos: sinNulos(datos),
        }),
      );
    },
    async registrarRealizada(cuentaId, datos) {
      const res = objeto(
        await rpc('api_registrar_visita_realizada', {
          p_cuenta_id: cuentaId,
          p_datos: sinNulos(datos),
        }),
      );
      if (typeof res.creada !== 'boolean') throw unavailable();
      return { creada: res.creada, visita: objeto(res.visita) };
    },
    async cancelar(cuentaId, visitaId, motivo) {
      return objeto(
        await rpc('api_cancelar_visita', {
          p_cuenta_id: cuentaId,
          p_visita_id: visitaId,
          p_motivo: motivo,
        }),
      );
    },
    async listarSolicitudes(cuentaId, { filters, sort, limit, offset }) {
      return pagina(
        await rpc('api_listar_solicitudes_visita', {
          p_cuenta_id: cuentaId,
          p_filtros: { ...filters },
          p_orden: orden(sort),
          p_limite: limit,
          p_desplazamiento: offset,
        }),
      );
    },
    async autorizarSolicitud(cuentaId, solicitudId, datos) {
      return objeto(
        await rpc('api_autorizar_solicitud_visita', {
          p_cuenta_id: cuentaId,
          p_solicitud_id: solicitudId,
          p_datos: datos,
        }),
      );
    },
    async rechazarSolicitud(cuentaId, solicitudId, motivo) {
      return objeto(
        await rpc('api_rechazar_solicitud_visita', {
          p_cuenta_id: cuentaId,
          p_solicitud_id: solicitudId,
          p_motivo: motivo,
        }),
      );
    },
  };
}
