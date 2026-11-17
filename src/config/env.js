/* Configuración validada al iniciar · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { esClavePublicaPush } from '../lib/web-push-validation.js';

const schema = z
  .object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    SUPABASE_URL: z.url(),
    SUPABASE_PUBLISHABLE_KEY: z.string().startsWith('sb_publishable_'),
    FRONTEND_ORIGINS: z.string().min(1),
    TRUST_PROXY_HOPS: z.coerce.number().int().min(0).max(10).default(0),
    PWA_ORIGIN: z.url().optional(),
    BROWSER_SESSION_KEY: z
      .string()
      .regex(/^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/)
      .optional(),
    // Backoffice, invitaciones y Web Push. Solo en el servidor.
    SUPABASE_SECRET_KEY: z.string().startsWith('sb_secret_').optional(),
    // Reservado para el borrador de solicitudes externas, que no se publica en esta integración.
    CODIGO_SEGUIMIENTO_SECRETO: z.string().min(32).optional(),
    WEB_PUSH_ENABLED: z
      .enum(['true', 'false'])
      .default('false')
      .transform((valor) => valor === 'true'),
    WEB_PUSH_PUBLIC_KEY: z.string().refine(esClavePublicaPush).optional(),
  })
  .refine((env) => !env.WEB_PUSH_ENABLED || !!env.WEB_PUSH_PUBLIC_KEY, {
    path: ['WEB_PUSH_PUBLIC_KEY'],
  });

export function readEnv(input) {
  const result = schema.safeParse(input);
  if (!result.success) {
    // Nunca imprimir valores de configuración: podrían contener credenciales.
    throw new Error(
      `Configuración inválida: ${result.error.issues.map((i) => i.path.join('.')).join(', ')}`,
    );
  }
  const env = result.data;
  const origins = env.FRONTEND_ORIGINS.split(',').map((v) => v.trim());
  for (const value of [env.SUPABASE_URL, ...origins, ...(env.PWA_ORIGIN ? [env.PWA_ORIGIN] : [])]) {
    const url = new URL(value);
    if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Protocolo de URL inválido.');
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if (url.protocol !== 'https:' && (env.NODE_ENV === 'production' || !local)) {
      throw new Error('Se requiere HTTPS; HTTP solo se permite en desarrollo local.');
    }
    if (url.username || url.password || url.search || url.hash) throw new Error('URL inválida.');
  }
  if (
    [...origins, ...(env.PWA_ORIGIN ? [env.PWA_ORIGIN] : [])].some(
      (origin) => new URL(origin).origin !== origin,
    )
  ) {
    throw new Error('FRONTEND_ORIGINS debe contener orígenes exactos sin rutas ni barra final.');
  }
  return { ...env, origins };
}
