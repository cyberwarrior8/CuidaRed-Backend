/* Configuración validada al iniciar · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { esClavePublicaPush } from '../lib/web-push-validation.js';

const opcional = (regla) =>
  z.preprocess((valor) => (valor === '' ? undefined : valor), regla.optional());

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
    VISITAS_PUBLICAS_HABILITADAS: z
      .enum(['0', '1'])
      .default('0')
      .transform((valor) => valor === '1'),
    VISITAS_RESEND_API_KEY: z.string().startsWith('re_').optional(),
    VISITAS_CORREO_REMITENTE: opcional(z.email()),
    VISITAS_CORREO_PROVEEDOR: z.enum(['resend', 'smtp']).default('resend'),
    VISITAS_SMTP_HOST: opcional(z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$/)),
    VISITAS_SMTP_PORT: z.coerce
      .number()
      .int()
      .refine((puerto) => [465, 587].includes(puerto))
      .default(465),
    VISITAS_SMTP_USUARIO: opcional(z.email()),
    VISITAS_SMTP_PASSWORD: opcional(z.string().min(1)),
    VISITAS_CORREO_HABILITADO: z
      .enum(['0', '1'])
      .default('1')
      .transform((valor) => valor === '1'),
    CODIGO_SEGUIMIENTO_SECRETO: z.string().min(32).optional(),
    WEB_PUSH_ENABLED: z
      .enum(['true', 'false'])
      .default('false')
      .transform((valor) => valor === 'true'),
    WEB_PUSH_PUBLIC_KEY: z.string().refine(esClavePublicaPush).optional(),
    STRIPE_SANDBOX_ENABLED: z
      .enum(['true', 'false'])
      .default('false')
      .transform((valor) => valor === 'true'),
    STRIPE_SECRET_KEY: z
      .string()
      .regex(/^(?:sk|rk)_test_[A-Za-z0-9]+$/)
      .optional(),
    STRIPE_WEBHOOK_SECRET: z
      .string()
      .regex(/^whsec_[A-Za-z0-9]+$/)
      .optional(),
    STRIPE_SANDBOX_PRODUCTS_JSON: z.string().optional(),
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
  if (
    env.VISITAS_CORREO_PROVEEDOR === 'resend' &&
    (env.VISITAS_RESEND_API_KEY || env.VISITAS_CORREO_REMITENTE) &&
    (!env.VISITAS_RESEND_API_KEY ||
      !env.VISITAS_CORREO_REMITENTE ||
      !env.PWA_ORIGIN ||
      !env.SUPABASE_SECRET_KEY)
  ) {
    throw new Error(
      'Configura VISITAS_RESEND_API_KEY, VISITAS_CORREO_REMITENTE, PWA_ORIGIN y SUPABASE_SECRET_KEY para enviar avisos.',
    );
  }
  if (env.VISITAS_CORREO_PROVEEDOR === 'smtp') {
    if (
      env.VISITAS_CORREO_HABILITADO &&
      (!correoVisitaConfigurado(env) || !env.SUPABASE_SECRET_KEY)
    ) {
      throw new Error(
        'Configura VISITAS_CORREO_REMITENTE, VISITAS_SMTP_HOST, VISITAS_SMTP_USUARIO, VISITAS_SMTP_PASSWORD, PWA_ORIGIN y SUPABASE_SECRET_KEY para enviar avisos por SMTP.',
      );
    }
    if (
      env.VISITAS_SMTP_USUARIO &&
      env.VISITAS_CORREO_REMITENTE &&
      env.VISITAS_SMTP_USUARIO.toLowerCase() !== env.VISITAS_CORREO_REMITENTE.toLowerCase()
    ) {
      throw new Error('VISITAS_CORREO_REMITENTE debe coincidir con VISITAS_SMTP_USUARIO.');
    }
  }
  if (
    env.VISITAS_PUBLICAS_HABILITADAS &&
    (!env.SUPABASE_SECRET_KEY || !env.CODIGO_SEGUIMIENTO_SECRETO)
  ) {
    throw new Error(
      'Configura SUPABASE_SECRET_KEY y CODIGO_SEGUIMIENTO_SECRETO para habilitar las visitas públicas.',
    );
  }
  const origins = env.FRONTEND_ORIGINS.split(',').map((v) => v.trim());
  if (
    env.STRIPE_SANDBOX_ENABLED &&
    (!env.STRIPE_SECRET_KEY ||
      !env.STRIPE_WEBHOOK_SECRET ||
      !env.SUPABASE_SECRET_KEY ||
      !env.PWA_ORIGIN ||
      !origins.includes(env.PWA_ORIGIN))
  ) {
    throw new Error(
      'Stripe Sandbox requiere STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, SUPABASE_SECRET_KEY y PWA_ORIGIN autorizado.',
    );
  }
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
  const productoId = z.string().regex(/^prod_[A-Za-z0-9]+$/);
  const productos = z.strictObject({
    basico_familiar: productoId,
    cuidado_integral: productoId,
    operacion_base: productoId,
    gestion_comunitaria_avanzada: productoId,
  });
  let stripeProducts = null;
  if (env.STRIPE_SANDBOX_PRODUCTS_JSON) {
    try {
      stripeProducts = productos.parse(JSON.parse(env.STRIPE_SANDBOX_PRODUCTS_JSON));
      if (new Set(Object.values(stripeProducts)).size !== 4) throw new Error();
    } catch {
      throw new Error('Configuración inválida: STRIPE_SANDBOX_PRODUCTS_JSON');
    }
  }
  return { ...env, origins, stripeProducts };
}

export function correoVisitaConfigurado(env) {
  return Boolean(
    env.VISITAS_CORREO_REMITENTE &&
    env.PWA_ORIGIN &&
    (env.VISITAS_CORREO_PROVEEDOR === 'smtp'
      ? env.VISITAS_SMTP_HOST && env.VISITAS_SMTP_USUARIO && env.VISITAS_SMTP_PASSWORD
      : env.VISITAS_RESEND_API_KEY),
  );
}
