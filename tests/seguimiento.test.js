/* Pruebas API ID03 (bloque 3b): asignaciones, riesgo, indicaciones e historial, sin base real. © 2026 Equipo CuidaRed – INTEC. */
import { readFileSync } from 'node:fs';
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { businessError } from '../src/lib/business-errors.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';
import { ERRORES_SEGUIMIENTO } from '../src/modules/seguimiento/seguimiento-errors.js';
import { createSeguimientoRepository } from '../src/modules/seguimiento/seguimiento-repository.js';

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
const ENV = '3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f';
const USR = '9b2e7c1a-4d3f-4a5b-8c6d-1e2f3a4b5c6d';
const IND = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
const base = `/api/v1/cuentas/7/envejecientes/${ENV}`;

const completas = {
  ingresos_fijos: true,
  vivienda: 'propia',
  vive_solo: false,
  cronica: false,
  movilidad: 'independiente',
  medicamentos: false,
  familiares: true,
  frecuencia: 'diaria',
  cuidador: true,
};

function setup({ rol = 'coordinador', tipo = 'familia', acceso = true, handlers = {} } = {}) {
  const contexto = {
    cuenta_id: 7,
    tipo,
    rol,
    membresia_id: 11,
    permisos: permisosDe(rol, tipo),
    es_titular: false,
    acceso_operativo: acceso,
    suscripcion_estado: acceso ? 'prueba' : 'vencida',
    funcionalidades: [],
  };
  const rpc = vi.fn(async (name, params) => {
    if (name === 'api_contexto_cuenta') return contexto;
    if (!(name in handlers)) throw new Error(`RPC inesperada: ${name}`);
    const handler = handlers[name];
    return typeof handler === 'function' ? handler(params) : handler;
  });
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue(profile),
    rpc,
  };
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: actorId, email: profile.correo }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const audit = vi.fn();
  const app = createApp({ env: { origins: ['http://localhost:5173'] }, gateway, audit });
  const call = (method, path) => request(app)[method](path).auth('token', { type: 'bearer' });
  // Llamadas a RPC de negocio (sin la de contexto de cuenta).
  const negocio = () => rpc.mock.calls.filter(([name]) => name !== 'api_contexto_cuenta');
  return { app, rpc, audit, call, negocio };
}

// Un error de la base tal como lo entrega el adaptador (mapRpcError) a las rutas.
const falla = (code, message) => async () => {
  throw mapRpcError({ code, message });
};

