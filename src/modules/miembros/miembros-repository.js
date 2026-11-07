/* Persistencia de miembros: llamadas a las RPC de cuidared_api con el JWT del usuario · ID02/RF-11/RF-12. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from '../../lib/errors.js';
import { ALREADY_MEMBER_CONFLICT } from './miembros-errors.js';
import {
  readCuidador,
  readListado,
  readMembresiaAceptada,
  readMiembro,
  readTitularidad,
} from './miembros-schemas.js';

/*
 * Cada método es una RPC que vuelve a autorizar con cuidared_interno.exigir: el router solo se adelanta con
 * requirePermiso. La cuenta es siempre la de la ruta y la identidad sale del JWT en la base: ningún método recibe
 * un id de actor. `rpc` es res.locals.access.repository.rpc (mapea los errores según CR-162).
 */
export function createMiembrosRepository({ rpc }) {
  const conflict = { conflict: ALREADY_MEMBER_CONFLICT };
  return {
    async listar(cuentaId, { filters, sort, limit, offset }) {
      const raw = await rpc('api_listar_miembros', {
        p_cuenta_id: cuentaId,
        p_rol: filters.rol ?? null,
        p_estado: filters.estado ?? null,
        p_orden: sort.map(({ field, direction }) => (direction === 'desc' ? `-${field}` : field)),
        p_limite: limit,
        p_desplazamiento: offset,
      });
      return readListado(raw);
    },
    async detalle(cuentaId, membresiaId) {
      return readMiembro(
        await rpc('api_detalle_miembro', { p_cuenta_id: cuentaId, p_membresia_id: membresiaId }),
      );
    },
    /** Paso 1 de la invitación: autoriza, valida rol y límites y dice si la persona ya tiene perfil. */
    async prepararInvitacion(cuentaId, { correo, cedula, rol }) {
      const raw = await rpc('api_preparar_invitacion', {
        p_cuenta_id: cuentaId,
        p_correo: correo,
        p_cedula: cedula,
        p_rol: rol,
      });
      if (typeof raw?.usuario_existe !== 'boolean') throw unavailable();
      return raw.usuario_existe;
    },
    /** Paso 2: crea la membresía pendiente. La persona se resuelve por correo y cédula, nunca por un id del cliente. */
    async agregarMiembro(cuentaId, { correo, cedula, rol }) {
      return readMiembro(
        await rpc(
          'api_agregar_miembro',
          { p_cuenta_id: cuentaId, p_correo: correo, p_cedula: cedula, p_rol: rol },
          conflict,
        ),
      );
    },
    async cambiarRol(cuentaId, membresiaId, rol) {
      return readMiembro(
        await rpc(
          'api_cambiar_rol_miembro',
          { p_cuenta_id: cuentaId, p_membresia_id: membresiaId, p_rol: rol },
          conflict,
        ),
      );
    },
    async desactivar(cuentaId, membresiaId) {
      return readMiembro(
        await rpc('api_desactivar_miembro', { p_cuenta_id: cuentaId, p_membresia_id: membresiaId }),
      );
    },
    async reactivar(cuentaId, membresiaId) {
      return readMiembro(
        await rpc(
          'api_reactivar_miembro',
          { p_cuenta_id: cuentaId, p_membresia_id: membresiaId },
          conflict,
        ),
      );
    },
    async transferirTitularidad(cuentaId, membresiaId) {
      return readTitularidad(
        await rpc('api_transferir_titularidad', {
          p_cuenta_id: cuentaId,
          p_membresia_id: membresiaId,
        }),
      );
    },
    async obtenerCuidador(cuentaId, membresiaId) {
      return readCuidador(
        await rpc('api_obtener_cuidador_miembro', {
          p_cuenta_id: cuentaId,
          p_membresia_id: membresiaId,
        }),
      );
    },
    async guardarCuidador(cuentaId, membresiaId, { tipo_cuidado_id, cuidador_independiente }) {
      return readCuidador(
        await rpc('api_guardar_cuidador_miembro', {
          p_cuenta_id: cuentaId,
          p_membresia_id: membresiaId,
          p_tipo_cuidado_id: tipo_cuidado_id,
          p_cuidador_independiente: cuidador_independiente,
        }),
      );
    },
    async finalizarCuidador(cuentaId, membresiaId) {
      return readMiembro(
        await rpc('api_finalizar_cuidador_miembro', {
          p_cuenta_id: cuentaId,
          p_membresia_id: membresiaId,
        }),
      );
    },
    /* Membresías propias (sin cuenta en la ruta: la RPC solo actúa sobre la pendiente de quien llama). */
    async aceptarPropia(membresiaId) {
      return readMembresiaAceptada(
        await rpc('api_aceptar_membresia', { p_membresia_id: membresiaId }, conflict),
      );
    },
    async rechazarPropia(membresiaId) {
      await rpc('api_rechazar_membresia', { p_membresia_id: membresiaId });
    },
  };
}
