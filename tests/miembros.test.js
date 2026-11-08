/* Miembros, invitaciones, roles, titularidad y cuidadores sin base real · ID02/RF-11/RF-12. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { businessError } from '../src/lib/business-errors.js';
import { AppError } from '../src/lib/errors.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';

const actorId = 'a271ce25-7f40-4c45-b5ba-dbc6a0011234';
const profile = {
  usuario_id: actorId,
  cedula: '00112345678',
  nombres: 'Ana',
  apellidos: 'Pérez',
  correo: 'ana@example.test',
  telefono: null,
  estado: 'activo',
};
const invitacion = {
  correo: 'Nuevo.Miembro@Example.TEST ',
  cedula: '00198765432',
  nombres: 'Nuevo',
  apellidos: 'Miembro',
  rol: 'cuidador',
};

const contexto = ({ tipo = 'familia', rol = 'coordinador', ...extra } = {}) => ({
  cuenta_id: 7,
  tipo,
  rol,
  membresia_id: 11,
  permisos: permisosDe(rol, tipo),
  es_titular: true,
  acceso_operativo: true,
  suscripcion_estado: 'prueba',
  funcionalidades: [],
  ...extra,
});
const miembro = (extra = {}) => ({
  membresia_id: 21,
  rol: 'cuidador',
  estado: 'activa',
  fecha_inicio: '2026-11-06',
  fecha_fin: null,
  es_titular: false,
  usuario: {
    id: 'b0c1d2e3-0000-4000-8000-000000000021',
    nombres: 'Diego',
    apellidos: 'Cuidador',
    correo: 'diego@example.test',
    telefono: null,
  },
  cuidador: null,
  ...extra,
});
const perfil = (extra = {}) => ({
  cuidador_id: 5,
  tipo_cuidado_id: 1,
  tipo_cuidado: 'Cuidador remunerado',
  cuidador_independiente: false,
  usuario_empleador_id: actorId,
  fecha_inicio: '2026-11-06',
  ...extra,
});
// Error de una RPC tal como lo produce el adaptador (SQLSTATE P0001 + código CR_*).
const negocio = (code) => mapRpcError({ code: 'P0001', message: code });
const rechaza = (error) => vi.fn().mockRejectedValue(error);

/**
 * Gateway simulado: `handlers` responde cada RPC por nombre; cualquier RPC no prevista falla la prueba.
 * `ctx` puede ser un objeto, una función (p_cuenta_id) → contexto, o null (sin membresía activa).
 */
function setup({ ctx = contexto(), rpc = {}, admin } = {}) {
  const handlers = {
    api_contexto_cuenta: async (params) => (typeof ctx === 'function' ? ctx(params) : ctx),
    ...rpc,
  };
  const rpcMock = vi.fn(async (name, params, options) => {
    if (!handlers[name]) throw new Error(`RPC inesperada: ${name}`);
    return options === undefined ? handlers[name](params) : handlers[name](params, options);
  });
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue(profile),
    rpc: rpcMock,
  };
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: actorId, email: profile.correo }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const audit = vi.fn();
  const adminGateway =
    admin === undefined ? { inviteUser: vi.fn().mockResolvedValue({ id: 'nuevo' }) } : admin;
  const app = createApp({ env: { origins: [] }, gateway, audit, adminGateway });
  const llamadas = (nombre) => rpcMock.mock.calls.filter(([n]) => n === nombre);
  return { app, rpc: rpcMock, audit, adminGateway, llamadas };
}
const http = (app, method, path) =>
  request(app)[method](`/api/v1${path}`).auth('token', { type: 'bearer' });