describe('RF-09/V2: primero el permiso de la matriz, después la RPC', () => {
  const tabla = [
    // [método, ruta, rol sin permiso, tipo de cuenta, cuerpo]
    ['get', `${base}/riesgo`, 'familiar', 'familia'],
    ['get', `${base}/riesgo`, 'voluntario', 'organizacion'],
    ['post', `${base}/evaluaciones`, 'cuidador', 'familia', { respuestas: completas }],
    [
      'post',
      `${base}/riesgos`,
      'cuidador',
      'familia',
      { riesgo_id: 1, nivel: 'alto', motivo: 'Motivo válido' },
    ],
    ['post', '/api/v1/cuentas/7/riesgos/5/resolver', 'cuidador', 'familia', {}],
    [
      'post',
      `${base}/asignaciones`,
      'cuidador',
      'familia',
      { tipo: 'cuidador_asignado', usuario_id: USR },
    ],
    ['post', `${base}/asignaciones/${USR}/revocar`, 'familiar', 'familia', {}],
    ['post', `${base}/familiares`, 'coordinador', 'organizacion', { usuario_id: USR }],
    ['post', `${base}/familiares/${USR}/revocar`, 'cuidador', 'familia', {}],
    ['get', `${base}/indicaciones`, 'voluntario', 'organizacion'],
    [
      'post',
      `${base}/indicaciones`,
      'familiar',
      'familia',
      { tipo_indicacion_id: 1, titulo: 'Metformina', fecha_inicio: '2026-11-01' },
    ],
    [
      'post',
      `${base}/indicaciones`,
      'administrador',
      'organizacion',
      { tipo_indicacion_id: 1, titulo: 'Metformina', fecha_inicio: '2026-11-01' },
    ],
    [
      'patch',
      `/api/v1/cuentas/7/indicaciones/${IND}`,
      'familiar',
      'familia',
      { titulo: 'Otro título' },
    ],
    [
      'post',
      `/api/v1/cuentas/7/indicaciones/${IND}/estado`,
      'familiar',
      'familia',
      { estado: 'suspendida' },
    ],
  ];
  it.each(tabla)(
    '%s %s con %s en %s responde 403 sin llamar a la RPC',
    async (metodo, ruta, rol, tipo, cuerpo) => {
      const { call, negocio } = setup({ rol, tipo });
      const res = await call(metodo, ruta).send(cuerpo).expect(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
      expect(negocio()).toHaveLength(0);
    },
  );

  it('la cuenta sin prueba ni plan vigente bloquea la lectura operativa (D07)', async () => {
    const { call, negocio } = setup({ acceso: false });
    const res = await call('get', `${base}/historial`).expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    expect(negocio()).toHaveLength(0);
  });

  it('exige sesión', async () => {
    const { app } = setup();
    await request(app).get(`${base}/historial`).expect(401);
  });
});

describe('RF-12/RF-13: asignaciones y permiso familiar explícito', () => {
  it('consulta con la cuenta de la ruta y el adulto de la ruta', async () => {
    const lista = { cuidadores: [{ nombres: 'Ana', apellidos: 'Gil' }], voluntarios: [] };
    const { call, rpc } = setup({ rol: 'cuidador', handlers: { api_asignaciones_listar: lista } });
    const res = await call('get', `${base}/asignaciones`).expect(200);
    expect(res.body).toEqual({ data: lista });
    expect(rpc).toHaveBeenCalledWith('api_asignaciones_listar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
    });
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it.each(['abc', '123', '3f1c2d4e-5a6b-4c7d-8e9f', `${ENV}x`])(
    'un id de adulto malformado (%s) es un recurso inexistente y no llega a la base',
    async (id) => {
      const { call, negocio } = setup();
      const res = await call('get', `/api/v1/cuentas/7/envejecientes/${id}/asignaciones`).expect(
        404,
      );
      expect(res.body.error.code).toBe('NOT_FOUND');
      expect(negocio()).toHaveLength(0);
    },
  );

  it('asigna un cuidador o voluntario y audita sin datos del adulto', async () => {
    const asignacion = { envejeciente_id: ENV, usuario_id: USR, tipo: 'cuidador_asignado' };
    const { call, rpc, audit } = setup({ handlers: { api_asignar: asignacion } });
    const res = await call('post', `${base}/asignaciones`)
      .send({ tipo: 'cuidador_asignado', usuario_id: USR })
      .expect(201);
    expect(res.body).toEqual({ data: asignacion });
    expect(rpc).toHaveBeenCalledWith('api_asignar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_tipo: 'cuidador_asignado',
      p_usuario_id: USR,
    });
    expect(audit).toHaveBeenCalledWith({
      requestId: expect.any(String),
      actorId,
      action: 'asignacion.creada',
      result: 'success',
    });
  });

  it.each([
    ['sin cuerpo', undefined],
    ['tipo de vínculo ajeno a las asignaciones', { tipo: 'familiar_responsable', usuario_id: USR }],
    ['tipo desconocido', { tipo: 'cuidador_principal', usuario_id: USR }],
    ['usuario no es un id', { tipo: 'cuidador_asignado', usuario_id: '1' }],
    ['cuenta en el cuerpo', { tipo: 'cuidador_asignado', usuario_id: USR, cuenta_id: 9 }],
    ['actor en el cuerpo', { tipo: 'cuidador_asignado', usuario_id: USR, autorizado_por: USR }],
  ])('rechaza el cuerpo inválido (%s) sin llamar a la RPC', async (_caso, cuerpo) => {
    const { call, negocio } = setup();
    const res = await call('post', `${base}/asignaciones`).send(cuerpo).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(negocio()).toHaveLength(0);
  });

  it.each([
    ['P0001', 'CR_ROL_NO_COMPATIBLE', 422, 'ROLE_NOT_COMPATIBLE'],
    ['P0001', 'CR_ROL_NO_PERMITIDO', 422, 'ROLE_NOT_ALLOWED'],
    ['P0001', 'CR_ADULTO_INACTIVO', 409, 'ADULT_INACTIVE'],
    ['42501', undefined, 403, 'FORBIDDEN'],
    ['P0002', undefined, 404, 'NOT_FOUND'],
  ])('traduce el error %s %s de la RPC a %i %s', async (code, message, status, publico) => {
    const { call } = setup({ handlers: { api_asignar: falla(code, message) } });
    const res = await call('post', `${base}/asignaciones`)
      .send({ tipo: 'voluntario_asignado', usuario_id: USR })
      .expect(status);
    expect(res.body.error.code).toBe(publico);
    expect(JSON.stringify(res.body)).not.toMatch(/CR_|P0001|42501/);
  });

  it('revoca una asignación (204), con motivo opcional', async () => {
    const { call, rpc, audit } = setup({ handlers: { api_asignacion_revocar: null } });
    await call('post', `${base}/asignaciones/${USR}/revocar`).expect(204);
    expect(rpc).toHaveBeenLastCalledWith('api_asignacion_revocar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_usuario_id: USR,
      p_motivo: null,
    });
    await call('post', `${base}/asignaciones/${USR}/revocar`)
      .send({ motivo: ' Cambio de turno ' })
      .expect(204);
    expect(rpc).toHaveBeenLastCalledWith(
      'api_asignacion_revocar',
      expect.objectContaining({ p_motivo: 'Cambio de turno' }),
    );
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'asignacion.revocada' }));
  });

  it('revocar rechaza motivos largos, campos extra e ids malformados', async () => {
    const { call, negocio } = setup();
    await call('post', `${base}/asignaciones/${USR}/revocar`)
      .send({ motivo: 'x'.repeat(301) })
      .expect(422);
    await call('post', `${base}/asignaciones/${USR}/revocar`).send({ usuario_id: USR }).expect(422);
    await call('post', `${base}/asignaciones/no-es-un-id/revocar`).expect(404);
    expect(negocio()).toHaveLength(0);
  });

  it('autoriza y revoca a un familiar con el permiso familiares:autorizar', async () => {
    const autorizacion = { envejeciente_id: ENV, usuario_id: USR, tipo: 'familiar_responsable' };
    const { call, rpc, audit } = setup({
      handlers: { api_familiar_autorizar: autorizacion, api_familiar_revocar: null },
    });
    const res = await call('post', `${base}/familiares`).send({ usuario_id: USR }).expect(201);
    expect(res.body.data).toEqual(autorizacion);
    expect(rpc).toHaveBeenCalledWith('api_familiar_autorizar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_usuario_id: USR,
    });
    await call('post', `${base}/familiares/${USR}/revocar`)
      .send({ motivo: 'Ya no es responsable' })
      .expect(204);
    expect(rpc).toHaveBeenLastCalledWith('api_familiar_revocar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_usuario_id: USR,
      p_motivo: 'Ya no es responsable',
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'familiar.autorizado' }));
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'familiar.revocado' }));
  });

  it('en Organización solo el Administrador autoriza familiares', async () => {
    const admin = setup({
      rol: 'administrador',
      tipo: 'organizacion',
      handlers: { api_familiar_autorizar: {} },
    });
    await admin.call('post', `${base}/familiares`).send({ usuario_id: USR }).expect(201);
    const coord = setup({ rol: 'coordinador', tipo: 'organizacion' });
    await coord.call('post', `${base}/familiares`).send({ usuario_id: USR }).expect(403);
  });

  it('un 404 de revocación (inexistente o ya revocada) no revela más', async () => {
    const { call } = setup({ handlers: { api_familiar_revocar: falla('P0002') } });
    const res = await call('post', `${base}/familiares/${USR}/revocar`).expect(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
  });
});

