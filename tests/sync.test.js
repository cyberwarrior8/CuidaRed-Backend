/* Pruebas API de la sincronización de visitas sin conexión · ID04/RF-10 (RNF-4.2), gateway real con transporte simulado. © 2026 Equipo CuidaRed – INTEC. */
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
  visita2: '4a7c9b2f-6d3e-4f8b-8c21-3e5d7f9a1b23',
  adulto1: '7d1c0f3a-2b4e-4a6c-8d9e-1f2a3b4c5d6e',
  adulto2: '9e8d7c6b-5a49-4382-a1b0-c9d8e7f60514',
  op1: 'c0000000-0000-4000-8000-000000000001',
  op2: 'c0000000-0000-4000-8000-000000000002',
  op3: 'c0000000-0000-4000-8000-000000000003',
  op4: 'c0000000-0000-4000-8000-000000000004',
};
const MARCA = '2026-11-06T15:00:00.123Z';
const BASE = '2026-11-06T09:00:00.456Z';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const rpcError = (code, message = 'detalle privado del proveedor') =>
  json({ code, message, details: 'private_details', hint: 'private_hint' }, 400);

// Operaciones válidas del cliente.
const detalle = (adulto = ID.adulto1) => ({
  envejeciente_id: adulto,
  estado_general: 'estable',
  observacion: 'Se encuentra bien y colabora.',
});
const registrar = (extra = {}) => ({
  id_cliente: ID.op1,
  entidad: 'visita',
  tipo: 'registrar',
  registro_id: ID.visita,
  datos: { detalles: [detalle()], checklist: ['higiene'] },
  actualizado_en: MARCA,
  base_actualizado_en: BASE,
  ...extra,
});
const iniciar = (extra = {}) => ({
  id_cliente: ID.op2,
  entidad: 'visita',
  tipo: 'iniciar',
  registro_id: ID.visita2,
  datos: {},
  actualizado_en: MARCA,
  ...extra,
});

// Lo que devuelve la RPC (todas las claves, con nulos), tal como lo arma cuidared_interno.sync_item.
const itemRpc = (extra = {}) => ({
  id_cliente: ID.op1,
  resultado: 'aplicada',
  registro_id: ID.visita,
  motivo: null,
  gana: null,
  resultado_original: null,
  actualizado_en_servidor: '2026-11-06T16:00:00.789Z',
  ...extra,
});