describe('sesión y contexto de cuenta', () => {
  it.each([
    ['get', '/cuentas/7/miembros'],
    ['post', '/cuentas/7/miembros'],
    ['patch', '/cuentas/7/miembros/21'],
    ['post', '/cuentas/7/titularidad'],
    ['post', '/me/membresias/21/aceptar'],
    ['post', '/me/membresias/21/rechazar'],
  ])('%s %s exige sesión (401) antes de consultar la base', async (method, path) => {
    const { app, rpc } = setup();
    await request(app)[method](`/api/v1${path}`).expect(401);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('sin membresía activa en la cuenta responde 404 sin revelar si existe', async () => {
    const { app, llamadas } = setup({ ctx: null });
    await http(app, 'get', '/cuentas/7/miembros').expect(404);
    await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(404);
    expect(llamadas('api_listar_miembros')).toHaveLength(0);
  });

  it.each(['0', 'abc', '-1', '1.5', '99999999999999999999'])(
    'el id de cuenta %s no existe (404)',
    async (id) => {
      const { app, rpc } = setup();
      await http(app, 'get', `/cuentas/${id}/miembros`).expect(404);
      expect(rpc).not.toHaveBeenCalled();
    },
  );
});

describe('RF-09/RF-11: permisos por rol y tipo de cuenta (V2)', () => {
  const mutaciones = [
    ['post', '/cuentas/7/miembros', invitacion],
    ['patch', '/cuentas/7/miembros/21', { rol: 'familiar' }],
    ['post', '/cuentas/7/miembros/21/desactivar', undefined],
    ['post', '/cuentas/7/miembros/21/reactivar', undefined],
    ['post', '/cuentas/7/titularidad', { membresia_id: 21 }],
    ['get', '/cuentas/7/miembros/21', undefined],
    ['get', '/cuentas/7/miembros/21/cuidador', undefined],
    [
      'post',
      '/cuentas/7/miembros/21/cuidador',
      { tipo_cuidado_id: 1, cuidador_independiente: true },
    ],
  ];

  it.each([
    ['familia', 'coordinador', 200],
    ['organizacion', 'administrador', 200],
    ['organizacion', 'coordinador', 403],
    ['organizacion', 'cuidador', 403],
    ['organizacion', 'voluntario', 403],
    ['organizacion', 'familiar', 403],
    ['familia', 'cuidador', 403],
    ['familia', 'familiar', 403],
  ])('listar miembros: %s / %s → %s', async (tipo, rol, status) => {
    const { app, llamadas } = setup({
      ctx: contexto({ tipo, rol }),
      rpc: { api_listar_miembros: async () => ({ total: 1, items: [miembro()] }) },
    });
    const res = await http(app, 'get', '/cuentas/7/miembros').expect(status);
    if (status === 403) {
      expect(res.body.error.code).toBe('FORBIDDEN');
      expect(llamadas('api_listar_miembros')).toHaveLength(0);
    }
  });

  it.each(mutaciones.filter(([, ruta]) => !ruta.endsWith('/cuidador')))(
    'el Coordinador de una Organización NO gestiona miembros: %s %s',
    async (method, path, body) => {
      const { app, rpc, adminGateway } = setup({
        ctx: contexto({ tipo: 'organizacion', rol: 'coordinador' }),
      });
      const call = http(app, method, path);
      await (body ? call.send(body) : call).expect(403);
      expect(rpc.mock.calls.map(([n]) => n)).toEqual(['api_contexto_cuenta']);
      expect(adminGateway.inviteUser).not.toHaveBeenCalled();
    },
  );

  it.each([
    ['familia', 'cuidador'],
    ['familia', 'familiar'],
    ['organizacion', 'cuidador'],
    ['organizacion', 'familiar'],
    ['organizacion', 'voluntario'],
  ])('%s / %s no gestiona miembros ni cuidadores (todas las rutas)', async (tipo, rol) => {
    const { app, rpc } = setup({ ctx: contexto({ tipo, rol }) });
    for (const [method, path, body] of mutaciones) {
      const call = http(app, method, path);
      await (body ? call.send(body) : call).expect(403);
    }
    expect(rpc.mock.calls.map(([n]) => n).every((n) => n === 'api_contexto_cuenta')).toBe(true);
  });

  it('el Coordinador de una Familia sí gestiona miembros y cuidadores', async () => {
    const { app } = setup({
      rpc: {
        api_detalle_miembro: async () => miembro(),
        api_obtener_cuidador_miembro: async () => null,
      },
    });
    await http(app, 'get', '/cuentas/7/miembros/21').expect(200);
    await http(app, 'get', '/cuentas/7/miembros/21/cuidador').expect(200, { data: null });
  });

  it('el Coordinador de una Organización puede gestionar el perfil global, sin gestionar membresías', async () => {
    const { app } = setup({
      ctx: contexto({ tipo: 'organizacion', rol: 'coordinador' }),
      rpc: { api_obtener_cuidador_miembro: async () => null },
    });
    await http(app, 'get', '/cuentas/7/miembros/21/cuidador').expect(200, { data: null });
    await http(app, 'get', '/cuentas/7/miembros/21').expect(403);
  });

  it('cuenta sin vigencia: bloquea la gestión de miembros y cuidadores', async () => {
    const { app, llamadas } = setup({
      ctx: contexto({ acceso_operativo: false, suscripcion_estado: 'vencida' }),
      rpc: { api_listar_miembros: async () => ({ total: 0, items: [] }) },
    });
    await http(app, 'get', '/cuentas/7/miembros').expect(403);
    const res = await http(app, 'get', '/cuentas/7/miembros/21/cuidador').expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    expect(llamadas('api_obtener_cuidador_miembro')).toHaveLength(0);
  });

  it('una persona con roles distintos en dos cuentas no mezcla permisos', async () => {
    const { app, llamadas } = setup({
      ctx: ({ p_cuenta_id }) =>
        p_cuenta_id === '7'
          ? contexto({ cuenta_id: 7 })
          : contexto({ cuenta_id: 8, tipo: 'organizacion', rol: 'familiar' }),
      rpc: { api_listar_miembros: async () => ({ total: 0, items: [] }) },
    });
    await http(app, 'get', '/cuentas/7/miembros').expect(200);
    await http(app, 'get', '/cuentas/8/miembros').expect(403);
    expect(llamadas('api_listar_miembros').map(([, p]) => p.p_cuenta_id)).toEqual(['7']);
  });
});

describe('RF-11: listado y detalle de miembros', () => {
  const listar = (items, total = items.length) => ({
    api_listar_miembros: vi.fn(async () => ({ total, items })),
  });

  it('pagina, ordena y filtra pasando los valores como parámetros', async () => {
    const rpc = listar([miembro()], 3);
    const { app, llamadas } = setup({ rpc });
    const res = await http(app, 'get', '/cuentas/7/miembros')
      .query({
        page: '2',
        limit: '1',
        sort: '-apellidos',
        'filter[rol]': 'cuidador',
        'filter[estado]': 'activa',
      })
      .expect(200);
    expect(llamadas('api_listar_miembros')[0][1]).toEqual({
      p_cuenta_id: '7',
      p_rol: 'cuidador',
      p_estado: 'activa',
      p_orden: ['-apellidos', 'membresia_id'],
      p_limite: 1,
      p_desplazamiento: 1,
    });
    expect(res.body.meta).toEqual({ page: 2, limit: 1, total: 3, totalPages: 3 });
    expect(res.body.data).toHaveLength(1);
    expect(res.body.data[0].membresia_id).toBe('21');
  });

  it('orden y paginación predeterminados: nombres, apellidos y fecha_inicio', async () => {
    const { app, llamadas } = setup({ rpc: listar([]) });
    const res = await http(app, 'get', '/cuentas/7/miembros').expect(200);
    expect(llamadas('api_listar_miembros')[0][1]).toMatchObject({
      p_rol: null,
      p_estado: null,
      p_orden: ['nombres', 'apellidos', 'fecha_inicio', 'membresia_id'],
      p_limite: 20,
      p_desplazamiento: 0,
    });
    expect(res.body).toEqual({ data: [], meta: { page: 1, limit: 20, total: 0, totalPages: 0 } });
  });

  it('una página fuera del conjunto devuelve 200 con data vacía', async () => {
    const { app } = setup({ rpc: listar([], 3) });
    const res = await http(app, 'get', '/cuentas/7/miembros').query({ page: '9' }).expect(200);
    expect(res.body.data).toEqual([]);
    expect(res.body.meta.total).toBe(3);
  });

  it.each([
    { limit: '0' },
    { limit: '101' },
    { page: 'a' },
    { sort: 'cedula' },
    { sort: 'nombres,nombres' },
    { sort: 'nombres; drop table cuidared.membresia' },
    { 'filter[rol]': 'reina' },
    { 'filter[estado]': 'activo' },
    { 'filter[cedula]': '00112345678' },
    { cuenta_id: '9' },
    { q: 'ana' },
  ])('rechaza parámetros inválidos %j (422) sin consultar la base', async (query) => {
    const { app, llamadas } = setup({ rpc: listar([]) });
    const res = await http(app, 'get', '/cuentas/7/miembros').query(query).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(llamadas('api_listar_miembros')).toHaveLength(0);
  });

  it('el DTO es una lista cerrada: no reenvía campos que la RPC añada de más', async () => {
    const sucio = miembro({
      cedula: '00112345678',
      password: 'secreto',
      usuario: { ...miembro().usuario, cedula: '00112345678', raw_user_meta_data: { a: 1 } },
      cuidador: perfil({ interno: 'x' }),
    });
    const { app } = setup({ rpc: listar([sucio]) });
    const res = await http(app, 'get', '/cuentas/7/miembros').expect(200);
    const fila = res.body.data[0];
    expect(Object.keys(fila).sort()).toEqual(
      [
        'cuidador',
        'es_titular',
        'estado',
        'fecha_fin',
        'fecha_inicio',
        'membresia_id',
        'rol',
        'usuario',
      ].sort(),
    );
    expect(Object.keys(fila.usuario).sort()).toEqual(
      ['apellidos', 'correo', 'id', 'nombres', 'telefono'].sort(),
    );
    expect(Object.keys(fila.cuidador).sort()).toEqual(
      [
        'cuidador_id',
        'cuidador_independiente',
        'fecha_inicio',
        'tipo_cuidado',
        'tipo_cuidado_id',
        'usuario_empleador_id',
      ].sort(),
    );
  });

  it('un contrato roto de la RPC es indisponibilidad, no datos a medias', async () => {
    const { app } = setup({ rpc: listar([{ membresia_id: 1 }]) });
    await http(app, 'get', '/cuentas/7/miembros').expect(503);
  });

  it('detalle: usa el id de la ruta y la cuenta de la ruta', async () => {
    const rpc = { api_detalle_miembro: vi.fn(async () => miembro({ cuidador: perfil() })) };
    const { app } = setup({ rpc });
    const res = await http(app, 'get', '/cuentas/7/miembros/21').expect(200);
    expect(rpc.api_detalle_miembro).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_membresia_id: '21',
    });
    expect(res.body.data.cuidador.tipo_cuidado).toBe('Cuidador remunerado');
  });

  it.each(['0', 'abc', '-1', '1.5', '99999999999999999999', '9223372036854775808'])(
    'el id de membresía %s no existe (404) y no llega a la base',
    async (id) => {
      const { app, llamadas } = setup({ rpc: { api_detalle_miembro: async () => miembro() } });
      await http(app, 'get', `/cuentas/7/miembros/${id}`).expect(404);
      expect(llamadas('api_detalle_miembro')).toHaveLength(0);
    },
  );

  it('una membresía de otra cuenta es 404 (la RPC no la encuentra en ESTA cuenta)', async () => {
    const { app } = setup({
      rpc: { api_detalle_miembro: rechaza(mapRpcError({ code: 'P0002' })) },
    });
    const res = await http(app, 'get', '/cuentas/7/miembros/21').expect(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('RF-11: invitar miembros', () => {
  const rpcInvitar = (existe, extra = {}) => ({
    api_preparar_invitacion: vi.fn(async () => ({ usuario_existe: existe })),
    api_agregar_miembro: vi.fn(async () => miembro({ estado: 'pendiente' })),
    ...extra,
  });

  it('persona que ya existe: no se crea identidad, se agrega la membresía pendiente', async () => {
    const rpc = rpcInvitar(true);
    const { app, adminGateway, audit } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(201);
    expect(adminGateway.inviteUser).not.toHaveBeenCalled();
    // El correo se normaliza; el actor y la identidad de la persona nunca viajan en la petición.
    const esperado = {
      p_cuenta_id: '7',
      p_correo: 'nuevo.miembro@example.test',
      p_cedula: '00198765432',
      p_rol: 'cuidador',
    };
    expect(rpc.api_preparar_invitacion).toHaveBeenCalledWith(esperado);
    expect(rpc.api_agregar_miembro).toHaveBeenCalledWith(esperado, expect.any(Object));
    expect(res.body.data).toMatchObject({ estado: 'pendiente', usuario_existente: true });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'miembro.invitado', actorId, result: 'success' }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toMatch(/example\.test|00198765432|Nuevo/);
  });

  it('persona nueva: prepara, crea la identidad con el gateway administrativo y luego agrega', async () => {
    const rpc = rpcInvitar(false);
    const { app, adminGateway } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(201);
    expect(adminGateway.inviteUser).toHaveBeenCalledTimes(1);
    expect(adminGateway.inviteUser).toHaveBeenCalledWith({
      email: 'nuevo.miembro@example.test',
      cedula: '00198765432',
      nombres: 'Nuevo',
      apellidos: 'Miembro',
    });
    const orden = [
      rpc.api_preparar_invitacion.mock.invocationCallOrder[0],
      adminGateway.inviteUser.mock.invocationCallOrder[0],
      rpc.api_agregar_miembro.mock.invocationCallOrder[0],
    ];
    expect(orden).toEqual([...orden].sort((a, b) => a - b));
    expect(res.body.data.usuario_existente).toBe(false);
  });

  it('sin gateway administrativo no se invita a personas nuevas (503) ni se agrega nada', async () => {
    const rpc = rpcInvitar(false);
    const { app, audit } = setup({ rpc, admin: null });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(503);
    expect(res.body.error.code).toBe('INVITATIONS_UNAVAILABLE');
    expect(rpc.api_agregar_miembro).not.toHaveBeenCalled();
    expect(audit).not.toHaveBeenCalledWith(expect.objectContaining({ result: 'success' }));
  });

  it('sin gateway administrativo sí se agrega a quien ya existe', async () => {
    const { app } = setup({ rpc: rpcInvitar(true), admin: null });
    await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(201);
  });

  it('sin cupo en el plan no se crea ninguna identidad (límite antes de invitar)', async () => {
    const rpc = rpcInvitar(false, {
      api_preparar_invitacion: rechaza(negocio('CR_LIMITE_PLAN')),
    });
    const { app, adminGateway } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(409);
    expect(res.body.error.code).toBe('PLAN_LIMIT_REACHED');
    expect(adminGateway.inviteUser).not.toHaveBeenCalled();
    expect(rpc.api_agregar_miembro).not.toHaveBeenCalled();
  });

  it('otra invitación ocupó el último cupo entre medias: la RPC final lo rechaza (409)', async () => {
    const rpc = rpcInvitar(false, { api_agregar_miembro: rechaza(negocio('CR_LIMITE_PLAN')) });
    const { app, audit } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(409);
    expect(res.body.error.code).toBe('PLAN_LIMIT_REACHED');
    expect(audit).not.toHaveBeenCalledWith(expect.objectContaining({ result: 'success' }));
  });

  it.each([
    ['CR_IDENTIDAD_NO_COINCIDE', 409, 'IDENTITY_MISMATCH'],
    ['CR_YA_ES_MIEMBRO', 409, 'ALREADY_MEMBER'],
    ['CR_ROL_NO_PERMITIDO', 422, 'ROLE_NOT_ALLOWED'],
  ])('%s en la preparación → %s %s sin crear identidad', async (codigo, status, publico) => {
    const rpc = rpcInvitar(true, { api_preparar_invitacion: rechaza(negocio(codigo)) });
    const { app, adminGateway } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(status);
    expect(res.body.error.code).toBe(publico);
    expect(adminGateway.inviteUser).not.toHaveBeenCalled();
  });

  it('la identidad que no coincide devuelve un mensaje genérico, sin revelar la cédula', async () => {
    const rpc = rpcInvitar(true, {
      api_preparar_invitacion: rechaza(negocio('CR_IDENTIDAD_NO_COINCIDE')),
    });
    const { app } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(409);
    expect(JSON.stringify(res.body)).not.toMatch(/00198765432|c[eé]dula/i);
  });

  it('un conflicto del proveedor al crear la identidad llega como 409 y no agrega la membresía', async () => {
    const rpc = rpcInvitar(false);
    const admin = {
      inviteUser: vi
        .fn()
        .mockRejectedValue(new AppError(409, 'INVITATION_CONFLICT', 'No se pudo.')),
    };
    const { app } = setup({ rpc, admin });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(409);
    expect(res.body.error.code).toBe('INVITATION_CONFLICT');
    expect(rpc.api_agregar_miembro).not.toHaveBeenCalled();
  });

  it('el índice único de membresía vigente (23505) es un 409 ALREADY_MEMBER', async () => {
    const rpc = rpcInvitar(true, {
      api_agregar_miembro: vi.fn(async (_p, options) => {
        throw mapRpcError({ code: '23505' }, options);
      }),
    });
    const { app } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(409);
    expect(res.body.error.code).toBe('ALREADY_MEMBER');
  });

  it.each([
    ['campo desconocido (cuenta_id)', { cuenta_id: 99 }],
    ['campo desconocido (usuario_id)', { usuario_id: actorId }],
    ['campo desconocido (estado)', { estado: 'activa' }],
    ['cédula con guiones', { cedula: '001-9876543-2' }],
    ['cédula corta', { cedula: '123' }],
    ['cédula numérica', { cedula: 19876543210 }],
    ['correo inválido', { correo: 'sin-arroba' }],
    ['nombres vacíos', { nombres: '   ' }],
    ['apellidos demasiado largos', { apellidos: 'x'.repeat(101) }],
    ['rol inexistente', { rol: 'superadmin' }],
    ['rol ausente', { rol: undefined }],
  ])('rechaza el cuerpo con %s (422) sin tocar la base ni Auth', async (_nombre, cambio) => {
    const rpc = rpcInvitar(false);
    const { app, adminGateway, llamadas } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros')
      .send({ ...invitacion, ...cambio })
      .expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(adminGateway.inviteUser).not.toHaveBeenCalled();
    expect(llamadas('api_preparar_invitacion')).toHaveLength(0);
  });

  it.each(['voluntario', 'administrador'])(
    'en una cuenta Familia no existe el rol %s (422)',
    async (rol) => {
      const rpc = rpcInvitar(true);
      const { app } = setup({ rpc });
      const res = await http(app, 'post', '/cuentas/7/miembros')
        .send({ ...invitacion, rol })
        .expect(422);
      expect(res.body.error.code).toBe('ROLE_NOT_ALLOWED');
      expect(rpc.api_preparar_invitacion).not.toHaveBeenCalled();
    },
  );

  it('en una Organización el Administrador puede invitar voluntarios', async () => {
    const rpc = rpcInvitar(true);
    const { app } = setup({ ctx: contexto({ tipo: 'organizacion', rol: 'administrador' }), rpc });
    await http(app, 'post', '/cuentas/7/miembros')
      .send({ ...invitacion, rol: 'voluntario' })
      .expect(201);
  });

  it('limita las invitaciones por persona que invita (429)', async () => {
    const { app } = setup({ rpc: rpcInvitar(true) });
    for (let i = 0; i < 30; i += 1) {
      await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(201);
    }
    const res = await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(429);
    expect(res.body.error.code).toBe('RATE_LIMITED');
  });
});

describe('RF-11: cambiar rol, desactivar y reactivar', () => {
  it('cambia el rol con la cuenta y el id de la ruta y devuelve la membresía nueva', async () => {
    const rpc = {
      api_cambiar_rol_miembro: vi.fn(async () => miembro({ membresia_id: 22, rol: 'familiar' })),
    };
    const { app, audit } = setup({ rpc });
    const res = await http(app, 'patch', '/cuentas/7/miembros/21')
      .send({ rol: 'familiar' })
      .expect(200);
    expect(rpc.api_cambiar_rol_miembro).toHaveBeenCalledWith(
      { p_cuenta_id: '7', p_membresia_id: '21', p_rol: 'familiar' },
      expect.any(Object),
    );
    expect(res.body.data).toMatchObject({ membresia_id: '22', rol: 'familiar' });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'miembro.rol_cambiado', actorId }),
    );
  });

  it.each([
    ['sin cuerpo', {}],
    ['rol inexistente', { rol: 'reina' }],
    ['campo desconocido (estado)', { rol: 'familiar', estado: 'activa' }],
    ['campo desconocido (usuario_id)', { rol: 'familiar', usuario_id: actorId }],
    ['rol como lista', { rol: ['familiar'] }],
  ])('PATCH rechaza %s (422)', async (_nombre, body) => {
    const { app, llamadas } = setup({ rpc: { api_cambiar_rol_miembro: async () => miembro() } });
    await http(app, 'patch', '/cuentas/7/miembros/21').send(body).expect(422);
    expect(llamadas('api_cambiar_rol_miembro')).toHaveLength(0);
  });

  it('en una cuenta Familia no se puede cambiar a un rol de Organización (422)', async () => {
    const { app, llamadas } = setup({ rpc: { api_cambiar_rol_miembro: async () => miembro() } });
    const res = await http(app, 'patch', '/cuentas/7/miembros/21')
      .send({ rol: 'voluntario' })
      .expect(422);
    expect(res.body.error.code).toBe('ROLE_NOT_ALLOWED');
    expect(llamadas('api_cambiar_rol_miembro')).toHaveLength(0);
  });

  it.each([
    ['CR_MEMBRESIA_PROPIA', 409, 'OWN_MEMBERSHIP'],
    ['CR_TITULAR_PROTEGIDO', 409, 'OWNER_PROTECTED'],
    ['CR_ULTIMO_GESTOR', 409, 'LAST_MANAGER'],
    ['CR_LIMITE_PLAN', 409, 'PLAN_LIMIT_REACHED'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
    ['CR_ROL_NO_PERMITIDO', 422, 'ROLE_NOT_ALLOWED'],
  ])('las protecciones de la RPC (%s) llegan como %s %s', async (codigo, status, publico) => {
    const rpc = {
      api_cambiar_rol_miembro: rechaza(negocio(codigo)),
      api_desactivar_miembro: rechaza(negocio(codigo)),
      api_reactivar_miembro: rechaza(negocio(codigo)),
    };
    const { app, audit } = setup({ rpc });
    const a = await http(app, 'patch', '/cuentas/7/miembros/21')
      .send({ rol: 'familiar' })
      .expect(status);
    const b = await http(app, 'post', '/cuentas/7/miembros/21/desactivar').expect(status);
    const c = await http(app, 'post', '/cuentas/7/miembros/21/reactivar').expect(status);
    expect([a, b, c].map((r) => r.body.error.code)).toEqual([publico, publico, publico]);
    expect(audit).not.toHaveBeenCalledWith(expect.objectContaining({ result: 'success' }));
  });

  it('desactivar y reactivar devuelven la membresía y se auditan', async () => {
    const rpc = {
      api_desactivar_miembro: vi.fn(async () =>
        miembro({ estado: 'inactiva', fecha_fin: '2026-11-06' }),
      ),
      api_reactivar_miembro: vi.fn(async () => miembro({ membresia_id: 30 })),
    };
    const { app, audit } = setup({ rpc });
    const baja = await http(app, 'post', '/cuentas/7/miembros/21/desactivar').expect(200);
    expect(baja.body.data).toMatchObject({ estado: 'inactiva', fecha_fin: '2026-11-06' });
    expect(rpc.api_desactivar_miembro).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_membresia_id: '21',
    });
    const alta = await http(app, 'post', '/cuentas/7/miembros/21/reactivar').expect(200);
    expect(alta.body.data).toMatchObject({ membresia_id: '30', estado: 'activa' });
    const acciones = audit.mock.calls.map(([e]) => e.action);
    expect(acciones).toEqual(['miembro.desactivado', 'miembro.reactivado']);
  });

  it.each([
    { cuenta_id: 9 },
    { usuario_id: actorId },
    { rol: 'administrador' },
    { estado: 'activa' },
  ])('las acciones no admiten cuerpo %j (422)', async (body) => {
    const { app, llamadas } = setup();
    await http(app, 'post', '/cuentas/7/miembros/21/desactivar').send(body).expect(422);
    await http(app, 'post', '/cuentas/7/miembros/21/reactivar').send(body).expect(422);
    expect(llamadas('api_desactivar_miembro')).toHaveLength(0);
  });

  it.each([
    ['patch', '/cuentas/7/miembros/abc', { rol: 'familiar' }],
    ['post', '/cuentas/7/miembros/0/desactivar', undefined],
    ['post', '/cuentas/7/miembros/-3/reactivar', undefined],
  ])('el id inválido de %s %s es 404 sin consultar la base', async (method, path, body) => {
    const { app, rpc } = setup();
    const call = http(app, method, path);
    await (body ? call.send(body) : call).expect(404);
    expect(rpc.mock.calls.map(([n]) => n)).toEqual(['api_contexto_cuenta']);
  });

  it('la membresía de otra cuenta no existe aunque se conozca su id (404)', async () => {
    const notFound = mapRpcError({ code: 'P0002' });
    const rpc = {
      api_cambiar_rol_miembro: rechaza(notFound),
      api_desactivar_miembro: rechaza(notFound),
      api_reactivar_miembro: rechaza(notFound),
    };
    const { app } = setup({ rpc });
    await http(app, 'patch', '/cuentas/7/miembros/99').send({ rol: 'familiar' }).expect(404);
    await http(app, 'post', '/cuentas/7/miembros/99/desactivar').expect(404);
    await http(app, 'post', '/cuentas/7/miembros/99/reactivar').expect(404);
  });

  it('solo existen GET, POST y PATCH: no hay PUT ni DELETE de miembros', async () => {
    const { app } = setup();
    await http(app, 'put', '/cuentas/7/miembros/21').send({ rol: 'familiar' }).expect(404);
    await http(app, 'delete', '/cuentas/7/miembros/21').expect(404);
  });
});

