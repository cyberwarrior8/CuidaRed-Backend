/* Cliente privilegiado aislado para tareas de Auth y del Backoffice. © 2026 Equipo CuidaRed – INTEC. */
import { createClient } from '@supabase/supabase-js';
import { setTimeout as delay } from 'node:timers/promises';
import { mapRpcError } from '../modules/access/supabase-gateway.js';
import { AppError, unavailable } from './errors.js';

const transientStatuses = new Set([0, 502, 503, 504, 520, 521, 522, 523, 524]);
const transientCodes = new Set(['57014', '55P03', 'PGRST003']);

function systemOptions(fetchImpl) {
  return {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: {
      fetch: (input, init = {}) =>
        fetchImpl(input, { ...init, signal: init.signal ?? AbortSignal.timeout(10_000) }),
    },
  };
}

// Cliente privado para procesos del sistema. Cada gateway expone sus operaciones permitidas.
export function createSystemClient(env, fetchImpl = globalThis.fetch) {
  if (!env.SUPABASE_SECRET_KEY) return null;
  return createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, {
    ...systemOptions(fetchImpl),
    db: { schema: 'cuidared_api' },
  });
}

// Las invitaciones usan Auth y las escrituras de negocio usan el JWT de quien invita.
export function createAdminGateway(env, fetchImpl = globalThis.fetch) {
  const admin = createSystemClient(env, fetchImpl);
  if (!admin) return null;
  const publicAuth = createClient(
    env.SUPABASE_URL,
    env.SUPABASE_PUBLISHABLE_KEY,
    systemOptions(fetchImpl),
  ).auth;
  const backofficeRpc = async (name, args) => {
    if (!/^[a-z_]+$/.test(name)) throw new Error('RPC administrativa inválida.');
    const validatingSession = name === 'sesion' && args?.p_accion === 'validar';
    const read = name === 'leer' || name === 'eventos' || validatingSession;
    const rpc = () => admin.rpc('api_bo_' + name, args).retry(false);
    const attempt = () => (read ? rpc().abortSignal(AbortSignal.timeout(5000)) : rpc());
    let result = await attempt();
    if (result.error) {
      const statementRejected = transientCodes.has(result.error.code);
      // Una escritura de log solo se reintenta con un rechazo explícito de PostgREST o PostgreSQL.
      if (
        (read && (statementRejected || transientStatuses.has(result.status))) ||
        (name === 'log' && statementRejected)
      ) {
        await delay(150 + Math.floor(Math.random() * 201));
        result = await attempt();
      }
    }
    if (result.error) {
      const error = mapRpcError(result.error);
      if (error.status === 503) {
        error.dependency = 'supabase.api_bo_' + name;
        error.upstreamStatus = result.status;
        if (typeof result.error.code === 'string' && /^[0-9A-Z]{5,12}$/.test(result.error.code)) {
          error.upstreamCode = result.error.code;
        }
      }
      throw error;
    }
    return result.data;
  };

  // Un cursor compartido por instancia evita un sondeo por navegador y no depende de un JWT service_role legado.
  const listeners = new Set();
  let timer;
  let cursor = null;
  let active = false;
  let degraded = false;
  let failures = 0;
  let retryAt = 0;
  async function poll() {
    if (active || Date.now() < retryAt) return;
    active = true;
    try {
      const result = await backofficeRpc('eventos', { p_cursor: cursor });
      if (listeners.size) {
        cursor = result.cursor;
        if (degraded) for (const listen of listeners) listen('recuperado');
        // El socket envía su propio evento de conexión al abrirse.
        for (const theme of result.temas) {
          if (theme !== 'conexion') for (const listen of listeners) listen(theme);
        }
      }
      degraded = false;
      failures = 0;
      retryAt = 0;
    } catch {
      if (!degraded) for (const listen of listeners) listen('degradado');
      degraded = true;
      failures = Math.min(failures + 1, 4);
      retryAt = Date.now() + Math.min(15000, 1500 * 2 ** failures);
    } finally {
      active = false;
    }
  }

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
     * Crea la identidad invitada con los datos exigidos por el perfil y devuelve su id.
     */
    async inviteUser({ email, cedula, nombres, apellidos }) {
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        data: { cedula, nombres, apellidos },
      });
      if (error) {
        if (error.status === 422 || error.code === 'email_exists')
          throw new AppError(
            409,
            'INVITATION_CONFLICT',
            'No se pudo invitar a esa persona con esos datos.',
          );
        throw unavailable();
      }
      return { id: data.user.id };
    },
    backofficeRpc,
    async sendRecovery(email) {
      const { error } = await publicAuth.resetPasswordForEmail(email, {
        ...(env.PWA_ORIGIN ? { redirectTo: env.PWA_ORIGIN + '/restablecer' } : {}),
      });
      if (error) throw unavailable();
    },
    async uploadBrand(path, data) {
      const { error } = await admin.storage
        .from('cuidared-marca')
        .upload(path, data, { contentType: 'image/png', cacheControl: '31536000' });
      if (error) throw unavailable();
    },
    watchBackoffice(listener) {
      listeners.add(listener);
      if (degraded) listener('degradado');
      if (!timer) {
        timer = setInterval(poll, 1500).unref();
        void poll();
      }
      return () => {
        listeners.delete(listener);
        if (!listeners.size) {
          clearInterval(timer);
          timer = undefined;
          cursor = null;
        }
      };
    },
  };
}
