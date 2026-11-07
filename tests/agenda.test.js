/* Pruebas API de agenda de cuidado y evidencias privadas · ID04/RF-16, RS-013, D12/D13, sin base real. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { businessError } from '../src/lib/business-errors.js';
import { AppError } from '../src/lib/errors.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { AGENDA_BUSINESS_ERRORS } from '../src/modules/agenda/agenda-errors.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';

const userId = 'a271ce25-7f40-4c45-b5ba-dbc6a0011234';
const profile = {
  usuario_id: userId,
  cedula: '00112345678',
  nombres: 'Ana',
  apellidos: 'Pérez',
  correo: 'ana@example.test',
  telefono: null,
  estado: 'activo',
};
const tareaId = 'b3e1c5a2-9f4d-4c7e-8a21-5d6f7e8a9b0c';
const evidenciaId = 'c4f2d6b3-0a5e-4d8f-9b32-6e7a8f9b0c1d';
const adultoId = 'd5a3e7c4-1b6f-4e90-a043-7f8b9a0c1d2e';
const base = '/api/v1/cuentas/7';
const ahora = new Date('2026-11-06T12:00:00.000Z');

const contexto = (rol = 'coordinador', extra = {}) => ({
  cuenta_id: 7,
  tipo: 'familia',
  rol,
  membresia_id: 11,
  permisos: permisosDe(rol, 'familia'),
  es_titular: rol === 'coordinador',
  acceso_operativo: true,
  suscripcion_estado: 'prueba',
  funcionalidades: ['registro_visitas'],
  ...extra,
});

/** Repository simulado: `api_contexto_cuenta` devuelve el contexto; las demás RPC se atienden con `respuestas`. */
function setup({ rol = 'coordinador', ctx = {}, respuestas = {}, storage = {} } = {}) {
  const rpc = vi.fn(async (name, params) => {
    if (name === 'api_contexto_cuenta') return contexto(rol, ctx);
    const respuesta = respuestas[name];
    if (respuesta === undefined) throw new Error(`RPC inesperada: ${name}`);
    return typeof respuesta === 'function' ? respuesta(params) : respuesta;
  });
  const bucket = {
    signedUploadUrl: vi.fn(async (path) => ({
      path,
      token: 'token-de-subida',
      signedUrl: `https://storage.test/upload/${path}?token=token-de-subida`,
    })),
    signedDownloadUrl: vi.fn(async (path) => `https://storage.test/download/${path}?sig=abc`),
    ...storage,
  };
  const repository = {
    session: vi.fn().mockResolvedValue({ vigente: true }),
    getProfile: vi.fn().mockResolvedValue(profile),
    rpc,
    storage: vi.fn(() => bucket),
  };
  const gateway = {
    authenticate: vi.fn().mockResolvedValue({ id: userId, email: profile.correo }),
    forToken: vi.fn().mockReturnValue(repository),
  };
  const audit = vi.fn();
  const app = createApp({
    env: { origins: ['http://localhost:5173'] },
    gateway,
    audit,
    now: () => ahora,
  });
  const llamadas = (name) => rpc.mock.calls.filter(([n]) => n === name);
  const agenda = () => rpc.mock.calls.filter(([n]) => n !== 'api_contexto_cuenta');
  return { app, rpc, repository, bucket, audit, llamadas, agenda };
}

const api = (app, method, path) =>
  request(app)[method](`${base}${path}`).auth('token', { type: 'bearer' });

const tareaValida = () => ({
  envejeciente_id: adultoId,
  cuidador_id: 12,
  titulo: 'Medir la presión',
  prioridad_id: 2,
  fecha_programada: '2026-11-07',
  hora_programada: '08:00',
  requiere_evidencia: true,
});
const archivoValido = () => ({
  nombre_archivo: 'foto.jpg',
  tipo_mime: 'image/jpeg',
  tamano_bytes: 1000,
});
const rutaValida = `cuenta/7/tarea/${tareaId}/e6a4f8d5-2c7a-4fa1-b654-8a9c0b1d2e3f.jpg`;

