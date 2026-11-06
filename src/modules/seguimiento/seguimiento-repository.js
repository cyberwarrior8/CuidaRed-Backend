/* Persistencia del seguimiento: RPC de cuidared_api con el JWT del usuario · ID03. © 2026 Equipo CuidaRed – INTEC. */
import { paginatedResponse } from '../../lib/collection-query.js';
import { unavailable } from '../../lib/errors.js';

/*
 * Cada método llama a una RPC de docs/propuestas/fase-3b-seguimiento.sql. La autorización definitiva ocurre allí
 * (membresía, permiso y alcance sobre el adulto); la API solo se adelanta con requirePermiso. La cuenta y el actor
 * jamás se toman del cuerpo: la cuenta sale de la ruta ya resuelta y el actor, del JWT dentro de la base.
 * Un resultado con forma inesperada es un contrato roto de la base: indisponibilidad (503), no un dato.
 */

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const objeto = (value) => {
  if (!isObject(value)) throw unavailable();
  return value;
};
const lista = (value) => {
  if (!Array.isArray(value)) throw unavailable();
  return value;
};

/** Convierte {items, total} de la base en la respuesta paginada de CR-162. */
function pagina(resultado, query) {
  const { items, total } = objeto(resultado);
  lista(items);
  if (!Number.isSafeInteger(total) || total < 0) throw unavailable();
  try {
    return paginatedResponse(items, { ...query, total });
  } catch {
    throw unavailable();
  }
}

export function createSeguimientoRepository(rpc) {
  const cuenta = (cuentaId) => Number(cuentaId);

  return {
    /* Asignaciones y permiso familiar */
    async listarAsignaciones(cuentaId, envejecienteId) {
      return objeto(
        await rpc('api_asignaciones_listar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
        }),
      );
    },
    async asignar(cuentaId, envejecienteId, { tipo, usuario_id: usuarioId }) {
      return objeto(
        await rpc('api_asignar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_tipo: tipo,
          p_usuario_id: usuarioId,
        }),
      );
    },
    async revocarAsignacion(cuentaId, envejecienteId, usuarioId, { motivo }) {
      await rpc('api_asignacion_revocar', {
        p_cuenta_id: cuenta(cuentaId),
        p_envejeciente_id: envejecienteId,
        p_usuario_id: usuarioId,
        p_motivo: motivo ?? null,
      });
    },
    async autorizarFamiliar(cuentaId, envejecienteId, { usuario_id: usuarioId }) {
      return objeto(
        await rpc('api_familiar_autorizar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_usuario_id: usuarioId,
        }),
      );
    },
    async revocarFamiliar(cuentaId, envejecienteId, usuarioId, { motivo }) {
      await rpc('api_familiar_revocar', {
        p_cuenta_id: cuenta(cuentaId),
        p_envejeciente_id: envejecienteId,
        p_usuario_id: usuarioId,
        p_motivo: motivo ?? null,
      });
    },

    /* Riesgo */
    async consultarRiesgo(cuentaId, envejecienteId) {
      return objeto(
        await rpc('api_riesgo_consultar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
        }),
      );
    },
    async evaluarRiesgo(cuentaId, envejecienteId, { respuestas }) {
      return objeto(
        await rpc('api_riesgo_evaluar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_respuestas: respuestas,
        }),
      );
    },
    async registrarRiesgo(cuentaId, envejecienteId, datos) {
      return objeto(
        await rpc('api_riesgo_registrar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_riesgo_id: datos.riesgo_id,
          p_nivel: datos.nivel,
          p_motivo: datos.motivo,
          p_observacion: datos.observacion ?? null,
        }),
      );
    },
    async resolverRiesgo(cuentaId, envejecienteRiesgoId, { observacion }) {
      return objeto(
        await rpc('api_riesgo_resolver', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_riesgo_id: envejecienteRiesgoId,
          p_observacion: observacion ?? null,
        }),
      );
    },

    /* Indicaciones médicas */
    async listarIndicaciones(cuentaId, envejecienteId, query, orden) {
      return pagina(
        await rpc('api_indicaciones_listar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_estado: query.filters.estado ?? null,
          p_orden: orden.campo,
          p_desc: orden.descendente,
          p_limite: query.limit,
          p_desplazamiento: query.offset,
        }),
        query,
      );
    },
    async crearIndicacion(cuentaId, envejecienteId, datos) {
      return objeto(
        await rpc('api_indicacion_crear', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_datos: datos,
        }),
      );
    },
    async editarIndicacion(cuentaId, indicacionId, datos) {
      return objeto(
        await rpc('api_indicacion_editar', {
          p_cuenta_id: cuenta(cuentaId),
          p_indicacion_id: indicacionId,
          p_datos: datos,
        }),
      );
    },
    async cambiarEstadoIndicacion(cuentaId, indicacionId, { estado }) {
      return objeto(
        await rpc('api_indicacion_estado', {
          p_cuenta_id: cuenta(cuentaId),
          p_indicacion_id: indicacionId,
          p_estado: estado,
        }),
      );
    },

    /* Historial consolidado */
    async listarHistorial(cuentaId, envejecienteId, query, orden) {
      return pagina(
        await rpc('api_historial_listar', {
          p_cuenta_id: cuenta(cuentaId),
          p_envejeciente_id: envejecienteId,
          p_tipo: query.filters.tipo ?? null,
          p_desc: orden.descendente,
          p_limite: query.limit,
          p_desplazamiento: query.offset,
        }),
        query,
      );
    },
  };
}
