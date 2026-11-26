/* Soporte, aislamiento por cuenta y eliminación privilegiada sin envíos reales. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { AppError } from '../src/lib/errors.js';
import { createAdminGateway } from '../src/lib/supabase-admin.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';

const actor = 'ac0f640e-31ca-46e0-a403-90a428202101';
const target = 'ac0f640e-31ca-46e0-a403-90a428202102';
const session = 'ac0f640e-31ca-46e0-a403-90a428202103';
const job = 'ac0f640e-31ca-46e0-a403-90a428202104';
const version = '2026-11-22T18:00:00.000Z';
const body = {
  tipo: 'eliminar_usuario',
  asunto: 'Eliminar cuenta inactiva',
  descripcion: 'Solicitamos revisar una cuenta inactiva para invitarla nuevamente.',
  usuario_objetivo_id: target,
};
function fixture({
  rol = 'administrador',
  tipo = 'organizacion',
  bo = 'super_admin',
  handlers = {},
  deleted = vi.fn(async () => {}),
  aal = 'aal2',
} = {}) {
  const rpc = vi.fn(async (name, args) => {
    if (name in handlers) return handlers[name](args);
    if (name === 'api_contexto_cuenta')
      return {
        cuenta_id: '7',
        membresia_id: '1',
        tipo,
        rol,
        permisos: permisosDe(rol, tipo),
        acceso_operativo: true,
      };
    if (name === 'api_soporte_listar')
      return { data: [], meta: { page: 1, limit: 25, total: 0, totalPages: 1 } };
    if (name === 'api_soporte_crear') return { id: '1', ...body };
    if (name === 'sesion') return { estado: bo === 'mfa' ? 'mfa' : 'ok', rol: bo };
    if (name === 'eliminacion_preparar') return { estado: 'preparada', operacion_id: job };
    if (name === 'eliminacion_estado') return { estado: 'eliminado' };
    return {};
  });
  const profile = { usuario_id: actor, estado: 'activo' };
  const gateway = {
    authenticate: vi.fn(async () => ({ id: actor })),
    forToken: () => ({
      session: async () => ({ vigente: true }),
      getProfile: async () => profile,
      rpc,
    }),
  };
  const adminGateway = { backofficeRpc: rpc, deleteUser: deleted, watchBackoffice: () => () => {} };
  const app = createApp({ env: { origins: [] }, gateway, adminGateway, audit: vi.fn() });
  const token =
    'header.' +
    Buffer.from(JSON.stringify({ sub: actor, session_id: session, aal })).toString('base64url') +
    '.test';
  const call = (method, path) => request(app)[method](path).auth(token, { type: 'bearer' });
  return { app, call, rpc, deleted };
}
describe('Soporte de la organización', () => {
  it.each([
    ['coordinador', 'organizacion'],
    ['cuidador', 'organizacion'],
    ['familiar', 'organizacion'],
    ['voluntario', 'organizacion'],
    ['coordinador', 'familia'],
  ])('deniega soporte a %s en %s', async (rol, tipo) => {
    const { call, rpc } = fixture({ rol, tipo });
    await call('get', '/api/v1/cuentas/7/soporte').expect(403);
    await call('post', '/api/v1/cuentas/7/soporte').send(body).expect(403);
    expect(rpc.mock.calls.some(([name]) => name.startsWith('api_soporte_'))).toBe(false);
  });
  it('exige una sesión y limita los parámetros de alcance', async () => {
    const { app, call } = fixture();
    await request(app).post('/api/v1/cuentas/7/soporte').send(body).expect(401);
    await call('get', '/api/v1/cuentas/7/soporte?cuenta=8').expect(422);
    await call('post', '/api/v1/cuentas/7/soporte')
      .send({ ...body, cuenta_id: 8 })
      .expect(422);
    await call('post', '/api/v1/cuentas/7/soporte')
      .send({ ...body, usuario_objetivo_id: null })
      .expect(422);
  });
  it('crea en la cuenta de la ruta y devuelve el código sin borrar al usuario', async () => {
    const { call, rpc, deleted } = fixture();
    await call('post', '/api/v1/cuentas/7/soporte').send(body).expect(201);
    expect(rpc).toHaveBeenCalledWith('api_soporte_crear', {
      p_cuenta_id: '7',
      p_tipo: body.tipo,
      p_asunto: body.asunto,
      p_descripcion: body.descripcion,
      p_usuario_objetivo: target,
    });
    expect(deleted).not.toHaveBeenCalled();
  });
  it('mantiene la respuesta pública y su versión para impedir sobrescrituras', async () => {
    const { call, rpc } = fixture();
    await call('post', '/api/v1/cuentas/7/soporte/1/mensajes')
      .send({ mensaje: 'Información adicional', version })
      .expect(200);
    expect(rpc).toHaveBeenCalledWith('api_soporte_responder', {
      p_cuenta_id: '7',
      p_id: '1',
      p_mensaje: 'Información adicional',
      p_version: version,
    });
    await call('post', '/api/v1/cuentas/7/soporte/1/mensajes')
      .send({ mensaje: 'Información adicional', version, estado: 'resuelta' })
      .expect(422);
  });
  it('propaga el rechazo del recurso ajeno sin entregar el detalle', async () => {
    const { call } = fixture({
      handlers: {
        api_soporte_detalle: () => {
          throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
        },
      },
    });
    const response = await call('get', '/api/v1/cuentas/7/soporte/2').expect(404);
    expect(response.body.data).toBeUndefined();
  });
});
describe('Bandeja y eliminación en backoffice', () => {
  it.each(['soporte', 'auditor'])('el rol %s no elimina identidades', async (bo) => {
    const { call, deleted, rpc } = fixture({ bo });
    const path = '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion';
    await call('get', path).expect(403);
    await call('post', path)
      .send({ confirmacion: 'miembro@example.test', motivo: 'Petición validada de prueba' })
      .expect(403);
    expect(deleted).not.toHaveBeenCalled();
    expect(rpc.mock.calls.some(([name]) => name === 'eliminacion_preparar')).toBe(false);
  });
  it('Auditor lee la bandeja pero no responde', async () => {
    const { call, rpc } = fixture({ bo: 'auditor' });
    await call('get', '/api/admin/soporte').expect(200);
    await call('post', '/api/admin/soporte/1/responder')
      .send({ estado: 'en_revision', mensaje: 'Revisando solicitud', version })
      .expect(403);
    expect(rpc.mock.calls.some(([name]) => name === 'soporte_actualizar')).toBe(false);
  });
  it('Soporte responde con estado y versión, sin ejecutar la eliminación', async () => {
    const { call, rpc, deleted } = fixture({ bo: 'soporte' });
    await call('post', '/api/admin/soporte/1/responder')
      .send({ estado: 'en_revision', mensaje: 'Revisando solicitud', version })
      .expect(200);
    expect(rpc).toHaveBeenCalledWith(
      'soporte_actualizar',
      expect.objectContaining({
        p_id: '1',
        p_estado: 'en_revision',
        p_version: version,
        p_actor: actor,
        p_sesion: session,
      }),
    );
    expect(deleted).not.toHaveBeenCalled();
  });
  it('la falta de MFA impide preparar una eliminación', async () => {
    const { call, deleted } = fixture({ bo: 'mfa', aal: 'aal1' });
    const response = await call('post', '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion')
      .send({ confirmacion: 'miembro@example.test', motivo: 'Prueba de seguridad' })
      .expect(403);
    expect(response.body.error.code).toBe('MFA_REQUIRED');
    expect(deleted).not.toHaveBeenCalled();
  });
  it('un perfil protegido o con historial nunca alcanza la API de Auth', async () => {
    const { call, deleted } = fixture({
      handlers: {
        eliminacion_preparar: () => {
          throw new AppError(409, 'USER_DELETE_BLOCKED', 'Tiene historial');
        },
      },
    });
    await call('post', '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion')
      .send({ confirmacion: 'miembro@example.test', motivo: 'Petición de prueba' })
      .expect(409);
    expect(deleted).not.toHaveBeenCalled();
  });
  it('prepara primero y confirma el resultado de Auth antes de informar éxito', async () => {
    const { call, rpc, deleted } = fixture();
    await call('post', '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion')
      .send({
        confirmacion: 'miembro@example.test',
        motivo: 'Solicitud verificada',
        solicitud_id: '1',
      })
      .expect(200);
    expect(deleted).toHaveBeenCalledExactlyOnceWith(target);
    expect(rpc).toHaveBeenCalledWith(
      'eliminacion_preparar',
      expect.objectContaining({
        p_usuario: target,
        p_confirmacion: 'miembro@example.test',
        p_solicitud: '1',
      }),
    );
    expect(rpc).toHaveBeenCalledWith(
      'eliminacion_estado',
      expect.objectContaining({ p_operacion: job }),
    );
  });
  it('una repetición de una eliminación completada no llama otra vez a Auth', async () => {
    const { call, deleted } = fixture({
      handlers: { eliminacion_preparar: () => ({ estado: 'eliminado', operacion_id: job }) },
    });
    await call('post', '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion')
      .send({ confirmacion: 'miembro@example.test', motivo: 'Solicitud verificada' })
      .expect(200);
    expect(deleted).not.toHaveBeenCalled();
  });
  it('un resultado incierto de Auth se reconcilia con la transacción en la base', async () => {
    const { call } = fixture({
      deleted: vi.fn(async () => {
        throw new Error('Corte posterior al commit');
      }),
    });
    await call('post', '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion')
      .send({ confirmacion: 'miembro@example.test', motivo: 'Solicitud verificada' })
      .expect(200);
    const failed = fixture({
      deleted: vi.fn(async () => {
        throw new Error('Fallo de proveedor');
      }),
      handlers: { eliminacion_estado: () => ({ estado: 'preparada' }) },
    });
    await failed
      .call('post', '/api/admin/cuentas/7/usuarios/' + target + '/eliminacion')
      .send({ confirmacion: 'miembro@example.test', motivo: 'Solicitud verificada' })
      .expect(503);
  });
  it('el adaptador llama a la eliminación definitiva oficial de Supabase Auth', async () => {
    const fetch = vi.fn(async () => Response.json({ id: target }));
    const gateway = createAdminGateway(
      {
        SUPABASE_URL: 'https://test.supabase.co',
        SUPABASE_SECRET_KEY: 'sb_secret_test',
        SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test',
      },
      fetch,
    );
    await gateway.deleteUser(target);
    expect(fetch).toHaveBeenCalledOnce();
    const [url, init] = fetch.mock.calls[0];
    expect(String(url)).toBe('https://test.supabase.co/auth/v1/admin/users/' + target);
    expect(init.method).toBe('DELETE');
    expect(JSON.parse(init.body)).toEqual({ should_soft_delete: false });
  });
});