/** Aplicación completa con el gateway real; las RPC de sync se resuelven con `rpc[nombre](parametros)` (puede ser asíncrona). */
function setup({
  rol = 'cuidador',
  tipo = 'organizacion',
  accesoOperativo = true,
  sinMembresia = false,
  permisos = permisosDe(rol, tipo),
  rpc = {},
} = {}) {
  const llamadas = [];
  let enCurso = 0;
  let maxConcurrentes = 0;
  const fetch = vi.fn(async (url, init = {}) => {
    const u = String(url);
    if (u.endsWith('/auth/v1/user')) return json(actor);
    const nombre = u.split('/rpc/')[1];
    const cuerpo = init.body ? JSON.parse(init.body) : {};
    if (nombre === 'api_sesion') return json({ vigente: true });
    if (nombre === 'api_mi_perfil') {
      return json({ usuario_id: actor.id, nombres: 'Ana', apellidos: 'Pérez', estado: 'activo' });
    }
    if (nombre === 'api_contexto_cuenta') {
      if (sinMembresia) return json(null);
      return json({
        cuenta_id: 7,
        tipo,
        rol,
        membresia_id: 11,
        permisos,
        es_titular: false,
        acceso_operativo: accesoOperativo,
        suscripcion_estado: accesoOperativo ? 'activa' : 'vencida',
        funcionalidades: [],
      });
    }
    llamadas.push({ nombre, cuerpo });
    const manejador = rpc[nombre];
    if (!manejador) return json({ code: 'PGRST202', message: 'sin definir' }, 404);
    enCurso += 1;
    maxConcurrentes = Math.max(maxConcurrentes, enCurso);
    try {
      await new Promise((resolve) => setTimeout(resolve, 1));
      const salida = await manejador(cuerpo);
      return salida instanceof Response ? salida : json(salida);
    } finally {
      enCurso -= 1;
    }
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
  return { app, api, audit, llamadas, rpcLlamadas, concurrentes: () => maxConcurrentes };
}

const APLICAR = 'api_sync_aplicar_operacion';
const OBTENER = 'api_sync_obtener_operacion';
const post = (s, operaciones) => s.api('post', '/sync').send({ operaciones });
const eventos = (audit) => audit.mock.calls.map(([e]) => e);

describe('POST /sync: lote de operaciones', () => {
  it('envía cada operación a su RPC con la cuenta de la ruta y devuelve un resultado por operación', async () => {
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          p_operacion.id_cliente === ID.op1
            ? itemRpc()
            : itemRpc({
                id_cliente: ID.op2,
                registro_id: ID.visita2,
                resultado: 'duplicada',
                resultado_original: 'aplicada',
                motivo: null,
              }),
      },
    });
    const res = await post(s, [registrar(), iniciar()]).expect(200);
    expect(res.body).toEqual({
      data: {
        resultados: [
          {
            id_cliente: ID.op1,
            resultado: 'aplicada',
            registro_id: ID.visita,
            actualizado_en_servidor: '2026-11-06T16:00:00.789Z',
          },
          {
            id_cliente: ID.op2,
            resultado: 'duplicada',
            registro_id: ID.visita2,
            resultado_original: 'aplicada',
            actualizado_en_servidor: '2026-11-06T16:00:00.789Z',
          },
        ],
      },
    });
    const llamadas = s.rpcLlamadas(APLICAR);
    expect(llamadas).toHaveLength(2);
    expect(llamadas[0].cuerpo).toEqual({ p_cuenta_id: '7', p_operacion: registrar() });
    // Sin base: la clave no viaja (no se envían nulos).
    expect(llamadas[1].cuerpo).toEqual({ p_cuenta_id: '7', p_operacion: iniciar() });
    expect(Object.keys(llamadas[1].cuerpo.p_operacion)).not.toContain('base_actualizado_en');
  });

  it('procesa las operaciones una tras otra y en el orden recibido', async () => {
    const orden = [];
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) => {
          orden.push(p_operacion.id_cliente);
          return itemRpc({
            id_cliente: p_operacion.id_cliente,
            registro_id: p_operacion.registro_id,
          });
        },
      },
    });
    await post(s, [
      registrar({ id_cliente: ID.op3 }),
      registrar({ id_cliente: ID.op1 }),
      registrar({ id_cliente: ID.op4 }),
    ]).expect(200);
    expect(orden).toEqual([ID.op3, ID.op1, ID.op4]);
    expect(s.concurrentes()).toBe(1);
  });

  it('traduce los cuatro resultados y devuelve solo la lista cerrada de campos', async () => {
    const respuestas = {
      [ID.op1]: itemRpc({ secreto: 'no sale', cuenta_id: 9 }),
      [ID.op2]: itemRpc({
        id_cliente: ID.op2,
        resultado: 'conflicto',
        gana: 'servidor',
        motivo: 'SERVIDOR_MAS_RECIENTE',
      }),
      [ID.op3]: itemRpc({
        id_cliente: ID.op3,
        resultado: 'conflicto',
        gana: 'local',
        actualizado_en_servidor: '2026-11-06T16:30:00.000Z',
      }),
      [ID.op4]: itemRpc({
        id_cliente: ID.op4,
        resultado: 'rechazada',
        motivo: 'FORBIDDEN',
        actualizado_en_servidor: null,
        detalle_interno: 'adulto 7d1c0f3a',
      }),
    };
    const s = setup({
      rpc: { [APLICAR]: ({ p_operacion }) => respuestas[p_operacion.id_cliente] },
    });
    const res = await post(s, [
      registrar(),
      registrar({ id_cliente: ID.op2 }),
      registrar({ id_cliente: ID.op3 }),
      registrar({ id_cliente: ID.op4 }),
    ]).expect(200);
    const [r1, r2, r3, r4] = res.body.data.resultados;
    expect(r1).toEqual({
      id_cliente: ID.op1,
      resultado: 'aplicada',
      registro_id: ID.visita,
      actualizado_en_servidor: '2026-11-06T16:00:00.789Z',
    });
    expect(r2).toMatchObject({
      resultado: 'conflicto',
      gana: 'servidor',
      motivo: 'SERVIDOR_MAS_RECIENTE',
    });
    expect(r3).toMatchObject({ resultado: 'conflicto', gana: 'local' });
    expect(r3).not.toHaveProperty('motivo');
    // El rechazo no revela nada: sin versión del servidor y sin campos que la base no declara.
    expect(r4).toEqual({
      id_cliente: ID.op4,
      resultado: 'rechazada',
      registro_id: ID.visita,
      motivo: 'FORBIDDEN',
      actualizado_en_servidor: null,
    });
    expect(JSON.stringify(res.body)).not.toMatch(/secreto|cuenta_id|detalle_interno/);
  });

  it('una operación rechazada no detiene las siguientes', async () => {
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          p_operacion.id_cliente === ID.op1
            ? itemRpc({
                resultado: 'rechazada',
                motivo: 'FORBIDDEN',
                actualizado_en_servidor: null,
              })
            : itemRpc({ id_cliente: p_operacion.id_cliente }),
      },
    });
    const res = await post(s, [registrar(), registrar({ id_cliente: ID.op2 })]).expect(200);
    expect(res.body.data.resultados.map((r) => r.resultado)).toEqual(['rechazada', 'aplicada']);
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(2);
  });

  it('acepta un lote de 25 operaciones, una RPC por operación, y rechaza 26 sin tocar la base', async () => {
    const lote = (n) =>
      Array.from({ length: n }, (_, i) =>
        registrar({
          id_cliente: `c0000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`,
          datos: { detalles: [detalle()] },
        }),
      );
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          itemRpc({ id_cliente: p_operacion.id_cliente, registro_id: p_operacion.registro_id }),
      },
    });
    const res = await post(s, lote(25)).expect(200);
    expect(res.body.data.resultados).toHaveLength(25);
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(25);
    const otro = setup();
    await post(otro, lote(26)).expect(422);
    expect(otro.rpcLlamadas(APLICAR)).toHaveLength(0);
  });

  it('reenvía la misma clave dos veces en un mismo lote: la base resuelve la repetida', async () => {
    const vistas = new Set();
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) => {
          const repetida = vistas.has(p_operacion.id_cliente);
          vistas.add(p_operacion.id_cliente);
          return itemRpc(
            repetida ? { resultado: 'duplicada', resultado_original: 'aplicada' } : {},
          );
        },
      },
    });
    const res = await post(s, [registrar(), registrar()]).expect(200);
    expect(res.body.data.resultados.map((r) => r.resultado)).toEqual(['aplicada', 'duplicada']);
  });

  it('entidad o tipo no soportados: el contenido no se envía a la base y la base los rechaza por operación', async () => {
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          itemRpc({
            id_cliente: p_operacion.id_cliente,
            resultado: 'rechazada',
            motivo: p_operacion.entidad === 'visita' ? 'TIPO_NO_SOPORTADO' : 'ENTIDAD_NO_SOPORTADA',
            actualizado_en_servidor: null,
          }),
      },
    });
    const res = await post(s, [
      registrar({
        id_cliente: ID.op1,
        entidad: 'necesidad',
        tipo: 'crear',
        datos: { descripcion: 'dato sensible', cualquier: ['cosa'] },
      }),
      registrar({ id_cliente: ID.op2, tipo: 'borrar', datos: { observacion: 'dato sensible' } }),
    ]).expect(200);
    expect(res.body.data.resultados.map((r) => r.motivo)).toEqual([
      'ENTIDAD_NO_SOPORTADA',
      'TIPO_NO_SOPORTADO',
    ]);
    for (const { cuerpo } of s.rpcLlamadas(APLICAR)) expect(cuerpo.p_operacion.datos).toEqual({});
  });

  it('un nombre como «constructor» no se confunde con una entidad ni un tipo soportados', async () => {
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          itemRpc({ id_cliente: p_operacion.id_cliente, resultado: 'rechazada', motivo: 'X' }),
      },
    });
    await post(s, [
      registrar({ entidad: 'constructor' }),
      registrar({ id_cliente: ID.op2, tipo: 'constructor' }),
    ]).expect(200);
    const llamadas = s.rpcLlamadas(APLICAR);
    expect(llamadas).toHaveLength(2);
    for (const { cuerpo } of llamadas) expect(cuerpo.p_operacion.datos).toEqual({});
  });
});

