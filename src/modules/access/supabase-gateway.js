/* Acceso con JWT del usuario, sin claves privilegiadas · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { createClient } from '@supabase/supabase-js';
import { businessError } from '../../lib/business-errors.js';
import { AppError, unavailable } from '../../lib/errors.js';

const expired = () => new AppError(401, 'INVALID_SESSION', 'Inicia sesión de nuevo.');

/**
 * Traduce el error de una RPC a un error público (CR-162). `conflict` permite a cada operación dar su propio
 * código y mensaje para 23505 (p. ej. PROFILE_CONFLICT en el perfil propio).
 */
export function mapRpcError(error, { conflict } = {}) {
  if (error.code === '28000') return new AppError(401, 'UNAUTHORIZED', 'Inicia sesión de nuevo.');
  if (error.code === '42501') {
    return new AppError(403, 'FORBIDDEN', 'No tienes permiso para realizar esta acción.');
  }
  if (error.code === 'P0002') return new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
  if (error.code === '23505') {
    return conflict
      ? new AppError(409, conflict.code, conflict.message)
      : new AppError(
          409,
          'CONFLICT',
          'No se pudo guardar porque entra en conflicto con otro registro.',
        );
  }
  if (error.code === '22023' || error.code === '23514') {
    return new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  }
  // Reglas de negocio señaladas por las RPC (lista cerrada de códigos CR_*).
  if (error.code === 'P0001') return businessError(error.message) ?? unavailable();
  return unavailable();
}

const PROFILE_CONFLICT = {
  code: 'PROFILE_CONFLICT',
  message: 'No se pudo guardar el perfil con esos datos.',
};

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

  // Cliente sin JWT (rol anon) solo para las RPC públicas que lo permiten explícitamente (p. ej. solicitudes de
  // visita de personas externas). Nunca se usa para operaciones de una cuenta.
  const anonDb = createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
    ...options,
    db: { schema: 'cuidared_api' },
  });
  const publicRpc = async (name, parameters = {}, rpcOptions = {}) => {
    if (!/^api_publico_[a-z0-9_]+$/.test(name)) throw new Error('Nombre de RPC pública inválido.');
    const { data, error } = await anonDb.rpc(name, parameters);
    if (error) throw mapRpcError(error, rpcOptions);
    return data;
  };

  return {
    publico: () => ({ rpc: publicRpc }),
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
      /**
       * Llama una RPC de `cuidared_api` con el JWT del usuario (RLS y auth.uid() activos, CR-160).
       * Los módulos de fases 2+ construyen sus repositorios sobre esta función.
       */
      const rpc = async (name, parameters = {}, rpcOptions = {}) => {
        if (!/^api_[a-z0-9_]+$/.test(name)) throw new Error('Nombre de RPC inválido.');
        const { data, error } = await db.rpc(name, parameters);
        if (error) throw mapRpcError(error, rpcOptions);
        return data;
      };
      return {
        rpc,
        session: (action) => rpc('api_sesion', { p_accion: action }),
        getProfile: () => rpc('api_mi_perfil'),
        updateProfile: (data) =>
          rpc('api_actualizar_mi_perfil', { p_datos: data }, { conflict: PROFILE_CONFLICT }),
      };
    },
  };
}
