/* Contrato HTTP de suscripciones Web Push · RF-18/RF-21. © 2026 Equipo CuidaRed – INTEC. */
import { createECDH } from 'node:crypto';
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { readEnv } from '../src/config/env.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { conSesion, perfil, rpcPorNombre, usuarioId } from './cuentas-support.js';

const prefijo = '/api/v1/notificaciones-push';
const prueba = createECDH('prime256v1');
prueba.setPrivateKey(Buffer.alloc(32, 1));
const clavePublica = prueba.getPublicKey().toString('base64url');
const secreto = Buffer.alloc(16, 2).toString('base64url');
const endpoint = 'https://fcm.googleapis.com/fcm/send/sintetico-1:aviso';
const suscripcion = { endpoint, keys: { p256dh: clavePublica, auth: secreto } };

function montar(rpc, habilitado = true) {
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue(perfil),
    rpc,
  };
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: usuarioId, email: perfil.correo }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const audit = vi.fn();
  const app = createApp({
    env: {
      origins: ['http://localhost:5173'],
      WEB_PUSH_ENABLED: habilitado,
      WEB_PUSH_PUBLIC_KEY: clavePublica,
    },
    gateway,
    audit,
  });
  return { app, audit, gateway };
}

describe('configuración Web Push (RF-18)', () => {
  const env = {
    SUPABASE_URL: 'https://proyecto.example.test',
    SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_example',
    FRONTEND_ORIGINS: 'http://localhost:5173',
  };

  it('arranca deshabilitado por defecto y exige una clave VAPID real si se activa', () => {
    expect(readEnv(env).WEB_PUSH_ENABLED).toBe(false);
    expect(readEnv({ ...env, WEB_PUSH_ENABLED: 'false' }).WEB_PUSH_ENABLED).toBe(false);
    expect(
      readEnv({ ...env, WEB_PUSH_ENABLED: 'true', WEB_PUSH_PUBLIC_KEY: clavePublica })
        .WEB_PUSH_ENABLED,
    ).toBe(true);
    expect(() => readEnv({ ...env, WEB_PUSH_ENABLED: 'true' })).toThrow('WEB_PUSH_PUBLIC_KEY');
    expect(() =>
      readEnv({ ...env, WEB_PUSH_PUBLIC_KEY: 'no_es_una_clave', WEB_PUSH_ENABLED: 'true' }),
    ).toThrow('WEB_PUSH_PUBLIC_KEY');
    expect(() => readEnv({ ...env, WEB_PUSH_ENABLED: '1' })).toThrow('WEB_PUSH_ENABLED');
  });

  it('requiere sesión y devuelve únicamente la clave pública si está habilitado', async () => {
    const rpc = rpcPorNombre({});
    const { app, gateway } = montar(rpc);
    await request(app).get(`${prefijo}/configuracion`).expect(401);
    expect(gateway.authenticate).not.toHaveBeenCalled();
    const res = await conSesion(request(app).get(`${prefijo}/configuracion`)).expect(200);
    expect(res.body).toEqual({ data: { habilitado: true, clave_publica: clavePublica } });
    expect(res.headers['cache-control']).toBe('no-store');
    expect(rpc).not.toHaveBeenCalled();
  });

  it('oculta la clave y bloquea el alta, pero permite consultar una suscripción propia', async () => {
    const rpc = rpcPorNombre({ api_push_estado_suscripcion: () => ({ activa: true }) });
    const { app } = montar(rpc, false);
    const res = await conSesion(request(app).get(`${prefijo}/configuracion`)).expect(200);
    expect(res.body).toEqual({ data: { habilitado: false, clave_publica: null } });
    await conSesion(request(app).post(`${prefijo}/suscripciones`))
      .send(suscripcion)
      .expect(503)
      .expect(({ body }) => expect(body.error.code).toBe('PUSH_DISABLED'));
    await conSesion(request(app).post(`${prefijo}/suscripciones/estado`))
      .send({ endpoint })
      .expect(200, { data: { activa: true } });
    expect(rpc).toHaveBeenCalledExactlyOnceWith('api_push_estado_suscripcion', {
      p_endpoint: endpoint,
    });
  });
});

