/* Acceso con JWT del usuario, sin claves privilegiadas · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { createClient } from '@supabase/supabase-js';
import { AppError, unavailable } from '../../lib/errors.js';

const expired = () => new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');

export function createSupabaseGateway(env, fetchImpl = globalThis.fetch) {
  const options = {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: {
      fetch: (input, init = {}) =>
        fetchImpl(input, {
          ...init,
          signal: init.signal
            ? AbortSignal.any([init.signal, AbortSignal.timeout(10_000)])
            : AbortSignal.timeout(10_000),
        }),
    },
  };
  const authClient = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, options);

  return {
    async authenticate(token) {
      const { data, error } = await authClient.auth.getUser(token);
      if (error) {
        if (error.status >= 500 || error.name === 'AuthRetryableFetchError') throw unavailable();
        throw expired();
      }
      if (!data.user || data.user.is_anonymous || !data.user.email_confirmed_at) throw expired();
      return { id: data.user.id, email: data.user.email };
    },
    forToken(token) {
      // Cliente por petición: un token no puede contaminar la sesión de otra petición.
      const db = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
        ...options,
        global: { ...options.global, headers: { Authorization: `Bearer ${token}` } },
        db: { schema: 'cuidared_api' },
      });
      const rpc = async (name, parameters = {}) => {
        const { data, error } = await db.rpc(name, parameters);
        if (error) {
          if (error.code === '42501') throw expired();
          if (error.code === '23505') {
            throw new AppError(
              409,
              'PROFILE_CONFLICT',
              'No se pudo guardar el perfil con esos datos.',
            );
          }
          if (error.code === '22023') {
            throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
          }
          throw unavailable();
        }
        return data;
      };
      return {
        session: (action) => rpc('api_sesion', { p_accion: action }),
        getProfile: () => rpc('api_mi_perfil'),
        updateProfile: (data) => rpc('api_actualizar_mi_perfil', { p_datos: data }),
      };
    },
  };
}
