/* Autenticación y permisos de Backoffice · BO-01 a BO-03. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { AppError } from '../../lib/errors.js';
import { deny } from './backoffice-repository.js';

export function backofficeClaims(token, id) {
  let claims;
  try {
    claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
  } catch {
    throw new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');
  }
  if (claims?.sub !== id || !z.uuid().safeParse(claims.session_id).success) {
    throw new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');
  }
  return { actorId: id, sessionId: claims.session_id, aal: claims.aal ?? 'aal1' };
}

export function requireBackoffice(gateway, repository) {
  return async (req, res, next) => {
    const header = req.get('authorization');
    if (!header || header.length > 8192 || !/^Bearer [^\s]+$/i.test(header)) {
      throw new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');
    }
    const token = header.slice(7);
    const identity = await gateway.authenticate(token);
    res.locals.actorId = identity.id;
    // Supabase ha verificado el JWT anterior. Solo entonces utilizamos sus claims de sesión.
    const context = backofficeClaims(token, identity.id);
    const result = await repository.session(context, 'validar', req);
    if (result?.estado === 'mfa') {
      throw new AppError(
        403,
        'MFA_REQUIRED',
        'Verifica tu identidad con la aplicación de autenticación.',
      );
    }
    if (result?.estado === 'expirada')
      throw new AppError(401, 'INVALID_SESSION', 'Tu sesión venció. Inicia sesión de nuevo.');
    if (result?.estado !== 'ok') throw deny();
    res.locals.backoffice = { ...context, rol: result.rol, profile: result };
    next();
  };
}

export function requireRole(repository, ...roles) {
  return async (req, res, next) => {
    const context = res.locals.backoffice;
    if (!roles.includes(context.rol)) {
      await repository.audit(
        context,
        'acceso.denegado',
        'Operación fuera de los permisos del rol',
        req,
      );
      throw deny();
    }
    next();
  };
}
