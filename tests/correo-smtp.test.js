/* SMTP de visitas sin dominio propio: TLS, selección, errores y secretos. © 2026 Equipo CuidaRed – INTEC. */
import { afterEach, describe, expect, it, vi } from 'vitest';
import nodemailer from 'nodemailer';
import { correoVisitaConfigurado, readEnv } from '../src/config/env.js';
import { enviarCorreoVisita } from '../src/modules/visitas/avisos-visita.js';
import { enviarCorreoSmtp } from '../src/modules/visitas/correo-smtp.js';

const config = {
  VISITAS_CORREO_PROVEEDOR: 'smtp',
  VISITAS_CORREO_REMITENTE: 'proyecto@example.test',
  VISITAS_SMTP_HOST: 'smtp.example.test',
  VISITAS_SMTP_PORT: 465,
  VISITAS_SMTP_USUARIO: 'proyecto@example.test',
  VISITAS_SMTP_PASSWORD: 'secreto-sintetico-no-real',
  PWA_ORIGIN: 'http://localhost:5173',
};
const mensaje = {
  to: ['visitante@example.test'],
  subject: 'Solicitud recibida',
  text: 'Pendiente de revisión.',
};
const baseEnv = {
  SUPABASE_URL: 'https://cuidared.example.test',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_prueba',
  SUPABASE_SECRET_KEY: 'sb_secret_prueba',
  FRONTEND_ORIGINS: 'http://localhost:5173',
};
const transporte = () => ({
  sendMail: vi.fn(async () => ({ accepted: mensaje.to, rejected: [] })),
  close: vi.fn(),
});

afterEach(() => vi.restoreAllMocks());

describe('correo SMTP de visitas', () => {
  it('envía desde la cuenta autenticada con TLS y un Message-ID estable y cierra la conexión', async () => {
    const smtp = transporte();
    const crear = vi.fn(() => smtp);
    const primero = await enviarCorreoSmtp(mensaje, config, 'aviso/1', crear);
    const segundo = await enviarCorreoSmtp(mensaje, config, 'aviso/1', crear);
    expect(primero).toMatchObject({ resultado: 'enviado', codigo: null });
    expect(segundo.proveedorId).toBe(primero.proveedorId);
    expect(primero.proveedorId).toMatch(/^<cuidared\.[0-9a-f]{64}@example\.test>$/);
    expect(crear).toHaveBeenCalledWith(
      expect.objectContaining({
        secure: true,
        requireTLS: true,
        logger: false,
        debug: false,
        tls: { minVersion: 'TLSv1.2', rejectUnauthorized: true },
      }),
    );
    expect(smtp.sendMail).toHaveBeenCalledWith(
      expect.objectContaining({
        from: { name: 'CuidaRed', address: config.VISITAS_CORREO_REMITENTE },
      }),
    );
    expect(smtp.close).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(primero)).not.toContain(config.VISITAS_SMTP_PASSWORD);
  });

  it('exige STARTTLS en el puerto 587', async () => {
    const crear = vi.fn(transporte);
    await enviarCorreoSmtp(mensaje, { ...config, VISITAS_SMTP_PORT: 587 }, 'aviso/2', crear);
    expect(crear).toHaveBeenCalledWith(
      expect.objectContaining({ port: 587, secure: false, requireTLS: true }),
    );
  });

  it.each([
    ['EAUTH', 535, 'fallido', 'SMTP_AUTH_UNAVAILABLE'],
    ['ETIMEDOUT', undefined, 'reintentar', 'SMTP_TEMPORARILY_UNAVAILABLE'],
    ['EENVELOPE', 451, 'reintentar', 'SMTP_TEMPORARILY_UNAVAILABLE'],
    ['EENVELOPE', 550, 'fallido', 'SMTP_SEND_FAILED'],
  ])(
    'clasifica %s y no revela la respuesta privada del servidor',
    async (code, responseCode, resultado, codigo) => {
      const smtp = transporte();
      smtp.sendMail.mockRejectedValue({
        code,
        responseCode,
        message: config.VISITAS_SMTP_PASSWORD,
        response: mensaje.to[0],
      });
      const entrega = await enviarCorreoSmtp(mensaje, config, 'aviso/3', () => smtp);
      expect(entrega).toEqual({ resultado, codigo, proveedorId: null, httpStatus: null });
      expect(smtp.close).toHaveBeenCalledOnce();
      expect(JSON.stringify(entrega)).not.toContain(config.VISITAS_SMTP_PASSWORD);
      expect(JSON.stringify(entrega)).not.toContain(mensaje.to[0]);
    },
  );

  it('no da por enviado un correo rechazado', async () => {
    const smtp = transporte();
    smtp.sendMail.mockResolvedValue({ accepted: [], rejected: mensaje.to });
    await expect(enviarCorreoSmtp(mensaje, config, 'aviso/4', () => smtp)).resolves.toMatchObject({
      resultado: 'fallido',
      codigo: 'SMTP_RECIPIENT_REJECTED',
    });
  });

  it('selecciona SMTP sin consultar Resend', async () => {
    vi.spyOn(nodemailer, 'createTransport').mockReturnValue(transporte());
    const fetch = vi.fn();
    await expect(enviarCorreoVisita(mensaje, config, 'aviso/5', fetch)).resolves.toMatchObject({
      resultado: 'enviado',
    });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('permite preparar SMTP en pausa y requiere credenciales antes de habilitarlo', () => {
    const pausado = {
      ...baseEnv,
      VISITAS_CORREO_PROVEEDOR: 'smtp',
      VISITAS_CORREO_HABILITADO: '0',
      VISITAS_SMTP_PASSWORD: '',
      VISITAS_CORREO_REMITENTE: '',
    };
    expect(correoVisitaConfigurado(readEnv(pausado))).toBe(false);
    expect(() => readEnv({ ...pausado, VISITAS_CORREO_HABILITADO: '1' })).toThrow(
      'VISITAS_SMTP_PASSWORD',
    );
    expect(correoVisitaConfigurado(readEnv({ ...baseEnv, ...config }))).toBe(true);
  });

  it('rechaza remitentes ajenos, puertos sin TLS y proveedores desconocidos sin exponer secretos', () => {
    expect(() =>
      readEnv({ ...baseEnv, ...config, VISITAS_CORREO_REMITENTE: 'otra@example.test' }),
    ).toThrow('debe coincidir');
    expect(() => readEnv({ ...baseEnv, ...config, VISITAS_SMTP_PORT: '25' })).toThrow(
      'VISITAS_SMTP_PORT',
    );
    expect(() => readEnv({ ...baseEnv, ...config, VISITAS_CORREO_PROVEEDOR: 'otro' })).toThrow(
      'VISITAS_CORREO_PROVEEDOR',
    );
  });
});
