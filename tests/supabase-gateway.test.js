/* Transporte SDK interceptado, sin proyecto real · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseGateway } from '../src/modules/access/supabase-gateway.js';
import request from 'supertest';
import { createApp } from '../src/app.js';

const env = {
  SUPABASE_URL: 'https://auth.example.test',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test_only',
};
const user = {
  id: 'a271ce25-7f40-4c45-b5ba-dbc6a0011234',
  email: 'ana@example.test',
  email_confirmed_at: '2026-01-01T00:00:00Z',
  is_anonymous: false,
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

describe('adaptador Supabase con contexto del usuario', () => {
  it('verifica identidad con Auth, no por decodificación local del JWT', async () => {
    const fetch = vi.fn().mockResolvedValue(json({ ...user, user_metadata: { rol: 'admin' } }));
    const identity = await createSupabaseGateway(env, fetch).authenticate('token');
    expect(identity).toEqual({ id: user.id, email: user.email });
    expect(fetch.mock.calls[0][0]).toBe('https://auth.example.test/auth/v1/user');
    expect(new Headers(fetch.mock.calls[0][1].headers).get('Authorization')).toBe('Bearer token');
  });
  it.each([
    { ...user, is_anonymous: true },
    { ...user, email_confirmed_at: null },
  ])('rechaza identidad no apta', async (identity) => {
    const fetch = vi.fn().mockResolvedValue(json(identity));
    await expect(createSupabaseGateway(env, fetch).authenticate('token')).rejects.toMatchObject({
      status: 401,
    });
  });
  it('distingue fallo del proveedor de credenciales inválidas', async () => {
    const invalid = vi.fn().mockResolvedValue(json({ msg: 'invalid token' }, 401));
    await expect(createSupabaseGateway(env, invalid).authenticate('token')).rejects.toMatchObject({
      status: 401,
    });
    const down = vi.fn().mockResolvedValue(json({ msg: 'unavailable' }, 503));
    await expect(createSupabaseGateway(env, down).authenticate('token')).rejects.toMatchObject({
      status: 503,
    });
  });
  it('aísla tokens de peticiones simultáneas y selecciona esquema explícito', async () => {
    const calls = [];
    const fetch = vi.fn(async (url, init) => {
      const headers = new Headers(init.headers);
      calls.push({
        url,
        authorization: headers.get('Authorization'),
        schema: headers.get('Content-Profile'),
      });
      return json(null);
    });
    const gateway = createSupabaseGateway(env, fetch);
    await Promise.all([
      gateway.forToken('token-a').getProfile(),
      gateway.forToken('token-b').getProfile(),
    ]);
    expect(calls.map((v) => v.authorization).sort()).toEqual(['Bearer token-a', 'Bearer token-b']);
    expect(
      calls.every((v) => v.url.endsWith('/rpc/api_mi_perfil') && v.schema === 'cuidared_api'),
    ).toBe(true);
  });
  it('un contrato RPC aún no aplicado falla 503, sin simular persistencia', async () => {
    const fetch = vi
      .fn()
      .mockResolvedValue(json({ code: 'PGRST202', message: 'private schema detail' }, 404));
    await expect(
      createSupabaseGateway(env, fetch).forToken('token').session('validar'),
    ).rejects.toMatchObject({ status: 503, code: 'DEPENDENCY_UNAVAILABLE' });
  });
  it('no filtra datos de la persona en conflicto', async () => {
    const fetch = vi
      .fn()
      .mockResolvedValue(
        json({ code: '23505', details: 'cedula=00112345678', message: 'private' }, 409),
      );
    await expect(
      createSupabaseGateway(env, fetch).forToken('token').updateProfile({}),
    ).rejects.toMatchObject({
      status: 409,
      message: 'No se pudo guardar el perfil con esos datos.',
    });
  });
  it.each([
    ['28000', 401, 'UNAUTHORIZED'],
    ['42501', 403, 'FORBIDDEN'],
    ['P0002', 404, 'NOT_FOUND'],
    ['22023', 422, 'INVALID_INPUT'],
    ['23514', 422, 'INVALID_INPUT'],
  ])('CR-162: transforma SQLSTATE %s en HTTP %i y %s', async (sqlstate, status, code) => {
    const fetch = vi.fn().mockResolvedValue(
      json(
        {
          code: sqlstate,
          message: 'private_message',
          details: 'private_details',
          hint: 'private_hint',
        },
        400,
      ),
    );
    await expect(
      createSupabaseGateway(env, fetch).forToken('token').updateProfile({}),
    ).rejects.toMatchObject({ status, code });
  });
});

describe('CR-162: contrato HTTP desde errores RPC reales del adaptador', () => {
  it.each([
    ['28000', 401, 'UNAUTHORIZED'],
    ['42501', 403, 'FORBIDDEN'],
    ['P0002', 404, 'NOT_FOUND'],
    ['22023', 422, 'INVALID_INPUT'],
    ['23514', 422, 'INVALID_INPUT'],
    ['23505', 409, 'PROFILE_CONFLICT'],
    ['XX000', 503, 'DEPENDENCY_UNAVAILABLE'],
    ['PGRST202', 503, 'DEPENDENCY_UNAVAILABLE'],
  ])(
    '%s conserva HTTP %i y código %s sin detalles del proveedor',
    async (sqlstate, status, code) => {
      const fetch = vi.fn(async (url) => {
        if (url.endsWith('/auth/v1/user')) return json(user);
        if (url.endsWith('/rpc/api_sesion')) return json({ vigente: true });
        if (url.endsWith('/rpc/api_mi_perfil'))
          return json({
            usuario_id: user.id,
            nombres: 'Ana',
            apellidos: 'Pérez',
            estado: 'activo',
          });
        return json(
          {
            code: sqlstate,
            message: 'private_message',
            details: 'private_details',
            hint: 'private_hint',
          },
          400,
        );
      });
      const audit = vi.fn();
      const app = createApp({
        env: { origins: [] },
        gateway: createSupabaseGateway(env, fetch),
        audit,
      });
      const response = await request(app)
        .patch('/api/v1/me')
        .auth('token', { type: 'bearer' })
        .send({ nombres: 'Ana' })
        .expect(status);
      expect(response.body.error.code).toBe(code);
      expect(response.body.error.message).toEqual(expect.any(String));
      expect(response.body.requestId).toBe(response.headers['x-request-id']);
      for (const marker of ['private_message', 'private_details', 'private_hint']) {
        expect(JSON.stringify(response.body)).not.toContain(marker);
        expect(JSON.stringify(audit.mock.calls)).not.toContain(marker);
      }
      expect(response.body.error).not.toHaveProperty('details');
      expect(response.body.error).not.toHaveProperty('hint');
    },
  );
});
