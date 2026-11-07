/* Cliente service_role aislado para tareas del sistema · CR-160, RS-010. © 2026 Equipo CuidaRed – INTEC. */
import { createClient } from '@supabase/supabase-js';
import { AppError, unavailable } from './errors.js';

/*
 * Único punto con la clave secreta. Solo se crea si SUPABASE_SECRET_KEY está configurada y expone una lista
 * cerrada de operaciones que no pueden hacerse con el JWT del usuario (crear la identidad Auth de un invitado).
 * Nunca lee ni escribe tablas de negocio: la membresía la crea una RPC con el JWT de quien invita, que es la que
 * autoriza. La clave no se registra, no se devuelve y no llega al frontend.
 */
export function createAdminGateway(env, fetchImpl = globalThis.fetch) {
  if (!env.SUPABASE_SECRET_KEY) return null;
  const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: {
      fetch: (input, init = {}) =>
        fetchImpl(input, { ...init, signal: init.signal ?? AbortSignal.timeout(10_000) }),
    },
  });
  return {
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