describe('RF-16: permisos y aislamiento en la API', () => {
  it.each([
    ['familiar', 'get', '/tareas'],
    ['voluntario', 'get', '/tareas'],
    ['cuidador', 'post', '/tareas'],
    ['cuidador', 'patch', `/tareas/${tareaId}`],
    ['cuidador', 'post', `/tareas/${tareaId}/cancelar`],
    ['cuidador', 'post', `/evidencias/${evidenciaId}/validar`],
    ['cuidador', 'post', `/evidencias/${evidenciaId}/rechazar`],
    ['coordinador', 'post', `/tareas/${tareaId}/iniciar`],
    ['coordinador', 'post', `/tareas/${tareaId}/completar`],
    ['coordinador', 'post', `/tareas/${tareaId}/evidencias/subida`],
    ['coordinador', 'post', `/tareas/${tareaId}/evidencias`],
  ])('el rol %s no puede %s %s (403 sin tocar la base)', async (rol, method, path) => {
    const { app, agenda } = setup({ rol });
    const res = await api(app, method, path).send({}).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(agenda()).toHaveLength(0);
  });

  it('el Cuidador consulta la agenda; el Coordinador gestiona; el Administrador de Organización valida', async () => {
    const { app } = setup({
      rol: 'cuidador',
      respuestas: { api_tareas_listar: { data: [], total: 0 } },
    });
    await api(app, 'get', '/tareas').expect(200);
    const org = setup({
      rol: 'administrador',
      ctx: { tipo: 'organizacion', permisos: permisosDe('administrador', 'organizacion') },
      respuestas: { api_evidencia_validar: { tarea_completada: false } },
    });
    await api(org.app, 'post', `/evidencias/${evidenciaId}/validar`).expect(200);
  });

  it('cuenta vencida: se bloquea la agenda operativa (D07)', async () => {
    const { app, agenda } = setup({ ctx: { acceso_operativo: false } });
    const res = await api(app, 'get', '/tareas').expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    expect(agenda()).toHaveLength(0);
  });

  it.each([
    ['coordinador', 'get', '/tareas/no-es-uuid'],
    ['coordinador', 'patch', '/tareas/123'],
    ['coordinador', 'post', '/tareas/%27%3B--/cancelar'],
    ['cuidador', 'post', '/tareas/no-es-uuid/iniciar'],
    ['cuidador', 'post', '/tareas/x/completar'],
    ['cuidador', 'post', '/tareas/x/evidencias/subida'],
    ['cuidador', 'post', '/tareas/x/evidencias'],
    ['coordinador', 'get', '/tareas/x/evidencias'],
    ['coordinador', 'post', '/evidencias/x/validar'],
    ['coordinador', 'post', '/evidencias/9/rechazar'],
  ])(
    'identificador mal formado (%s) en %s %s: 404 sin consultar la base',
    async (rol, method, path) => {
      const { app, agenda } = setup({ rol });
      const res = await api(app, method, path).send({ motivo: 'Motivo válido' }).expect(404);
      expect(res.body.error.code).toBe('NOT_FOUND');
      expect(agenda()).toHaveLength(0);
    },
  );

  it('una tarea de otra cuenta, de otro cuidador o inexistente es un 404 uniforme', async () => {
    const { app } = setup({
      rol: 'cuidador',
      respuestas: {
        api_tarea_obtener: () => {
          throw mapRpcError({ code: 'P0002' });
        },
      },
    });
    const res = await api(app, 'get', `/tareas/${tareaId}`).expect(404);
    expect(res.body.error).toEqual({ code: 'NOT_FOUND', message: 'Recurso no encontrado.' });
  });

  it('sin sesión no se llega a la agenda', async () => {
    const { app, agenda } = setup();
    await request(app).get(`${base}/tareas`).expect(401);
    expect(agenda()).toHaveLength(0);
  });
});