describe('suscripciones personales (RF-18/RF-21)', () => {
  it('registra con el JWT actual y responde sin endpoints, identidades o claves', async () => {
    const rpc = rpcPorNombre({ api_push_registrar_suscripcion: () => null });
    const { app, audit, gateway } = montar(rpc);
    const res = await conSesion(request(app).post(`${prefijo}/suscripciones`))
      .send(suscripcion)
      .expect(204);
    expect(res.text).toBe('');
    expect(gateway.forToken).toHaveBeenCalledWith('token');
    expect(rpc).toHaveBeenCalledWith(
      'api_push_registrar_suscripcion',
      { p_endpoint: endpoint, p_p256dh: clavePublica, p_auth: secreto },
      { conflict: expect.objectContaining({ code: 'PUSH_SUBSCRIPTION_CONFLICT' }) },
    );
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: usuarioId,
        action: 'web_push.suscripcion_registrada',
        result: 'success',
      }),
    );
    const logs = JSON.stringify(audit.mock.calls);
    for (const valor of [endpoint, clavePublica, secreto]) expect(logs).not.toContain(valor);
  });

  it.each([
    'https://fcm.googleapis.com/wp/sintetico',
    'https://updates.push.services.mozilla.com/wpush/v2/sintetico',
    'https://web.push.apple.com/sintetico',
  ])('acepta el endpoint del proveedor permitido %s', async (endpoint) => {
    const rpc = rpcPorNombre({ api_push_registrar_suscripcion: () => null });
    const { app } = montar(rpc);
    await conSesion(request(app).post(`${prefijo}/suscripciones`))
      .send({ ...suscripcion, endpoint })
      .expect(204);
  });

  it.each([
    'http://fcm.googleapis.com/wp/sintetico',
    'https://localhost/push',
    'https://fcm.googleapis.com.ejemplo.test/wp/sintetico',
    'https://intranet.test@fcm.googleapis.com/wp/sintetico',
    'https://fcm.googleapis.com:443/wp/sintetico',
    'https://fcm.googleapis.com/wp/../otro',
    'https://fcm.googleapis.com/wp/%2e%2e',
    'https://fcm.googleapis.com/wp/sintetico?q=1',
    'https://fcm.googleapis.com/wp/sintetico#alerta',
    'https://fcm.googleapis.com/wp/sintetico\n',
    `https://fcm.googleapis.com/wp/${'a'.repeat(4097)}`,
  ])('rechaza un endpoint fuera del formato esperado (caso %#)', async (endpoint) => {
    const rpc = rpcPorNombre({});
    const { app } = montar(rpc);
    await conSesion(request(app).post(`${prefijo}/suscripciones`))
      .send({ ...suscripcion, endpoint })
      .expect(422);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('rechaza claves no canónicas, puntos fuera de la curva y campos de identidad', async () => {
    const rpc = rpcPorNombre({});
    const { app } = montar(rpc);
    const puntoInvalido = Buffer.alloc(65);
    puntoInvalido[0] = 4;
    for (const body of [
      { ...suscripcion, usuario_id: usuarioId },
      { ...suscripcion, cuenta_id: '7' },
      { ...suscripcion, keys: { ...suscripcion.keys, permiso: 'alertas:ver' } },
      {
        ...suscripcion,
        keys: { ...suscripcion.keys, p256dh: puntoInvalido.toString('base64url') },
      },
      { ...suscripcion, keys: { ...suscripcion.keys, auth: secreto + '==' } },
      { ...suscripcion, keys: { ...suscripcion.keys, auth: `${secreto.slice(0, -1)}h` } },
    ]) {
      await conSesion(request(app).post(`${prefijo}/suscripciones`))
        .send(body)
        .expect(422);
    }
    expect(rpc).not.toHaveBeenCalled();
  });

  it('consulta estado propio y descarta los campos ajenos al contrato', async () => {
    const rpc = rpcPorNombre({ api_push_estado_suscripcion: () => ({ activa: true, endpoint }) });
    const { app } = montar(rpc);
    await conSesion(request(app).post(`${prefijo}/suscripciones/estado`))
      .send({ endpoint })
      .expect(200, { data: { activa: true } });
    expect(rpc).toHaveBeenCalledWith('api_push_estado_suscripcion', { p_endpoint: endpoint });
  });

  it('propaga un estado de persistencia inválido como indisponibilidad sin divulgar campos', async () => {
    const rpc = rpcPorNombre({
      api_push_estado_suscripcion: () => ({ activa: 'true', endpoint }),
    });
    const { app } = montar(rpc);
    const res = await conSesion(request(app).post(`${prefijo}/suscripciones/estado`))
      .send({ endpoint })
      .expect(503);
    expect(res.text).not.toContain(endpoint);
  });

  it('añade un conflicto por endpoint sin divulgar el propietario ni el endpoint', async () => {
    const rpc = vi.fn(async (_nombre, _parametros, opciones) => {
      throw mapRpcError({ code: '23505', details: endpoint }, opciones);
    });
    const { app } = montar(rpc);
    const res = await conSesion(request(app).post(`${prefijo}/suscripciones`))
      .send(suscripcion)
      .expect(409);
    expect(res.body.error.code).toBe('PUSH_SUBSCRIPTION_CONFLICT');
    expect(res.text).not.toContain(endpoint);
  });

  it('permite revocar incluso con el servicio deshabilitado y sin revelar si el dispositivo existía', async () => {
    const rpc = rpcPorNombre({ api_push_revocar_suscripcion: () => null });
    const { app, audit } = montar(rpc, false);
    const ruta = `${prefijo}/suscripciones/revocar`;
    await request(app).post(ruta).send({ endpoint }).expect(401);
    await conSesion(request(app).post(ruta)).send({ endpoint, usuario_id: usuarioId }).expect(422);
    await conSesion(request(app).post(ruta)).send({ endpoint }).expect(204);
    expect(rpc).toHaveBeenCalledExactlyOnceWith('api_push_revocar_suscripcion', {
      p_endpoint: endpoint,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'web_push.suscripcion_revocada' }),
    );
  });
});
