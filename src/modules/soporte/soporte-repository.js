/* Persistencia de soporte y borrado controlado de acceso. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from '../../lib/errors.js';

const session = (c) => ({ p_actor: c.actorId, p_sesion: c.sessionId, p_aal: c.aal });
export const filtros = (q) => ({
  p_estado: q.estado ?? null,
  p_buscar: q.search || null,
  p_pagina: q.page,
  p_limite: q.limit,
});
export function createSoporteRepository(gateway) {
  const rpc = (name, args) => {
    if (!gateway) throw unavailable();
    return gateway.backofficeRpc(name, args);
  };
  return {
    listar: (c, q) => rpc('soporte_leer', { ...session(c), ...filtros(q) }),
    detalle: (c, id) => rpc('soporte_leer', { ...session(c), p_id: id }),
    responder: (c, id, body) =>
      rpc('soporte_actualizar', {
        ...session(c),
        p_id: id,
        p_estado: body.estado,
        p_mensaje: body.mensaje,
        p_version: body.version,
      }),
    revision: (c, cuenta, usuario) =>
      rpc('eliminacion_leer', { ...session(c), p_cuenta: cuenta, p_usuario: usuario }),
    preparar: (c, cuenta, usuario, body) =>
      rpc('eliminacion_preparar', {
        ...session(c),
        p_cuenta: cuenta,
        p_usuario: usuario,
        p_confirmacion: body.confirmacion,
        p_motivo: body.motivo,
        p_solicitud: body.solicitud_id,
      }),
    estado: (c, operacion) => rpc('eliminacion_estado', { ...session(c), p_operacion: operacion }),
  };
}