describe('RF-16: listado de tareas (CR-162)', () => {
  it('traduce filtros, orden y paginación a la RPC y devuelve la página con sus metadatos', async () => {
    const fila = { tarea_id: tareaId, titulo: 'Medir la presión', estado: 'pendiente' };
    const { app, llamadas } = setup({
      respuestas: { api_tareas_listar: { data: [fila], total: 41 } },
    });
    const res = await api(app, 'get', '/tareas')
      .query({
        page: '2',
        limit: '10',
        sort: '-fecha_programada',
        'filter[estado]': 'pendiente',
        'filter[desde]': '2026-11-01',
        'filter[hasta]': '2026-11-30',
        'filter[envejeciente_id]': adultoId,
        'filter[cuidador_id]': '12',
      })
      .expect(200);
    expect(res.body).toEqual({
      data: [fila],
      meta: { page: 2, limit: 10, total: 41, totalPages: 5 },
    });
    expect(llamadas('api_tareas_listar')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_filtros: {
        estado: 'pendiente',
        desde: '2026-11-01',
        hasta: '2026-11-30',
        envejeciente_id: adultoId,
        cuidador_id: 12,
      },
      p_orden: [
        { campo: 'fecha_programada', direccion: 'desc' },
        { campo: 'tarea_id', direccion: 'asc' },
      ],
      p_limit: 10,
      p_offset: 10,
    });
  });

  it('usa el orden y la paginación predeterminados', async () => {
    const { app, llamadas } = setup({ respuestas: { api_tareas_listar: { data: [], total: 0 } } });
    const res = await api(app, 'get', '/tareas').expect(200);
    expect(res.body.meta).toEqual({ page: 1, limit: 20, total: 0, totalPages: 0 });
    expect(llamadas('api_tareas_listar')[0][1]).toMatchObject({
      p_filtros: {},
      p_orden: [
        { campo: 'fecha_programada', direccion: 'asc' },
        { campo: 'hora_programada', direccion: 'asc' },
        { campo: 'tarea_id', direccion: 'asc' },
      ],
      p_limit: 20,
      p_offset: 0,
    });
  });

  it.each([
    ['filtro desconocido', { 'filter[titulo]': 'x' }],
    ['parámetro desconocido', { cuenta_id: '8' }],
    ['estado inexistente', { 'filter[estado]': 'borrada' }],
    ['fecha inválida', { 'filter[desde]': '2026-02-30' }],
    ['rango invertido', { 'filter[desde]': '2026-12-01', 'filter[hasta]': '2026-11-01' }],
    ['adulto no UUID', { 'filter[envejeciente_id]': '1 or 1=1' }],
    ['cuidador no numérico', { 'filter[cuidador_id]': 'abc' }],
    ['orden fuera de la lista', { sort: 'titulo' }],
    ['orden inyectado', { sort: 'fecha_programada;drop table tarea_agenda' }],
    ['límite excesivo', { limit: '101' }],
    ['página cero', { page: '0' }],
  ])('%s: 422 sin consultar la base', async (_nombre, query) => {
    const { app, agenda } = setup();
    const res = await api(app, 'get', '/tareas').query(query).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(agenda()).toHaveLength(0);
  });

  it('un parámetro repetido se rechaza', async () => {
    const { app, agenda } = setup();
    await api(app, 'get', '/tareas?filter[estado]=pendiente&filter[estado]=completada').expect(422);
    expect(agenda()).toHaveLength(0);
  });

  it('un contrato roto de la base es indisponibilidad, no un listado inventado', async () => {
    const { app } = setup({ respuestas: { api_tareas_listar: { data: 'x', total: 'y' } } });
    await api(app, 'get', '/tareas').expect(503);
  });
});

describe('RF-16: crear tareas y series', () => {
  it('crea la tarea con los datos validados y audita, sin aceptar actor ni estado del cliente', async () => {
    const creada = { serie_id: null, tareas: [{ tarea_id: tareaId, estado: 'pendiente' }] };
    const { app, llamadas, audit } = setup({ respuestas: { api_tarea_crear: creada } });
    const body = { ...tareaValida(), titulo: '  Medir la presión  ', indicacion_medica_id: null };
    const res = await api(app, 'post', '/tareas').send(body).expect(201);
    expect(res.body).toEqual({ data: creada });
    expect(llamadas('api_tarea_crear')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_datos: { ...tareaValida(), titulo: 'Medir la presión', indicacion_medica_id: null },
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: userId,
        action: 'agenda.tarea_creada',
        result: 'success',
      }),
    );
  });

  it('envía la repetición semanal con días ISO y fecha de fin', async () => {
    const { app, llamadas } = setup({ respuestas: { api_tarea_crear: { tareas: [] } } });
    const repeticion = { frecuencia: 'semanal', dias_semana: [1, 3, 7], hasta: '2026-12-07' };
    await api(app, 'post', '/tareas')
      .send({ ...tareaValida(), repeticion })
      .expect(201);
    expect(llamadas('api_tarea_crear')[0][1].p_datos.repeticion).toEqual(repeticion);
  });

  it.each([
    ['campo desconocido', { prioridad: 'alta' }],
    ['estado enviado por el cliente', { estado: 'completada' }],
    ['actor enviado por el cliente', { usuario_creador_id: userId }],
    ['cuenta enviada por el cliente', { cuenta_id: 99 }],
    ['título corto', { titulo: 'ab' }],
    ['título largo', { titulo: 'x'.repeat(81) }],
    ['fecha inexistente', { fecha_programada: '2026-02-30' }],
    ['fecha con otro formato', { fecha_programada: '07/11/2026' }],
    ['hora inválida', { hora_programada: '25:00' }],
    ['evidencia como texto', { requiere_evidencia: 'si' }],
    ['cuidador como texto', { cuidador_id: '12' }],
    ['cuidador negativo', { cuidador_id: -1 }],
    ['adulto no UUID', { envejeciente_id: '1' }],
    ['prioridad decimal', { prioridad_id: 1.5 }],
  ])('%s: 422 INVALID_INPUT sin consultar la base', async (_nombre, extra) => {
    const { app, agenda } = setup();
    const res = await api(app, 'post', '/tareas')
      .send({ ...tareaValida(), ...extra })
      .expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(agenda()).toHaveLength(0);
  });

  it.each([
    ['frecuencia desconocida', { frecuencia: 'mensual', hasta: '2026-12-07' }],
    ['sin fecha de fin', { frecuencia: 'diaria' }],
    [
      'día de la semana fuera de 1 a 7',
      { frecuencia: 'semanal', dias_semana: [0], hasta: '2026-12-07' },
    ],
    ['día de la semana 8', { frecuencia: 'semanal', dias_semana: [8], hasta: '2026-12-07' }],
    ['campo desconocido', { frecuencia: 'diaria', hasta: '2026-12-07', cada: 2 }],
    ['fin con otro formato', { frecuencia: 'diaria', hasta: 'mañana' }],
  ])('repetición con %s: INVALID_REPETITION', async (_nombre, repeticion) => {
    const { app, agenda } = setup();
    const res = await api(app, 'post', '/tareas')
      .send({ ...tareaValida(), repeticion })
      .expect(422);
    expect(res.body.error.code).toBe('INVALID_REPETITION');
    expect(agenda()).toHaveLength(0);
  });

  it.each([
    ['CR_CUIDADOR_NO_ASIGNADO', 422, 'CAREGIVER_NOT_ASSIGNED'],
    ['CR_INDICACION_NO_CORRESPONDE', 422, 'INDICATION_MISMATCH'],
    ['CR_REPETICION_INVALIDA', 422, 'INVALID_REPETITION'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
    ['CR_CUENTA_SIN_ACCESO', 403, 'SUBSCRIPTION_INACTIVE'],
  ])(
    'traduce %s de la base a %s/%s sin mostrar el texto interno',
    async (codigo, status, publico) => {
      const { app } = setup({
        respuestas: {
          api_tarea_crear: () => {
            throw mapRpcError({ code: 'P0001', message: codigo });
          },
        },
      });
      const res = await api(app, 'post', '/tareas').send(tareaValida()).expect(status);
      expect(res.body.error.code).toBe(publico);
      expect(JSON.stringify(res.body)).not.toContain('CR_');
    },
  );

  it('un adulto de otra cuenta es un 404 y un permiso insuficiente en la base, un 403', async () => {
    const respuestas = (code) => ({
      api_tarea_crear: () => {
        throw mapRpcError({ code });
      },
    });
    await api(setup({ respuestas: respuestas('P0002') }).app, 'post', '/tareas')
      .send(tareaValida())
      .expect(404);
    await api(setup({ respuestas: respuestas('42501') }).app, 'post', '/tareas')
      .send(tareaValida())
      .expect(403);
  });
});