describe('RF-11: titularidad', () => {
  const transferida = {
    cuenta_id: 7,
    usuario_titular_id: 'b0c1d2e3-0000-4000-8000-000000000021',
    membresia_id: 21,
  };

  it('solo el titular actual: quien gestiona miembros sin ser titular recibe 403', async () => {
    const rpc = { api_transferir_titularidad: vi.fn(async () => transferida) };
    const { app } = setup({ ctx: contexto({ es_titular: false }), rpc });
    const res = await http(app, 'post', '/cuentas/7/titularidad')
      .send({ membresia_id: 21 })
      .expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(rpc.api_transferir_titularidad).not.toHaveBeenCalled();
  });

  it('el titular transfiere a una membresía de la cuenta y queda auditado', async () => {
    const rpc = { api_transferir_titularidad: vi.fn(async () => transferida) };
    const { app, audit } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/titularidad')
      .send({ membresia_id: 21 })
      .expect(200);
    expect(rpc.api_transferir_titularidad).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_membresia_id: '21',
    });
    // Los identificadores bigint viajan como texto, igual que en el contexto de cuenta.
    expect(res.body.data).toEqual({ ...transferida, cuenta_id: '7', membresia_id: '21' });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({
        action: 'cuenta.titularidad_transferida',
        actorId,
        result: 'success',
      }),
    );
  });

  it('acepta el id como texto de dígitos y lo normaliza a número', async () => {
    const rpc = { api_transferir_titularidad: vi.fn(async () => transferida) };
    const { app } = setup({ rpc });
    await http(app, 'post', '/cuentas/7/titularidad').send({ membresia_id: '21' }).expect(200);
    expect(rpc.api_transferir_titularidad).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_membresia_id: '21',
    });
  });

  it.each([
    ['sin cuerpo', undefined],
    ['sin membresia_id', {}],
    ['id no numérico', { membresia_id: 'abc' }],
    ['id cero', { membresia_id: 0 }],
    ['id negativo', { membresia_id: -4 }],
    ['id decimal', { membresia_id: 1.5 }],
    ['id inseguro', { membresia_id: Number.MAX_SAFE_INTEGER + 2 }],
    ['campo desconocido (cuenta_id)', { membresia_id: 21, cuenta_id: 9 }],
    ['campo desconocido (usuario_id)', { membresia_id: 21, usuario_id: actorId }],
  ])('rechaza %s (422)', async (_nombre, body) => {
    const rpc = { api_transferir_titularidad: vi.fn(async () => transferida) };
    const { app } = setup({ rpc });
    const call = http(app, 'post', '/cuentas/7/titularidad');
    await (body === undefined ? call : call.send(body)).expect(422);
    expect(rpc.api_transferir_titularidad).not.toHaveBeenCalled();
  });

  it.each([
    ['CR_DESTINO_NO_GESTOR', 422, 'NEW_OWNER_NOT_MANAGER'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
  ])('%s → %s %s', async (codigo, status, publico) => {
    const { app, audit } = setup({ rpc: { api_transferir_titularidad: rechaza(negocio(codigo)) } });
    const res = await http(app, 'post', '/cuentas/7/titularidad')
      .send({ membresia_id: 21 })
      .expect(status);
    expect(res.body.error.code).toBe(publico);
    expect(audit).not.toHaveBeenCalledWith(expect.objectContaining({ result: 'success' }));
  });

  it('un destino de otra cuenta es 404 y un contrato roto, 503', async () => {
    const a = setup({
      rpc: { api_transferir_titularidad: rechaza(mapRpcError({ code: 'P0002' })) },
    });
    await http(a.app, 'post', '/cuentas/7/titularidad').send({ membresia_id: 21 }).expect(404);
    const b = setup({ rpc: { api_transferir_titularidad: async () => ({ cuenta_id: 7 }) } });
    await http(b.app, 'post', '/cuentas/7/titularidad').send({ membresia_id: 21 }).expect(503);
  });
});

