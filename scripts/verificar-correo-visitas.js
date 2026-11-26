/* Diagnóstico y prueba explícita del correo de visitas. © 2026 Equipo CuidaRed – INTEC. */
import 'dotenv/config';
import { randomUUID } from 'node:crypto';
import { parseArgs } from 'node:util';
import { z } from 'zod';
import { correoVisitaConfigurado, readEnv } from '../src/config/env.js';
import { enviarCorreoVisita } from '../src/modules/visitas/avisos-visita.js';

async function iniciar() {
  const { values } = parseArgs({
    options: { 'enviar-a': { type: 'string' } },
    allowPositionals: false,
  });
  const env = readEnv(process.env);
  console.log(
    JSON.stringify({
      proveedor: env.VISITAS_CORREO_PROVEEDOR,
      remitente: env.VISITAS_CORREO_REMITENTE || null,
      credencialesConfiguradas: correoVisitaConfigurado(env),
      colaHabilitada: env.VISITAS_CORREO_HABILITADO && correoVisitaConfigurado(env),
      origenSeguimiento: env.PWA_ORIGIN || null,
    }),
  );
  if (!values['enviar-a']) {
    console.log('Diagnóstico local: no se enviaron correos ni se consumió la cola.');
    console.log('Para una prueba explícita: npm run visitas:correo -- --enviar-a=TU_BUZON');
    return;
  }
  const destinatario = z.email().safeParse(values['enviar-a']);
  if (!destinatario.success) throw new Error('Indica un destinatario válido con --enviar-a.');
  if (!correoVisitaConfigurado(env))
    throw new Error(
      'Completa el remitente y las credenciales del proveedor elegido en el .env del backend.',
    );
  const entrega = await enviarCorreoVisita(
    {
      to: [destinatario.data],
      subject: 'CuidaRed · prueba del correo de visitas',
      text: [
        'Este es un correo de prueba de la configuración de visitas de CuidaRed.',
        'No corresponde a una solicitud ni confirma una cita.',
        `El seguimiento de solicitudes está disponible en ${env.PWA_ORIGIN}/solicitud-visita.`,
        'Esta prueba no consume avisos pendientes ni modifica visitas.',
      ].join('\n\n'),
    },
    env,
    `cuidared-prueba/${randomUUID()}`,
  );
  console.log(JSON.stringify(entrega));
  if (entrega.resultado !== 'enviado') {
    throw new Error(
      'El proveedor no aceptó la prueba. Revisa las credenciales y el permiso de envío.',
    );
  }
  if (env.VISITAS_CORREO_PROVEEDOR === 'smtp') {
    console.log(
      'El servidor de correo aceptó la prueba. Revisa el buzón del destinatario y spam; la aceptación no confirma su recepción.',
    );
  } else {
    console.log(
      'Resend aceptó la prueba. Confirma Delivered en Emails → Sending y revisa el buzón y spam.',
    );
    if (entrega.proveedorId) console.log(`https://resend.com/emails/${entrega.proveedorId}`);
  }
}

iniciar().catch((error) => {
  // No mostrar errores de transporte completos ni datos de configuración.
  console.error(
    error instanceof TypeError ? 'No se pudo conectar con el proveedor de correo.' : error.message,
  );
  process.exitCode = 1;
});
