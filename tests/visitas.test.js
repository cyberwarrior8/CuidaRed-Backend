/* Pruebas API de visitas y solicitudes de visita · ID04/RF-02, gateway real con transporte simulado. © 2026 Equipo CuidaRed – INTEC. */
import { describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createSupabaseGateway } from '../src/modules/access/supabase-gateway.js';
import { permisosDe } from '../src/modules/cuentas/permisos.js';

const env = {
  SUPABASE_URL: 'https://auth.example.test',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test_only',
};
const actor = {
  id: 'a271ce25-7f40-4c45-b5ba-dbc6a0011234',
  email: 'ana@example.test',
  email_confirmed_at: '2026-01-01T00:00:00Z',
  is_anonymous: false,
};
const ID = {
  visita: '3f6b8a1e-5c2d-4e7a-9b10-2d4c6e8f0a12',
  adulto1: '7d1c0f3a-2b4e-4a6c-8d9e-1f2a3b4c5d6e',
  adulto2: '9e8d7c6b-5a49-4382-a1b0-c9d8e7f60514',
  adulto3: 'e4d5c6b7-a8f9-4a0b-9c1d-2e3f4a5b6c7d',
  adulto4: 'f5e6d7c8-b9a0-4b1c-8d2e-3f4a5b6c7d8e',
  adulto5: '0a1b2c3d-4e5f-4a6b-9c7d-8e9f0a1b2c3d',
  participante1: 'b1a2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
  participante2: 'c2b3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e',
  participante3: 'd3c4e5f6-a7b8-4c9d-8e1f-2a3b4c5d6e7f',
  participante4: 'e4d5f6a7-b8c9-4d0e-9f2a-3b4c5d6e7f80',
  solicitud: '1b2c3d4e-5f6a-4b7c-8d8e-9f0a1b2c3d4e',
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const rpcError = (code, message = 'detalle privado del proveedor') =>
  json({ code, message, details: 'private_details', hint: 'private_hint' }, 400);

const visita = (extra = {}) => ({
  visita_id: ID.visita,
  fecha: '2026-11-10',
  hora_programada: '10:00',
  estado: 'programada',
  origen: 'interna',
  adultos: [{ envejeciente_id: ID.adulto1, nombres: 'Ana', apellidos: 'Mayor' }],
  participantes: [],
  ...extra,
});

/** Aplicación completa con el gateway real; las RPC de visitas se resuelven con `rpc[nombre](parametros)`. */
function setup({
  rol = 'coordinador',
  tipo = 'organizacion',
  accesoOperativo = true,
  permisos = permisosDe(rol, tipo),
  rpc = {},
} = {}) {
  const llamadas = [];
  const fetch = vi.fn(async (url, init = {}) => {
    const u = String(url);
    if (u.endsWith('/auth/v1/user')) return json(actor);
    const nombre = u.split('/rpc/')[1];
    const cuerpo = init.body ? JSON.parse(init.body) : {};
    llamadas.push({ nombre, cuerpo });
    if (nombre === 'api_sesion') return json({ vigente: true });
    if (nombre === 'api_mi_perfil') {
      return json({ usuario_id: actor.id, nombres: 'Ana', apellidos: 'Pérez', estado: 'activo' });
    }
    if (nombre === 'api_contexto_cuenta') {
      return json({
        cuenta_id: 7,
        tipo,
        rol,
        membresia_id: 11,
        permisos,
        es_titular: false,
        acceso_operativo: accesoOperativo,
        suscripcion_estado: 'activa',
        funcionalidades: [],
      });
    }
    const manejador = rpc[nombre];
    if (!manejador) return json({ code: 'PGRST202', message: 'sin definir' }, 404);
    const salida = manejador(cuerpo);
    return salida instanceof Response ? salida : json(salida);
  });
  const audit = vi.fn();
  const app = createApp({
    env: { origins: [] },
    gateway: createSupabaseGateway(env, fetch),
    audit,
  });
  const rpcLlamadas = (nombre) => llamadas.filter((l) => l.nombre === nombre);
  const api = (metodo, ruta) =>
    request(app)[metodo](`/api/v1/cuentas/7${ruta}`).auth('token', { type: 'bearer' });
  return { app, api, audit, llamadas, rpcLlamadas };
}

describe('GET /visitas: historial paginado con el alcance del usuario', () => {
  it('traduce paginación, orden y filtros a la RPC y devuelve metadatos', async () => {
    const { api, rpcLlamadas } = setup({
      rol: 'cuidador',
      rpc: { api_listar_visitas: () => ({ total: 11, items: [visita(), visita()] }) },
    });
    const res = await api('get', '/visitas')
      .query(
        'page=2&limit=5&sort=-fecha&filter[estado]=programada&filter[desde]=2026-11-01' +
          `&filter[envejeciente_id]=${ID.adulto1}`,
      )
      .expect(200);
    expect(res.body.meta).toEqual({ page: 2, limit: 5, total: 11, totalPages: 3 });
    expect(res.body.data).toHaveLength(2);
    expect(rpcLlamadas('api_listar_visitas')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_filtros: { estado: 'programada', desde: '2026-11-01', envejeciente_id: ID.adulto1 },
      p_orden: [
        { campo: 'fecha', direccion: 'desc' },
        { campo: 'visita_id', direccion: 'asc' },
      ],
      p_limite: 5,
      p_desplazamiento: 5,
    });
  });
  it('el orden predeterminado es fecha y hora descendentes con desempate estable', async () => {
    const { api, rpcLlamadas } = setup({
      rpc: { api_listar_visitas: () => ({ total: 0, items: [] }) },
    });
    await api('get', '/visitas').expect(200);
    expect(rpcLlamadas('api_listar_visitas')[0].cuerpo.p_orden).toEqual([
      { campo: 'fecha', direccion: 'desc' },
      { campo: 'hora_programada', direccion: 'desc' },
      { campo: 'visita_id', direccion: 'asc' },
    ]);
  });
  it.each([
    'filter[estado]=borrada',
    'filter[cuenta_id]=9',
    'filter[envejeciente_id]=no-es-uuid',
    'filter[desde]=ayer',
    'sort=razon',
    'sort=fecha;drop',
    'limit=101',
    'page=0',
    'cuenta_id=9',
    'filter[estado]=programada&filter[estado]=completada',
  ])('rechaza la consulta %s sin llamar a la base', async (consulta) => {
    const { api, rpcLlamadas } = setup();
    await api('get', '/visitas').query(consulta).expect(422);
    expect(rpcLlamadas('api_listar_visitas')).toHaveLength(0);
  });
  it('un contrato roto de la base es indisponibilidad, no un listado inventado', async () => {
    const { api } = setup({ rpc: { api_listar_visitas: () => ({ items: 'nada' }) } });
    await api('get', '/visitas').expect(503);
  });
  it('con la cuenta vencida se bloquea el módulo operativo (D07)', async () => {
    const { api, rpcLlamadas } = setup({ accesoOperativo: false });
    const res = await api('get', '/visitas').expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    expect(rpcLlamadas('api_listar_visitas')).toHaveLength(0);
  });
  it('exige sesión', async () => {
    await request(setup().app).get('/api/v1/cuentas/7/visitas').expect(401);
  });
});

