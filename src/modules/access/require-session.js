/* Autenticación y revocación actual por petición · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { AppError, unavailable } from '../../lib/errors.js';

export const invalidSession = () => new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');

export function bearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string' || header.length > 8192 || !/^Bearer [^\s]+$/i.test(header)) {
    throw invalidSession();
  }
  return header.slice(7);
}

export async function resolveSession(gateway, token, onIdentity = () => {}) {
  const identity = await gateway.authenticate(token);
  onIdentity(identity);
  const repository = gateway.forToken(token);
  const session = await repository.session('validar');
  if (!session || typeof session.vigente !== 'boolean') throw unavailable();
  if (!session.vigente && session.motivo === 'usuario_inactivo') {
    throw new AppError(403, 'USER_INACTIVE', 'Tu usuario no está activo.');
  }
  if (!session.vigente && session.motivo === 'cuenta_deshabilitada') {
    throw new AppError(
      403,
      'ACCOUNT_DISABLED',
      'La cuenta está deshabilitada. Contacta a soporte. Los registros pendientes no se sincronizaron.',
    );
  }
  if (!session.vigente) throw invalidSession();
  const profile = await repository.getProfile();
  if (!profile)
    throw new AppError(
      409,
      'PROFILE_REQUIRED',
      'El perfil de tu invitación no está disponible. Contacta a la persona responsable.',
    );
  if (profile && profile.usuario_id !== identity.id) throw unavailable();
  if (profile && profile.estado !== 'activo') {
    throw new AppError(403, 'USER_INACTIVE', 'Tu usuario no está activo.');
  }
  return { identity, repository, profile };
}

export function requireSession(gateway) {
  return async (req, res, next) => {
    res.locals.access = await resolveSession(gateway, bearerToken(req), (identity) => {
      res.locals.actorId = identity.id;
    });
    next();
  };
}