describe('RF-14 / D11: evaluación y factores de riesgo', () => {
  const evaluacion = {
    evaluacion_riesgo_id: 3,
    puntaje: 30,
    nivel: 'medio',
    nivel_vigente: 'medio',
  };

  it('envía las respuestas y devuelve lo que calculó la base, no lo que dice el cliente', async () => {
    const { call, rpc, audit } = setup({ handlers: { api_riesgo_evaluar: evaluacion } });
    const res = await call('post', `${base}/evaluaciones`)
      .send({ respuestas: completas })
      .expect(201);
    expect(res.body).toEqual({ data: evaluacion });
    expect(rpc).toHaveBeenCalledWith('api_riesgo_evaluar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_respuestas: completas,
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'riesgo.evaluado' }));
  });

  it.each([
    ['puntaje', { puntaje: 0 }],
    ['nivel', { nivel: 'bajo' }],
    ['desglose', { desglose: [] }],
  ])('no acepta %s del cliente (resultado calculado en el servidor)', async (_campo, extra) => {
    const { call, negocio } = setup();
    await call('post', `${base}/evaluaciones`)
      .send({ respuestas: completas, ...extra })
      .expect(422);
    await call('post', `${base}/evaluaciones`)
      .send({ respuestas: { ...completas, ...extra } })
      .expect(422);
    expect(negocio()).toHaveLength(0);
  });

  it.each([
    [
      'falta una pregunta',
      (r) => Object.fromEntries(Object.entries(r).filter(([k]) => k !== 'vivienda')),
    ],
    ['una selección vacía', (r) => ({ ...r, movilidad: '' })],
    ['una respuesta null', (r) => ({ ...r, cronica: null })],
    ['sin respuestas', () => ({})],
  ])(
    'respuestas incompletas (%s): 422 EVALUATION_INCOMPLETE sin llamar a la RPC (D11)',
    async (_caso, hacer) => {
      const { call, negocio } = setup();
      const res = await call('post', `${base}/evaluaciones`)
        .send({ respuestas: hacer(completas) })
        .expect(422);
      expect(res.body.error.code).toBe('EVALUATION_INCOMPLETE');
      expect(negocio()).toHaveLength(0);
    },
  );

  it.each([
    ['opción fuera del cuestionario', { vivienda: 'castillo' }],
    ['sí/no como texto', { cronica: 'si' }],
    ['selección como número', { frecuencia: 3 }],
    ['pregunta desconocida', { color_favorito: 'azul' }],
    ['clave en camelCase', { viveSolo: true }],
  ])('respuestas inválidas (%s): 422 INVALID_INPUT', async (_caso, extra) => {
    const { call, negocio } = setup();
    const res = await call('post', `${base}/evaluaciones`)
      .send({ respuestas: { ...completas, ...extra } })
      .expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(negocio()).toHaveLength(0);
  });

  it('el mismo error de la base se traduce igual (defensa en profundidad)', async () => {
    const { call } = setup({
      handlers: { api_riesgo_evaluar: falla('P0001', 'CR_EVALUACION_INCOMPLETA') },
    });
    const res = await call('post', `${base}/evaluaciones`)
      .send({ respuestas: completas })
      .expect(422);
    expect(res.body.error.code).toBe('EVALUATION_INCOMPLETE');
  });

  it('registra un factor y lo reemplaza en la base', async () => {
    const resultado = { factor: { envejeciente_riesgo_id: 9 }, nivel_vigente: 'alto' };
    const { call, rpc, audit } = setup({ handlers: { api_riesgo_registrar: resultado } });
    const res = await call('post', `${base}/riesgos`)
      .send({ riesgo_id: 4, nivel: 'alto', motivo: ' Dos caídas el último mes ', observacion: '' })
      .expect(201);
    expect(res.body).toEqual({ data: resultado });
    expect(rpc).toHaveBeenCalledWith('api_riesgo_registrar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_riesgo_id: 4,
      p_nivel: 'alto',
      p_motivo: 'Dos caídas el último mes',
      p_observacion: null,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'riesgo.factor_registrado' }),
    );
  });

  it.each([
    ['nivel inválido', { riesgo_id: 4, nivel: 'critico', motivo: 'Motivo válido' }],
    ['motivo corto', { riesgo_id: 4, nivel: 'alto', motivo: 'no' }],
    ['sin motivo', { riesgo_id: 4, nivel: 'alto' }],
    ['factor 0', { riesgo_id: 0, nivel: 'alto', motivo: 'Motivo válido' }],
    ['factor como texto', { riesgo_id: '4', nivel: 'alto', motivo: 'Motivo válido' }],
    [
      'observación larga',
      { riesgo_id: 4, nivel: 'alto', motivo: 'Motivo válido', observacion: 'x'.repeat(301) },
    ],
    [
      'estado en el cuerpo',
      { riesgo_id: 4, nivel: 'alto', motivo: 'Motivo válido', estado: 'resuelto' },
    ],
  ])('registrar factor rechaza %s', async (_caso, cuerpo) => {
    const { call, negocio } = setup();
    await call('post', `${base}/riesgos`).send(cuerpo).expect(422);
    expect(negocio()).toHaveLength(0);
  });

  it('resuelve un factor por su id, dentro de la cuenta de la ruta', async () => {
    const resultado = { factor: { estado: 'resuelto' }, nivel_vigente: null };
    const { call, rpc } = setup({ handlers: { api_riesgo_resolver: resultado } });
    const res = await call('post', '/api/v1/cuentas/7/riesgos/5/resolver')
      .send({ observacion: 'Se superó' })
      .expect(200);
    expect(res.body).toEqual({ data: resultado });
    expect(rpc).toHaveBeenCalledWith('api_riesgo_resolver', {
      p_cuenta_id: '7',
      p_envejeciente_riesgo_id: '5',
      p_observacion: 'Se superó',
    });
    await call('post', '/api/v1/cuentas/7/riesgos/abc/resolver').expect(404);
    await call('post', '/api/v1/cuentas/7/riesgos/0/resolver').expect(404);
    await call('post', '/api/v1/cuentas/7/riesgos/5/resolver')
      .send({ estado: 'activo' })
      .expect(422);
  });

  it('un factor ya resuelto o ajeno se traduce sin detalles', async () => {
    const yaResuelto = setup({
      handlers: { api_riesgo_resolver: falla('P0001', 'CR_ESTADO_INVALIDO') },
    });
    const res = await yaResuelto.call('post', '/api/v1/cuentas/7/riesgos/5/resolver').expect(409);
    expect(res.body.error.code).toBe('INVALID_STATE');
    const ajeno = setup({ handlers: { api_riesgo_resolver: falla('P0002') } });
    await ajeno.call('post', '/api/v1/cuentas/7/riesgos/5/resolver').expect(404);
  });

  it('consulta el riesgo: «Sin evaluación vigente» llega tal como la base lo calcula', async () => {
    const vacio = {
      nivel_vigente: null,
      texto: 'Sin evaluación vigente',
      factores_vigentes: [],
      historial: [],
      ultima_evaluacion: null,
    };
    const { call, rpc, audit } = setup({
      rol: 'cuidador',
      handlers: { api_riesgo_consultar: vacio },
    });
    const res = await call('get', `${base}/riesgo`).expect(200);
    expect(res.body).toEqual({ data: vacio });
    expect(rpc).toHaveBeenCalledWith('api_riesgo_consultar', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'riesgo.consultado' }));
  });

  it('el cuidador consulta pero no modifica el riesgo (V2)', async () => {
    const { call, negocio } = setup({ rol: 'cuidador', handlers: { api_riesgo_consultar: {} } });
    await call('get', `${base}/riesgo`).expect(200);
    await call('post', `${base}/evaluaciones`).send({ respuestas: completas }).expect(403);
    await call('post', `${base}/riesgos`)
      .send({ riesgo_id: 1, nivel: 'alto', motivo: 'Motivo válido' })
      .expect(403);
    expect(negocio()).toHaveLength(1);
  });
});

