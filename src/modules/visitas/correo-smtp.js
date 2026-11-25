/* Avisos de visitas desde un buzón existente, sin dominio propio. © 2026 Equipo CuidaRed – INTEC. */
import { createHash } from 'node:crypto';
import nodemailer from 'nodemailer';

export async function enviarCorreoSmtp(
  mensaje,
  config,
  idempotencia,
  crearTransporte = nodemailer.createTransport,
) {
  const transporte = crearTransporte({
    host: config.VISITAS_SMTP_HOST,
    port: config.VISITAS_SMTP_PORT ?? 465,
    secure: (config.VISITAS_SMTP_PORT ?? 465) === 465,
    requireTLS: true,
    tls: { minVersion: 'TLSv1.2', rejectUnauthorized: true },
    auth: { user: config.VISITAS_SMTP_USUARIO, pass: config.VISITAS_SMTP_PASSWORD },
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 10000,
    disableFileAccess: true,
    disableUrlAccess: true,
    logger: false,
    debug: false,
  });
  const dominio = config.VISITAS_CORREO_REMITENTE.split('@')[1].toLowerCase();
  const messageId = `<cuidared.${createHash('sha256').update(idempotencia).digest('hex')}@${dominio}>`;
  try {
    const resultado = await transporte.sendMail({
      from: { name: 'CuidaRed', address: config.VISITAS_CORREO_REMITENTE },
      to: mensaje.to,
      subject: mensaje.subject,
      text: mensaje.text,
      messageId,
      disableFileAccess: true,
      disableUrlAccess: true,
    });
    const aceptado = resultado.accepted?.length > 0 && !resultado.rejected?.length;
    return {
      resultado: aceptado ? 'enviado' : 'fallido',
      httpStatus: null,
      proveedorId: aceptado ? messageId : null,
      codigo: aceptado ? null : 'SMTP_RECIPIENT_REJECTED',
    };
  } catch (error) {
    const temporal =
      (error.responseCode >= 400 && error.responseCode < 500) ||
      ['ETIMEDOUT', 'ECONNRESET', 'ECONNECTION', 'ESOCKET', 'EDNS'].includes(error.code);
    return {
      resultado: temporal ? 'reintentar' : 'fallido',
      httpStatus: null,
      proveedorId: null,
      codigo:
        error.code === 'EAUTH'
          ? 'SMTP_AUTH_UNAVAILABLE'
          : temporal
            ? 'SMTP_TEMPORARILY_UNAVAILABLE'
            : 'SMTP_SEND_FAILED',
    };
  } finally {
    transporte.close();
  }
}