describe('RF-12: perfil Cuidador por cuenta', () => {
  const cuerpo = { tipo_cuidado_id: 1, cuidador_independiente: false };

  it('GET devuelve el perfil vigente o null', async () => {
    const rpc = {
      api_obtener_cuidador_miembro: vi
        .fn()
        .mockResolvedValueOnce(perfil())
        .mockResolvedValueOnce(null),
    };
    const { app } = setup({ rpc });
    const res = await http(app, 'get', '/cuentas/7/miembros/21/cuidador').expect(200);
    expect(res.body.data).toMatchObject({
      cuidador_id: '5',
      tipo_cuidado: 'Cuidador remunerado',
      cuidador_independiente: false,
    });
    expect(rpc.api_obtener_cuidador_miembro).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_membresia_id: '21',
    });
    await http(app, 'get', '/cuentas/7/miembros/21/cuidador').expect(200, { data: null });
  });

  it('POST crea o actualiza el perfil sin aceptar empleador ni cuenta del cliente', async () => {
    const rpc = { api_guardar_cuidador_miembro: vi.fn(async () => perfil({ tipo_cuidado_id: 2 })) };
    const { app, audit } = setup({ rpc });
    const res = await http(app, 'post', '/cuentas/7/miembros/21/cuidador')
      .send({ tipo_cuidado_id: 2, cuidador_independiente: false })
      .expect(200);
    expect(rpc.api_guardar_cuidador_miembro).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_membresia_id: '21',
      p_tipo_cuidado_id: 2,
      p_cuidador_independiente: false,
    });
    expect(res.body.data.tipo_cuidado_id).toBe(2);
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'cuidador.guardado', actorId }),
    );
  });

  it.each([
    ['sin cuerpo', {}],
    ['sin cuidador_independiente', { tipo_cuidado_id: 1 }],
    ['sin tipo_cuidado_id', { cuidador_independiente: true }],
    ['tipo como texto', { tipo_cuidado_id: '1', cuidador_independiente: true }],
    ['tipo cero', { tipo_cuidado_id: 0, cuidador_independiente: true }],
    ['tipo decimal', { tipo_cuidado_id: 1.5, cuidador_independiente: true }],
    ['tipo fuera de smallint', { tipo_cuidado_id: 40000, cuidador_independiente: true }],
    ['independiente como texto', { tipo_cuidado_id: 1, cuidador_independiente: 'true' }],
    ['empleador del cliente', { ...cuerpo, usuario_empleador_id: actorId }],
    ['cuenta del cliente', { ...cuerpo, cuenta_id: 9 }],
    ['fechas del cliente', { ...cuerpo, fecha_fin: '2026-01-01' }],
  ])('POST rechaza %s (422)', async (_nombre, body) => {
    const { app, llamadas } = setup({
      rpc: { api_guardar_cuidador_miembro: async () => perfil() },
    });
    await http(app, 'post', '/cuentas/7/miembros/21/cuidador').send(body).expect(422);
    expect(llamadas('api_guardar_cuidador_miembro')).toHaveLength(0);
  });

  it('solo para miembros con rol cuidador (409) y catálogos inexistentes (422)', async () => {
    const a = setup({
      rpc: { api_guardar_cuidador_miembro: rechaza(negocio('CR_NO_ES_CUIDADOR')) },
    });
    const res = await http(a.app, 'post', '/cuentas/7/miembros/21/cuidador')
      .send(cuerpo)
      .expect(409);
    expect(res.body.error.code).toBe('NOT_A_CAREGIVER');
    const b = setup({
      rpc: { api_guardar_cuidador_miembro: rechaza(mapRpcError({ code: '22023' })) },
    });
    await http(b.app, 'post', '/cuentas/7/miembros/21/cuidador').send(cuerpo).expect(422);
  });

  it('una cuenta no puede finalizar un perfil global desde la ruta antigua', async () => {
    const { app, llamadas } = setup();
    await http(app, 'post', '/cuentas/7/miembros/21/cuidador/finalizar').expect(404);
    expect(llamadas('api_finalizar_cuidador_miembro')).toHaveLength(0);
  });

  it('la membresía de otra cuenta no existe para el perfil (404)', async () => {
    const notFound = mapRpcError({ code: 'P0002' });
    const rpc = {
      api_obtener_cuidador_miembro: rechaza(notFound),
      api_guardar_cuidador_miembro: rechaza(notFound),
    };
    const { app } = setup({ rpc });
    await http(app, 'get', '/cuentas/7/miembros/99/cuidador').expect(404);
    await http(app, 'post', '/cuentas/7/miembros/99/cuidador').send(cuerpo).expect(404);
  });
});

