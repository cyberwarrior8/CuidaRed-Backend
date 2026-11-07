/* Pruebas API ID03/RF-01/RF-17: perfiles de adultos mayores, consentimiento, contactos y estado (sin base real). © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { businessError } from '../src/lib/business-errors.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';
import { ENVEJECIENTES_CODIGOS } from '../src/modules/envejecientes/envejecientes-errors.js';

/*
 * El gateway es simulado: cada RPC devuelve datos fijos o el error que produciría la base (mapRpcError traduce
 * P0002, 42501, 22023 y los CR_*). La autorización real, el alcance por asignación y el aislamiento entre cuentas
 * los certifican las pruebas SQL (docs/verificacion/local/pruebas-3a-*.sql); aquí se comprueba lo que hace Express:
 * permisos por rol antes de llamar a la base, validación estricta, cuenta tomada de la ruta, proyección por nivel
 * de visibilidad, errores públicos sin fugas y auditoría sin datos personales.
 */

const ACTOR = 'a271ce25-7f40-4c45-b5ba-dbc6a0011234';
const ADULTO = '5d3c1a52-8c2e-4f6b-9a3b-0f6f4c1d2e77';
const CUENTA = 7;
const BASE = `/api/v1/cuentas/${CUENTA}`;

const contexto = (rol, tipo, extra = {}) => ({
  cuenta_id: CUENTA,
  tipo,
  rol,
  membresia_id: 11,
  permisos: permisosDe(rol, tipo),
  es_titular: false,
  acceso_operativo: true,
  suscripcion_estado: 'activa',
  funcionalidades: [],
  ...extra,
});

const CONTACTO = {
  contacto_id: 31,
  envejeciente_id: ADULTO,
  nombres: 'Luis',
  apellidos: 'Peña',
  parentesco: 'Hijo/a',
  telefono: '8295550101',
  es_principal: true,
};
// Lo que devuelve la base a un usuario con adultos:ver-sensible; las pruebas de rol verifican que Express lo recorta.
const FILA_COMPLETA = {
  envejeciente_id: ADULTO,
  estado: 'activo',
  nombres: 'Rosa María',
  apellidos: 'Peña Díaz',
  direccion: 'Calle 1 #2',
  zona: 'Centro',
  municipio_cod: '0101',
  municipio_nombre: 'Santo Domingo de Guzmán',
  provincia_cod: '01',
  contacto_principal: CONTACTO,
  cedula: '00112345678',
  fecha_nacimiento: '1950-03-15',
  sexo: 'F',
  telefono: '8095550100',
  fecha_creacion: '2026-11-06T12:00:00.000000Z',
  fecha_actualizacion: '2026-11-06T12:00:00.000000Z',
  contactos: [CONTACTO],
  motivo_estado: null,
  fecha_estado: '2026-11-06T12:00:00.000000Z',
  condicion_general: { autonomia: 'parcial', condiciones: ['cronica'], nota: 'Usa bastón' },
  consentimiento: {
    otorgado: true,
    otorgado_por: 'adulto',
    representante: null,
    fecha: '2026-11-06T12:00:00.000000Z',
    registrado_por: ACTOR,
  },
};
const ITEM = {
  envejeciente_id: ADULTO,
  estado: 'activo',
  nombres: 'Rosa María',
  apellidos: 'Peña Díaz',
  municipio_cod: '0101',
  zona: 'Centro',
  fecha_creacion: '2026-11-06T12:00:00.000000Z',
  fecha_nacimiento: '1950-03-15',
  sexo: 'F',
  autonomia: 'parcial',
};
const SENSIBLES = [
  'cedula',
  'fecha_nacimiento',
  'sexo',
  'telefono',
  'contactos',
  'condicion_general',
  'consentimiento',
  'motivo_estado',
  'fecha_estado',
  'fecha_creacion',
  'fecha_actualizacion',
];

const PERFIL = {
  nombres: '  Rosa   María ',
  apellidos: 'Peña Díaz',
  cedula: '001-1234567-8',
  fecha_nacimiento: '1950-03-15',
  sexo: 'F',
  telefono: '809 555 0100',
  municipio_cod: '0101',
  zona: 'Centro',
  direccion: 'Calle 1 #2',
  autonomia: 'parcial',
  condiciones: ['cronica', 'movilidad', 'cronica'],
  nota_condicion: 'Usa bastón',
  consentimiento: { otorgado: true, otorgado_por: 'adulto' },
  contactos: [
    {
      nombres: 'Luis',
      apellidos: 'Peña',
      parentesco: 'Hijo/a',
      telefono: '829-555-0101',
      es_principal: true,
    },
  ],
};
const otroContacto = (extra = {}) => ({
  nombres: 'Eva',
  apellidos: 'Abreu',
  parentesco: 'Amigo/a',
  telefono: '809 555 0199',
  ...extra,
});

const rpcError = (code, message) => mapRpcError({ code, message });

/**
 * `respuestas` asigna a cada RPC un valor fijo o una función (params) → valor; una función que lanza simula el error
 * de la base. Una RPC sin respuesta falla la prueba (nada se llama sin que se haya previsto).
 */
function setup({ rol = 'coordinador', tipo = 'familia', ctx, respuestas = {} } = {}) {
  const rpc = vi.fn(async (name, params) => {
    if (name === 'api_contexto_cuenta') {
      return ctx === undefined ? contexto(rol, tipo) : ctx;
    }
    if (!(name in respuestas)) throw new Error(`RPC no prevista: ${name}`);
    const r = respuestas[name];
    return typeof r === 'function' ? r(params) : r;
  });
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue({
      usuario_id: ACTOR,
      cedula: '00100000000',
      nombres: 'Ana',
      apellidos: 'Pérez',
      correo: 'ana@example.test',
      telefono: null,
      estado: 'activo',
    }),
    rpc,
  };
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: ACTOR, email: 'ana@example.test' }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const audit = vi.fn();
  const app = createApp({ env: { origins: ['http://localhost:5173'] }, gateway, audit });
  const call = (method, path) =>
    request(app)[method](`${BASE}${path}`).auth('token', { type: 'bearer' });
  // RPC de negocio llamadas (sin el contexto de cuenta).
  const llamadas = () => rpc.mock.calls.filter(([name]) => name !== 'api_contexto_cuenta');
  return { app, rpc, audit, call, llamadas };
}