describe('POST /sync: validación', () => {
  it.each([
    ['sin cuerpo', undefined],
    ['sin operaciones', {}],
    ['operaciones vacías', { operaciones: [] }],
    ['operaciones no es una lista', { operaciones: registrar() }],
    ['campo extra en el sobre', { operaciones: [registrar()], usuario_id: actor.id }],
    ['cuenta en el cuerpo', { operaciones: [registrar()], cuenta_id: 9 }],
  ])('el sobre del lote inválido (%s) es 422 sin tocar la base', async (_nombre, cuerpo) => {
    const s = setup();
    const peticion = s.api('post', '/sync');
    const res = await (cuerpo === undefined ? peticion : peticion.send(cuerpo)).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
  });

  it('una operación mal formada pero identificable se responde rechazada y las demás siguen', async () => {
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          itemRpc({ id_cliente: p_operacion.id_cliente, registro_id: p_operacion.registro_id }),
      },
    });
    const res = await post(s, [
      registrar({ id_cliente: ID.op1, datos: { detalles: [] } }),
      registrar({ id_cliente: ID.op2 }),
    ]).expect(200);
    expect(res.body.data.resultados).toEqual([
      {
        id_cliente: ID.op1,
        resultado: 'rechazada',
        registro_id: ID.visita,
        motivo: 'INVALID_INPUT',
        actualizado_en_servidor: null,
      },
      expect.objectContaining({ id_cliente: ID.op2, resultado: 'aplicada' }),
    ]);
    // La mal formada no llega a la base.
    expect(s.rpcLlamadas(APLICAR).map((l) => l.cuerpo.p_operacion.id_cliente)).toEqual([ID.op2]);
  });

  it.each([
    ['un campo desconocido', { usuario_id: actor.id }],
    ['la cuenta en la operación', { cuenta_id: 9 }],
    ['registro_id que no es UUID', { registro_id: '123' }],
    ['entidad en mayúsculas', { entidad: 'Visita' }],
    ['tipo con caracteres inválidos', { tipo: 'registrar; drop table x' }],
    ['datos que no son un objeto', { datos: [] }],
    ['datos ausentes', { datos: undefined }],
    ['marca con desfase en lugar de Z', { actualizado_en: '2026-11-06T11:00:00-04:00' }],
    ['marca sin zona', { actualizado_en: '2026-11-06T15:00:00' }],
    ['marca con otro formato', { actualizado_en: '06/11/2026' }],
    ['marca con un número', { actualizado_en: 1762441200000 }],
    ['marca con un día que no existe', { actualizado_en: '2026-02-30T10:00:00Z' }],
    ['marca con una hora que no existe', { actualizado_en: '2026-11-06T24:00:00Z' }],
    ['marca ausente', { actualizado_en: undefined }],
    ['base ilegible', { base_actualizado_en: 'ayer' }],
    ['datos con un campo desconocido', { datos: { detalles: [detalle()], rol: 'admin' } }],
    [
      'datos con visita_id (es registro_id)',
      { datos: { detalles: [detalle()], visita_id: ID.visita } },
    ],
    ['datos sin detalles', { datos: { checklist: ['higiene'] } }],
    [
      'detalle con observación corta',
      { datos: { detalles: [{ ...detalle(), observacion: 'ab' }] } },
    ],
    [
      'checklist fuera del catálogo',
      { datos: { detalles: [detalle()], checklist: ['inventado'] } },
    ],
    ['fecha inválida', { datos: { detalles: [detalle()], fecha: '2026-02-30' } }],
    [
      'más de cuatro adultos',
      {
        datos: {
          detalles: [1, 2, 3, 4, 5].map((n) => detalle(`7d1c0f3a-2b4e-4a6c-8d9e-1f2a3b4c5d6${n}`)),
        },
      },
    ],
  ])('operación con %s: rechazada INVALID_INPUT, sin llegar a la base', async (_nombre, cambio) => {
    const s = setup();
    const res = await post(s, [registrar(cambio)]).expect(200);
    expect(res.body.data.resultados).toEqual([
      expect.objectContaining({
        id_cliente: ID.op1,
        resultado: 'rechazada',
        motivo: 'INVALID_INPUT',
        actualizado_en_servidor: null,
      }),
    ]);
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
  });

  it('iniciar no lleva datos: cualquier contenido es INVALID_INPUT', async () => {
    const s = setup();
    const res = await post(s, [iniciar({ datos: { observacion: 'hola' } })]).expect(200);
    expect(res.body.data.resultados[0]).toMatchObject({
      resultado: 'rechazada',
      motivo: 'INVALID_INPUT',
    });
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
  });

  it('sin id_cliente válido no hay a quién responder: 422 para todo el lote y no se aplica nada', async () => {
    const s = setup({ rpc: { [APLICAR]: () => itemRpc() } });
    const res = await post(s, [registrar(), registrar({ id_cliente: 'no-es-uuid' })]).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
    await post(s, [registrar({ id_cliente: undefined })]).expect(422);
    await post(s, ['texto']).expect(422);
    await post(s, [null]).expect(422);
    await post(s, [[registrar()]]).expect(422);
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
  });

  it('las marcas con milisegundos, sin ellos y con más precisión son válidas', async () => {
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          itemRpc({ id_cliente: p_operacion.id_cliente, registro_id: p_operacion.registro_id }),
      },
    });
    await post(s, [
      registrar({ id_cliente: ID.op1, actualizado_en: '2026-11-06T15:00:00Z' }),
      registrar({ id_cliente: ID.op2, actualizado_en: '2026-11-06T15:00:00.123456Z' }),
      registrar({ id_cliente: ID.op3, base_actualizado_en: null }),
    ]).expect(200);
    const [a, b, c] = s.rpcLlamadas(APLICAR).map((l) => l.cuerpo.p_operacion);
    expect(a.actualizado_en).toBe('2026-11-06T15:00:00Z');
    expect(b.actualizado_en).toBe('2026-11-06T15:00:00.123456Z');
    expect(c).not.toHaveProperty('base_actualizado_en');
  });

  it('los nulos opcionales de los datos no viajan a la base', async () => {
    const s = setup({ rpc: { [APLICAR]: () => itemRpc() } });
    await post(s, [
      registrar({
        datos: {
          detalles: [{ ...detalle(), estado_general: null }],
          checklist: null,
          hora_inicio: null,
        },
      }),
    ]).expect(200);
    expect(s.rpcLlamadas(APLICAR)[0].cuerpo.p_operacion.datos).toEqual({
      detalles: [{ envejeciente_id: ID.adulto1, observacion: 'Se encuentra bien y colabora.' }],
    });
  });
});

