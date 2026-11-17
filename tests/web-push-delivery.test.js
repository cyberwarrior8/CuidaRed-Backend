/* Prueba del emisor Web Push · RF-18. © 2026 Equipo CuidaRed – INTEC. */
import { generateVAPIDKeys } from 'web-push';
import { describe, expect, it, vi } from 'vitest';
import {
  crearEmisorPush,
  despacharLotePush,
  leerVapid,
} from '../src/modules/web-push/web-push-delivery.js';

const servidor = generateVAPIDKeys();
const navegador = generateVAPIDKeys();
const vapid = { ...servidor, subject: 'mailto:alertas@example.test' };
const entrega = {
  entrega_id: '11111111-1111-4111-8111-111111111111',
  reserva_id: '22222222-2222-4222-8222-222222222222',
  notificacion_id: '33333333-3333-4333-8333-333333333333',
  cuenta_id: '9007199254740993',
  endpoint: 'https://fcm.googleapis.com/fcm/send/sintetico',
  p256dh: navegador.publicKey,
  auth: Buffer.alloc(16, 2).toString('base64url'),
  ttl: 1800,
};

describe('emisor Web Push RF-18', () => {
  it('verifica la pareja VAPID antes de iniciar', () => {
    const env = { SUPABASE_SECRET_KEY: 'sb_secret_demo', WEB_PUSH_PUBLIC_KEY: vapid.publicKey };
    const variables = {
      WEB_PUSH_VAPID_SUBJECT: vapid.subject,
      WEB_PUSH_PRIVATE_KEY: vapid.privateKey,
    };
    expect(leerVapid(env, variables)).toEqual(vapid);
    expect(() =>
      leerVapid(env, { ...variables, WEB_PUSH_PRIVATE_KEY: navegador.privateKey }),
    ).toThrow('Las claves VAPID no forman un par válido.');
  });

  it('envía cifrado con TTL y tema estables, sin seguir redirecciones', async () => {
    const red = vi.fn(async () => new Response(null, { status: 201 }));
    await expect(crearEmisorPush(vapid, red)(entrega)).resolves.toBe('enviada');
    const [url, peticion] = red.mock.calls[0];
    const cabeceras = new Headers(peticion.headers);
    expect(url).toBe(entrega.endpoint);
    expect(peticion).toMatchObject({ method: 'POST', redirect: 'manual' });
    expect(cabeceras.get('content-encoding')).toBe('aes128gcm');
    expect(cabeceras.get('ttl')).toBe('1800');
    expect(cabeceras.get('topic')).toBe(entrega.notificacion_id.replaceAll('-', ''));
    expect(peticion.body.toString()).not.toContain(entrega.cuenta_id);
  });

  it.each([
    [404, 'caducada'],
    [410, 'caducada'],
    [429, 'reintentar'],
    [500, 'reintentar'],
    [403, 'fallida'],
    [302, 'fallida'],
  ])('clasifica %s como %s', async (status, salida) => {
    const red = vi.fn(async () => new Response(null, { status }));
    await expect(crearEmisorPush(vapid, red)(entrega)).resolves.toBe(salida);
    expect(red).toHaveBeenCalledTimes(1);
  });

  it('revalida los destinos y conserva el reintento ante un fallo de red', async () => {
    const red = vi.fn(async () => {
      throw new Error();
    });
    const enviar = crearEmisorPush(vapid, red);
    await expect(
      enviar({ ...entrega, endpoint: 'https://fcm.googleapis.com.ejemplo.test/fcm/send/push' }),
    ).resolves.toBe('caducada');
    expect(red).not.toHaveBeenCalled();
    await expect(enviar(entrega)).resolves.toBe('reintentar');
  });

  it('finaliza cada entrega aunque otra falle', async () => {
    const otra = { ...entrega, entrega_id: entrega.reserva_id };
    const cola = {
      reservar: vi.fn(async () => [entrega, otra]),
      finalizar: vi.fn(async (item) => {
        if (item === otra) throw new Error();
      }),
    };
    const enviar = vi.fn(async () => 'enviada');
    await expect(despacharLotePush(cola, enviar)).resolves.toEqual({ entregadas: 1, fallos: 1 });
    expect(cola.finalizar).toHaveBeenCalledWith(entrega, 'enviada');
    expect(cola.finalizar).toHaveBeenCalledWith(otra, 'enviada');
  });
});
