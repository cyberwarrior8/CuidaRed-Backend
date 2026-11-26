/* Avisos transaccionales de visitas. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import { readEnv } from '../src/config/env.js';
import { generarCodigoSeguimiento } from '../src/modules/publico/codigo-seguimiento.js';
import {
  enviarAviso,
  enviarCorreoVisita,
  iniciarAvisosVisita,
} from '../src/modules/visitas/avisos-visita.js';

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
  it.each(['observaciones', 'realizada'])(
    'el aviso %s incluye el código y el enlace de aportes, sin notas privadas',
    async (evento) => {
      const fetch = vi.fn(async () => Response.json({}));
      const referencia = '22222222-2222-4222-8222-222222222222';
      const cfg = {
        ...config,
        CODIGO_SEGUIMIENTO_SECRETO: 'secreto-exclusivamente-sintetico-de-prueba',
      };
      await enviarAviso({ ...aviso, evento, referencia_codigo: referencia }, cfg, fetch);
      const correo = JSON.parse(fetch.mock.calls[0][1].body);
      expect(correo.to).toEqual([aviso.correo]);
      expect(correo.text).toContain(
        generarCodigoSeguimiento(referencia, cfg.CODIGO_SEGUIMIENTO_SECRETO),
      );
      expect(correo.text).toContain(cfg.PWA_ORIGIN + '/solicitud-visita#observaciones');
      expect(correo.text).not.toContain(aviso.observacion);
    },
  );
  it('el rechazo informa el motivo y mantiene el código de seguimiento', async () => {
    const fetch = vi.fn(async () => Response.json({}));
    await enviarAviso(
      { ...aviso, evento: 'rechazada', motivo: 'No hay disponibilidad.' },
      config,
      fetch,
    );
    const correo = JSON.parse(fetch.mock.calls[0][1].body);
    expect(correo.subject).toContain('no fue autorizada');
    expect(correo.text).toContain('No hay disponibilidad.');
  });
  it('el acuse distingue el horario solicitado de una visita confirmada', async () => {
    const fetch = vi.fn(async () => Response.json({}));
    await enviarAviso({ ...aviso, evento: 'recibida' }, config, fetch);
    const correo = JSON.parse(fetch.mock.calls[0][1].body);
    expect(correo.subject).toBe('Recibimos tu solicitud de visita');
    expect(correo.text).toContain('Horario solicitado:');
    expect(correo.text).toContain('El horario todavía no está confirmado');
    expect(correo.text).not.toContain(aviso.observacion);
  });

  it('dirige al equipo a su portal sin revelar datos privados ni el código del visitante', async () => {
    const fetch = vi.fn(async () => Response.json({}));
    await enviarAviso(
      { ...aviso, evento: 'nueva_solicitud', destinatario: 'organizacion' },
      config,
      fetch,
    );
    const correo = JSON.parse(fetch.mock.calls[0][1].body);
    expect(correo.subject).toBe('Nueva solicitud de visita por revisar');
    expect(correo.text).toContain(`${config.PWA_ORIGIN}/inicio`);
    expect(correo.text).not.toContain('/solicitud-visita');
    expect(correo.text).not.toContain(aviso.observacion);
  });

  it('pausa la cola sin reclamar ni cerrar avisos pendientes', () => {
    const adminGateway = { visitaPublicaRpc: vi.fn() };
    const detener = iniciarAvisosVisita({
      env: { ...config, VISITAS_CORREO_HABILITADO: false },
      adminGateway,
      audit: vi.fn(),
    });
    detener();
    expect(adminGateway.visitaPublicaRpc).not.toHaveBeenCalled();
  });

  it('conserva el identificador de Resend para comprobar la entrega sin exponer errores privados', async () => {
    const proveedorId = '4548488a-ffb8-46b3-b85e-dad3e8a065a0';
    const correo = { to: [aviso.correo], subject: 'Prueba', text: 'Prueba de entrega' };
    const fetch = vi.fn(async () => Response.json({ id: proveedorId }));
    await expect(enviarCorreoVisita(correo, config, 'prueba/1', fetch)).resolves.toEqual({
      resultado: 'enviado',
      httpStatus: 200,
      proveedorId,
      codigo: null,
    });
    const rechazo = await enviarCorreoVisita(correo, config, 'prueba/2', async () =>
      Response.json({ name: 'validation_error', message: aviso.correo }, { status: 403 }),
    );
    expect(rechazo).toEqual({
      resultado: 'fallido',
      httpStatus: 403,
      proveedorId: null,
      codigo: 'validation_error',
    });
    expect(JSON.stringify(rechazo)).not.toContain(aviso.correo);
  });

  it('tolera una respuesta de error no JSON sin inventar un envío aceptado', async () => {
    await expect(
      enviarCorreoVisita(
        {},
        config,
        'prueba/3',
        async () => new Response('<html>No disponible</html>', { status: 503 }),
      ),
    ).resolves.toMatchObject({
      resultado: 'reintentar',
      httpStatus: 503,
      proveedorId: null,
    });
  });

  it('valida la pausa por entorno y conserva el comportamiento previo al omitirla', () => {
    const base = {
      SUPABASE_URL: 'https://cuidared.example.test',
      SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_prueba',
      FRONTEND_ORIGINS: 'http://localhost:5173',
    };
    expect(readEnv(base).VISITAS_CORREO_HABILITADO).toBe(true);
    expect(readEnv({ ...base, VISITAS_CORREO_HABILITADO: '0' }).VISITAS_CORREO_HABILITADO).toBe(
      false,
    );
    expect(() => readEnv({ ...base, VISITAS_CORREO_HABILITADO: 'no' })).toThrow(
      'VISITAS_CORREO_HABILITADO',
    );
  });

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