describe('POST /sync: permisos y cuenta vencida', () => {
  it.each(['administrador', 'familiar'])(
    'el rol %s no tiene sync:usar: 403 sin consultar la base',
    async (rol) => {
      const s = setup({ rol });
      const res = await post(s, [registrar()]).expect(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
      expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
    },
  );

  it.each(['coordinador', 'cuidador', 'voluntario'])('el rol %s sincroniza', async (rol) => {
    const s = setup({ rol, rpc: { [APLICAR]: () => itemRpc() } });
    await post(s, [registrar()]).expect(200);
  });

  it('en una cuenta vencida no se corta la petición: cada operación la rechaza la base con SUBSCRIPTION_INACTIVE', async () => {
    const s = setup({
      accesoOperativo: false,
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          itemRpc({
            id_cliente: p_operacion.id_cliente,
            resultado: 'rechazada',
            motivo: 'SUBSCRIPTION_INACTIVE',
            actualizado_en_servidor: null,
          }),
      },
    });
    const res = await post(s, [registrar(), registrar({ id_cliente: ID.op2 })]).expect(200);
    expect(res.body.data.resultados.map((r) => [r.resultado, r.motivo])).toEqual([
      ['rechazada', 'SUBSCRIPTION_INACTIVE'],
      ['rechazada', 'SUBSCRIPTION_INACTIVE'],
    ]);
    // La base decide y registra cada rechazo: el middleware no se adelanta.
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(2);
    expect(eventos(s.audit).filter((e) => e.action === 'sync.error')).toHaveLength(2);
  });

  it('sin sesión es 401', async () => {
    const s = setup();
    await request(s.app)
      .post('/api/v1/cuentas/7/sync')
      .send({ operaciones: [registrar()] })
      .expect(401);
  });

  it('una cuenta sin membresía del usuario, o con identificador inválido, es 404 sin consultar sync', async () => {
    const s = setup({ sinMembresia: true, rpc: { [APLICAR]: () => itemRpc() } });
    await post(s, [registrar()]).expect(404);
    await request(s.app)
      .post('/api/v1/cuentas/abc/sync')
      .auth('token', { type: 'bearer' })
      .send({ operaciones: [registrar()] })
      .expect(404);
    expect(s.rpcLlamadas(APLICAR)).toHaveLength(0);
  });
});