describe('RF-15: indicaciones médicas', () => {
  const indicacion = { indicacion_medica_id: IND, titulo: 'Metformina', estado: 'activa' };
  const crear = { tipo_indicacion_id: 2, titulo: 'Metformina 850 mg', fecha_inicio: '2026-11-01' };

  it('lista paginada con orden y filtro, y metadatos CR-162', async () => {
    const handler = vi.fn(async () => ({ items: [indicacion], total: 41 }));
    const { call, audit } = setup({
      rol: 'familiar',
      handlers: { api_indicaciones_listar: handler },
    });
    const res = await call('get', `${base}/indicaciones`).expect(200);
    expect(res.body).toEqual({
      data: [indicacion],
      meta: { page: 1, limit: 20, total: 41, totalPages: 3 },
    });
    expect(handler).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_estado: null,
      p_orden: 'fecha_inicio',
      p_desc: true,
      p_limite: 20,
      p_desplazamiento: 0,
    });
    await call('get', `${base}/indicaciones`)
      .query({ page: 2, limit: 5, sort: 'fecha_creacion', 'filter[estado]': 'suspendida' })
      .expect(200);
    expect(handler).toHaveBeenLastCalledWith(
      expect.objectContaining({
        p_estado: 'suspendida',
        p_orden: 'fecha_creacion',
        p_desc: false,
        p_limite: 5,
        p_desplazamiento: 5,
      }),
    );
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'indicaciones.consultadas' }),
    );
  });

  it.each([
    ['filtro con valor inválido', { 'filter[estado]': 'vigente' }],
    ['filtro desconocido', { 'filter[titulo]': 'x' }],
    ['parámetro desconocido', { q: 'metformina' }],
    ['orden por campo no autorizado', { sort: 'titulo' }],
    ['orden con varios campos', { sort: '-fecha_inicio,fecha_creacion' }],
    ['desempate descendente', { sort: '-fecha_inicio,-indicacion_medica_id' }],
    ['límite excesivo', { limit: 101 }],
    ['página cero', { page: 0 }],
  ])('rechaza %s con 422', async (_caso, query) => {
    const { call, negocio } = setup();
    const res = await call('get', `${base}/indicaciones`).query(query).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(negocio()).toHaveLength(0);
  });

  it('una página fuera del conjunto devuelve 200 con data vacío', async () => {
    const { call } = setup({ handlers: { api_indicaciones_listar: { items: [], total: 3 } } });
    const res = await call('get', `${base}/indicaciones`).query({ page: 9 }).expect(200);
    expect(res.body).toEqual({ data: [], meta: { page: 9, limit: 20, total: 3, totalPages: 1 } });
  });

  it('un resultado inconsistente de la base es indisponibilidad, no datos', async () => {
    const desbordado = setup({
      handlers: { api_indicaciones_listar: { items: Array(25).fill(indicacion), total: 25 } },
    });
    await desbordado.call('get', `${base}/indicaciones`).expect(503);
    const roto = setup({ handlers: { api_indicaciones_listar: { items: 'x', total: 1 } } });
    await roto.call('get', `${base}/indicaciones`).expect(503);
    const nulo = setup({ handlers: { api_indicaciones_listar: null } });
    await nulo.call('get', `${base}/indicaciones`).expect(503);
  });

  it('crea la indicación, normaliza vacíos a null y audita', async () => {
    const { call, rpc, audit } = setup({
      rol: 'cuidador',
      handlers: { api_indicacion_crear: indicacion },
    });
    const res = await call('post', `${base}/indicaciones`)
      .send({
        ...crear,
        titulo: '  Metformina 850 mg ',
        descripcion: '',
        frecuencia_horario: 'Cada 12 horas',
        fecha_fin: null,
      })
      .expect(201);
    expect(res.body).toEqual({ data: indicacion });
    expect(rpc).toHaveBeenCalledWith('api_indicacion_crear', {
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_datos: {
        tipo_indicacion_id: 2,
        titulo: 'Metformina 850 mg',
        descripcion: null,
        frecuencia_horario: 'Cada 12 horas',
        fecha_inicio: '2026-11-01',
        fecha_fin: null,
      },
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'indicacion.creada' }));
  });

  it.each([
    ['sin título', { tipo_indicacion_id: 2, fecha_inicio: '2026-11-01' }],
    ['título corto', { ...crear, titulo: 'ab' }],
    ['sin tipo', { titulo: 'Metformina', fecha_inicio: '2026-11-01' }],
    ['sin fecha de inicio', { tipo_indicacion_id: 2, titulo: 'Metformina' }],
    ['fecha inexistente', { ...crear, fecha_inicio: '2026-02-30' }],
    ['fecha con otro formato', { ...crear, fecha_inicio: '01/11/2026' }],
    ['fin anterior al inicio', { ...crear, fecha_fin: '2026-10-31' }],
    ['descripción larga', { ...crear, descripcion: 'x'.repeat(301) }],
    ['estado en la creación', { ...crear, estado: 'finalizada' }],
    ['adulto en el cuerpo', { ...crear, envejeciente_id: ENV }],
    ['registrador en el cuerpo', { ...crear, registrado_por: USR }],
  ])('crear rechaza %s', async (_caso, cuerpo) => {
    const { call, negocio } = setup();
    await call('post', `${base}/indicaciones`).send(cuerpo).expect(422);
    expect(negocio()).toHaveLength(0);
  });

  it('edita parcialmente: null limpia, omitir conserva', async () => {
    const { call, rpc, audit } = setup({ handlers: { api_indicacion_editar: indicacion } });
    const res = await call('patch', `/api/v1/cuentas/7/indicaciones/${IND}`)
      .send({ titulo: 'Metformina 1000 mg', descripcion: null, fecha_fin: '2026-12-31' })
      .expect(200);
    expect(res.body).toEqual({ data: indicacion });
    expect(rpc).toHaveBeenCalledWith('api_indicacion_editar', {
      p_cuenta_id: '7',
      p_indicacion_id: IND,
      p_datos: { titulo: 'Metformina 1000 mg', descripcion: null, fecha_fin: '2026-12-31' },
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'indicacion.editada' }));
  });

  it.each([
    ['cuerpo vacío', {}],
    ['estado (tiene su propia acción)', { estado: 'finalizada' }],
    ['título nulo', { titulo: null }],
    ['fin anterior al inicio', { fecha_inicio: '2026-11-01', fecha_fin: '2026-10-01' }],
    ['campo desconocido', { evidencia_url: 'https://x.test/receta.pdf' }],
  ])('editar rechaza %s', async (_caso, cuerpo) => {
    const { call, negocio } = setup();
    await call('patch', `/api/v1/cuentas/7/indicaciones/${IND}`).send(cuerpo).expect(422);
    expect(negocio()).toHaveLength(0);
  });

  it('editar o cambiar el estado de una indicación ajena o finalizada se traduce sin detalles', async () => {
    const ajena = setup({ handlers: { api_indicacion_editar: falla('P0002') } });
    await ajena
      .call('patch', `/api/v1/cuentas/7/indicaciones/${IND}`)
      .send({ titulo: 'Otro' })
      .expect(404);
    const finalizada = setup({
      handlers: { api_indicacion_estado: falla('P0001', 'CR_ESTADO_INVALIDO') },
    });
    const res = await finalizada
      .call('post', `/api/v1/cuentas/7/indicaciones/${IND}/estado`)
      .send({ estado: 'activa' })
      .expect(409);
    expect(res.body.error.code).toBe('INVALID_STATE');
    await ajena
      .call('patch', '/api/v1/cuentas/7/indicaciones/no-es-un-id')
      .send({ titulo: 'Otro' })
      .expect(404);
  });

  it('cambia el estado y audita', async () => {
    const { call, rpc, audit } = setup({
      handlers: { api_indicacion_estado: { ...indicacion, estado: 'suspendida' } },
    });
    const res = await call('post', `/api/v1/cuentas/7/indicaciones/${IND}/estado`)
      .send({ estado: 'suspendida' })
      .expect(200);
    expect(res.body.data.estado).toBe('suspendida');
    expect(rpc).toHaveBeenCalledWith('api_indicacion_estado', {
      p_cuenta_id: '7',
      p_indicacion_id: IND,
      p_estado: 'suspendida',
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'indicacion.estado_cambiado' }),
    );
    await call('post', `/api/v1/cuentas/7/indicaciones/${IND}/estado`)
      .send({ estado: 'vigente' })
      .expect(422);
    await call('post', `/api/v1/cuentas/7/indicaciones/${IND}/estado`).send({}).expect(422);
  });
});