describe('RF-16: editar y cancelar', () => {
  it('PATCH envía solo los campos indicados (null quita hora e indicación) y exige alguno', async () => {
    const { app, llamadas, audit } = setup({
      respuestas: { api_tarea_actualizar: { tarea_id: tareaId } },
    });
    await api(app, 'patch', `/tareas/${tareaId}`)
      .send({
        titulo: 'Nuevo título',
        hora_programada: null,
        indicacion_medica_id: null,
        alcance: 'siguientes',
      })
      .expect(200);
    expect(llamadas('api_tarea_actualizar')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_tarea_id: tareaId,
      p_datos: {
        titulo: 'Nuevo título',
        hora_programada: null,
        indicacion_medica_id: null,
        alcance: 'siguientes',
      },
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.tarea_actualizada' }),
    );
    for (const body of [
      {},
      { alcance: 'esta' },
      { estado: 'completada' },
      { titulo: 'ab' },
      { alcance: 'todas', titulo: 'Válido' },
    ]) {
      await api(app, 'patch', `/tareas/${tareaId}`).send(body).expect(422);
    }
    expect(llamadas('api_tarea_actualizar')).toHaveLength(1);
  });

  it('cancelar exige motivo y usa el alcance «esta» por omisión', async () => {
    const { app, llamadas, audit } = setup({
      respuestas: { api_tarea_cancelar: { canceladas: 1, tarea: { tarea_id: tareaId } } },
    });
    const res = await api(app, 'post', `/tareas/${tareaId}/cancelar`)
      .send({ motivo: '  Se pospone  ' })
      .expect(200);
    expect(res.body.data.canceladas).toBe(1);
    expect(llamadas('api_tarea_cancelar')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_tarea_id: tareaId,
      p_motivo: 'Se pospone',
      p_alcance: 'esta',
    });
    await api(app, 'post', `/tareas/${tareaId}/cancelar`)
      .send({ motivo: 'La terapia termina', alcance: 'siguientes' })
      .expect(200);
    expect(llamadas('api_tarea_cancelar')[1][1]).toMatchObject({ p_alcance: 'siguientes' });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.tarea_cancelada' }),
    );
    for (const body of [
      {},
      { motivo: '' },
      { motivo: 'ab' },
      { motivo: 'Motivo', alcance: 'todas' },
      { motivo: 'Motivo', extra: 1 },
    ]) {
      await api(app, 'post', `/tareas/${tareaId}/cancelar`).send(body).expect(422);
    }
    expect(llamadas('api_tarea_cancelar')).toHaveLength(2);
  });

  it('una tarea que ya no está abierta es un 409 INVALID_STATE', async () => {
    const { app } = setup({
      respuestas: {
        api_tarea_cancelar: () => {
          throw mapRpcError({ code: 'P0001', message: 'CR_ESTADO_INVALIDO' });
        },
      },
    });
    const res = await api(app, 'post', `/tareas/${tareaId}/cancelar`)
      .send({ motivo: 'Ya no hace falta' })
      .expect(409);
    expect(res.body.error.code).toBe('INVALID_STATE');
  });
});

