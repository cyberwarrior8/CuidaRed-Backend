/* Pruebas API ID01/RF-09/RF-21 sin base real. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/lib/errors.js';
import { createAuditSink } from '../src/lib/audit.js';
import { readEnv } from '../src/config/env.js';

const id = 'a271ce25-7f40-4c45-b5ba-dbc6a0011234';
const profile = {
  usuario_id: id,
  cedula: '00112345678',
  nombres: 'Ana',
  apellidos: 'Pérez',
  correo: 'ana@example.test',
  telefono: null,
  estado: 'activo',
};

function setup(overrides = {}) {
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue(profile),
    updateProfile: vi.fn(async (input) => ({ ...profile, ...input })),
    ...overrides,
  };
  const audit = vi.fn();
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id, email: profile.correo }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const app = createApp({ env: { origins: ['http://localhost:5173'] }, gateway, audit });
  return { app, gateway, repository, audit };
}

describe('ID01 / RF-09: sesión y perfil propio', () => {
  it('liveness no equivale a disponibilidad de Auth/BD', async () => {
    const { app, gateway } = setup();
    await request(app).get('/health/live').expect(200, { status: 'ok' });
    expect(gateway.authenticate).not.toHaveBeenCalled();
  });
  it.each([undefined, '', 'Basic abc', 'Bearer abc def'])(
    'rechaza autorización %s',
    async (header) => {
      const { app, gateway } = setup();
      const call = request(app).get('/api/v1/me');
      if (header !== undefined) call.set('Authorization', header);
      await call.expect(401);
      expect(gateway.authenticate).not.toHaveBeenCalled();
    },
  );
  it('no acepta tokens en query string', async () => {
    await request(setup().app).get('/api/v1/me?access_token=secreto').expect(401);
  });
  it('valida token y sesión vigente antes de devolver un perfil', async () => {
    const { app, repository, gateway } = setup();
    const res = await request(app)
      .get('/api/v1/me')
      .auth('signed-token', { type: 'bearer' })
      .expect(200);
    expect(gateway.authenticate).toHaveBeenCalledWith('signed-token');
    expect(repository.session).toHaveBeenCalledWith('validar');
    expect(res.body.data.profile.id).toBe(id);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.data.profile).not.toHaveProperty('password');
  });
  it('una sesión revocada o vencida no consulta perfil', async () => {
    const { app, repository } = setup({ session: vi.fn().mockResolvedValue({ vigente: false }) });
    await request(app).get('/api/v1/me').auth('token', { type: 'bearer' }).expect(401);
    expect(repository.getProfile).not.toHaveBeenCalled();
  });
  it('rechaza un usuario desactivado aunque su JWT sea válido', async () => {
    const { app } = setup({
      getProfile: vi.fn().mockResolvedValue({ ...profile, estado: 'inactivo' }),
    });
    await request(app).get('/api/v1/me').auth('token', { type: 'bearer' }).expect(403);
  });
  it('rechaza desactivación señalada por la comprobación actual del servidor', async () => {
    const { app } = setup({
      session: vi.fn().mockResolvedValue({ vigente: false, motivo: 'usuario_inactivo' }),
    });
    await request(app).get('/api/v1/me').auth('token', { type: 'bearer' }).expect(403);
  });
  it('una dependencia caída cierra el acceso con error controlado', async () => {
    const { app } = setup({ session: vi.fn().mockRejectedValue(new Error('connection secret')) });
    const res = await request(app).get('/api/v1/me').auth('token', { type: 'bearer' }).expect(500);
    expect(JSON.stringify(res.body)).not.toContain('connection secret');
  });
  it('un perfil de otra identidad nunca llega a la respuesta', async () => {
    const { app } = setup({
      getProfile: vi.fn().mockResolvedValue({ ...profile, usuario_id: 'otra-persona' }),
    });
    await request(app).get('/api/v1/me').auth('token', { type: 'bearer' }).expect(503);
  });
  it('un invitado sin perfil previo debe contactar a quien lo invitó', async () => {
    const { app, repository } = setup({ getProfile: vi.fn().mockResolvedValue(null) });
    await request(app).get('/api/v1/me').auth('token', { type: 'bearer' }).expect(409);
    expect(repository.updateProfile).not.toHaveBeenCalled();
  });
  it.each(['rol', 'estado', 'usuario_id', 'correo', 'cuenta_id', 'password'])(
    'impide asignación masiva de %s',
    async (field) => {
      const { app, repository } = setup();
      await request(app)
        .patch('/api/v1/me')
        .auth('token', { type: 'bearer' })
        .send({ nombres: 'Pedro', [field]: 'intruso' })
        .expect(422);
      expect(repository.updateProfile).not.toHaveBeenCalled();
    },
  );
  it('conserva la cédula como identidad no editable por perfil', async () => {
    await request(setup().app)
      .patch('/api/v1/me')
      .auth('token', { type: 'bearer' })
      .send({ cedula: '00212345678' })
      .expect(422);
  });
  it('no existe autorregistro de perfil ni edición vacía', async () => {
    const { app } = setup();
    await request(app)
      .post('/api/v1/me')
      .auth('token', { type: 'bearer' })
      .send({ cedula: '001-1234567-8', nombres: 'Ana', apellidos: 'Pérez' })
      .expect(404);
    await request(app).patch('/api/v1/me').auth('token', { type: 'bearer' }).send({}).expect(422);
  });
  it('actualiza los campos permitidos y registra el resultado', async () => {
    const { app, repository, audit } = setup();
    await request(app)
      .patch('/api/v1/me')
      .auth('token', { type: 'bearer' })
      .send({ telefono: null })
      .expect(200);
    expect(repository.updateProfile).toHaveBeenCalledWith({ telefono: null });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'profile.updated', actorId: id }),
    );
  });
  it('registra actividad y cierra la sesión del servidor', async () => {
    const { app, repository } = setup();
    await request(app)
      .post('/api/v1/session/activity')
      .auth('token', { type: 'bearer' })
      .expect(204);
    await request(app).post('/api/v1/session/logout').auth('token', { type: 'bearer' }).expect(204);
    expect(repository.session).toHaveBeenCalledWith('actividad');
    expect(repository.session).toHaveBeenCalledWith('cerrar');
  });
  it('expirar entre validación y actividad no devuelve éxito', async () => {
    const session = vi
      .fn()
      .mockResolvedValueOnce({ vigente: true })
      .mockResolvedValueOnce({ vigente: false });
    await request(setup({ session }).app)
      .post('/api/v1/session/activity')
      .auth('token', { type: 'bearer' })
      .expect(401);
  });
  it('maneja duplicados sin revelar identidad existente', async () => {
    const { app } = setup({
      updateProfile: vi
        .fn()
        .mockRejectedValue(
          new AppError(409, 'PROFILE_CONFLICT', 'No se pudo guardar el perfil con esos datos.'),
        ),
    });
    await request(app)
      .patch('/api/v1/me')
      .auth('token', { type: 'bearer' })
      .send({ nombres: 'Ana', apellidos: 'Pérez' })
      .expect(409);
  });
  it('CORS rechaza origen ajeno y permite preflight del frontend', async () => {
    const { app } = setup();
    await request(app).get('/api/v1/me').set('Origin', 'https://evil.test').expect(403);
    const res = await request(app)
      .options('/api/v1/me')
      .set('Origin', 'http://localhost:5173')
      .set('Access-Control-Request-Method', 'PATCH')
      .expect(204);
    expect(res.headers['access-control-allow-origin']).toBe('http://localhost:5173');
  });
  it('controla JSON inválido y cuerpos demasiado grandes', async () => {
    const { app } = setup();
    await request(app)
      .post('/api/v1/me')
      .set('Content-Type', 'application/json')
      .send('{')
      .expect(400);
    await request(app)
      .post('/api/v1/me')
      .send({ enorme: 'x'.repeat(20_000) })
      .expect(413);
  });
});

describe('configuración y auditoría', () => {
  const env = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test',
    FRONTEND_ORIGINS: 'http://localhost:5173',
  };
  it('requiere claves públicas modernas y HTTPS en producción', () => {
    expect(readEnv(env).PORT).toBe(3000);
    expect(() => readEnv({ ...env, SUPABASE_PUBLISHABLE_KEY: 'sb_secret_supersecret' })).toThrow();
    expect(() => readEnv({ ...env, NODE_ENV: 'production' })).toThrow();
    expect(() => readEnv({ ...env, FRONTEND_ORIGINS: '*' })).toThrow();
  });
  it('nunca registra datos arbitrarios del cliente ni valores de configuración', () => {
    const write = vi.fn();
    createAuditSink(write)({
      action: 'profile.updated',
      result: 'success',
      password: 'secreto',
      authorization: 'token',
      correo: 'privado',
    });
    expect(write.mock.calls[0][0]).not.toMatch(/secreto|token|privado/);
    try {
      readEnv({ ...env, SUPABASE_PUBLISHABLE_KEY: 'sb_secret_supersecret' });
    } catch (e) {
      expect(e.message).not.toContain('supersecret');
    }
  });
});