describe('RF-11: aceptar o rechazar la membresía propia', () => {
  const aceptada = { membresia_id: 21, cuenta_id: 7, rol: 'cuidador', estado: 'activa' };

  it('acepta sin contexto de cuenta: solo la RPC sobre la membresía propia pendiente', async () => {
    const rpc = { api_aceptar_membresia: vi.fn(async () => aceptada) };
    const { app, rpc: mock, audit } = setup({ rpc });
    const res = await http(app, 'post', '/me/membresias/21/aceptar').expect(200);
    expect(res.body.data).toEqual({ ...aceptada, membresia_id: '21', cuenta_id: '7' });
    expect(mock.mock.calls.map(([n]) => n)).toEqual(['api_aceptar_membresia']);
    expect(rpc.api_aceptar_membresia).toHaveBeenCalledWith(
      { p_membresia_id: '21' },
      expect.any(Object),
    );
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'membresia.aceptada', actorId, result: 'success' }),
    );
  });

  it('rechaza con 204 y sin cuerpo', async () => {
    const rpc = { api_rechazar_membresia: vi.fn(async () => null) };
    const { app, audit } = setup({ rpc });
    const res = await http(app, 'post', '/me/membresias/21/rechazar').expect(204);
    expect(res.text).toBe('');
    expect(rpc.api_rechazar_membresia).toHaveBeenCalledWith({ p_membresia_id: '21' });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'membresia.rechazada', actorId }),
    );
  });

  it('la membresía de otra persona (o inexistente) es 404', async () => {
    const notFound = mapRpcError({ code: 'P0002' });
    const rpc = {
      api_aceptar_membresia: rechaza(notFound),
      api_rechazar_membresia: rechaza(notFound),
    };
    const { app } = setup({ rpc });
    await http(app, 'post', '/me/membresias/99/aceptar').expect(404);
    await http(app, 'post', '/me/membresias/99/rechazar').expect(404);
  });

  it.each([
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
    ['CR_LIMITE_PLAN', 409, 'PLAN_LIMIT_REACHED'],
  ])('al aceptar, %s → %s %s', async (codigo, status, publico) => {
    const { app } = setup({ rpc: { api_aceptar_membresia: rechaza(negocio(codigo)) } });
    const res = await http(app, 'post', '/me/membresias/21/aceptar').expect(status);
    expect(res.body.error.code).toBe(publico);
  });

  it('ya no está pendiente: rechazar también es 409', async () => {
    const { app } = setup({
      rpc: { api_rechazar_membresia: rechaza(negocio('CR_ESTADO_INVALIDO')) },
    });
    await http(app, 'post', '/me/membresias/21/rechazar').expect(409);
  });

  it.each(['0', 'abc', '-1', '1.5', '99999999999999999999'])(
    'el id %s es 404 sin consultar la base',
    async (id) => {
      const { app, rpc } = setup();
      await http(app, 'post', `/me/membresias/${id}/aceptar`).expect(404);
      await http(app, 'post', `/me/membresias/${id}/rechazar`).expect(404);
      expect(rpc).not.toHaveBeenCalled();
    },
  );

  it.each([
    { cuenta_id: 9 },
    { usuario_id: actorId },
    { rol: 'administrador' },
    { estado: 'activa' },
  ])('no admite cuerpo %j (422)', async (body) => {
    const { app, rpc } = setup();
    await http(app, 'post', '/me/membresias/21/aceptar').send(body).expect(422);
    await http(app, 'post', '/me/membresias/21/rechazar').send(body).expect(422);
    expect(rpc).not.toHaveBeenCalled();
  });

  it('solo POST: no se acepta con GET ni se cambia con PATCH', async () => {
    const { app } = setup();
    await http(app, 'get', '/me/membresias/21/aceptar').expect(404);
    await http(app, 'patch', '/me/membresias/21').send({ estado: 'activa' }).expect(404);
  });

  it('un contrato roto de la RPC es indisponibilidad', async () => {
    const { app } = setup({ rpc: { api_aceptar_membresia: async () => ({ estado: 'activa' }) } });
    await http(app, 'post', '/me/membresias/21/aceptar').expect(503);
  });
});