describe('RF-16 / D12: ejecución por el cuidador asignado', () => {
  it('iniciar y completar llaman a la base con cuenta y tarea de la ruta, nunca del cuerpo', async () => {
    const { app, llamadas, audit } = setup({
      rol: 'cuidador',
      respuestas: {
        api_tarea_iniciar: { estado: 'en_progreso' },
        api_tarea_completar: { estado: 'completada' },
      },
    });
    expect(
      (await api(app, 'post', `/tareas/${tareaId}/iniciar`).expect(200)).body.data.estado,
    ).toBe('en_progreso');
    expect(
      (await api(app, 'post', `/tareas/${tareaId}/completar`).send({}).expect(200)).body.data
        .estado,
    ).toBe('completada');
    expect(llamadas('api_tarea_iniciar')[0][1]).toEqual({ p_cuenta_id: 7, p_tarea_id: tareaId });
    expect(llamadas('api_tarea_completar')[0][1]).toEqual({ p_cuenta_id: 7, p_tarea_id: tareaId });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.tarea_iniciada' }),
    );
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.tarea_completada' }),
    );
    // El estado no se envía desde el cliente.
    await api(app, 'post', `/tareas/${tareaId}/completar`)
      .send({ estado: 'completada' })
      .expect(422);
    expect(llamadas('api_tarea_completar')).toHaveLength(1);
  });

  it('D12: sin evidencia validada la base responde EVIDENCE_REQUIRED (409) y la API no completa', async () => {
    const { app } = setup({
      rol: 'cuidador',
      respuestas: {
        api_tarea_completar: () => {
          throw mapRpcError({ code: 'P0001', message: 'CR_EVIDENCIA_REQUERIDA' });
        },
      },
    });
    const res = await api(app, 'post', `/tareas/${tareaId}/completar`).expect(409);
    expect(res.body.error.code).toBe('EVIDENCE_REQUIRED');
  });

  it('otro cuidador recibe 404 y quien no es el asignado, 403', async () => {
    const lanzar = (code) => ({
      api_tarea_iniciar: () => {
        throw mapRpcError({ code });
      },
    });
    await api(
      setup({ rol: 'cuidador', respuestas: lanzar('P0002') }).app,
      'post',
      `/tareas/${tareaId}/iniciar`,
    ).expect(404);
    await api(
      setup({ rol: 'cuidador', respuestas: lanzar('42501') }).app,
      'post',
      `/tareas/${tareaId}/iniciar`,
    ).expect(403);
  });
});

