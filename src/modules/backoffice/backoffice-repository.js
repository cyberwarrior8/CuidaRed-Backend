/* Persistencia del Backoffice · BO-01 a BO-34. © 2026 Equipo CuidaRed – INTEC. */
import { AppError, unavailable } from '../../lib/errors.js';
import { registerBusinessErrors } from '../../lib/business-errors.js';

registerBusinessErrors({
  CR_BO_ULTIMO_GESTOR: {
    status: 409,
    publicCode: 'LAST_MANAGER',
    message: 'La organización debe conservar al menos un administrador o coordinador activo.',
  },
  CR_BO_EXTENSION_LIMITE: {
    status: 409,
    publicCode: 'TRIAL_EXTENSION_LIMIT',
    message: 'La extensión supera el límite de días o de extensiones de la prueba.',
  },
  CR_BO_PRUEBA_NO_EXTENSIBLE: {
    status: 409,
    publicCode: 'TRIAL_NOT_EXTENDABLE',
    message: 'La prueba ya no se puede extender.',
  },
  CR_CUENTA_DESHABILITADA: {
    status: 403,
    publicCode: 'ACCOUNT_DISABLED',
    message:
      'La cuenta está deshabilitada. Contacta a soporte. Los registros pendientes no se sincronizaron.',
  },
});

export function createBackofficeRepository(adminGateway) {
  const rpc = (name, args) => {
    if (!adminGateway) throw unavailable();
    return adminGateway.backofficeRpc(name, args);
  };
  const session = (context) => ({
    p_actor: context.actorId,
    p_sesion: context.sessionId,
    p_aal: context.aal,
  });
  const auditContext = (req) => ({ p_ip: req.ip || null, p_agente: req.get('user-agent') || null });
  return {
    admit: (actorId, sessionId, req) =>
      rpc('admitir', { p_actor: actorId, p_sesion: sessionId, ...auditContext(req) }),
    session: (context, action, req) =>
      rpc('sesion', { ...session(context), p_accion: action, ...auditContext(req) }),
    read: (context, resource, filters = {}) =>
      rpc('leer', { ...session(context), p_recurso: resource, p_filtros: filters }),
    supervision: (context, meses) => rpc('supervision', { ...session(context), p_meses: meses }),
    mutate: (context, action, data, motivo, req) =>
      rpc('mutar', {
        ...session(context),
        p_accion: action,
        p_datos: data,
        p_motivo: motivo,
        ...auditContext(req),
      }),
    attempt: (key, action) => rpc('intento', { p_clave: key, p_accion: action }),
    audit: (context, action, reason, req) =>
      rpc('auditar', {
        p_actor: context?.actorId ?? null,
        p_rol: context?.rol ?? 'sin_rol',
        p_accion: action,
        p_motivo: reason,
        ...auditContext(req),
      }),
    async uploadLogo(path, data) {
      if (!adminGateway) throw unavailable();
      await adminGateway.uploadBrand(path, data);
    },
    async resetPassword(email) {
      if (!adminGateway) throw unavailable();
      await adminGateway.sendRecovery(email);
    },
  };
}

export function deny() {
  return new AppError(403, 'FORBIDDEN', 'Tu rol no tiene permiso para esta acción.');
}
