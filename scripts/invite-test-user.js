/* Invitación administrativa manual de pruebas · ID01. © 2026 Equipo CuidaRed – INTEC. */
import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import { z } from 'zod';

dotenv.config({ quiet: true });

const invalidProfile =
  'Define INVITATION_PROFILE_JSON con email, cedula, nombres y apellidos válidos.';
const invalidUrl =
  'Configura SUPABASE_URL en .env con el origen HTTPS de Supabase, sin credenciales, rutas, consultas ni fragmentos.';
const invalidKey =
  'SUPABASE_ADMIN_KEY debe contener una clave secret completa que comience por sb_secret_. No uses la publicable ni la contraseña de Gmail.';
const connectionCodes = new Set([
  'ENOTFOUND',
  'EAI_AGAIN',
  'ETIMEDOUT',
  'ECONNRESET',
  'ECONNREFUSED',
  'UND_ERR_CONNECT_TIMEOUT',
  'CERT_HAS_EXPIRED',
  'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
]);

const profileSchema = z
  .object({
    email: z.email(),
    cedula: z.string().regex(/^\d{11}$/),
    nombres: z.string().trim().min(1).max(100),
    apellidos: z.string().trim().min(1).max(100),
  })
  .strict();

async function main() {
  let profile;
  try {
    profile = profileSchema.parse(JSON.parse(process.env.INVITATION_PROFILE_JSON ?? ''));
  } catch {
    throw new Error(invalidProfile);
  }
  let baseUrl;
  try {
    const url = new URL(process.env.SUPABASE_URL ?? '');
    if (
      url.protocol !== 'https:' ||
      url.username ||
      url.password ||
      url.pathname !== '/' ||
      url.search ||
      url.hash
    ) {
      throw new Error(invalidUrl);
    }
    baseUrl = url.origin;
  } catch {
    throw new Error(invalidUrl);
  }
  if (!process.argv.includes('--send')) {
    console.info('Datos válidos. Sin --send no se contacta Supabase ni se envía correo.');
    return;
  }
  const key = process.env.SUPABASE_ADMIN_KEY?.trim();
  if (!key || !/^sb_secret_[A-Za-z0-9_-]+$/.test(key)) {
    throw new Error(invalidKey);
  }
  const client = createClient(baseUrl, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data, error } = await client.auth.admin.inviteUserByEmail(profile.email, {
    data: {
      cedula: profile.cedula,
      nombres: profile.nombres,
      apellidos: profile.apellidos,
    },
  });
  if (error || !data.user?.id) {
    console.error(
      'No se confirmó la invitación. Revisa Auth y sus logs antes de repetir el envío.',
    );
    if (
      typeof error?.code === 'string' &&
      /^[a-z][a-z0-9_]{0,79}$/.test(error.code) &&
      !error.code.startsWith('sb_')
    ) {
      console.error(`Código del proveedor: ${error.code}`);
    }
    if (Number.isInteger(error?.status)) console.error(`Estado HTTP: ${error.status}`);
    process.exitCode = 1;
    return;
  }
  console.info('Supabase aceptó la invitación. Comprueba el perfil y la recepción del correo.');
}

main().catch((error) => {
  // Solo mensajes propios o códigos conocidos; nunca imprimir excepciones del SDK con credenciales.
  if ([invalidProfile, invalidUrl, invalidKey].includes(error?.message)) {
    console.error(error.message);
  } else {
    const code = error?.cause?.code ?? error?.code;
    console.error('No se completó la operación por un fallo de conexión o ejecución.');
    if (connectionCodes.has(code)) console.error(`Código de conexión: ${code}`);
    console.error('Comprueba Auth y sus logs antes de repetir el envío.');
  }
  process.exitCode = 1;
});