describe('RS-013 / D13: subida de evidencias a Storage privado', () => {
  it('la base autoriza y genera la ruta; la API firma exactamente esa ruta', async () => {
    const { app, bucket, repository, llamadas, audit } = setup({
      rol: 'cuidador',
      respuestas: { api_evidencia_preparar_subida: { ruta: rutaValida } },
    });
    const res = await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
      .send(archivoValido())
      .expect(200);
    expect(llamadas('api_evidencia_preparar_subida')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_tarea_id: tareaId,
      p_datos: archivoValido(),
    });
    expect(repository.storage).toHaveBeenCalledWith('evidencias');
    expect(bucket.signedUploadUrl).toHaveBeenCalledWith(rutaValida);
    expect(res.body.data).toEqual({
      ruta: rutaValida,
      url_subida: `https://storage.test/upload/${rutaValida}?token=token-de-subida`,
      token: 'token-de-subida',
      bucket: 'evidencias',
      expira_en_segundos: 7200,
      tipos_permitidos: ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'],
      tamano_maximo_bytes: 5 * 1024 * 1024,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.evidencia_subida_solicitada' }),
    );
  });

  it('el cliente no puede elegir la ruta', async () => {
    const { app, agenda, bucket } = setup({ rol: 'cuidador' });
    await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
      .send({ ...archivoValido(), ruta: `cuenta/8/tarea/${tareaId}/x.jpg` })
      .expect(422);
    expect(agenda()).toHaveLength(0);
    expect(bucket.signedUploadUrl).not.toHaveBeenCalled();
  });

  it.each([
    ['GIF', { tipo_mime: 'image/gif' }],
    ['ejecutable', { tipo_mime: 'application/x-msdownload' }],
    ['SVG', { tipo_mime: 'image/svg+xml' }],
    ['5 MB + 1 byte', { tamano_bytes: 5 * 1024 * 1024 + 1 }],
    ['archivo vacío', { tamano_bytes: 0 }],
    ['tamaño decimal', { tamano_bytes: 10.5 }],
    ['tamaño como texto', { tamano_bytes: '1000' }],
    ['nombre con ruta', { nombre_archivo: '../../etc/passwd' }],
    ['nombre con barra invertida', { nombre_archivo: 'a\\b.jpg' }],
    ['nombre vacío', { nombre_archivo: '' }],
  ])('RS-013: %s se rechaza como INVALID_FILE sin firmar nada', async (_nombre, extra) => {
    const { app, agenda, bucket } = setup({ rol: 'cuidador' });
    const res = await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
      .send({ ...archivoValido(), ...extra })
      .expect(422);
    expect(res.body.error.code).toBe('INVALID_FILE');
    expect(agenda()).toHaveLength(0);
    expect(bucket.signedUploadUrl).not.toHaveBeenCalled();
  });

  it('el límite exacto de 5 MB y los cuatro tipos se aceptan', async () => {
    const { app } = setup({
      rol: 'cuidador',
      respuestas: { api_evidencia_preparar_subida: { ruta: rutaValida } },
    });
    for (const tipo_mime of ['image/jpeg', 'image/png', 'image/webp', 'application/pdf']) {
      await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
        .send({ nombre_archivo: 'a.bin', tipo_mime, tamano_bytes: 5 * 1024 * 1024 })
        .expect(200);
    }
  });

  it('si la base no autoriza no se firma la subida (otro cuidador, tarea cerrada, límite, cuenta ajena)', async () => {
    for (const [error, status] of [
      [mapRpcError({ code: 'P0002' }), 404],
      [mapRpcError({ code: '42501' }), 403],
      [mapRpcError({ code: 'P0001', message: 'CR_ESTADO_INVALIDO' }), 409],
      [mapRpcError({ code: 'P0001', message: 'CR_LIMITE_EVIDENCIAS' }), 409],
      [mapRpcError({ code: 'P0001', message: 'CR_ARCHIVO_INVALIDO' }), 422],
    ]) {
      const { app, bucket } = setup({
        rol: 'cuidador',
        respuestas: {
          api_evidencia_preparar_subida: () => {
            throw error;
          },
        },
      });
      await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
        .send(archivoValido())
        .expect(status);
      expect(bucket.signedUploadUrl).not.toHaveBeenCalled();
    }
  });

  it('un contrato roto de la base no firma ninguna ruta', async () => {
    const { app, bucket } = setup({
      rol: 'cuidador',
      respuestas: { api_evidencia_preparar_subida: { ruta: 42 } },
    });
    await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
      .send(archivoValido())
      .expect(503);
    expect(bucket.signedUploadUrl).not.toHaveBeenCalled();
  });

  it('un fallo o una denegación de Storage no se disfraza de éxito', async () => {
    for (const [error, status] of [
      [new AppError(403, 'FORBIDDEN', 'No tienes permiso para realizar esta acción.'), 403],
      [new AppError(503, 'DEPENDENCY_UNAVAILABLE', 'El servicio no está disponible.'), 503],
    ]) {
      const { app } = setup({
        rol: 'cuidador',
        respuestas: { api_evidencia_preparar_subida: { ruta: rutaValida } },
        storage: {
          signedUploadUrl: vi.fn().mockRejectedValue(error),
        },
      });
      await api(app, 'post', `/tareas/${tareaId}/evidencias/subida`)
        .send(archivoValido())
        .expect(status);
    }
  });
});

