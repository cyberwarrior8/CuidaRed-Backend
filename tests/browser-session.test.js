/* Sesión protegida, rotación y revalidación de vigencia · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { unavailable } from '../src/lib/errors.js';

const origin = 'http://localhost:5173';
const root = '/api/v1/session/browser';
const id = 'a271ce25-7f40-4c45-b5ba-dbc6a0011234';
const sid = '39ae1da6-30b5-4a0f-a1a9-e252cf652163';
const exp = 1_800_000_000;
const jwt = (sessionId = sid, firma = 'firma') =>
  `e30.${Buffer.from(JSON.stringify({ session_id: sessionId, exp })).toString('base64url')}.${firma}`;
const first = jwt();
const renewed = jwt(sid, 'nueva');
const initialRefresh = 'credencial-de-renovacion';
const cookieValue = (response) => response.headers['set-cookie'][0].split(';')[0];

function setup() {
  const now = vi.fn(() => new Date('2026-11-17T08:00:00Z'));
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue({ usuario_id: id, estado: 'activo' }),
  };
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id, email: 'test@example.test' }),
    forToken: vi.fn(() => repository),
    refreshBrowserSession: vi
      .fn()
      .mockResolvedValue({ access_token: renewed, refresh_token: 'renovada' }),
  };
  const app = createApp({
    env: { origins: [origin], BROWSER_SESSION_KEY: Buffer.alloc(32, 19).toString('base64url') },
    gateway,
    now,
    audit: vi.fn(),
  });
  const call = (path) =>
    request(app)
      .post(root + path)
      .set('Origin', origin);
  const login = () =>
    call('/start').auth(first, { type: 'bearer' }).send({ refresh_token: initialRefresh });
  return { app, call, gateway, login, now, repository };
}

describe('sesión de navegador', () => {
  it('aísla la cookie y envía únicamente el token de acceso, con expiración fija', async () => {
    const { app, login, call, gateway, repository, now } = setup();
    const start = await login().expect(200);
    expect(start.body.data).toEqual({ access_token: first, expires_at: exp, user: { id } });
    const cookie = start.headers['set-cookie'][0];
    expect(cookie).toContain('Path=/api/v1/session/browser;');
    expect(cookie).toMatch(/HttpOnly; Secure; SameSite=Strict/);
    expect(cookie).toContain('Expires=Tue, 17 Nov 2026 20:00:00 GMT');
    expect(cookie).not.toContain(initialRefresh);
    expect(start.headers['cache-control']).toBe('no-store');
    expect(start.headers['access-control-allow-credentials']).toBe('true');
    await request(app)
      .get('/api/v1/me')
      .set('Origin', origin)
      .set('Cookie', cookieValue(start))
      .expect(401);
    now.mockReturnValue(new Date('2026-11-17T08:02:00Z'));
    const restored = await call('/restore').set('Cookie', cookieValue(start)).expect(200);
    expect(gateway.refreshBrowserSession).toHaveBeenCalledWith(initialRefresh);
    expect(restored.body.data.access_token).toBe(renewed);
    expect(restored.body.data).not.toHaveProperty('refresh_token');
    expect(restored.headers['set-cookie'][0]).toContain('Expires=Tue, 17 Nov 2026 20:00:00 GMT');
    expect(repository.session.mock.calls).toEqual([['validar'], ['validar']]);
    await call('/restore').set('Cookie', cookieValue(restored)).expect(200);
    expect(gateway.refreshBrowserSession).toHaveBeenLastCalledWith('renovada');
  });

  it('rechaza origen ausente o externo, cookies alteradas y refresh de otra sesión', async () => {
    const { app, login, call, gateway } = setup();
    const response = await login().expect(200);
    const cookie = cookieValue(response);
    await request(app)
      .post(root + '/restore')
      .set('Cookie', cookie)
      .expect(403);
    await request(app)
      .post(root + '/clear')
      .set('Origin', 'https://otro.example')
      .set('Cookie', cookie)
      .expect(403);
    await call('/restore')
      .set('Cookie', cookie + 'A')
      .expect(401);
    expect(gateway.refreshBrowserSession).not.toHaveBeenCalled();
    gateway.refreshBrowserSession.mockResolvedValueOnce({
      access_token: jwt('2385487a-0ac6-4842-8d5a-f33fa7f2fee1'),
      refresh_token: 'ajeno',
    });
    const fallo = await call('/restore').set('Cookie', cookie).expect(401);
    expect(fallo.headers['set-cookie'][0]).toContain('Expires=Thu, 01 Jan 1970');
  });

  it('respeta la revocación y la inactividad del servidor, limpia el cierre manual y conserva la cookie ante un fallo transitorio', async () => {
    const { login, call, gateway, now, repository } = setup();
    await call('/restore').expect(204);
    const cookie = cookieValue(await login().expect(200));
    gateway.refreshBrowserSession.mockRejectedValueOnce(unavailable());
    const error = await call('/restore').set('Cookie', cookie).expect(503);
    expect(error.headers['set-cookie']).toBeUndefined();
    repository.session.mockResolvedValueOnce({ vigente: false });
    const expired = await call('/restore').set('Cookie', cookie).expect(401);
    expect(expired.headers['set-cookie'][0]).toContain('Expires=Thu, 01 Jan 1970');
    now.mockReturnValue(new Date('2026-11-17T20:00:00Z'));
    gateway.refreshBrowserSession.mockClear();
    await call('/restore').set('Cookie', cookie).expect(401);
    expect(gateway.refreshBrowserSession).not.toHaveBeenCalled();
    const closed = await call('/clear').set('Cookie', cookie).expect(204);
    expect(closed.headers['set-cookie'][0]).toContain('Expires=Thu, 01 Jan 1970');
  });
});