describe('ID03: permisos y contexto de cuenta', () => {
  it('exige sesión y no acepta rutas sin token', async () => {
    const { app } = setup();
    await request(app).get(`${BASE}/envejecientes`).expect(401);
  });
  it('sin membresía activa la cuenta no existe: 404 sin llamar a ninguna RPC de adultos', async () => {
    const { call, llamadas } = setup({ ctx: null });
    const res = await call('get', '/envejecientes').expect(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
    expect(llamadas()).toHaveLength(0);
  });
  it('cuenta vencida: bloquea también la consulta (D07)', async () => {
    const { call, llamadas } = setup({
      ctx: contexto('coordinador', 'familia', { acceso_operativo: false }),
    });
    const res = await call('get', '/envejecientes').expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    expect(llamadas()).toHaveLength(0);
  });

  const escrituras = [
    ['post', '/envejecientes', PERFIL],
    ['patch', `/envejecientes/${ADULTO}`, { zona: 'Gazcue' }],
    ['post', `/envejecientes/${ADULTO}/estado`, { estado: 'inactivo', motivo: 'Se mudó' }],
    ['post', `/envejecientes/${ADULTO}/contactos`, otroContacto()],
    ['patch', '/contactos/31', { telefono: '8095550100' }],
    ['post', '/contactos/31/principal', {}],
    ['post', '/contactos/31/eliminar', {}],
  ];
  it.each([
    ['cuidador', 'familia'],
    ['familiar', 'familia'],
    ['cuidador', 'organizacion'],
    ['familiar', 'organizacion'],
    ['voluntario', 'organizacion'],
  ])('%s de %s no escribe: 403 antes de llamar a la base', async (rol, tipo) => {
    const { call, llamadas } = setup({ rol, tipo });
    for (const [metodo, ruta, cuerpo] of escrituras) {
      const res = await call(metodo, ruta).send(cuerpo).expect(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
    }
    expect(llamadas()).toHaveLength(0);
  });
  it('cada rol consulta con adultos:ver (el alcance lo decide la base)', async () => {
    for (const [rol, tipo] of [
      ['administrador', 'organizacion'],
      ['coordinador', 'familia'],
      ['cuidador', 'familia'],
      ['familiar', 'familia'],
      ['voluntario', 'organizacion'],
    ]) {
      const { call } = setup({
        rol,
        tipo,
        respuestas: { api_listar_envejecientes: { total: 0, items: [] } },
      });
      await call('get', '/envejecientes').expect(200);
    }
  });
  it('solo existen GET, POST y PATCH: PUT y DELETE no están enrutados', async () => {
    const { call, llamadas } = setup();
    await call('put', `/envejecientes/${ADULTO}`).send(PERFIL).expect(404);
    await call('delete', `/envejecientes/${ADULTO}`).expect(404);
    await call('delete', '/contactos/31').expect(404);
    expect(llamadas()).toHaveLength(0);
  });
});

describe('ID03: listado paginado con alcance por rol', () => {
  const listado = { total: 1, items: [ITEM] };

  it('usa el orden predeterminado (apellidos, nombres, fecha de creación) y la cuenta de la ruta', async () => {
    const { call, rpc } = setup({ respuestas: { api_listar_envejecientes: listado } });
    const res = await call('get', '/envejecientes').expect(200);
    expect(rpc).toHaveBeenCalledWith('api_listar_envejecientes', {
      p_cuenta_id: CUENTA,
      p_estado: null,
      p_municipio_cod: null,
      p_orden: ['apellidos', 'nombres', 'fecha_creacion', 'envejeciente_id'],
      p_limite: 20,
      p_desplazamiento: 0,
    });
    expect(res.body.meta).toEqual({ page: 1, limit: 20, total: 1, totalPages: 1 });
    expect(res.body.data).toHaveLength(1);
  });
  it('pasa paginación, orden y filtros tipados como parámetros', async () => {
    const { call, rpc } = setup({
      respuestas: { api_listar_envejecientes: { total: 45, items: [ITEM] } },
    });
    const res = await call('get', '/envejecientes')
      .query({
        page: '3',
        limit: '10',
        sort: '-fecha_creacion,nombres',
        'filter[estado]': 'inactivo',
        'filter[municipio_cod]': '0102',
      })
      .expect(200);
    expect(rpc).toHaveBeenCalledWith('api_listar_envejecientes', {
      p_cuenta_id: CUENTA,
      p_estado: 'inactivo',
      p_municipio_cod: '0102',
      p_orden: ['-fecha_creacion', 'nombres', 'envejeciente_id'],
      p_limite: 10,
      p_desplazamiento: 20,
    });
    expect(res.body.meta).toEqual({ page: 3, limit: 10, total: 45, totalPages: 5 });
  });
  it('una página fuera del conjunto responde 200 con datos vacíos y el total real', async () => {
    const { call } = setup({ respuestas: { api_listar_envejecientes: { total: 2, items: [] } } });
    const res = await call('get', '/envejecientes').query({ page: '9' }).expect(200);
    expect(res.body).toEqual({ data: [], meta: { page: 9, limit: 20, total: 2, totalPages: 1 } });
  });
  it('un desplazamiento desmedido no desborda el entero de la base', async () => {
    const { call, rpc } = setup({
      respuestas: { api_listar_envejecientes: { total: 0, items: [] } },
    });
    await call('get', '/envejecientes').query({ page: '9999999999', limit: '100' }).expect(200);
    expect(rpc.mock.calls.at(-1)[1].p_desplazamiento).toBe(2_147_483_647);
  });
  it.each([
    ['filtro de estado desconocido', { 'filter[estado]': 'borrado' }],
    ['filtro de municipio inválido', { 'filter[municipio_cod]': 'x1' }],
    ['filtro por cuenta (no permitido)', { 'filter[cuenta_id]': '9' }],
    ['filtro por cédula (no permitido)', { 'filter[cedula]': '00112345678' }],
    ['orden por cédula', { sort: 'cedula' }],
    ['orden repetido', { sort: 'nombres,nombres' }],
    ['parámetro desconocido', { cuenta_id: '9' }],
    ['límite excesivo', { limit: '101' }],
    ['página cero', { page: '0' }],
  ])('rechaza con 422 sin tocar la base: %s', async (_nombre, consulta) => {
    const { call, llamadas } = setup();
    const res = await call('get', '/envejecientes').query(consulta).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(llamadas()).toHaveLength(0);
  });
  it('un voluntario recibe filas mínimas aunque la base devolviera más', async () => {
    const { call } = setup({
      rol: 'voluntario',
      tipo: 'organizacion',
      respuestas: {
        api_listar_envejecientes: {
          total: 1,
          items: [{ ...ITEM, cedula: '001', telefono: '8095550100' }],
        },
      },
    });
    const { body } = await call('get', '/envejecientes').expect(200);
    expect(Object.keys(body.data[0]).sort()).toEqual(
      [
        'apellidos',
        'envejeciente_id',
        'estado',
        'fecha_creacion',
        'municipio_cod',
        'nombres',
        'zona',
      ].sort(),
    );
  });
  it('un familiar ve identificación básica y no la autonomía; el cuidador y el gestor sí', async () => {
    const lista = { total: 1, items: [{ ...ITEM, cedula: '001' }] };
    const familiar = setup({ rol: 'familiar', respuestas: { api_listar_envejecientes: lista } });
    const f = (await familiar.call('get', '/envejecientes').expect(200)).body.data[0];
    expect(f).toHaveProperty('fecha_nacimiento');
    expect(f).not.toHaveProperty('autonomia');
    expect(f).not.toHaveProperty('cedula');
    for (const rol of ['cuidador', 'coordinador']) {
      const { call } = setup({ rol, respuestas: { api_listar_envejecientes: lista } });
      const g = (await call('get', '/envejecientes').expect(200)).body.data[0];
      expect(g.autonomia).toBe('parcial');
      expect(g).not.toHaveProperty('cedula');
    }
  });
  it('un contrato roto de la base es indisponibilidad, no una lista vacía', async () => {
    for (const malo of [
      null,
      { items: [ITEM] },
      { total: 1, items: 'x' },
      { total: '1', items: [] },
    ]) {
      const { call } = setup({ respuestas: { api_listar_envejecientes: malo } });
      await call('get', '/envejecientes').expect(503);
    }
  });
  it('un permiso denegado o sesión inválida de la RPC se traduce sin detalles', async () => {
    const { call } = setup({
      respuestas: {
        api_listar_envejecientes: () => {
          throw rpcError('42501', 'permiso denegado a la tabla envejeciente');
        },
      },
    });
    const res = await call('get', '/envejecientes').expect(403);
    expect(JSON.stringify(res.body)).not.toContain('tabla');
  });
});

describe('ID03: alta del perfil con consentimiento y contactos', () => {
  const ok = { api_crear_envejeciente: FILA_COMPLETA };

  it('crea el perfil en una sola llamada con datos normalizados y la cuenta de la ruta', async () => {
    const { call, rpc, llamadas } = setup({ respuestas: ok });
    const res = await call('post', '/envejecientes').send(PERFIL).expect(201);
    expect(llamadas()).toHaveLength(1);
    const [nombre, params] = rpc.mock.calls.at(-1);
    expect(nombre).toBe('api_crear_envejeciente');
    expect(params.p_cuenta_id).toBe(CUENTA);
    expect(params.p_datos).toEqual({
      nombres: 'Rosa María',
      apellidos: 'Peña Díaz',
      cedula: '00112345678',
      fecha_nacimiento: '1950-03-15',
      sexo: 'F',
      telefono: '8095550100',
      municipio_cod: '0101',
      zona: 'Centro',
      direccion: 'Calle 1 #2',
      autonomia: 'parcial',
      condiciones: ['cronica', 'movilidad'],
      nota_condicion: 'Usa bastón',
      consentimiento: { otorgado: true, otorgado_por: 'adulto' },
      contactos: [
        {
          nombres: 'Luis',
          apellidos: 'Peña',
          parentesco: 'Hijo/a',
          telefono: '8295550101',
          es_principal: true,
        },
      ],
    });
    expect(res.body.data.envejeciente_id).toBe(ADULTO);
    expect(res.body.data.consentimiento.otorgado).toBe(true);
    expect(res.body.data.condicion_general.autonomia).toBe('parcial');
  });
  it('acepta consentimiento de un representante con su nombre y varios contactos', async () => {
    const { call, rpc } = setup({ respuestas: ok });
    await call('post', '/envejecientes')
      .send({
        ...PERFIL,
        telefono: null,
        consentimiento: {
          otorgado: true,
          otorgado_por: 'representante',
          representante: 'María Pérez',
        },
        contactos: [...PERFIL.contactos, otroContacto({ es_principal: false }), otroContacto()],
      })
      .expect(201);
    const datos = rpc.mock.calls.at(-1)[1].p_datos;
    expect(datos.consentimiento.representante).toBe('María Pérez');
    expect(datos.telefono).toBeNull();
    expect(datos.contactos).toHaveLength(3);
    expect(datos.contactos[2].es_principal).toBe(false);
  });
  it('la dirección, las condiciones y la nota son opcionales', async () => {
    const { call, rpc } = setup({ respuestas: ok });
    const { direccion, condiciones, nota_condicion, telefono, ...minimo } = PERFIL;
    void [direccion, condiciones, nota_condicion, telefono];
    await call('post', '/envejecientes').send(minimo).expect(201);
    const datos = rpc.mock.calls.at(-1)[1].p_datos;
    expect(datos).not.toHaveProperty('condiciones');
    expect(datos).not.toHaveProperty('cuenta_id');
  });
  it.each([
    ['cuenta_id', 99],
    ['usuario_registrador_id', ACTOR],
    ['estado', 'inactivo'],
    ['riesgo', 'alto'],
    ['rol', 'administrador'],
    ['fecha_creacion', '2020-01-01T00:00:00Z'],
  ])('impide asignación masiva de %s (strictObject)', async (campo, valor) => {
    const { call, llamadas } = setup({ respuestas: ok });
    await call('post', '/envejecientes')
      .send({ ...PERFIL, [campo]: valor })
      .expect(422);
    expect(llamadas()).toHaveLength(0);
  });
  it.each([
    ['sin nombres', { nombres: undefined }],
    ['nombre con dígitos', { nombres: 'Rosa 2' }],
    ['nombre de una letra', { nombres: 'R' }],
    ['apellido con marcado', { apellidos: '<b>Peña</b>' }],
    ['cédula corta', { cedula: '123' }],
    ['cédula con letras', { cedula: '0011234567a' }],
    ['sexo en palabras', { sexo: 'Femenino' }],
    ['sexo fuera de lista', { sexo: 'X' }],
    ['fecha inexistente', { fecha_nacimiento: '1950-02-31' }],
    ['fecha con otro formato', { fecha_nacimiento: '15/03/1950' }],
    ['fecha anterior a 1900', { fecha_nacimiento: '1850-01-01' }],
    ['teléfono corto', { telefono: '12345' }],
    ['municipio no numérico', { municipio_cod: 'ab' }],
    ['sin zona', { zona: '' }],
    ['zona demasiado larga', { zona: 'z'.repeat(61) }],
    ['dirección demasiado larga', { direccion: 'd'.repeat(151) }],
    ['autonomía fuera de lista', { autonomia: 'total' }],
    ['condición fuera de catálogo', { condiciones: ['diabetes'] }],
    ['condiciones que no es lista', { condiciones: 'cronica' }],
    ['nota demasiado larga', { nota_condicion: 'n'.repeat(501) }],
    [
      'consentimiento con clave extra',
      { consentimiento: { otorgado: true, otorgado_por: 'adulto', x: 1 } },
    ],
    ['otorgante desconocido', { consentimiento: { otorgado: true, otorgado_por: 'tutor' } }],
    [
      'representante con el adulto como otorgante',
      { consentimiento: { otorgado: true, otorgado_por: 'adulto', representante: 'María Pérez' } },
    ],
    [
      'contacto con teléfono inválido',
      { contactos: [{ ...PERFIL.contactos[0], telefono: '123' }] },
    ],
    [
      'contacto con clave extra',
      { contactos: [{ ...PERFIL.contactos[0], envejeciente_id: ADULTO }] },
    ],
    ['contactos que no es lista', { contactos: 'x' }],
  ])('422 sin tocar la base: %s', async (_nombre, cambios) => {
    const { call, llamadas } = setup({ respuestas: ok });
    const res = await call('post', '/envejecientes')
      .send({ ...PERFIL, ...cambios })
      .expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(llamadas()).toHaveLength(0);
  });
  it('rechaza cuerpos que no son un objeto JSON', async () => {
    const { call, llamadas } = setup({ respuestas: ok });
    await call('post', '/envejecientes').send([]).expect(422);
    await call('post', '/envejecientes').expect(422);
    expect(llamadas()).toHaveLength(0);
  });

  describe('consentimiento informado (CR-158)', () => {
    it.each([
      ['sin consentimiento', { consentimiento: undefined }],
      [
        'consentimiento no otorgado',
        { consentimiento: { otorgado: false, otorgado_por: 'adulto' } },
      ],
      [
        'representante sin nombre',
        { consentimiento: { otorgado: true, otorgado_por: 'representante' } },
      ],
    ])('%s: 422 CONSENT_REQUIRED y no se guarda nada', async (_nombre, cambios) => {
      const { call, llamadas } = setup({ respuestas: ok });
      const res = await call('post', '/envejecientes')
        .send({ ...PERFIL, ...cambios })
        .expect(422);
      expect(res.body.error.code).toBe('CONSENT_REQUIRED');
      expect(llamadas()).toHaveLength(0);
    });
    it('la base también lo exige (defensa en profundidad)', async () => {
      const { call } = setup({
        respuestas: {
          api_crear_envejeciente: () => {
            throw rpcError('P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
          },
        },
      });
      const res = await call('post', '/envejecientes').send(PERFIL).expect(422);
      expect(res.body.error.code).toBe('CONSENT_REQUIRED');
    });
  });

  describe('contactos de emergencia (RF-17)', () => {
    const principal = PERFIL.contactos[0];
    it.each([
      ['sin contactos', { contactos: undefined }],
      ['lista vacía', { contactos: [] }],
      ['ningún principal', { contactos: [{ ...principal, es_principal: false }] }],
      ['sin indicar el principal', { contactos: [{ ...principal, es_principal: undefined }] }],
      ['dos principales', { contactos: [principal, otroContacto({ es_principal: true })] }],
      [
        'más de cinco',
        {
          contactos: Array.from({ length: 6 }, (_, i) => ({ ...principal, es_principal: i === 0 })),
        },
      ],
    ])('%s: 422 CONTACT_PRINCIPAL_INVALID', async (_nombre, cambios) => {
      const { call, llamadas } = setup({ respuestas: ok });
      const res = await call('post', '/envejecientes')
        .send({ ...PERFIL, ...cambios })
        .expect(422);
      expect(res.body.error.code).toBe('CONTACT_PRINCIPAL_INVALID');
      expect(llamadas()).toHaveLength(0);
    });
    it('acepta exactamente cinco con un principal', async () => {
      const { call } = setup({ respuestas: ok });
      await call('post', '/envejecientes')
        .send({
          ...PERFIL,
          contactos: Array.from({ length: 5 }, (_, i) => ({ ...principal, es_principal: i === 2 })),
        })
        .expect(201);
    });
  });

  describe('errores de negocio de la base', () => {
    const fallo = (code, message) => ({
      api_crear_envejeciente: () => {
        throw rpcError(code, message);
      },
    });
    it('cédula duplicada en cualquier cuenta: 409 genérico que no revela de quién es', async () => {
      const { call, audit } = setup({ respuestas: fallo('P0001', 'CR_CEDULA_DUPLICADA') });
      const res = await call('post', '/envejecientes').send(PERFIL).expect(409);
      expect(res.body.error).toEqual({
        code: 'CEDULA_DUPLICATE',
        message: 'Ya existe un perfil registrado con esa cédula.',
      });
      const texto = JSON.stringify(res.body);
      expect(texto).not.toContain('cuenta');
      expect(texto).not.toContain('Rosa');
      expect(audit).not.toHaveBeenCalledWith(expect.objectContaining({ action: 'adulto.created' }));
    });
    it('límite del plan alcanzado: 409 PLAN_LIMIT_REACHED', async () => {
      const { call } = setup({ respuestas: fallo('P0001', 'CR_LIMITE_PLAN') });
      const res = await call('post', '/envejecientes').send(PERFIL).expect(409);
      expect(res.body.error.code).toBe('PLAN_LIMIT_REACHED');
    });
    it('cuenta vencida detectada por la base: 403 SUBSCRIPTION_INACTIVE', async () => {
      const { call } = setup({ respuestas: fallo('P0001', 'CR_CUENTA_SIN_ACCESO') });
      const res = await call('post', '/envejecientes').send(PERFIL).expect(403);
      expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    });
    it('entrada inválida para la base (edad, municipio inexistente): 422 INVALID_INPUT', async () => {
      const { call } = setup({ respuestas: fallo('22023', 'detalle interno') });
      const res = await call('post', '/envejecientes').send(PERFIL).expect(422);
      expect(res.body.error.code).toBe('INVALID_INPUT');
      expect(JSON.stringify(res.body)).not.toContain('detalle interno');
    });
    it('un código CR_* no registrado o un error desconocido no llegan al cliente', async () => {
      for (const error of [rpcError('P0001', 'CR_NO_REGISTRADO'), rpcError('XX000', 'secreto')]) {
        const { call } = setup({
          respuestas: {
            api_crear_envejeciente: () => {
              throw error;
            },
          },
        });
        const res = await call('post', '/envejecientes').send(PERFIL).expect(503);
        expect(JSON.stringify(res.body)).not.toMatch(/secreto|CR_NO_REGISTRADO/);
      }
    });
  });

  it('audita el alta sin datos personales', async () => {
    const { call, audit } = setup({ respuestas: ok });
    await call('post', '/envejecientes').send(PERFIL).expect(201);
    expect(audit).toHaveBeenCalledTimes(1);
    expect(audit.mock.calls[0][0]).toMatchObject({
      actorId: ACTOR,
      action: 'adulto.created',
      result: 'success',
    });
    const texto = JSON.stringify(audit.mock.calls);
    for (const dato of ['00112345678', '001-1234567-8', 'Rosa', 'Peña', '8095550100'])
      expect(texto).not.toContain(dato);
  });
});

describe('ID03: consulta del perfil por nivel de visibilidad', () => {
  const ver = { api_ver_envejeciente: FILA_COMPLETA };

  it('el gestor y el cuidador reciben el perfil completo, con condición general y consentimiento', async () => {
    for (const [rol, tipo] of [
      ['coordinador', 'familia'],
      ['administrador', 'organizacion'],
      ['cuidador', 'familia'],
    ]) {
      const { call, rpc } = setup({ rol, tipo, respuestas: ver });
      const { body } = await call('get', `/envejecientes/${ADULTO}`).expect(200);
      expect(rpc).toHaveBeenCalledWith('api_ver_envejeciente', {
        p_cuenta_id: CUENTA,
        p_envejeciente_id: ADULTO,
      });
      expect(body.data.cedula).toBe('00112345678');
      expect(body.data.condicion_general).toEqual({
        autonomia: 'parcial',
        condiciones: ['cronica'],
        nota: 'Usa bastón',
      });
      expect(body.data.consentimiento.otorgado_por).toBe('adulto');
      expect(body.data.contacto_principal.es_principal).toBe(true);
      expect(body.data.contactos).toHaveLength(1);
    }
  });
  it('el familiar autorizado ve la identificación pero no la condición ni el consentimiento', async () => {
    const { call } = setup({ rol: 'familiar', respuestas: ver });
    const { body } = await call('get', `/envejecientes/${ADULTO}`).expect(200);
    expect(body.data.cedula).toBe('00112345678');
    expect(body.data.contactos).toHaveLength(1);
    for (const campo of ['condicion_general', 'consentimiento', 'motivo_estado', 'fecha_estado'])
      expect(body.data).not.toHaveProperty(campo);
  });
  it('el voluntario solo recibe datos mínimos, aunque la base devolviera el perfil completo', async () => {
    const { call, audit } = setup({ rol: 'voluntario', tipo: 'organizacion', respuestas: ver });
    const { body } = await call('get', `/envejecientes/${ADULTO}`).expect(200);
    expect(Object.keys(body.data).sort()).toEqual(
      [
        'apellidos',
        'contacto_principal',
        'direccion',
        'envejeciente_id',
        'estado',
        'municipio_cod',
        'municipio_nombre',
        'nombres',
        'provincia_cod',
        'zona',
      ].sort(),
    );
    for (const campo of SENSIBLES) expect(body.data).not.toHaveProperty(campo);
    expect(body.data.contacto_principal.telefono).toBe('8295550101');
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'adulto.viewed' }));
  });
  it('un adulto de otra cuenta, sin asignar o inexistente responde exactamente igual: 404', async () => {
    const respuestas = {
      api_ver_envejeciente: () => {
        throw rpcError('P0002', 'adulto no encontrado');
      },
    };
    const cuerpos = [];
    for (const id of [ADULTO, '0b7a7f55-1f0e-4b53-8f0c-9d6d3a1c8e10']) {
      const { call } = setup({ respuestas });
      const res = await call('get', `/envejecientes/${id}`).expect(404);
      cuerpos.push({ ...res.body, requestId: undefined });
    }
    expect(cuerpos[0]).toEqual(cuerpos[1]);
    expect(cuerpos[0].error).toEqual({ code: 'NOT_FOUND', message: 'Recurso no encontrado.' });
  });
  it.each(['abc', '123', '5d3c1a52-8c2e-4f6b-9a3b', `${ADULTO}x`, '..%2F..%2Fcuentas'])(
    'un identificador mal formado (%s) es 404 y no llega a la base',
    async (id) => {
      const { call, llamadas } = setup({ respuestas: ver });
      await call('get', `/envejecientes/${id}`).expect(404);
      expect(llamadas()).toHaveLength(0);
    },
  );
  it('un perfil malformado de la base es indisponibilidad', async () => {
    const { call } = setup({ respuestas: { api_ver_envejeciente: { nombres: 'sin id' } } });
    await call('get', `/envejecientes/${ADULTO}`).expect(503);
  });
});

