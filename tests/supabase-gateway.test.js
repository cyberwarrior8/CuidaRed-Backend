/* Transporte SDK interceptado, sin proyecto real · RF-09. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import { createSupabaseGateway } from '../src/modules/access/supabase-gateway.js';

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
  it('convierte errores RPC de permisos y datos en respuestas controladas', async () => {
    for (const [code, status] of [
      ['42501', 401],
      ['22023', 422],
    ]) {
      const fetch = vi.fn().mockResolvedValue(json({ code }, 400));
      await expect(
        createSupabaseGateway(env, fetch).forToken('token').updateProfile({}),
      ).rejects.toMatchObject({ status });
    }
  });
});