describe('POST /sync: errores de la base', () => {
  it.each([
    ['28000', 401, 'UNAUTHORIZED'],
    ['42501', 403, 'FORBIDDEN'],
    ['22023', 422, 'INVALID_INPUT'],
    ['PGRST202', 503, 'DEPENDENCY_UNAVAILABLE'],
    ['XX000', 503, 'DEPENDENCY_UNAVAILABLE'],
  ])(
    'el error %s de la RPC interrumpe el lote como %s sin exponer detalles',
    async (codigo, estado, publico) => {
      const s = setup({ rpc: { [APLICAR]: () => rpcError(codigo) } });
      const res = await post(s, [registrar(), registrar({ id_cliente: ID.op2 })]).expect(estado);
      expect(res.body.error.code).toBe(publico);
      expect(JSON.stringify(res.body)).not.toMatch(/private|detalle privado/);
      // Se corta el lote en la primera falla: nada se inventa para el resto.
      expect(s.rpcLlamadas(APLICAR)).toHaveLength(1);
    },
  );

  it('si la base falla a mitad del lote, lo ya resuelto queda auditado y el lote se interrumpe', async () => {
    let n = 0;
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) => {
          n += 1;
          return n === 1 ? itemRpc({ id_cliente: p_operacion.id_cliente }) : rpcError('PGRST202');
        },
      },
    });
    await post(s, [registrar(), registrar({ id_cliente: ID.op2 })]).expect(503);
    expect(eventos(s.audit).filter((e) => e.action === 'sync.registro')).toHaveLength(1);
  });

  it.each([
    ['una respuesta que no es un objeto', 'texto'],
    ['una respuesta vacía', null],
    ['un resultado desconocido', itemRpc({ resultado: 'quiza' })],
    ['una respuesta sin resultado', { id_cliente: ID.op1, registro_id: ID.visita }],
    ['una respuesta sin id_cliente', { resultado: 'aplicada', registro_id: ID.visita }],
  ])(
    '%s de la RPC es indisponibilidad (503), nunca un resultado inventado',
    async (_nombre, salida) => {
      const s = setup({ rpc: { [APLICAR]: () => salida } });
      const res = await post(s, [registrar()]).expect(503);
      expect(res.body.error.code).toBe('DEPENDENCY_UNAVAILABLE');
    },
  );
});