describe('ID03: edición del perfil', () => {
  const editar = { api_editar_envejeciente: FILA_COMPLETA };

  it('edita solo los campos enviados y normaliza cédula y teléfono', async () => {
    const { call, rpc, audit } = setup({ respuestas: editar });
    const res = await call('patch', `/envejecientes/${ADULTO}`)
      .send({ cedula: '001-1234567-8', telefono: ' 809-555-0100 ', zona: ' Gazcue  Norte ' })
      .expect(200);
    expect(rpc).toHaveBeenCalledWith('api_editar_envejeciente', {
      p_cuenta_id: CUENTA,
      p_envejeciente_id: ADULTO,
      p_datos: { cedula: '00112345678', telefono: '8095550100', zona: 'Gazcue Norte' },
    });
    expect(res.body.data.envejeciente_id).toBe(ADULTO);
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'adulto.updated' }));
  });
  it('permite borrar el teléfono y la nota con null o cadena vacía', async () => {
    const { call, rpc } = setup({ respuestas: editar });
    await call('patch', `/envejecientes/${ADULTO}`)
      .send({ telefono: null, nota_condicion: '' })
      .expect(200);
    expect(rpc.mock.calls.at(-1)[1].p_datos).toEqual({ telefono: null, nota_condicion: null });
  });
  it('permite volver a registrar el consentimiento con representante', async () => {
    const { call, rpc } = setup({ respuestas: editar });
    await call('patch', `/envejecientes/${ADULTO}`)
      .send({
        consentimiento: {
          otorgado: true,
          otorgado_por: 'representante',
          representante: 'María Pérez',
        },
      })
      .expect(200);
    expect(rpc.mock.calls.at(-1)[1].p_datos.consentimiento.representante).toBe('María Pérez');
  });
  it('no se puede retirar el consentimiento por esta vía', async () => {
    const { call, llamadas } = setup({ respuestas: editar });
    const res = await call('patch', `/envejecientes/${ADULTO}`)
      .send({ consentimiento: { otorgado: false, otorgado_por: 'adulto' } })
      .expect(422);
    expect(res.body.error.code).toBe('CONSENT_REQUIRED');
    expect(llamadas()).toHaveLength(0);
  });
  it.each([
    ['cuerpo vacío', {}],
    ['estado (se cambia con /estado)', { estado: 'inactivo' }],
    ['cuenta', { cuenta_id: 9 }],
    ['registrador', { usuario_registrador_id: ACTOR }],
    ['contactos (se gestionan aparte)', { contactos: [] }],
    ['zona nula', { zona: null }],
    ['sexo inválido', { sexo: 'Z' }],
    ['cédula inválida', { cedula: '12' }],
  ])('422 sin tocar la base: %s', async (_nombre, cuerpo) => {
    const { call, llamadas } = setup({ respuestas: editar });
    await call('patch', `/envejecientes/${ADULTO}`).send(cuerpo).expect(422);
    expect(llamadas()).toHaveLength(0);
  });
  it('una cédula ya usada en cualquier cuenta es 409 genérico', async () => {
    const { call } = setup({
      respuestas: {
        api_editar_envejeciente: () => {
          throw rpcError('P0001', 'CR_CEDULA_DUPLICADA');
        },
      },
    });
    const res = await call('patch', `/envejecientes/${ADULTO}`)
      .send({ cedula: '00198765432' })
      .expect(409);
    expect(res.body.error.code).toBe('CEDULA_DUPLICATE');
  });
  it('un adulto ajeno o inexistente es 404 y un id mal formado ni llega a la base', async () => {
    const { call, llamadas } = setup({
      respuestas: {
        api_editar_envejeciente: () => {
          throw rpcError('P0002', 'no');
        },
      },
    });
    await call('patch', `/envejecientes/${ADULTO}`).send({ zona: 'x' }).expect(404);
    await call('patch', '/envejecientes/no-es-uuid').send({ zona: 'x' }).expect(404);
    expect(llamadas()).toHaveLength(1);
  });
});