describe('aislamiento por cuenta y auditoría', () => {
  it('la cuenta de la ruta es la única que llega a las RPC', async () => {
    const rpc = { api_listar_miembros: vi.fn(async () => ({ total: 0, items: [] })) };
    const { app } = setup({ ctx: ({ p_cuenta_id }) => contexto({ cuenta_id: p_cuenta_id }), rpc });
    await http(app, 'get', '/cuentas/9/miembros').expect(200);
    expect(rpc.api_listar_miembros.mock.calls[0][0].p_cuenta_id).toBe('9');
    // Intentar fijar otra cuenta por query o por cuerpo se rechaza.
    await http(app, 'get', '/cuentas/9/miembros').query({ cuenta_id: '7' }).expect(422);
    await http(app, 'post', '/cuentas/9/miembros')
      .send({ ...invitacion, cuenta_id: 7 })
      .expect(422);
    expect(rpc.api_listar_miembros).toHaveBeenCalledTimes(1);
  });

  it('ninguna llamada a las RPC lleva el actor ni un id de persona del cliente', async () => {
    const rpc = {
      api_preparar_invitacion: async () => ({ usuario_existe: true }),
      api_agregar_miembro: async () => miembro({ estado: 'pendiente' }),
      api_cambiar_rol_miembro: async () => miembro(),
      api_desactivar_miembro: async () => miembro(),
      api_reactivar_miembro: async () => miembro(),
      api_listar_miembros: async () => ({ total: 0, items: [] }),
    };
    const { app, rpc: mock } = setup({ rpc });
    await http(app, 'get', '/cuentas/7/miembros').expect(200);
    await http(app, 'post', '/cuentas/7/miembros').send(invitacion).expect(201);
    await http(app, 'patch', '/cuentas/7/miembros/21').send({ rol: 'familiar' }).expect(200);
    await http(app, 'post', '/cuentas/7/miembros/21/desactivar').expect(200);
    await http(app, 'post', '/cuentas/7/miembros/21/reactivar').expect(200);
    const claves = new Set(mock.mock.calls.flatMap(([, params]) => Object.keys(params ?? {})));
    expect([...claves].sort()).toEqual(
      [
        'p_cedula',
        'p_correo',
        'p_cuenta_id',
        'p_desplazamiento',
        'p_estado',
        'p_limite',
        'p_membresia_id',
        'p_orden',
        'p_rol',
      ].sort(),
    );
  });

  it('los errores públicos no exponen detalles de la base ni datos de la persona', async () => {
    const rpc = {
      api_detalle_miembro: rechaza(
        mapRpcError({
          code: 'XX000',
          message: 'relation cuidared.membresia id 21 diego@example.test',
        }),
      ),
    };
    const { app } = setup({ rpc });
    const res = await http(app, 'get', '/cuentas/7/miembros/21').expect(503);
    expect(JSON.stringify(res.body)).not.toMatch(/membresia|diego|XX000/);
  });
});

