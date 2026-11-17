/* Cliente service_role aislado para tareas del sistema · CR-160, RS-010. © 2026 Equipo CuidaRed – INTEC. */
import { createClient } from '@supabase/supabase-js';
import { AppError, unavailable } from './errors.js';

// Cliente privado para procesos del sistema. Cada gateway expone sus propias operaciones permitidas.
export function createSystemClient(env, fetchImpl = globalThis.fetch) {
  if (!env.SUPABASE_SECRET_KEY) return null;
  return createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: {
      fetch: (input, init = {}) =>
        fetchImpl(input, { ...init, signal: init.signal ?? AbortSignal.timeout(10_000) }),
    },
  });
}

// Las invitaciones usan Auth y las escrituras de negocio usan el JWT de quien invita.
export function createAdminGateway(env, fetchImpl = globalThis.fetch) {
  const admin = createSystemClient(env, fetchImpl);
  if (!admin) return null;
  return {
    async resendInvitation({ id, email }) {
      const { data, error } = await admin.auth.admin.getUserById(id);
      if (error || !data.user) throw unavailable();
      if (data.user.email?.toLowerCase() !== email.toLowerCase()) throw unavailable();
      if (data.user.email_confirmed_at) return 'perfil_activo';
      if (!data.user.invited_at) {
        throw new AppError(
          409,
          'INVITATION_CONFIRM_SIGNUP',
          'La persona debe confirmar su registro.',
        );
      }
      const { error: invitationError } = await admin.auth.admin.inviteUserByEmail(email);
      if (invitationError?.status === 429) {
        throw new AppError(429, 'RATE_LIMITED', 'Espera un momento antes de intentar de nuevo.');
      }
      if (invitationError) throw unavailable();
      return 'enviada';
    },
    /**
     * Crea la identidad invitada con los datos que exige el trigger de perfil (cédula, nombres, apellidos) y envía
     * el código por correo. Devuelve solo el id de la identidad.
     */
    async inviteUser({ email, cedula, nombres, apellidos }) {
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        data: { cedula, nombres, apellidos },
      });
      if (error) {
        if (error.status === 422 || error.code === 'email_exists') {
          throw new AppError(
            409,
            'INVITATION_CONFLICT',
            'No se pudo invitar a esa persona con esos datos.',
          );
        }
        throw unavailable();
      }
      return { id: data.user.id };
    },
  };
}