describe('POST /sync: auditoría', () => {
  it('registra sync.registro, sync.conflicto y sync.error; los reintentos (duplicada) no repiten la auditoría', async () => {
    const respuestas = {
      [ID.op1]: itemRpc(),
      [ID.op2]: itemRpc({ id_cliente: ID.op2, resultado: 'conflicto', gana: 'servidor' }),
      [ID.op3]: itemRpc({ id_cliente: ID.op3, resultado: 'conflicto', gana: 'local' }),
      [ID.op4]: itemRpc({ id_cliente: ID.op4, resultado: 'rechazada', motivo: 'FORBIDDEN' }),
    };
    const s = setup({
      rpc: {
        [APLICAR]: ({ p_operacion }) =>
          p_operacion.id_cliente in respuestas
            ? respuestas[p_operacion.id_cliente]
            : itemRpc({ resultado: 'duplicada', resultado_original: 'aplicada' }),
      },
    });
    await post(s, [
      registrar(),
      registrar({ id_cliente: ID.op2 }),
      registrar({ id_cliente: ID.op3 }),
      registrar({ id_cliente: ID.op4 }),
      registrar({ id_cliente: 'c0000000-0000-4000-8000-000000000009' }),
      registrar({ id_cliente: ID.op1, datos: { detalles: [] } }),
    ]).expect(200);
    const sync = eventos(s.audit).filter((e) => e.action.startsWith('sync.'));
    expect(sync.map((e) => [e.action, e.result, e.code])).toEqual([
      ['sync.registro', 'success', undefined],
      ['sync.conflicto', 'success', 'SERVER_WINS'],
      ['sync.conflicto', 'success', 'LOCAL_WINS'],
      ['sync.error', 'denied', 'FORBIDDEN'],
      // La operación mal formada también es un error auditado.
      ['sync.error', 'denied', 'INVALID_INPUT'],
    ]);
    for (const e of sync) {
      expect(e.actorId).toBe(actor.id);
      expect(e.requestId).toEqual(expect.any(String));
    }
  });

  it('la auditoría no lleva contenido: ni observaciones, ni adultos, ni identificadores de operación', async () => {
    const s = setup({ rpc: { [APLICAR]: () => itemRpc() } });
    await post(s, [
      registrar({
        datos: {
          detalles: [{ ...detalle(), observacion: 'Presenta mareos y confusión severa.' }],
        },
      }),
    ]).expect(200);
    const texto = JSON.stringify(s.audit.mock.calls);
    expect(texto).not.toMatch(/mareos|confusi|7d1c0f3a|c0000000|3f6b8a1e/);
  });
});

