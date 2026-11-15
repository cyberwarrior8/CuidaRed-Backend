/* Registro técnico persistente y minimizado · BO-19 a BO-24. © 2026 Equipo CuidaRed – INTEC. */
import { isBigintId } from './bigint-id.js';

const normalizedPath = (path) => {
  const parts = path.split('/').filter(Boolean);
  if (
    !parts
      .slice(0, 3)
      .join('/')
      .match(/^api\/(admin|v1)(\/|$)/)
  )
    return '/';
  return (
    '/' +
    parts
      .map((part) =>
        /^\d+$/.test(part)
          ? ':id'
          : /^[0-9a-f-]{36}$/i.test(part)
            ? ':uuid'
            : routeParts.has(part)
              ? part
              : ':segmento',
      )
      .join('/')
  );
};
const routeParts = new Set(
  (
    'api v1 admin backoffice salud marca cuentas me session activity logout login actividad salida ' +
    'agenda miembros membresias visitas seguimiento sync catalogos operaciones resumen pruebas estado usuarios ' +
    'extender-prueba cambiar-plan configuracion planes pagos metodos logos publicar restaurar logs auditoria ' +
    'recuperacion revocar suscripcion adultos envejecientes contactos necesidades alertas operacion telemetria'
  ).split(' '),
);
const safeCode = (code) =>
  typeof code === 'string' && /^[A-Z][A-Z0-9_]{0,63}$/.test(code) ? code : undefined;
const safeFrames = (error) =>
  typeof error?.stack === 'string'
    ? error.stack
        .split('\n')
        .slice(1, 12)
        .map((line) => {
          const frame = line.match(/(?:[/\\])src[/\\]([a-zA-Z0-9_./\\-]+\.js):(\d+):(\d+)\)?$/);
          return frame
            ? 'src/' + frame[1].replaceAll('\\', '/') + ':' + frame[2] + ':' + frame[3]
            : null;
        })
        .filter(Boolean)
        .join('\n') || null
    : null;

export function createSystemLogger(adminGateway, audit) {
  return async (entry) => {
    if (typeof adminGateway?.backofficeRpc !== 'function') return false;
    try {
      await adminGateway.backofficeRpc('log', entry);
      return true;
    } catch (error) {
      audit({
        requestId: entry.p_evento.request_id,
        action: 'log.persistence',
        result: 'error',
        code: 'LOG_STORAGE_UNAVAILABLE',
        dependency: 'supabase.api_bo_log',
        upstreamStatus: error?.upstreamStatus,
        upstreamCode: error?.upstreamCode,
      });
      return false;
    }
  };
}

export function createLoggingMiddleware(recordLog) {
  return (req, res, next) => {
    const start = performance.now();
    res.on('finish', () => {
      const requestPath = req.originalUrl.split('?')[0];
      const path = normalizedPath(requestPath);
      if (
        path === '/' ||
        (res.statusCode < 400 &&
          (req.method === 'GET' ||
            path.endsWith('/telemetria') ||
            path.endsWith('/actividad') ||
            path.endsWith('/activity')))
      )
        return;
      const origen = path.includes('/sync')
        ? 'sync'
        : /\/(login|session|salida)\b/.test(path)
          ? 'auth'
          : path.startsWith('/api/admin') || path.startsWith('/api/v1/backoffice')
            ? 'backoffice'
            : 'api';
      const code = safeCode(res.locals.errorCode);
      const messages = {
        SYNC_REJECTED: 'Registro de sincronización rechazado',
        SYNC_CONFLICT: 'Conflicto de sincronización',
      };
      const account = requestPath.match(
        /^\/api\/(?:admin|v1(?:\/backoffice)?)\/cuentas\/([0-9]+)(?:\/|$)/,
      )?.[1];
      const common = {
        origen,
        request_id: res.locals.requestId,
        metodo: req.method,
        ruta: path,
        http_status: res.statusCode,
        usuario_id: res.locals.actorId,
        cuenta_id:
          res.locals.cuenta?.cuentaId ??
          res.locals.logCuenta ??
          (isBigintId(account) ? account : undefined),
      };
      void recordLog({
        p_evento: {
          ...common,
          nivel: res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info',
          mensaje: code ? 'Solicitud ' + code : 'Solicitud completada',
          detalle_sanitizado: { duracion_ms: Math.round(performance.now() - start), code },
          stack_sanitizado: safeFrames(res.locals.unexpectedError),
        },
      });
      for (const event of res.locals.syncEvents ?? []) {
        void recordLog({
          p_evento: {
            ...common,
            nivel: 'warn',
            mensaje: messages[event.code],
            detalle_sanitizado: {
              code: safeCode(event.reason) ?? event.code,
              resultado: event.winner,
            },
          },
        });
      }
    });
    next();
  };
}
