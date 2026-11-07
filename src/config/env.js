/* Configuración validada al iniciar · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  SUPABASE_URL: z.url(),
  SUPABASE_PUBLISHABLE_KEY: z.string().startsWith('sb_publishable_'),
  FRONTEND_ORIGINS: z.string().min(1),
  // CR-160: opcional; solo habilita invitar miembros nuevos (crear su identidad Auth). Nunca va al frontend.
  SUPABASE_SECRET_KEY: z.string().startsWith('sb_secret_').optional(),
  // Secreto del servidor para la huella HMAC de los códigos de seguimiento de visitantes (obligatorio en producción).
  CODIGO_SEGUIMIENTO_SECRETO: z.string().min(32).optional(),
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
  if (env.NODE_ENV === 'production' && !env.CODIGO_SEGUIMIENTO_SECRETO) {
    throw new Error('Configuración inválida: CODIGO_SEGUIMIENTO_SECRETO');
  }
  const origins = env.FRONTEND_ORIGINS.split(',').map((v) => v.trim());
  for (const value of [env.SUPABASE_URL, ...origins]) {
    const url = new URL(value);
    if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Protocolo de URL inválido.');
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if (url.protocol !== 'https:' && (env.NODE_ENV === 'production' || !local)) {
      throw new Error('Se requiere HTTPS; HTTP solo se permite en desarrollo local.');
    }
    if (url.username || url.password || url.search || url.hash) throw new Error('URL inválida.');
  }
  if (origins.some((origin) => new URL(origin).origin !== origin)) {
    throw new Error('FRONTEND_ORIGINS debe contener orígenes exactos sin rutas ni barra final.');
  }
  return { ...env, origins };
}