describe('RF-16 / RS-013: registro de evidencias', () => {
  it('registra la evidencia pendiente con la ruta, la observación y los metadatos del archivo', async () => {
    const evidencia = { evidencia_id: evidenciaId, estado_validacion: 'pendiente' };
    const { app, llamadas, audit } = setup({
      rol: 'cuidador',
      respuestas: { api_evidencia_registrar: evidencia },
    });
    const body = { ruta: rutaValida, observacion: '  Tomada tras la visita ', ...archivoValido() };
    const res = await api(app, 'post', `/tareas/${tareaId}/evidencias`).send(body).expect(201);
    expect(res.body).toEqual({ data: evidencia });
    expect(llamadas('api_evidencia_registrar')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_tarea_id: tareaId,
      p_datos: { ...body, observacion: 'Tomada tras la visita' },
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.evidencia_registrada' }),
    );
  });

  it.each([
    ['sin ruta', { ruta: undefined }, 'INVALID_INPUT'],
    ['observación demasiado larga', { observacion: 'x'.repeat(301) }, 'INVALID_INPUT'],
    ['estado enviado por el cliente', { estado_validacion: 'validada' }, 'INVALID_INPUT'],
    ['validador enviado por el cliente', { validada_por: userId }, 'INVALID_INPUT'],
    ['archivo demasiado grande', { tamano_bytes: 6 * 1024 * 1024 }, 'INVALID_FILE'],
    ['tipo no permitido', { tipo_mime: 'text/html' }, 'INVALID_FILE'],
  ])('%s: se rechaza sin consultar la base', async (_nombre, extra, codigo) => {
    const { app, agenda } = setup({ rol: 'cuidador' });
    const res = await api(app, 'post', `/tareas/${tareaId}/evidencias`)
      .send({ ruta: rutaValida, ...archivoValido(), ...extra })
      .expect(422);
    expect(res.body.error.code).toBe(codigo);
    expect(agenda()).toHaveLength(0);
  });

  it.each([
    ['CR_ARCHIVO_INVALIDO', 422, 'INVALID_FILE'],
    ['CR_ARCHIVO_NO_SUBIDO', 409, 'FILE_NOT_UPLOADED'],
    ['CR_LIMITE_EVIDENCIAS', 409, 'EVIDENCE_LIMIT_REACHED'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
  ])(
    'traduce %s (ruta ajena, archivo sin subir, límite o tarea cerrada)',
    async (codigo, status, publico) => {
      const { app } = setup({
        rol: 'cuidador',
        respuestas: {
          api_evidencia_registrar: () => {
            throw mapRpcError({ code: 'P0001', message: codigo });
          },
        },
      });
      const res = await api(app, 'post', `/tareas/${tareaId}/evidencias`)
        .send({ ruta: rutaValida, ...archivoValido() })
        .expect(status);
      expect(res.body.error.code).toBe(publico);
    },
  );

  it('la misma ruta registrada dos veces es un conflicto (409)', async () => {
    const { app } = setup({
      rol: 'cuidador',
      respuestas: {
        api_evidencia_registrar: () => {
          throw mapRpcError({ code: '23505' });
        },
      },
    });
    await api(app, 'post', `/tareas/${tareaId}/evidencias`)
      .send({ ruta: rutaValida, ...archivoValido() })
      .expect(409);
  });
});

describe('RS-013: descarga de evidencias con URL firmada de 5 minutos', () => {
  const fila = (ruta, extra = {}) => ({
    evidencia_id: evidenciaId,
    tarea_id: tareaId,
    nombre_archivo: 'foto.jpg',
    tipo_mime: 'image/jpeg',
    estado_validacion: 'pendiente',
    ruta,
    ...extra,
  });

  it('firma cada evidencia por 300 segundos y nunca devuelve la ruta interna', async () => {
    const otra = `cuenta/7/tarea/${tareaId}/f7b5a9e6-3d8b-4ab2-8765-9b0d1c2e3f4a.pdf`;
    const { app, bucket, repository } = setup({
      respuestas: { api_evidencias_listar: [fila(rutaValida), fila(otra, { evidencia_id: 'x' })] },
    });
    const res = await api(app, 'get', `/tareas/${tareaId}/evidencias`).expect(200);
    expect(repository.storage).toHaveBeenCalledWith('evidencias');
    expect(bucket.signedDownloadUrl).toHaveBeenCalledWith(rutaValida, 300);
    expect(bucket.signedDownloadUrl).toHaveBeenCalledWith(otra, 300);
    expect(res.body.data).toHaveLength(2);
    expect(res.body.data[0]).toEqual({
      evidencia_id: evidenciaId,
      tarea_id: tareaId,
      nombre_archivo: 'foto.jpg',
      tipo_mime: 'image/jpeg',
      estado_validacion: 'pendiente',
      url_descarga: `https://storage.test/download/${rutaValida}?sig=abc`,
      url_expira_en: '2026-11-06T12:05:00.000Z',
    });
    expect(JSON.stringify(res.body)).not.toContain('"ruta"');
  });

  it('el Cuidador y el Coordinador consultan; la base decide cuáles ve cada uno', async () => {
    for (const rol of ['cuidador', 'coordinador']) {
      const { app } = setup({ rol, respuestas: { api_evidencias_listar: [] } });
      const res = await api(app, 'get', `/tareas/${tareaId}/evidencias`).expect(200);
      expect(res.body).toEqual({ data: [] });
    }
    const { app, bucket } = setup({
      rol: 'cuidador',
      respuestas: {
        api_evidencias_listar: () => {
          throw mapRpcError({ code: 'P0002' });
        },
      },
    });
    await api(app, 'get', `/tareas/${tareaId}/evidencias`).expect(404);
    expect(bucket.signedDownloadUrl).not.toHaveBeenCalled();
  });

  it('si el objeto ya no existe en el bucket conserva la evidencia sin URL; otros fallos se propagan', async () => {
    const faltante = setup({
      respuestas: { api_evidencias_listar: [fila(rutaValida)] },
      storage: {
        signedDownloadUrl: vi
          .fn()
          .mockRejectedValue(new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.')),
      },
    });
    const res = await api(faltante.app, 'get', `/tareas/${tareaId}/evidencias`).expect(200);
    expect(res.body.data[0]).toMatchObject({
      url_descarga: null,
      url_expira_en: null,
      nombre_archivo: 'foto.jpg',
    });
    const denegado = setup({
      respuestas: { api_evidencias_listar: [fila(rutaValida)] },
      storage: {
        signedDownloadUrl: vi
          .fn()
          .mockRejectedValue(new AppError(403, 'FORBIDDEN', 'No tienes permiso.')),
      },
    });
    await api(denegado.app, 'get', `/tareas/${tareaId}/evidencias`).expect(403);
  });

  it('un contrato roto de la base es indisponibilidad', async () => {
    const { app } = setup({
      respuestas: { api_evidencias_listar: [{ evidencia_id: evidenciaId }] },
    });
    await api(app, 'get', `/tareas/${tareaId}/evidencias`).expect(503);
  });
});

describe('D12: validar y rechazar evidencias', () => {
  it('validar llama a la base con la cuenta y la evidencia de la ruta y audita', async () => {
    const resultado = {
      evidencia: { evidencia_id: evidenciaId, estado_validacion: 'validada' },
      tarea: { tarea_id: tareaId, estado: 'completada' },
      tarea_completada: true,
    };
    const { app, llamadas, audit } = setup({ respuestas: { api_evidencia_validar: resultado } });
    const res = await api(app, 'post', `/evidencias/${evidenciaId}/validar`).expect(200);
    expect(res.body).toEqual({ data: resultado });
    expect(llamadas('api_evidencia_validar')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_evidencia_id: evidenciaId,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: userId,
        action: 'agenda.evidencia_validada',
        result: 'success',
      }),
    );
    // El validador y el resultado nunca vienen del cliente.
    await api(app, 'post', `/evidencias/${evidenciaId}/validar`)
      .send({ validada_por: userId })
      .expect(422);
    expect(llamadas('api_evidencia_validar')).toHaveLength(1);
  });

  it('rechazar exige un motivo de 5 a 200 caracteres', async () => {
    const { app, llamadas, audit } = setup({
      respuestas: { api_evidencia_rechazar: { tarea_completada: false } },
    });
    await api(app, 'post', `/evidencias/${evidenciaId}/rechazar`)
      .send({ motivo: '  La foto está borrosa  ' })
      .expect(200);
    expect(llamadas('api_evidencia_rechazar')[0][1]).toEqual({
      p_cuenta_id: 7,
      p_evidencia_id: evidenciaId,
      p_motivo: 'La foto está borrosa',
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'agenda.evidencia_rechazada' }),
    );
    for (const body of [
      {},
      { motivo: '' },
      { motivo: 'No' },
      { motivo: '    ' },
      { motivo: 'x'.repeat(201) },
      { motivo: 'Motivo válido', extra: 1 },
    ]) {
      const res = await api(app, 'post', `/evidencias/${evidenciaId}/rechazar`)
        .send(body)
        .expect(422);
      expect(res.body.error.code).toBe('INVALID_INPUT');
    }
    expect(llamadas('api_evidencia_rechazar')).toHaveLength(1);
  });

  it('una evidencia de otra cuenta es un 404 y una ya revisada, un 409', async () => {
    const lanzar = (error) => ({
      api_evidencia_validar: () => {
        throw error;
      },
    });
    await api(
      setup({ respuestas: lanzar(mapRpcError({ code: 'P0002' })) }).app,
      'post',
      `/evidencias/${evidenciaId}/validar`,
    ).expect(404);
    const res = await api(
      setup({ respuestas: lanzar(mapRpcError({ code: 'P0001', message: 'CR_ESTADO_INVALIDO' })) })
        .app,
      'post',
      `/evidencias/${evidenciaId}/validar`,
    ).expect(409);
    expect(res.body.error.code).toBe('INVALID_STATE');
  });
});

describe('CR-162: registro de códigos de negocio de la agenda', () => {
  it('cada código CR_* del módulo se traduce con su estado y código público, y solo esos', () => {
    for (const [codigo, definicion] of Object.entries(AGENDA_BUSINESS_ERRORS)) {
      const error = businessError(codigo);
      expect(error).toBeInstanceOf(AppError);
      expect([error.status, error.code]).toEqual([definicion.status, definicion.publicCode]);
      expect(error.message).toBe(definicion.message);
    }
    expect(Object.keys(AGENDA_BUSINESS_ERRORS).sort()).toEqual([
      'CR_ARCHIVO_INVALIDO',
      'CR_ARCHIVO_NO_SUBIDO',
      'CR_CUIDADOR_NO_ASIGNADO',
      'CR_EVIDENCIA_REQUERIDA',
      'CR_INDICACION_NO_CORRESPONDE',
      'CR_LIMITE_EVIDENCIAS',
      'CR_REPETICION_INVALIDA',
    ]);
    expect(businessError('CR_OTRO_MODULO_NO_REGISTRADO')).toBeUndefined();
  });
});
