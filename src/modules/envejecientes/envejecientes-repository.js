/* Persistencia de perfiles de adultos mayores y contactos (RPC con el JWT del usuario) · ID03. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from '../../lib/errors.js';

// p_desplazamiento es integer en la base: un offset mayor devuelve una página vacía con el total real.
const MAX_DESPLAZAMIENTO = 2_147_483_647;

/**
 * Cada operación llama a una RPC de `cuidared_api` que vuelve a autorizar (cuenta, rol, alcance sobre el adulto) y
 * valida las entradas. `rpc` es `res.locals.access.repository.rpc`: usa el JWT del usuario, nunca una clave privilegiada.
 * La cuenta sale siempre de la ruta ya verificada por requireCuenta, jamás del cuerpo ni de los filtros.
 */
export function envejecientesRepository(rpc) {
  return {
    async listar(cuentaId, { filters, sort, limit, offset }) {
      const resultado = await rpc('api_listar_envejecientes', {
        p_cuenta_id: cuentaId,
        p_estado: filters.estado ?? null,
        p_municipio_cod: filters.municipio_cod ?? null,
        p_orden: sort.map(({ field, direction }) => (direction === 'desc' ? `-${field}` : field)),
        p_limite: limit,
        p_desplazamiento: Math.min(offset, MAX_DESPLAZAMIENTO),
      });
      if (!resultado || !Array.isArray(resultado.items) || !Number.isSafeInteger(resultado.total)) {
        throw unavailable();
      }
      return resultado;
    },
    crear: (cuentaId, datos) =>
      rpc('api_crear_envejeciente', { p_cuenta_id: cuentaId, p_datos: datos }),
    ver: (cuentaId, envejecienteId) =>
      rpc('api_ver_envejeciente', { p_cuenta_id: cuentaId, p_envejeciente_id: envejecienteId }),
    editar: (cuentaId, envejecienteId, datos) =>
      rpc('api_editar_envejeciente', {
        p_cuenta_id: cuentaId,
        p_envejeciente_id: envejecienteId,
        p_datos: datos,
      }),
    cambiarEstado: (cuentaId, envejecienteId, estado, motivo) =>
      rpc('api_estado_envejeciente', {
        p_cuenta_id: cuentaId,
        p_envejeciente_id: envejecienteId,
        p_estado: estado,
        p_motivo: motivo ?? null,
      }),
    async listarContactos(cuentaId, envejecienteId) {
      const contactos = await rpc('api_listar_contactos', {
        p_cuenta_id: cuentaId,
        p_envejeciente_id: envejecienteId,
      });
      if (!Array.isArray(contactos)) throw unavailable();
      return contactos;
    },
    crearContacto: (cuentaId, envejecienteId, datos) =>
      rpc('api_crear_contacto', {
        p_cuenta_id: cuentaId,
        p_envejeciente_id: envejecienteId,
        p_datos: datos,
      }),
    editarContacto: (cuentaId, contactoId, datos) =>
      rpc('api_editar_contacto', {
        p_cuenta_id: cuentaId,
        p_contacto_id: contactoId,
        p_datos: datos,
      }),
    contactoPrincipal: (cuentaId, contactoId) =>
      rpc('api_principal_contacto', { p_cuenta_id: cuentaId, p_contacto_id: contactoId }),
    eliminarContacto: (cuentaId, contactoId) =>
      rpc('api_eliminar_contacto', { p_cuenta_id: cuentaId, p_contacto_id: contactoId }),
  };
}