describe('GET /visitas/:visitaId', () => {
  it('devuelve el detalle que arma la RPC según el alcance', async () => {
    const { api, rpcLlamadas } = setup({
      rol: 'familiar',
      rpc: { api_obtener_visita: () => visita() },
    });
    const res = await api('get', `/visitas/${ID.visita}`).expect(200);
    expect(res.body.data.visita_id).toBe(ID.visita);
    expect(rpcLlamadas('api_obtener_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_visita_id: ID.visita,
    });
  });
  it.each(['realizada', '123', 'no-es-uuid', '3f6b8a1e'])(
    'el id %s no es una visita: 404 sin consultar la base',
    async (id) => {
      const { api, rpcLlamadas } = setup();
      await api('get', `/visitas/${id}`).expect(404);
      expect(rpcLlamadas('api_obtener_visita')).toHaveLength(0);
    },
  );
  it('una visita de otra cuenta o inexistente responde igual: 404', async () => {
    const { api } = setup({ rpc: { api_obtener_visita: () => rpcError('P0002') } });
    const res = await api('get', `/visitas/${ID.visita}`).expect(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
    expect(JSON.stringify(res.body)).not.toContain('private');
  });
});

describe('POST /visitas: programar y autorizar', () => {
  const cuerpo = (extra = {}) => ({
    fecha: '2026-11-10',
    hora_programada: '10:00',
    razon: 'Control mensual',
    envejeciente_ids: [ID.adulto1, ID.adulto2],
    participante_ids: [ID.participante1],
    ...extra,
  });
  it('un usuario principal programa: 201 y la RPC recibe solo el cuerpo validado', async () => {
    const { api, rpcLlamadas, audit } = setup({
      rpc: { api_programar_visita: () => visita({ estado: 'programada' }) },
    });
    const res = await api('post', '/visitas')
      .send(cuerpo({ notas: null }))
      .expect(201);
    expect(res.body.data.estado).toBe('programada');
    expect(rpcLlamadas('api_programar_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_datos: cuerpo(),
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({
        action: 'visita.programada',
        actorId: actor.id,
        result: 'success',
      }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('Control mensual');
  });
  it('programar equivale a autorizar: con visitas:programar pero sin visitas:autorizar no se programa', async () => {
    const { api, rpcLlamadas } = setup({ permisos: ['visitas:ver', 'visitas:programar'] });
    await api('post', '/visitas').send(cuerpo()).expect(403);
    expect(rpcLlamadas('api_programar_visita')).toHaveLength(0);
  });
  it('el administrador de una Organización también programa (autoriza)', async () => {
    const { api } = setup({
      rol: 'administrador',
      rpc: { api_programar_visita: () => visita() },
    });
    await api('post', '/visitas').send(cuerpo()).expect(201);
  });
  it.each([
    ['cuidador', 'organizacion'],
    ['voluntario', 'organizacion'],
    ['familiar', 'organizacion'],
    ['cuidador', 'familia'],
    ['familiar', 'familia'],
  ])('%s en %s no programa: 403 sin llamar a la base', async (rol, tipo) => {
    const { api, rpcLlamadas } = setup({ rol, tipo });
    const res = await api('post', '/visitas').send(cuerpo()).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
    expect(rpcLlamadas('api_programar_visita')).toHaveLength(0);
  });
  it.each([
    ['campo desconocido', { cuenta_id: 8 }],
    ['actor enviado por el cliente', { autorizada_por: ID.participante1 }],
    ['sin adultos', { envejeciente_ids: [] }],
    [
      'más de cuatro adultos',
      { envejeciente_ids: [ID.adulto1, ID.adulto2, ID.adulto3, ID.adulto4, ID.adulto5] },
    ],
    ['adultos repetidos', { envejeciente_ids: [ID.adulto1, ID.adulto1] }],
    ['sin participantes', { participante_ids: [] }],
    [
      'más de tres participantes',
      {
        participante_ids: [ID.participante1, ID.participante2, ID.participante3, ID.participante4],
      },
    ],
    ['participantes repetidos', { participante_ids: [ID.participante1, ID.participante1] }],
    ['adulto no uuid', { envejeciente_ids: ['1'] }],
    ['fecha inválida', { fecha: '2026-02-30' }],
    ['hora inválida', { hora_programada: '25:00' }],
    ['motivo corto', { razon: 'ab' }],
    ['motivo largo', { razon: 'x'.repeat(121) }],
    ['notas largas', { notas: 'x'.repeat(301) }],
  ])('rechaza %s con 422', async (_caso, extra) => {
    const { api, rpcLlamadas } = setup();
    await api('post', '/visitas').send(cuerpo(extra)).expect(422);
    expect(rpcLlamadas('api_programar_visita')).toHaveLength(0);
  });
  it.each([
    ['CR_PARTICIPANTE_INVALIDO', 422, 'INVALID_PARTICIPANT'],
    ['CR_PARTICIPANTE_OCUPADO', 409, 'PARTICIPANT_BUSY'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
    ['CR_CUENTA_SIN_ACCESO', 403, 'SUBSCRIPTION_INACTIVE'],
  ])('%s se traduce a %i %s sin texto del proveedor', async (codigo, estado, publico) => {
    const { api } = setup({ rpc: { api_programar_visita: () => rpcError('P0001', codigo) } });
    const res = await api('post', '/visitas').send(cuerpo()).expect(estado);
    expect(res.body.error.code).toBe(publico);
    expect(JSON.stringify(res.body)).not.toContain('private');
  });
  it('un adulto de otra cuenta o inexistente (42501) responde 403 sin distinguirlos', async () => {
    const { api } = setup({ rpc: { api_programar_visita: () => rpcError('42501') } });
    const res = await api('post', '/visitas').send(cuerpo()).expect(403);
    expect(res.body.error.code).toBe('FORBIDDEN');
  });
});

describe('POST /visitas/:visitaId/iniciar', () => {
  it('el participante inicia la visita', async () => {
    const { api, rpcLlamadas, audit } = setup({
      rol: 'voluntario',
      rpc: { api_iniciar_visita: () => visita({ estado: 'en_curso' }) },
    });
    const res = await api('post', `/visitas/${ID.visita}/iniciar`).expect(200);
    expect(res.body.data.estado).toBe('en_curso');
    expect(rpcLlamadas('api_iniciar_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_visita_id: ID.visita,
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'visita.iniciada' }));
  });
  it.each([
    ['familiar', 'organizacion'],
    ['administrador', 'organizacion'],
  ])('%s (%s) no tiene visitas:registrar: 403', async (rol, tipo) => {
    const { api, rpcLlamadas } = setup({ rol, tipo });
    await api('post', `/visitas/${ID.visita}/iniciar`).expect(403);
    expect(rpcLlamadas('api_iniciar_visita')).toHaveLength(0);
  });
  it.each([
    ['CR_NO_PARTICIPA', 403, 'NOT_PARTICIPANT'],
    ['CR_VISITA_CERRADA', 409, 'VISIT_CLOSED'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
  ])('%s → %i %s', async (codigo, estado, publico) => {
    const { api } = setup({
      rol: 'cuidador',
      rpc: { api_iniciar_visita: () => rpcError('P0001', codigo) },
    });
    const res = await api('post', `/visitas/${ID.visita}/iniciar`).expect(estado);
    expect(res.body.error.code).toBe(publico);
  });
  it('una visita ajena o fuera de alcance (P0002) responde 404', async () => {
    const { api } = setup({
      rol: 'cuidador',
      rpc: { api_iniciar_visita: () => rpcError('P0002') },
    });
    await api('post', `/visitas/${ID.visita}/iniciar`).expect(404);
  });
  it('no acepta un cuerpo con datos ni un id inválido', async () => {
    const { api, rpcLlamadas } = setup();
    await api('post', `/visitas/${ID.visita}/iniciar`).send({ estado: 'completada' }).expect(422);
    await api('post', '/visitas/xyz/iniciar').expect(404);
    expect(rpcLlamadas('api_iniciar_visita')).toHaveLength(0);
  });
});

describe('POST /visitas/:visitaId/registrar: realización', () => {
  const detalle = (extra = {}) => ({
    envejeciente_id: ID.adulto1,
    estado_general: 'estable',
    observacion: 'Se encuentra bien y colabora.',
    ...extra,
  });
  it('registra la visita completa y la deja completada', async () => {
    const { api, rpcLlamadas, audit } = setup({
      rol: 'cuidador',
      rpc: { api_registrar_visita: () => visita({ estado: 'completada' }) },
    });
    const cuerpo = {
      detalles: [detalle()],
      checklist: ['alimentacion', 'higiene'],
      hora_inicio: '10:05',
      hora_fin: '10:50',
    };
    const res = await api('post', `/visitas/${ID.visita}/registrar`).send(cuerpo).expect(200);
    expect(res.body.data.estado).toBe('completada');
    expect(rpcLlamadas('api_registrar_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_visita_id: ID.visita,
      p_datos: cuerpo,
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'visita.registrada' }));
    expect(JSON.stringify(audit.mock.calls)).not.toContain('colabora');
  });
  it('registro mínimo del Voluntario: sin estado general ni checklist (los nulos no viajan)', async () => {
    const { api, rpcLlamadas } = setup({
      rol: 'voluntario',
      rpc: { api_registrar_visita: () => visita({ estado: 'completada' }) },
    });
    await api('post', `/visitas/${ID.visita}/registrar`)
      .send({
        detalles: [
          { envejeciente_id: ID.adulto1, estado_general: null, observacion: 'Todo bien.' },
        ],
        checklist: null,
      })
      .expect(200);
    expect(rpcLlamadas('api_registrar_visita')[0].cuerpo.p_datos).toEqual({
      detalles: [{ envejeciente_id: ID.adulto1, observacion: 'Todo bien.' }],
    });
  });
  it.each([
    ['sin detalles', {}],
    ['detalles vacíos', { detalles: [] }],
    [
      'más de cuatro adultos',
      { detalles: [1, 2, 3, 4, 5].map((n) => detalle({ envejeciente_id: ID[`adulto${n}`] })) },
    ],
    ['adulto repetido', { detalles: [detalle(), detalle()] }],
    ['estado general inválido', { detalles: [detalle({ estado_general: 'raro' })] }],
    ['observación corta', { detalles: [detalle({ observacion: 'ab' })] }],
    ['observación larga', { detalles: [detalle({ observacion: 'x'.repeat(1001) })] }],
    [
      'campo desconocido en el detalle',
      { detalles: [detalle({ registrado_por: ID.participante1 })] },
    ],
    ['aspecto fuera del catálogo', { detalles: [detalle()], checklist: ['inventado'] }],
    ['aspectos repetidos', { detalles: [detalle()], checklist: ['higiene', 'higiene'] }],
    ['hora inválida', { detalles: [detalle()], hora_fin: '9:70' }],
    ['campo desconocido', { detalles: [detalle()], estado: 'completada' }],
    ['actor enviado por el cliente', { detalles: [detalle()], usuario_id: ID.participante1 }],
  ])('rechaza %s con 422 sin llamar a la base', async (_caso, cuerpo) => {
    const { api, rpcLlamadas } = setup({ rol: 'cuidador' });
    await api('post', `/visitas/${ID.visita}/registrar`).send(cuerpo).expect(422);
    expect(rpcLlamadas('api_registrar_visita')).toHaveLength(0);
  });
  it.each([
    ['CR_VISITA_CERRADA', 409, 'VISIT_CLOSED'],
    ['CR_NO_PARTICIPA', 403, 'NOT_PARTICIPANT'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
  ])('%s → %i %s', async (codigo, estado, publico) => {
    const { api } = setup({
      rol: 'cuidador',
      rpc: { api_registrar_visita: () => rpcError('P0001', codigo) },
    });
    const res = await api('post', `/visitas/${ID.visita}/registrar`)
      .send({ detalles: [detalle()] })
      .expect(estado);
    expect(res.body.error.code).toBe(publico);
  });
  it('el Familiar no registra', async () => {
    const { api, rpcLlamadas } = setup({ rol: 'familiar' });
    await api('post', `/visitas/${ID.visita}/registrar`)
      .send({ detalles: [detalle()] })
      .expect(403);
    expect(rpcLlamadas('api_registrar_visita')).toHaveLength(0);
  });
});

describe('POST /visitas/realizada: visita no programada', () => {
  const cuerpo = (extra = {}) => ({
    visita_id: ID.visita,
    razon: 'Visita sin aviso previo',
    detalles: [
      { envejeciente_id: ID.adulto1, estado_general: 'estable', observacion: 'Todo en orden.' },
    ],
    ...extra,
  });
  it('201 al crear y 200 en la repetición idempotente con el mismo visita_id', async () => {
    let creada = true;
    const { api, rpcLlamadas } = setup({
      rol: 'cuidador',
      rpc: {
        api_registrar_visita_realizada: () => {
          const salida = {
            creada,
            visita: visita({ estado: 'completada', origen: 'sin_programar' }),
          };
          creada = false;
          return salida;
        },
      },
    });
    const primera = await api('post', '/visitas/realizada').send(cuerpo()).expect(201);
    expect(primera.body.data.origen).toBe('sin_programar');
    await api('post', '/visitas/realizada').send(cuerpo()).expect(200);
    expect(rpcLlamadas('api_registrar_visita_realizada')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_datos: cuerpo(),
    });
  });
  it('lo registra el personal con visitas:registrar; el Familiar y el Administrador no', async () => {
    for (const rol of ['familiar', 'administrador']) {
      const { api, rpcLlamadas } = setup({ rol });
      await api('post', '/visitas/realizada').send(cuerpo()).expect(403);
      expect(rpcLlamadas('api_registrar_visita_realizada')).toHaveLength(0);
    }
  });
  it.each([
    ['id que no es uuid', { visita_id: '123' }],
    ['fecha inválida', { fecha: '31/10/2026' }],
    ['campo desconocido', { origen: 'interna' }],
    ['sin detalles', { detalles: [] }],
  ])('rechaza %s con 422', async (_caso, extra) => {
    const { api, rpcLlamadas } = setup({ rol: 'cuidador' });
    await api('post', '/visitas/realizada').send(cuerpo(extra)).expect(422);
    expect(rpcLlamadas('api_registrar_visita_realizada')).toHaveLength(0);
  });
  it('un id ajeno o un adulto sin alcance se rechazan sin revelar detalles', async () => {
    const conflicto = setup({
      rol: 'cuidador',
      rpc: { api_registrar_visita_realizada: () => rpcError('P0001', 'CR_CONFLICTO') },
    });
    const a = await conflicto.api('post', '/visitas/realizada').send(cuerpo()).expect(409);
    expect(a.body.error.code).toBe('CONFLICT');
    const sinAlcance = setup({
      rol: 'cuidador',
      rpc: { api_registrar_visita_realizada: () => rpcError('42501') },
    });
    await sinAlcance.api('post', '/visitas/realizada').send(cuerpo()).expect(403);
  });
});

describe('POST /visitas/:visitaId/cancelar', () => {
  it('un usuario principal cancela con motivo', async () => {
    const { api, rpcLlamadas, audit } = setup({
      rpc: { api_cancelar_visita: () => visita({ estado: 'cancelada' }) },
    });
    const res = await api('post', `/visitas/${ID.visita}/cancelar`)
      .send({ motivo: 'El adulto está hospitalizado.' })
      .expect(200);
    expect(res.body.data.estado).toBe('cancelada');
    expect(rpcLlamadas('api_cancelar_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_visita_id: ID.visita,
      p_motivo: 'El adulto está hospitalizado.',
    });
    expect(audit).toHaveBeenCalledWith(expect.objectContaining({ action: 'visita.cancelada' }));
    expect(JSON.stringify(audit.mock.calls)).not.toContain('hospitalizado');
  });
  it.each(['cuidador', 'voluntario', 'familiar'])('%s no cancela: 403', async (rol) => {
    const { api, rpcLlamadas } = setup({ rol });
    await api('post', `/visitas/${ID.visita}/cancelar`)
      .send({ motivo: 'Motivo válido.' })
      .expect(403);
    expect(rpcLlamadas('api_cancelar_visita')).toHaveLength(0);
  });
  it.each([{}, { motivo: 'ab' }, { motivo: 'x'.repeat(301) }, { motivo: 'ok ok', estado: 'x' }])(
    'rechaza el cuerpo %j con 422',
    async (cuerpo) => {
      const { api, rpcLlamadas } = setup();
      await api('post', `/visitas/${ID.visita}/cancelar`).send(cuerpo).expect(422);
      expect(rpcLlamadas('api_cancelar_visita')).toHaveLength(0);
    },
  );
  it('una visita completada o ya cancelada responde 409 VISIT_CLOSED', async () => {
    const { api } = setup({
      rpc: { api_cancelar_visita: () => rpcError('P0001', 'CR_VISITA_CERRADA') },
    });
    const res = await api('post', `/visitas/${ID.visita}/cancelar`)
      .send({ motivo: 'Motivo válido.' })
      .expect(409);
    expect(res.body.error.code).toBe('VISIT_CLOSED');
  });
});

describe('solicitudes de visita de personas externas (gestión)', () => {
  const solicitud = (extra = {}) => ({
    solicitud_visita_id: ID.solicitud,
    estado: 'pendiente',
    visitante: {
      nombres: 'Juan',
      apellidos: 'Pérez',
      cedula: '00112345678',
      telefono: '8095550100',
    },
    ...extra,
  });
  it('quien autoriza lista las solicitudes con paginación y filtro por estado', async () => {
    const { api, rpcLlamadas } = setup({
      rpc: { api_listar_solicitudes_visita: () => ({ total: 1, items: [solicitud()] }) },
    });
    const res = await api('get', '/solicitudes-visita')
      .query('filter[estado]=pendiente&sort=fecha_propuesta')
      .expect(200);
    expect(res.body.meta.total).toBe(1);
    expect(res.body.data[0].visitante.cedula).toBe('00112345678');
    expect(rpcLlamadas('api_listar_solicitudes_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_filtros: { estado: 'pendiente' },
      p_orden: [
        { campo: 'fecha_propuesta', direccion: 'asc' },
        { campo: 'solicitud_visita_id', direccion: 'asc' },
      ],
      p_limite: 20,
      p_desplazamiento: 0,
    });
  });
  it.each(['cuidador', 'voluntario', 'familiar'])(
    '%s no ve los datos del visitante: 403 sin llamar a la base',
    async (rol) => {
      const { api, rpcLlamadas } = setup({ rol });
      await api('get', '/solicitudes-visita').expect(403);
      await api('post', `/solicitudes-visita/${ID.solicitud}/rechazar`)
        .send({ motivo: 'No procede.' })
        .expect(403);
      expect(rpcLlamadas('api_listar_solicitudes_visita')).toHaveLength(0);
      expect(rpcLlamadas('api_rechazar_solicitud_visita')).toHaveLength(0);
    },
  );
  it('autorizar crea la visita: 201 con el adulto, fecha y hora confirmados', async () => {
    const { api, rpcLlamadas, audit } = setup({
      rpc: { api_autorizar_solicitud_visita: () => visita({ origen: 'solicitud' }) },
    });
    const cuerpo = { envejeciente_id: ID.adulto1, fecha: '2026-11-12', hora: '15:30' };
    const res = await api('post', `/solicitudes-visita/${ID.solicitud}/autorizar`)
      .send(cuerpo)
      .expect(201);
    expect(res.body.data.origen).toBe('solicitud');
    expect(rpcLlamadas('api_autorizar_solicitud_visita')[0].cuerpo).toEqual({
      p_cuenta_id: 7,
      p_solicitud_id: ID.solicitud,
      p_datos: cuerpo,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'solicitud_visita.autorizada', actorId: actor.id }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('00112345678');
  });
  it.each([
    [{ fecha: '2026-11-12', hora: '15:30' }],
    [{ envejeciente_id: ID.adulto1, fecha: '2026-11-12' }],
    [{ envejeciente_id: ID.adulto1, fecha: '2026-11-12', hora: '15:30', estado: 'autorizada' }],
    [{ envejeciente_id: 'abc', fecha: '2026-11-12', hora: '15:30' }],
    [{ envejeciente_id: ID.adulto1, fecha: '2026-11-12', hora: '15:30', visitante: 'otro' }],
  ])('autorizar rechaza el cuerpo %j con 422', async (cuerpo) => {
    const { api, rpcLlamadas } = setup();
    await api('post', `/solicitudes-visita/${ID.solicitud}/autorizar`).send(cuerpo).expect(422);
    expect(rpcLlamadas('api_autorizar_solicitud_visita')).toHaveLength(0);
  });
  it('rechazar exige un motivo y devuelve la solicitud', async () => {
    const { api, rpcLlamadas } = setup({
      rpc: { api_rechazar_solicitud_visita: () => solicitud({ estado: 'rechazada' }) },
    });
    await api('post', `/solicitudes-visita/${ID.solicitud}/rechazar`)
      .send({ motivo: 'ab' })
      .expect(422);
    const res = await api('post', `/solicitudes-visita/${ID.solicitud}/rechazar`)
      .send({ motivo: 'No hay horario disponible.' })
      .expect(200);
    expect(res.body.data.estado).toBe('rechazada');
    expect(rpcLlamadas('api_rechazar_solicitud_visita')).toHaveLength(1);
  });
  it.each([
    ['CR_SOLICITUD_REVISADA', 409, 'REQUEST_ALREADY_REVIEWED'],
    ['CR_ESTADO_INVALIDO', 409, 'INVALID_STATE'],
  ])('%s → %i %s', async (codigo, estado, publico) => {
    const { api } = setup({
      rpc: { api_autorizar_solicitud_visita: () => rpcError('P0001', codigo) },
    });
    const res = await api('post', `/solicitudes-visita/${ID.solicitud}/autorizar`)
      .send({ envejeciente_id: ID.adulto1, fecha: '2026-11-12', hora: '15:30' })
      .expect(estado);
    expect(res.body.error.code).toBe(publico);
  });
  it('una solicitud de otra cuenta o inexistente responde 404; un id inválido ni consulta', async () => {
    const { api, rpcLlamadas } = setup({
      rpc: { api_rechazar_solicitud_visita: () => rpcError('P0002') },
    });
    await api('post', `/solicitudes-visita/${ID.solicitud}/rechazar`)
      .send({ motivo: 'No procede.' })
      .expect(404);
    await api('post', '/solicitudes-visita/1/rechazar').send({ motivo: 'No procede.' }).expect(404);
    expect(rpcLlamadas('api_rechazar_solicitud_visita')).toHaveLength(1);
  });
});

describe('contrato HTTP general', () => {
  it('solo GET, POST y PATCH: no existen PUT ni DELETE sobre visitas', async () => {
    const { api } = setup();
    await api('put', `/visitas/${ID.visita}`).send({}).expect(404);
    await api('delete', `/visitas/${ID.visita}`).expect(404);
    await api('patch', `/visitas/${ID.visita}`).send({}).expect(404);
  });
  it.each([
    ['28000', 401, 'UNAUTHORIZED'],
    ['42501', 403, 'FORBIDDEN'],
    ['P0002', 404, 'NOT_FOUND'],
    ['22023', 422, 'INVALID_INPUT'],
    ['23514', 422, 'INVALID_INPUT'],
    ['XX000', 503, 'DEPENDENCY_UNAVAILABLE'],
  ])(
    'el error de RPC %s llega como %i %s sin datos del proveedor',
    async (sqlstate, estado, codigo) => {
      const { api, audit } = setup({ rpc: { api_listar_visitas: () => rpcError(sqlstate) } });
      const res = await api('get', '/visitas').expect(estado);
      expect(res.body.error.code).toBe(codigo);
      expect(res.body.requestId).toBe(res.headers['x-request-id']);
      for (const marcador of ['private_details', 'private_hint', 'detalle privado']) {
        expect(JSON.stringify(res.body)).not.toContain(marcador);
        expect(JSON.stringify(audit.mock.calls)).not.toContain(marcador);
      }
    },
  );
  it('un código CR_* no registrado nunca llega al cliente', async () => {
    const { api } = setup({ rpc: { api_listar_visitas: () => rpcError('P0001', 'CR_INVENTADO') } });
    const res = await api('get', '/visitas').expect(503);
    expect(JSON.stringify(res.body)).not.toContain('CR_INVENTADO');
  });
});