describe('GET /sync/:idCliente: resultado de una operación propia', () => {
  const guardado = {
    ...itemRpc(),
    entidad: 'visita',
    tipo: 'registrar',
    procesada_en: '2026-11-06T16:00:01.000Z',
  };

  it('devuelve el resultado guardado de la operación', async () => {
    const s = setup({ rpc: { [OBTENER]: () => guardado } });
    const res = await s.api('get', `/sync/${ID.op1}`).expect(200);
    expect(res.body).toEqual({
      data: {
        id_cliente: ID.op1,
        resultado: 'aplicada',
        registro_id: ID.visita,
        actualizado_en_servidor: '2026-11-06T16:00:00.789Z',
        entidad: 'visita',
        tipo: 'registrar',
        procesada_en: '2026-11-06T16:00:01.000Z',
      },
    });
    expect(s.rpcLlamadas(OBTENER)[0].cuerpo).toEqual({ p_cuenta_id: '7', p_id_cliente: ID.op1 });
  });

  it('un identificador que no es UUID es 404 sin consultar la base', async () => {
    const s = setup({ rpc: { [OBTENER]: () => guardado } });
    await s.api('get', '/sync/no-es-uuid').expect(404);
    await s.api('get', '/sync/123').expect(404);
    expect(s.rpcLlamadas(OBTENER)).toHaveLength(0);
  });

  it('una operación ajena, de otra cuenta o inexistente es el mismo 404', async () => {
    const s = setup({ rpc: { [OBTENER]: () => rpcError('P0002') } });
    const res = await s.api('get', `/sync/${ID.op3}`).expect(404);
    expect(res.body.error.code).toBe('NOT_FOUND');
    expect(JSON.stringify(res.body)).not.toMatch(/private/);
  });

  it.each(['administrador', 'familiar'])('el rol %s no tiene sync:usar: 403', async (rol) => {
    const s = setup({ rol, rpc: { [OBTENER]: () => guardado } });
    await s.api('get', `/sync/${ID.op1}`).expect(403);
    expect(s.rpcLlamadas(OBTENER)).toHaveLength(0);
  });

  it('la lectura es operativa: en una cuenta vencida es 403 SUBSCRIPTION_INACTIVE', async () => {
    const s = setup({ accesoOperativo: false, rpc: { [OBTENER]: () => guardado } });
    const res = await s.api('get', `/sync/${ID.op1}`).expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
    expect(s.rpcLlamadas(OBTENER)).toHaveLength(0);
  });

  it('una respuesta de la base sin entidad o tipo es indisponibilidad', async () => {
    const s = setup({ rpc: { [OBTENER]: () => itemRpc() } });
    await s.api('get', `/sync/${ID.op1}`).expect(503);
  });
});

describe('Tamaño del cuerpo en /sync', () => {
  it('admite lotes de más de 16 kB solo en /sync y conserva el límite de 256 kB', async () => {
    const s = setup({ rpc: { [APLICAR]: () => itemRpc() } });
    const relleno = 'x'.repeat(40 * 1024);
    const grande = await s.api('post', '/sync').send({ operaciones: [registrar()], relleno });
    expect(grande.status).not.toBe(413);
    await s.api('patch', '').send({ nombre: relleno }).expect(413);
    await s
      .api('post', '/sync')
      .send({ operaciones: [registrar()], relleno: 'x'.repeat(300 * 1024) })
      .expect(413);
  });
});