describe('ID03: cambio de estado del adulto (CR-172)', () => {
  const RESULTADO = {
    envejeciente_id: ADULTO,
    estado: 'inactivo',
    motivo_estado: 'Se mudó',
    fecha_estado: '2026-11-06T12:00:00.000000Z',
    tareas_canceladas: 2,
    alertas_resueltas: 1,
    visitas_canceladas: 1,
  };
  const estado = { api_estado_envejeciente: RESULTADO };

  it('inactiva con motivo y devuelve lo que se canceló y resolvió', async () => {
    const { call, rpc, audit } = setup({ respuestas: estado });
    const res = await call('post', `/envejecientes/${ADULTO}/estado`)
      .send({ estado: 'inactivo', motivo: '  Se   mudó ' })
      .expect(200);
    expect(rpc).toHaveBeenCalledWith('api_estado_envejeciente', {
      p_cuenta_id: CUENTA,
      p_envejeciente_id: ADULTO,
      p_estado: 'inactivo',
      p_motivo: 'Se mudó',
    });
    expect(res.body.data).toEqual(RESULTADO);
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'adulto.state_changed' }));
  });
  it('el motivo es opcional al registrar fallecimiento o reactivar', async () => {
    const { call, rpc } = setup({
      respuestas: { api_estado_envejeciente: { ...RESULTADO, estado: 'fallecido' } },
    });
    await call('post', `/envejecientes/${ADULTO}/estado`).send({ estado: 'fallecido' }).expect(200);
    expect(rpc.mock.calls.at(-1)[1].p_motivo).toBeNull();
    await call('post', `/envejecientes/${ADULTO}/estado`)
      .send({ estado: 'activo', motivo: null })
      .expect(200);
    expect(rpc.mock.calls.at(-1)[1].p_estado).toBe('activo');
  });
  it.each([
    ['inactivar sin motivo', { estado: 'inactivo' }],
    ['inactivar con motivo en blanco', { estado: 'inactivo', motivo: '   ' }],
    ['inactivar con motivo de dos letras', { estado: 'inactivo', motivo: 'ab' }],
    ['motivo demasiado largo', { estado: 'inactivo', motivo: 'm'.repeat(201) }],
    ['estado desconocido', { estado: 'borrado', motivo: 'motivo válido' }],
    ['sin estado', { motivo: 'motivo válido' }],
    ['clave extra', { estado: 'inactivo', motivo: 'motivo válido', cuenta_id: 9 }],
  ])('422 sin tocar la base: %s', async (_nombre, cuerpo) => {
    const { call, llamadas } = setup({ respuestas: estado });
    await call('post', `/envejecientes/${ADULTO}/estado`).send(cuerpo).expect(422);
    expect(llamadas()).toHaveLength(0);
  });
  it('fallecido es terminal y un mismo estado no se repite: 409 INVALID_STATE', async () => {
    const { call } = setup({
      respuestas: {
        api_estado_envejeciente: () => {
          throw rpcError('P0001', 'CR_ESTADO_INVALIDO');
        },
      },
    });
    const res = await call('post', `/envejecientes/${ADULTO}/estado`)
      .send({ estado: 'activo' })
      .expect(409);
    expect(res.body.error.code).toBe('INVALID_STATE');
  });
  it('reactivar respeta el límite del plan: 409 PLAN_LIMIT_REACHED', async () => {
    const { call } = setup({
      respuestas: {
        api_estado_envejeciente: () => {
          throw rpcError('P0001', 'CR_LIMITE_PLAN');
        },
      },
    });
    const res = await call('post', `/envejecientes/${ADULTO}/estado`)
      .send({ estado: 'activo' })
      .expect(409);
    expect(res.body.error.code).toBe('PLAN_LIMIT_REACHED');
  });
  it('un adulto de otra cuenta es 404 y un id mal formado no llega a la base', async () => {
    const { call, llamadas } = setup({
      respuestas: {
        api_estado_envejeciente: () => {
          throw rpcError('P0002', 'no');
        },
      },
    });
    await call('post', `/envejecientes/${ADULTO}/estado`).send({ estado: 'activo' }).expect(404);
    await call('post', '/envejecientes/1/estado').send({ estado: 'activo' }).expect(404);
    expect(llamadas()).toHaveLength(1);
  });
  it('un resultado malformado de la base es indisponibilidad', async () => {
    const { call } = setup({ respuestas: { api_estado_envejeciente: { estado: 'inactivo' } } });
    await call('post', `/envejecientes/${ADULTO}/estado`)
      .send({ estado: 'inactivo', motivo: 'Se mudó' })
      .expect(503);
  });
});