describe('RF-3.4 / CU-06: historial consolidado', () => {
  const evento = {
    tipo: 'visita',
    fecha: '2026-11-01T14:00:00.000Z',
    titulo: 'Visita realizada',
    detalle: null,
    referencia_id: IND,
  };

  it('pagina en orden descendente por defecto y devuelve el formato de evento', async () => {
    const handler = vi.fn(async () => ({ items: [evento], total: 1 }));
    const { call } = setup({
      rol: 'voluntario',
      tipo: 'organizacion',
      handlers: { api_historial_listar: handler },
    });
    const res = await call('get', `${base}/historial`).expect(200);
    expect(res.body).toEqual({
      data: [evento],
      meta: { page: 1, limit: 20, total: 1, totalPages: 1 },
    });
    expect(handler).toHaveBeenCalledWith({
      p_cuenta_id: '7',
      p_envejeciente_id: ENV,
      p_tipo: null,
      p_desc: true,
      p_limite: 20,
      p_desplazamiento: 0,
    });
  });

  it('admite filtro por tipo, orden ascendente y paginación', async () => {
    const handler = vi.fn(async () => ({ items: [], total: 0 }));
    const { call, audit } = setup({ handlers: { api_historial_listar: handler } });
    await call('get', `${base}/historial`)
      .query({ 'filter[tipo]': 'evaluacion', sort: 'fecha', page: 3, limit: 10 })
      .expect(200);
    expect(handler).toHaveBeenCalledWith(
      expect.objectContaining({
        p_tipo: 'evaluacion',
        p_desc: false,
        p_limite: 10,
        p_desplazamiento: 20,
      }),
    );
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'historial.consultado' }));
  });

  it.each([
    ['tipo desconocido', { 'filter[tipo]': 'foto' }],
    ['filtro por rango no definido', { 'filter[desde]': '2026-01-01' }],
    ['orden por otro campo', { sort: 'titulo' }],
    ['orden repetido', { sort: 'fecha,-fecha' }],
    ['límite 0', { limit: 0 }],
    ['parámetro duplicado', 'page=1&page=2'],
  ])('rechaza %s con 422', async (_caso, query) => {
    const { call, negocio } = setup();
    const res = await call('get', `${base}/historial`).query(query).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(negocio()).toHaveLength(0);
  });

  it('un adulto fuera del alcance responde 403 y no filtra información', async () => {
    const { call } = setup({ rol: 'cuidador', handlers: { api_historial_listar: falla('42501') } });
    const res = await call('get', `${base}/historial`).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
});