describe('CR-162: códigos de negocio de miembros', () => {
  it.each([
    ['CR_IDENTIDAD_NO_COINCIDE', 409, 'IDENTITY_MISMATCH'],
    ['CR_YA_ES_MIEMBRO', 409, 'ALREADY_MEMBER'],
    ['CR_MEMBRESIA_PROPIA', 409, 'OWN_MEMBERSHIP'],
    ['CR_TITULAR_PROTEGIDO', 409, 'OWNER_PROTECTED'],
    ['CR_ULTIMO_GESTOR', 409, 'LAST_MANAGER'],
    ['CR_NO_ES_CUIDADOR', 409, 'NOT_A_CAREGIVER'],
    ['CR_DESTINO_NO_GESTOR', 422, 'NEW_OWNER_NOT_MANAGER'],
    ['CR_LIMITE_PLAN', 409, 'PLAN_LIMIT_REACHED'],
    ['CR_ROL_NO_PERMITIDO', 422, 'ROLE_NOT_ALLOWED'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
  ])('%s está registrado y se traduce a %s %s', (codigo, status, publico) => {
    // El módulo registra sus códigos al importarse desde los routers (createApp ya los importó).
    const error = businessError(codigo);
    expect(error).toBeInstanceOf(AppError);
    expect([error.status, error.code]).toEqual([status, publico]);
    expect(error.message).not.toMatch(/CR_|SQL|cuidared/);
  });
});