describe('ID03/RF-17: contactos de emergencia', () => {
  it('lista los contactos del adulto con el principal primero', async () => {
    const otro = { ...CONTACTO, contacto_id: 32, es_principal: false };
    const { call, rpc } = setup({
      rol: 'cuidador',
      respuestas: { api_listar_contactos: [CONTACTO, otro] },
    });
    const res = await call('get', `/envejecientes/${ADULTO}/contactos`).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_listar_contactos', {
      p_cuenta_id: CUENTA,
      p_envejeciente_id: ADULTO,
    });
    expect(res.body.data).toEqual([CONTACTO, otro]);
  });
  it('un voluntario recibe lo que la base le permite (solo el principal) y sin campos extra', async () => {
    const { call } = setup({
      rol: 'voluntario',
      tipo: 'organizacion',
      respuestas: { api_listar_contactos: [{ ...CONTACTO, correo: 'x@y.z' }] },
    });
    const res = await call('get', `/envejecientes/${ADULTO}/contactos`).expect(200);
    expect(res.body.data).toEqual([CONTACTO]);
  });
  it('un adulto fuera del alcance es 404 y un contrato roto es 503', async () => {
    const fuera = setup({
      rol: 'familiar',
      respuestas: {
        api_listar_contactos: () => {
          throw rpcError('P0002', 'no');
        },
      },
    });
    await fuera.call('get', `/envejecientes/${ADULTO}/contactos`).expect(404);
    const roto = setup({ respuestas: { api_listar_contactos: { x: 1 } } });
    await roto.call('get', `/envejecientes/${ADULTO}/contactos`).expect(503);
  });

  describe('alta', () => {
    const nuevo = { ...CONTACTO, contacto_id: 32, nombres: 'Eva', es_principal: false };
    it('crea un contacto no principal por defecto y normaliza el teléfono', async () => {
      const { call, rpc, audit } = setup({ respuestas: { api_crear_contacto: nuevo } });
      const res = await call('post', `/envejecientes/${ADULTO}/contactos`)
        .send(otroContacto())
        .expect(201);
      expect(rpc).toHaveBeenCalledWith('api_crear_contacto', {
        p_cuenta_id: CUENTA,
        p_envejeciente_id: ADULTO,
        p_datos: {
          nombres: 'Eva',
          apellidos: 'Abreu',
          parentesco: 'Amigo/a',
          telefono: '8095550199',
          es_principal: false,
        },
      });
      expect(res.body.data.contacto_id).toBe(32);
      expect(audit).toHaveBeenCalledWith(
        expect.objectContaining({ action: 'adulto.contact_created' }),
      );
    });
    it('con es_principal: true lo envía a la base, que reemplaza al anterior de forma atómica', async () => {
      const { call, rpc } = setup({
        respuestas: { api_crear_contacto: { ...nuevo, es_principal: true } },
      });
      await call('post', `/envejecientes/${ADULTO}/contactos`)
        .send(otroContacto({ es_principal: true }))
        .expect(201);
      expect(rpc.mock.calls.at(-1)[1].p_datos.es_principal).toBe(true);
    });
    it.each([
      ['sin teléfono', { telefono: undefined }],
      ['teléfono inválido', { telefono: '123' }],
      ['nombre con dígitos', { nombres: 'Eva 2' }],
      ['parentesco vacío', { parentesco: '' }],
      ['es_principal que no es booleano', { es_principal: 'si' }],
      ['adulto en el cuerpo', { envejeciente_id: ADULTO }],
      ['cuenta en el cuerpo', { cuenta_id: 9 }],
    ])('422 sin tocar la base: %s', async (_nombre, cambios) => {
      const { call, llamadas } = setup({ respuestas: { api_crear_contacto: nuevo } });
      await call('post', `/envejecientes/${ADULTO}/contactos`)
        .send(otroContacto(cambios))
        .expect(422);
      expect(llamadas()).toHaveLength(0);
    });
    it('máximo cinco contactos por adulto: 409 CONTACT_LIMIT_REACHED', async () => {
      const { call } = setup({
        respuestas: {
          api_crear_contacto: () => {
            throw rpcError('P0001', 'CR_LIMITE_CONTACTOS');
          },
        },
      });
      const res = await call('post', `/envejecientes/${ADULTO}/contactos`)
        .send(otroContacto())
        .expect(409);
      expect(res.body.error.code).toBe('CONTACT_LIMIT_REACHED');
    });
  });

  describe('edición, principal y eliminación', () => {
    it('edita solo nombres, apellidos, parentesco y teléfono', async () => {
      const { call, rpc, audit } = setup({ respuestas: { api_editar_contacto: CONTACTO } });
      await call('patch', '/contactos/31').send({ telefono: '829 555 0102' }).expect(200);
      expect(rpc).toHaveBeenCalledWith('api_editar_contacto', {
        p_cuenta_id: CUENTA,
        p_contacto_id: 31,
        p_datos: { telefono: '8295550102' },
      });
      expect(audit).toHaveBeenCalledWith(
        expect.objectContaining({ action: 'adulto.contact_updated' }),
      );
    });
    it.each([
      ['cuerpo vacío', {}],
      ['es_principal (se cambia con /principal)', { es_principal: false }],
      ['adulto', { envejeciente_id: ADULTO }],
      ['teléfono inválido', { telefono: '12' }],
    ])('PATCH 422 sin tocar la base: %s', async (_nombre, cuerpo) => {
      const { call, llamadas } = setup({ respuestas: { api_editar_contacto: CONTACTO } });
      await call('patch', '/contactos/31').send(cuerpo).expect(422);
      expect(llamadas()).toHaveLength(0);
    });
    it.each(['abc', '0', '-1', '1.5', '31x', '1234567890123456'])(
      'el identificador de contacto %s es 404 y no llega a la base',
      async (id) => {
        const { call, llamadas } = setup({
          respuestas: { api_editar_contacto: CONTACTO, api_principal_contacto: CONTACTO },
        });
        await call('patch', `/contactos/${id}`).send({ telefono: '8295550102' }).expect(404);
        await call('post', `/contactos/${id}/principal`).send({}).expect(404);
        await call('post', `/contactos/${id}/eliminar`).send({}).expect(404);
        expect(llamadas()).toHaveLength(0);
      },
    );
    it('cambia el principal con una sola llamada atómica', async () => {
      const { call, rpc, llamadas, audit } = setup({
        respuestas: { api_principal_contacto: { ...CONTACTO, contacto_id: 32 } },
      });
      const res = await call('post', '/contactos/32/principal').send({}).expect(200);
      expect(llamadas()).toHaveLength(1);
      expect(rpc).toHaveBeenCalledWith('api_principal_contacto', {
        p_cuenta_id: CUENTA,
        p_contacto_id: 32,
      });
      expect(res.body.data).toMatchObject({ contacto_id: 32, es_principal: true });
      expect(audit).toHaveBeenCalledWith(
        expect.objectContaining({ action: 'adulto.contact_principal_changed' }),
      );
    });
    it('elimina un contacto con 204 y sin cuerpo', async () => {
      const { call, rpc, audit } = setup({
        respuestas: { api_eliminar_contacto: { contacto_id: 32, eliminado: true } },
      });
      const res = await call('post', '/contactos/32/eliminar').send({}).expect(204);
      expect(res.text).toBe('');
      expect(rpc).toHaveBeenCalledWith('api_eliminar_contacto', {
        p_cuenta_id: CUENTA,
        p_contacto_id: 32,
      });
      expect(audit).toHaveBeenCalledWith(
        expect.objectContaining({ action: 'adulto.contact_deleted' }),
      );
    });
    it('no deja al adulto sin contactos: 409 LAST_CONTACT', async () => {
      const { call } = setup({
        respuestas: {
          api_eliminar_contacto: () => {
            throw rpcError('P0001', 'CR_ULTIMO_CONTACTO');
          },
        },
      });
      const res = await call('post', '/contactos/31/eliminar').send({}).expect(409);
      expect(res.body.error.code).toBe('LAST_CONTACT');
    });
    it('no elimina al principal sin designar otro: 422 CONTACT_PRINCIPAL_INVALID', async () => {
      const { call } = setup({
        respuestas: {
          api_eliminar_contacto: () => {
            throw rpcError('P0001', 'CR_CONTACTO_PRINCIPAL');
          },
        },
      });
      const res = await call('post', '/contactos/31/eliminar').send({}).expect(422);
      expect(res.body.error.code).toBe('CONTACT_PRINCIPAL_INVALID');
    });
    it('un contacto de otra cuenta o inexistente es 404 en las tres acciones', async () => {
      const noExiste = () => {
        throw rpcError('P0002', 'no');
      };
      const { call } = setup({
        respuestas: {
          api_editar_contacto: noExiste,
          api_principal_contacto: noExiste,
          api_eliminar_contacto: noExiste,
        },
      });
      await call('patch', '/contactos/31').send({ telefono: '8295550102' }).expect(404);
      await call('post', '/contactos/31/principal').send({}).expect(404);
      await call('post', '/contactos/31/eliminar').send({}).expect(404);
    });
  });
});