describe('Contrato entre la API y la propuesta SQL', () => {
  const sql = readFileSync(
    new URL('../docs/propuestas/fase-3b-seguimiento.sql', import.meta.url),
    'utf8',
  );

  // Parámetros de cada RPC declarada: { nombre: { requeridos: Set, todos: Set } }.
  function firmas() {
    const firmasSql = {};
    for (const [, nombre, lista] of sql.matchAll(
      /create function cuidared_api\.(api_\w+)\(([^)]*)\)/g,
    )) {
      const todos = new Set();
      const requeridos = new Set();
      for (const parte of lista
        .split(',')
        .map((p) => p.trim())
        .filter(Boolean)) {
        const clave = parte.split(/\s+/)[0];
        todos.add(clave);
        if (!/\sdefault\s/i.test(parte)) requeridos.add(clave);
      }
      firmasSql[nombre] = { todos, requeridos };
    }
    return firmasSql;
  }

  it('cada RPC que llama el repositorio existe y recibe exactamente sus parámetros', async () => {
    const llamadas = [];
    const rpc = vi.fn(async (nombre, parametros) => {
      llamadas.push([nombre, parametros]);
      return { items: [], total: 0 };
    });
    const repo = createSeguimientoRepository(rpc);
    const query = { page: 1, limit: 20, offset: 0, filters: {}, sort: [] };
    const orden = { campo: 'fecha_inicio', descendente: true };
    await repo.listarAsignaciones('7', ENV);
    await repo.asignar('7', ENV, { tipo: 'cuidador_asignado', usuario_id: USR });
    await repo.revocarAsignacion('7', ENV, USR, {});
    await repo.autorizarFamiliar('7', ENV, { usuario_id: USR });
    await repo.revocarFamiliar('7', ENV, USR, {});
    await repo.consultarRiesgo('7', ENV);
    await repo.evaluarRiesgo('7', ENV, { respuestas: completas });
    await repo.registrarRiesgo('7', ENV, { riesgo_id: 1, nivel: 'alto', motivo: 'Motivo válido' });
    await repo.resolverRiesgo('7', 5, {});
    await repo.listarIndicaciones('7', ENV, query, orden);
    await repo.crearIndicacion('7', ENV, crear());
    await repo.editarIndicacion('7', IND, { titulo: 'Otro' });
    await repo.cambiarEstadoIndicacion('7', IND, { estado: 'activa' });
    await repo.listarHistorial('7', ENV, query, orden);

    const declaradas = firmas();
    expect(llamadas).toHaveLength(14);
    for (const [nombre, parametros] of llamadas) {
      expect(declaradas[nombre], `RPC ${nombre} declarada en el SQL`).toBeDefined();
      const enviados = new Set(Object.keys(parametros));
      for (const clave of enviados)
        expect(declaradas[nombre].todos.has(clave), `${nombre}.${clave}`).toBe(true);
      for (const clave of declaradas[nombre].requeridos)
        expect(enviados.has(clave), `${nombre} requiere ${clave}`).toBe(true);
    }
    // Todas las RPC expuestas por la propuesta tienen su método y permisos de ejecución.
    expect(new Set(llamadas.map(([nombre]) => nombre))).toEqual(new Set(Object.keys(declaradas)));
    for (const nombre of Object.keys(declaradas)) {
      expect(sql).toMatch(new RegExp(`grant execute on function[^;]*cuidared_api\\.${nombre}\\(`));
    }
  });

  function crear() {
    return { tipo_indicacion_id: 1, titulo: 'Metformina', fecha_inicio: '2026-11-01' };
  }

  it('toda RPC es SECURITY DEFINER con search_path vacío y sin ejecución pública ni anónima', () => {
    const bloques = sql.split(/create function cuidared_api\./).slice(1);
    expect(bloques.length).toBe(14);
    for (const bloque of bloques) {
      const cabecera = bloque.slice(0, bloque.indexOf('$$'));
      expect(cabecera, cabecera.slice(0, 40)).toMatch(/security definer set search_path = ''/);
    }
    expect(sql).toMatch(/revoke all on function[^;]*from public, anon;/);
    expect(sql).toMatch(
      /revoke all on cuidared\.evaluacion_riesgo from public, anon, authenticated;/,
    );
    expect(sql).toMatch(/alter table cuidared\.evaluacion_riesgo enable row level security;/);
  });

  it('los códigos CR_* que lanza el SQL están registrados o son transversales', () => {
    const usados = new Set(
      [...sql.matchAll(/raise exception '(CR_[A-Z0-9_]+)'/g)].map((m) => m[1]),
    );
    expect(usados.size).toBeGreaterThan(0);
    for (const codigo of usados) {
      expect(businessError(codigo), codigo).toBeDefined();
    }
    for (const codigo of Object.keys(ERRORES_SEGUIMIENTO))
      expect(usados.has(codigo), codigo).toBe(true);
  });

  it('el cuestionario del servidor y el de la API declaran las mismas preguntas', async () => {
    const { PREGUNTAS, RESPUESTAS_OPCION } =
      await import('../src/modules/seguimiento/seguimiento-schemas.js');
    const definicion = sql.slice(sql.indexOf('cuestionario_riesgo_v1() returns jsonb'));
    const claves = [
      ...definicion.slice(0, definicion.indexOf("]'::jsonb")).matchAll(/"clave": "(\w+)"/g),
    ].map((m) => m[1]);
    expect(new Set(claves)).toEqual(new Set(PREGUNTAS));
    expect(claves).toHaveLength(9);
    for (const [clave, valores] of Object.entries(RESPUESTAS_OPCION)) {
      const fila = definicion.match(new RegExp(`"clave": "${clave}"[^\\n]*`))[0];
      expect([...fila.matchAll(/"(\w+)": \d+/g)].map((m) => m[1]).sort()).toEqual(
        [...valores].sort(),
      );
    }
  });
});
