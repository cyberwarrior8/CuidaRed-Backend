/* Autorización, privacidad y errores de Backoffice · BO-01 a BO-26. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/lib/errors.js';
import { createAdminGateway } from '../src/lib/supabase-admin.js';
import { createSystemLogger } from '../src/lib/system-logger.js';
import { prepareLogo } from '../src/modules/backoffice/backoffice-brand.js';

const actor = 'a5027ba5-9a17-47fa-8872-1221f994a6be';
const session = '73b4218e-be00-4325-a873-cd7e43df0edd';
const token = (aal = 'aal1') =>
  'header.' +
  Buffer.from(JSON.stringify({ sub: actor, session_id: session, aal })).toString('base64url') +
  '.firma';
const bearer = (aal) => 'Bearer ' + token(aal);
function fixture(handlers = {}) {
  const rpc = vi.fn(async (name, args) => {
    if (name in handlers) return handlers[name](args);
    if (name === 'sesion') return { estado: 'ok', rol: 'auditor', usuario_id: actor };
    if (name === 'leer') return { data: [], meta: { page: 1, limit: 25, total: 0, totalPages: 1 } };
    return undefined;
  });
  const gateway = {
    authenticate: vi.fn(async () => ({ id: actor })),
    passwordSession: vi.fn(async () => ({
      access_token: token(),
      refresh_token: 'refresh',
      actorId: actor,
    })),
  };
  const app = createApp({
    env: { origins: ['http://localhost:5174'], SUPABASE_URL: 'https://test.supabase.co' },
    gateway,
    adminGateway: { backofficeRpc: rpc },
    audit: vi.fn(),
  });
  return { app, rpc, gateway };
}
describe('Backoffice y PWA aislados', () => {
  it('exige un JWT y audita las acciones denegadas al auditor', async () => {
    const { app, rpc } = fixture();
    await request(app).get('/api/admin/cuentas').expect(401);
    await request(app)
      .post('/api/admin/cuentas/5/estado')
      .set('Authorization', bearer())
      .send({ estado: 'deshabilitada', motivo: 'Bloqueo de prueba' })
      .expect(403);
    expect(rpc).toHaveBeenCalledWith(
      'auditar',
      expect.objectContaining({ p_accion: 'acceso.denegado', p_actor: actor }),
    );
    expect(rpc.mock.calls.some(([name]) => name === 'mutar')).toBe(false);
  });
  it('restringe la exportación de logs al super administrador y auditor', async () => {
    const { app } = fixture({ sesion: () => ({ estado: 'ok', rol: 'soporte' }) });
    await request(app).get('/api/admin/logs').set('Authorization', bearer()).expect(200);
    await request(app)
      .get('/api/admin/logs/exportacion')
      .set('Authorization', bearer())
      .expect(403);
  });
  it('la API exige MFA antes de entregar información al administrador', async () => {
    const { app, rpc } = fixture({ sesion: () => ({ estado: 'mfa' }) });
    const res = await request(app)
      .get('/api/admin/resumen')
      .set('Authorization', bearer())
      .expect(403);
    expect(res.body.error.code).toBe('MFA_REQUIRED');
    expect(rpc.mock.calls.some(([name]) => name === 'leer')).toBe(false);
  });
  it('rechaza las credenciales válidas de PWA sin devolver sus tokens', async () => {
    const { app } = fixture({ intento: () => false, admitir: () => false });
    const res = await request(app)
      .post('/api/admin/login')
      .send({ email: 'persona@example.test', password: 'pass' })
      .expect(403);
    expect(res.body.data).toBeUndefined();
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
  it('respeta el bloqueo temporal antes de consultar Auth', async () => {
    const { app, gateway } = fixture({ intento: () => true });
    await request(app)
      .post('/api/admin/login')
      .send({ email: 'persona@example.test', password: 'pass' })
      .expect(429);
    expect(gateway.passwordSession).not.toHaveBeenCalled();
  });
  it('respeta un resultado vacío y propaga errores de escrituras', async () => {
    const { app, rpc } = fixture({
      sesion: () => ({ estado: 'ok', rol: 'soporte' }),
      mutar: () => {
        throw new AppError(503, 'DEPENDENCY_UNAVAILABLE', 'Servicio no disponible.');
      },
    });
    const list = await request(app)
      .get('/api/admin/cuentas?search=cuenta&limit=25')
      .set('Authorization', bearer())
      .expect(200);
    expect(list.body.data).toEqual([]);
    await request(app)
      .post('/api/admin/cuentas/5/estado')
      .set('Authorization', bearer())
      .send({ estado: 'deshabilitada', motivo: 'Bloqueo de prueba' })
      .expect(503);
    expect(rpc).toHaveBeenCalledWith(
      'mutar',
      expect.objectContaining({ p_datos: { cuenta: '5', estado: 'deshabilitada' } }),
    );
  });
  it('acepta categorías de telemetría y rechaza cargas arbitrarias', async () => {
    const { app, rpc } = fixture();
    await request(app)
      .post('/api/admin/telemetria')
      .send({ evento: 'javascript.error', detalle: 'información no permitida' })
      .expect(422);
    await request(app)
      .post('/api/admin/telemetria')
      .send({ evento: 'javascript.error' })
      .expect(204);
    expect(rpc).toHaveBeenCalledWith(
      'log',
      expect.objectContaining({
        p_evento: expect.objectContaining({ origen: 'frontend', ruta: '/pwa' }),
      }),
    );
  });
  it('acepta SVG vectorial transparente y lo guarda como PNG', async () => {
    const valid = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 40" width="80" height="40"><circle cx="20" cy="20" r="10" fill="blue"/></svg>',
    );
    const result = await prepareLogo(valid, 'image/svg+xml', 'completo_claro');
    expect(result.path).toMatch(/^completo_claro\/.+\.png$/);
    expect(result.data.subarray(1, 4).toString()).toBe('PNG');
    const invalid = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.test/image.png"/></svg>',
    );
    await expect(prepareLogo(invalid, 'image/svg+xml', 'completo_claro')).rejects.toMatchObject({
      code: 'INVALID_LOGO',
    });
  });
});

describe('Fallos transitorios de Supabase en el Backoffice', () => {
  const env = {
    SUPABASE_URL: 'https://test.supabase.co',
    SUPABASE_SECRET_KEY: 'sb_secret_test',
    SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test',
  };
  const transient = () => Response.json({ code: 'PGRST003' }, { status: 504 });

  it('reintenta validar y devuelve el estado MFA que entrega Supabase', async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new DOMException('Expiró el intento', 'TimeoutError'))
      .mockResolvedValueOnce(Response.json({ estado: 'mfa' }));
    const gateway = createAdminGateway(env, fetch);
    await expect(gateway.backofficeRpc('sesion', { p_accion: 'validar' })).resolves.toEqual({
      estado: 'mfa',
    });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it('conserva el fallo final con diagnóstico limitado y evita reintentar el registro de ingreso', async () => {
    const fetch = vi.fn(async () => transient());
    const gateway = createAdminGateway(env, fetch);
    await expect(gateway.backofficeRpc('sesion', { p_accion: 'validar' })).rejects.toMatchObject({
      code: 'DEPENDENCY_UNAVAILABLE',
      dependency: 'supabase.api_bo_sesion',
      upstreamStatus: 504,
      upstreamCode: 'PGRST003',
    });
    expect(fetch).toHaveBeenCalledTimes(2);
    await expect(gateway.backofficeRpc('sesion', { p_accion: 'ingreso' })).rejects.toMatchObject({
      code: 'DEPENDENCY_UNAVAILABLE',
    });
    expect(fetch).toHaveBeenCalledTimes(3);
  });

  it('recupera una lectura tras una interrupción de transporte', async () => {
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('Conexión interrumpida'))
      .mockResolvedValueOnce(Response.json({ data: [] }));
    const gateway = createAdminGateway(env, fetch);
    await expect(gateway.backofficeRpc('leer', { p_recurso: 'logs' })).resolves.toEqual({
      data: [],
    });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it('reintenta un log rechazado por el pool, pero registra el diagnóstico de un fallo ambiguo', async () => {
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(transient())
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(Response.json({ code: 'XX000' }, { status: 502 }));
    const audit = vi.fn();
    const recordLog = createSystemLogger(createAdminGateway(env, fetch), audit);
    const event = { p_evento: { request_id: session, mensaje: 'Evento de prueba' } };
    await expect(recordLog(event)).resolves.toBe(true);
    await expect(recordLog(event)).resolves.toBe(false);
    expect(fetch).toHaveBeenCalledTimes(3);
    expect(audit).toHaveBeenCalledExactlyOnceWith({
      requestId: session,
      action: 'log.persistence',
      result: 'error',
      code: 'LOG_STORAGE_UNAVAILABLE',
      dependency: 'supabase.api_bo_log',
      upstreamStatus: 502,
      upstreamCode: 'XX000',
    });
  });
});