describe('ID03: registro de códigos de negocio', () => {
  it('todos los CR_* de la fase tienen traducción pública con el estado esperado', () => {
    const esperado = {
      CR_CEDULA_DUPLICADA: [409, 'CEDULA_DUPLICATE'],
      CR_CONSENTIMIENTO_REQUERIDO: [422, 'CONSENT_REQUIRED'],
      CR_CONTACTO_PRINCIPAL: [422, 'CONTACT_PRINCIPAL_INVALID'],
      CR_ULTIMO_CONTACTO: [409, 'LAST_CONTACT'],
      CR_LIMITE_CONTACTOS: [409, 'CONTACT_LIMIT_REACHED'],
      CR_LIMITE_PLAN: [409, 'PLAN_LIMIT_REACHED'],
      CR_ESTADO_INVALIDO: [409, 'INVALID_STATE'],
      CR_CUENTA_SIN_ACCESO: [403, 'SUBSCRIPTION_INACTIVE'],
    };
    expect([...ENVEJECIENTES_CODIGOS].sort()).toEqual(Object.keys(esperado).sort());
    for (const [codigo, [status, publico]] of Object.entries(esperado)) {
      const error = businessError(codigo);
      expect([error.status, error.code]).toEqual([status, publico]);
      expect(error.message).not.toMatch(/CR_|cuenta \d|SQL/);
    }
  });
});
