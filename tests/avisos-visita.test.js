/* Avisos transaccionales de visitas. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import { enviarAviso } from '../src/modules/visitas/avisos-visita.js';

const config = {
  VISITAS_RESEND_API_KEY: 're_sintetica',
  VISITAS_CORREO_REMITENTE: 'visitas@example.test',
  PWA_ORIGIN: 'https://cuidared.example.test',
};
const aviso = {
  id: 'e1317bfa-9e1c-4da7-bcd4-8628fabcc906',
  evento: 'reprogramada',
  correo: 'visitante@example.test',
  organizacion: 'Centro de prueba',
  cita: '2026-11-20T15:00:00Z',
  fin: '12:00',
  observacion: 'Dato privado que no se envía por correo.',
};

describe('avisos de visitas', () => {
  it('notifica el cambio de horario con una clave estable y sin observaciones', async () => {
    const fetch = vi.fn(async () => new Response('{}', { status: 200 }));
    await expect(enviarAviso(aviso, config, fetch)).resolves.toBe('enviado');
    const [url, peticion] = fetch.mock.calls[0];
    expect(url).toBe('https://api.resend.com/emails');
    expect(peticion.headers['Idempotency-Key']).toBe(`cuidared-visita/${aviso.id}`);
    const correo = JSON.parse(peticion.body);
    expect(correo).toMatchObject({
      to: [aviso.correo],
      subject: 'La organización cambió el horario de tu visita',
    });
    expect(correo.text).toContain('hasta las 12:00');
    expect(correo.text).toContain(`${config.PWA_ORIGIN}/solicitud-visita`);
    expect(correo.text).not.toContain(aviso.observacion);
  });

  it.each([
    [429, 'reintentar'],
    [503, 'reintentar'],
    [422, 'fallido'],
  ])('clasifica HTTP %s como %s', async (codigo, resultado) => {
    await expect(
      enviarAviso(aviso, config, async () => new Response(null, { status: codigo })),
    ).resolves.toBe(resultado);
  });
});
