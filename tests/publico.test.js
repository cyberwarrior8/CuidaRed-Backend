/* Pruebas de las rutas públicas de solicitudes de visita · V2 §Visita, sin sesión y con transporte simulado. © 2026 Equipo CuidaRed – INTEC. */
import { createHash } from 'node:crypto';
import express from 'express';
import { describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { createSupabaseGateway } from '../src/modules/access/supabase-gateway.js';
import { createPublicoRouter } from '../src/modules/publico/publico-routes.js';
import {
  ALFABETO_CODIGO,
  generarCodigoSeguimiento,
  hashCodigo,
  normalizarCodigo,
  PATRON_CODIGO,
} from '../src/modules/publico/codigo-seguimiento.js';

const env = {
  SUPABASE_URL: 'https://auth.example.test',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test_only',
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const rpcError = (code, message = 'detalle privado del proveedor') =>
  json({ code, message, details: 'private_details', hint: 'private_hint' }, 400);

const solicitud = (extra = {}) => ({
  cuenta_id: 4,
  nombres: 'Juan',
  apellidos: 'Pérez',
  cedula: '001-1234567-8',
  telefono: '809 555-0100',
  correo: 'juan@correo.test',
  persona_a_visitar: 'Doña Ana',
  fecha_propuesta: '2026-12-01',
  hora_propuesta: '10:30',
  motivo: 'Visita de compañía',
  ...extra,
});
const estadoRpc = (extra = {}) => ({
  organizacion: 'Asilo San José',
  estado: 'autorizada',
  fecha: '2026-12-01',
  hora: '10:30',
  motivo_rechazo: null,
  puede_registrar_observacion: false,
  observacion: null,
  ...extra,
});

/**
 * Borrador público aislado para pruebas de contrato. La aplicación real mantiene cerradas estas rutas.
 */
function setup(rpc = {}) {
  const llamadas = [];
  const fetch = vi.fn(async (url, init = {}) => {
    const nombre = String(url).split('/rpc/')[1];
    const cuerpo = init.body ? JSON.parse(init.body) : {};
    const cabeceras = new Headers(init.headers);
    llamadas.push({ nombre, cuerpo, autorizacion: cabeceras.get('Authorization') });
    const manejador = rpc[nombre];
    if (!manejador) return json({ code: 'PGRST202', message: 'sin definir' }, 404);
    const salida = manejador(cuerpo);
    return salida instanceof Response ? salida : json(salida);
  });
  const audit = vi.fn();
  const deps = {
    env: { origins: [] },
    gateway: createSupabaseGateway(env, fetch),
    audit,
  };
  const app = express();
  app.use('/api/v1/publico', express.json(), (_req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  });
  app.use('/api/v1/publico', createPublicoRouter(deps));
  app.use(createApp(deps));
  app.use((error, _req, res, _next) => {
    res.status(error.status ?? 500).json({ error: { code: error.code, message: error.message } });
  });
  return { app, audit, llamadas, fetch };
}

describe('código de seguimiento', () => {
  it('formato VIS-XXXX-XXXX con alfabeto sin 0, O, 1 ni I', () => {
    const codigos = Array.from({ length: 500 }, () => generarCodigoSeguimiento());
    for (const codigo of codigos) {
      expect(codigo).toMatch(PATRON_CODIGO);
      expect(codigo.slice(4)).not.toMatch(/[01OI]/);
    }
    expect(ALFABETO_CODIGO).toHaveLength(32);
    expect(ALFABETO_CODIGO).not.toMatch(/[01OI]/);
    expect(new Set(codigos).size).toBe(codigos.length);
  });
  it('se guarda solo el SHA-256 del código normalizado', () => {
    const esperado = createHash('sha256').update('VIS-ABCD-2345').digest('hex');
    expect(hashCodigo('VIS-ABCD-2345')).toBe(esperado);
    expect(hashCodigo('  vis-abcd-2345 ')).toBe(esperado);
    expect(hashCodigo('vis-abcd -2345')).toBe(esperado);
    expect(normalizarCodigo(' vis-abcd 2345 ')).toBe('VIS-ABCD2345');
    expect(esperado).toMatch(/^[0-9a-f]{64}$/);
  });
});

it('la aplicación de integración no monta solicitudes externas', async () => {
  const gateway = { publico: vi.fn() };
  const app = createApp({ env: { origins: [] }, gateway, audit: vi.fn() });
  await request(app).get('/api/v1/publico/organizaciones').expect(404);
  await request(app).post('/api/v1/publico/solicitudes-visita').send(solicitud()).expect(404);
  expect(gateway.publico).not.toHaveBeenCalled();
});

describe('GET /publico/organizaciones', () => {
  it('no requiere sesión y solo expone cuenta_id y nombre', async () => {
    const { app, llamadas } = setup({
      api_publico_listar_organizaciones: () => [
        {
          cuenta_id: 4,
          nombre: 'Asilo San José',
          plan_id: 3,
          usuario_titular_id: 'secreto',
          tipo: 'organizacion',
        },
        { cuenta_id: 9, nombre: 'Fundación Esperanza', correo: 'privado@x.test' },
      ],
    });
    const res = await request(app).get('/api/v1/publico/organizaciones').expect(200);
    expect(res.body.data).toEqual([
      { cuenta_id: 4, nombre: 'Asilo San José' },
      { cuenta_id: 9, nombre: 'Fundación Esperanza' },
    ]);
    expect(res.headers['cache-control']).toBe('no-store');
    // Cliente anon: sin cabecera Authorization de usuario (solo la clave publicable del cliente).
    expect(llamadas[0].nombre).toBe('api_publico_listar_organizaciones');
    expect(llamadas[0].autorizacion ?? '').not.toMatch(/^Bearer (?!sb_publishable)/);
  });
  it('un contrato roto de la base es indisponibilidad', async () => {
    const { app } = setup({ api_publico_listar_organizaciones: () => ({ no: 'es lista' }) });
    await request(app).get('/api/v1/publico/organizaciones').expect(503);
  });
});

describe('POST /publico/solicitudes-visita: crear', () => {
  const crearConExito = () =>
    setup({
      api_publico_crear_solicitud: () => ({
        organizacion: 'Asilo San José',
        estado: 'pendiente',
        fecha_propuesta: '2026-12-01',
        hora_propuesta: '10:30',
        solicitud_visita_id: 'no-debe-salir',
        cuenta_id: 4,
      }),
    });

  it('genera el código en Express, manda solo su hash y lo devuelve una única vez', async () => {
    const { app, llamadas, audit } = crearConExito();
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud())
      .expect(201);
    const { codigo, ...resto } = res.body.data;
    expect(codigo).toMatch(PATRON_CODIGO);
    expect(resto).toEqual({
      organizacion: 'Asilo San José',
      estado: 'pendiente',
      fecha_propuesta: '2026-12-01',
      hora_propuesta: '10:30',
    });
    const enviado = llamadas[0].cuerpo.p_datos;
    expect(llamadas[0].nombre).toBe('api_publico_crear_solicitud');
    expect(enviado.codigo_hash).toBe(createHash('sha256').update(codigo).digest('hex'));
    // El código en claro no llega a la base ni a la auditoría.
    expect(JSON.stringify(llamadas)).not.toContain(codigo);
    expect(JSON.stringify(audit.mock.calls)).not.toContain(codigo);
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'solicitud_visita.creada' }),
    );
  });
  it('envía la cédula y el teléfono en forma canónica, solo a la RPC de creación', async () => {
    const { app, llamadas, audit } = crearConExito();
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud())
      .expect(201);
    expect(llamadas[0].cuerpo.p_datos).toMatchObject({
      cuenta_id: 4,
      cedula: '00112345678',
      telefono: '8095550100',
      correo: 'juan@correo.test',
    });
    // Ni la respuesta ni la auditoría contienen los datos personales del visitante.
    for (const dato of [
      '00112345678',
      '001-1234567-8',
      '8095550100',
      '809 555-0100',
      'Juan',
      'juan@correo.test',
    ]) {
      expect(JSON.stringify(res.body)).not.toContain(dato);
      expect(JSON.stringify(audit.mock.calls)).not.toContain(dato);
    }
  });
  it('cada solicitud recibe un código distinto', async () => {
    const { app, llamadas } = crearConExito();
    const a = await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud())
      .expect(201);
    const b = await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud())
      .expect(201);
    expect(a.body.data.codigo).not.toBe(b.body.data.codigo);
    expect(llamadas[0].cuerpo.p_datos.codigo_hash).not.toBe(llamadas[1].cuerpo.p_datos.codigo_hash);
  });
  it('el correo es opcional y una cadena vacía equivale a no indicarlo', async () => {
    const { app, llamadas } = crearConExito();
    await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud({ correo: '' }))
      .expect(201);
    const sinCorreo = solicitud();
    delete sinCorreo.correo;
    await request(app).post('/api/v1/publico/solicitudes-visita').send(sinCorreo).expect(201);
    expect(llamadas[0].cuerpo.p_datos.correo ?? null).toBeNull();
    expect(llamadas[1].cuerpo.p_datos.correo ?? null).toBeNull();
  });
  it.each([
    ['campo desconocido', { estado: 'autorizada' }],
    ['identidad de cuenta enviada como texto', { cuenta_id: '4' }],
    ['cuenta no positiva', { cuenta_id: 0 }],
    ['nombre con símbolos', { nombres: 'Juan<script>' }],
    ['nombre de un carácter', { nombres: 'J' }],
    ['cédula inválida', { cedula: '123' }],
    ['cédula con letras', { cedula: '0011234567x' }],
    ['teléfono inválido', { telefono: '555' }],
    ['correo inválido', { correo: 'sin-arroba' }],
    ['fecha inválida', { fecha_propuesta: '2026-13-01' }],
    ['hora inválida', { hora_propuesta: '24:00' }],
    ['motivo corto', { motivo: 'ab' }],
    ['motivo largo', { motivo: 'x'.repeat(301) }],
    ['persona a visitar corta', { persona_a_visitar: 'ab' }],
    ['código enviado por el cliente', { codigo_hash: 'a'.repeat(64) }],
  ])('rechaza %s con 422 sin llamar a la base', async (_caso, extra) => {
    const { app, llamadas } = crearConExito();
    await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud(extra))
      .expect(422);
    expect(llamadas).toHaveLength(0);
  });
  it('faltan campos obligatorios o el cuerpo está vacío: 422', async () => {
    const { app, llamadas } = crearConExito();
    await request(app).post('/api/v1/publico/solicitudes-visita').send({}).expect(422);
    await request(app).post('/api/v1/publico/solicitudes-visita').expect(422);
    const incompleta = solicitud();
    delete incompleta.motivo;
    await request(app).post('/api/v1/publico/solicitudes-visita').send(incompleta).expect(422);
    expect(llamadas).toHaveLength(0);
  });
  it.each([
    ['22023', 422, 'INVALID_INPUT'],
    ['23505', 409, 'CONFLICT'],
    ['XX000', 503, 'DEPENDENCY_UNAVAILABLE'],
  ])(
    'el error de RPC %s llega como %i %s sin datos del proveedor',
    async (sqlstate, estado, codigo) => {
      const { app } = setup({ api_publico_crear_solicitud: () => rpcError(sqlstate) });
      const res = await request(app)
        .post('/api/v1/publico/solicitudes-visita')
        .send(solicitud())
        .expect(estado);
      expect(res.body.error.code).toBe(codigo);
      expect(JSON.stringify(res.body)).not.toMatch(/private|privado/);
    },
  );
  it.each([
    ['CR_CONFLICTO', 409, 'CONFLICT'],
    ['CR_SOLICITUD_NO_DISPONIBLE', 409, 'REQUEST_UNAVAILABLE'],
  ])('%s → %i %s', async (codigo, estado, publico) => {
    const { app } = setup({ api_publico_crear_solicitud: () => rpcError('P0001', codigo) });
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita')
      .send(solicitud())
      .expect(estado);
    expect(res.body.error.code).toBe(publico);
  });
});

describe('POST /publico/solicitudes-visita/consulta', () => {
  it('consulta con el hash del código y devuelve solo el estado público', async () => {
    const { app, llamadas } = setup({
      api_publico_consultar_solicitud: () =>
        estadoRpc({
          envejeciente_id: 'secreto',
          participantes: ['x'],
          visita_id: 'v',
          cedula: '001',
        }),
    });
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita/consulta')
      .send({ codigo: ' vis-abcd-2345 ' })
      .expect(200);
    expect(llamadas[0].cuerpo).toEqual({ p_codigo_hash: hashCodigo('VIS-ABCD-2345') });
    expect(res.body.data).toEqual({
      ...estadoRpc(),
      estado_texto: 'Autorizada',
    });
    expect(JSON.stringify(res.body)).not.toMatch(/secreto|participantes|visita_id|cedula/);
  });
  it('un código inexistente y uno con formato inválido responden exactamente igual: 404 genérico', async () => {
    const { app, llamadas } = setup({ api_publico_consultar_solicitud: () => rpcError('P0002') });
    const inexistente = await request(app)
      .post('/api/v1/publico/solicitudes-visita/consulta')
      .send({ codigo: 'VIS-ZZZZ-2222' })
      .expect(404);
    expect(llamadas).toHaveLength(1);
    for (const codigo of [
      '',
      'abc',
      'VIS-0000-1111',
      'VIS-ABCD-234',
      "VIS-ABCD-2345'; drop table",
      '../../x',
    ]) {
      const invalido = await request(app)
        .post('/api/v1/publico/solicitudes-visita/consulta')
        .send({ codigo })
        .expect(404);
      expect(invalido.body.error).toEqual(inexistente.body.error);
    }
    // El formato inválido ni siquiera llega a la base.
    expect(llamadas).toHaveLength(1);
  });
  it.each([{}, { codigo: 123 }, { codigo: 'VIS-ABCD-2345', extra: 1 }, { codigo: 'x'.repeat(65) }])(
    'un cuerpo mal formado %j es 422',
    async (cuerpo) => {
      const { app, llamadas } = setup();
      await request(app)
        .post('/api/v1/publico/solicitudes-visita/consulta')
        .send(cuerpo)
        .expect(422);
      expect(llamadas).toHaveLength(0);
    },
  );
  it('el estado rechazado muestra el motivo; los estados tienen texto público', async () => {
    const { app } = setup({
      api_publico_consultar_solicitud: () =>
        estadoRpc({ estado: 'rechazada', motivo_rechazo: 'No hay horario disponible.' }),
    });
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita/consulta')
      .send({ codigo: 'VIS-ABCD-2345' })
      .expect(200);
    expect(res.body.data).toMatchObject({
      estado: 'rechazada',
      estado_texto: 'No autorizada',
      motivo_rechazo: 'No hay horario disponible.',
    });
  });
});

describe('POST /publico/solicitudes-visita/observacion', () => {
  it('el visitante deja su observación y la solicitud queda realizada', async () => {
    const { app, llamadas, audit } = setup({
      api_publico_registrar_observacion: () =>
        estadoRpc({ estado: 'realizada', observacion: 'Fue una visita muy agradable.' }),
    });
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita/observacion')
      .send({ codigo: 'vis-abcd-2345', observacion: '  Fue una visita muy agradable. ' })
      .expect(200);
    expect(llamadas[0].cuerpo).toEqual({
      p_codigo_hash: hashCodigo('VIS-ABCD-2345'),
      p_observacion: 'Fue una visita muy agradable.',
    });
    expect(res.body.data).toMatchObject({ estado: 'realizada', estado_texto: 'Visita realizada' });
    expect(JSON.stringify(audit.mock.calls)).not.toMatch(/agradable|ABCD/);
  });
  it('código inválido o inexistente: 404 antes de validar la observación', async () => {
    const { app, llamadas } = setup({ api_publico_registrar_observacion: () => rpcError('P0002') });
    const mal = await request(app)
      .post('/api/v1/publico/solicitudes-visita/observacion')
      .send({ codigo: 'nope', observacion: 'x' })
      .expect(404);
    const nada = await request(app)
      .post('/api/v1/publico/solicitudes-visita/observacion')
      .send({ codigo: 'VIS-ABCD-2345', observacion: 'Todo bien por aquí.' })
      .expect(404);
    expect(mal.body.error).toEqual(nada.body.error);
    expect(llamadas).toHaveLength(1);
  });
  it.each([
    [{ codigo: 'VIS-ABCD-2345', observacion: 'ab' }],
    [{ codigo: 'VIS-ABCD-2345', observacion: '   ' }],
    [{ codigo: 'VIS-ABCD-2345', observacion: 'x'.repeat(601) }],
    [{ codigo: 'VIS-ABCD-2345' }],
    [{ codigo: 'VIS-ABCD-2345', observacion: 'Todo bien.', estado: 'realizada' }],
  ])('rechaza %j con 422 sin llamar a la base', async (cuerpo) => {
    const { app, llamadas } = setup();
    await request(app)
      .post('/api/v1/publico/solicitudes-visita/observacion')
      .send(cuerpo)
      .expect(422);
    expect(llamadas).toHaveLength(0);
  });
  it('si la solicitud no está autorizada o la fecha aún no llega: 409 REQUEST_UNAVAILABLE', async () => {
    const { app } = setup({
      api_publico_registrar_observacion: () => rpcError('P0001', 'CR_SOLICITUD_NO_DISPONIBLE'),
    });
    const res = await request(app)
      .post('/api/v1/publico/solicitudes-visita/observacion')
      .send({ codigo: 'VIS-ABCD-2345', observacion: 'Todo bien por aquí.' })
      .expect(409);
    expect(res.body.error.code).toBe('REQUEST_UNAVAILABLE');
  });
});

describe('límite de peticiones y superficie pública', () => {
  it('limita las rutas públicas a diez peticiones por minuto', async () => {
    const { app } = setup({ api_publico_listar_organizaciones: () => [] });
    for (let i = 0; i < 10; i += 1) {
      await request(app).get('/api/v1/publico/organizaciones').expect(200);
    }
    const res = await request(app).get('/api/v1/publico/organizaciones').expect(429);
    expect(res.body.error.code).toBe('RATE_LIMITED');
  });
  it('el límite también cubre las consultas del código (frena el sondeo de códigos)', async () => {
    const { app } = setup({ api_publico_consultar_solicitud: () => rpcError('P0002') });
    for (let i = 0; i < 10; i += 1) {
      await request(app)
        .post('/api/v1/publico/solicitudes-visita/consulta')
        .send({ codigo: 'VIS-ABCD-2345' })
        .expect(404);
    }
    await request(app)
      .post('/api/v1/publico/solicitudes-visita/consulta')
      .send({ codigo: 'VIS-ABCD-2345' })
      .expect(429);
  });
  it('solo existen las cuatro rutas públicas con sus métodos', async () => {
    const { app, llamadas } = setup();
    await request(app).put('/api/v1/publico/solicitudes-visita').send(solicitud()).expect(404);
    await request(app).delete('/api/v1/publico/solicitudes-visita').expect(404);
    await request(app).get('/api/v1/publico/solicitudes-visita/consulta').expect(404);
    await request(app).get('/api/v1/publico/solicitudes-visita').expect(404);
    await request(app).post('/api/v1/publico/organizaciones').send({}).expect(404);
    await request(app).get('/api/v1/publico/cuentas').expect(404);
    expect(llamadas).toHaveLength(0);
  });
  it('la gestión de solicitudes sigue exigiendo sesión: lo público no la abre', async () => {
    const { app } = setup();
    await request(app).get('/api/v1/cuentas/4/solicitudes-visita').expect(401);
    await request(app)
      .post('/api/v1/cuentas/4/solicitudes-visita/1b2c3d4e-5f6a-4b7c-8d8e-9f0a1b2c3d4e/autorizar')
      .send({})
      .expect(401);
  });
  it('el cliente anon solo acepta RPC api_publico_*', async () => {
    const gateway = createSupabaseGateway(env, vi.fn());
    await expect(gateway.publico().rpc('api_listar_visitas', {})).rejects.toThrow();
    await expect(gateway.publico().rpc('api_sesion', {})).rejects.toThrow();
  });
});

describe('Huella del código con secreto del servidor', () => {
  it('con CODIGO_SEGUIMIENTO_SECRETO usa HMAC-SHA256 y no coincide con el SHA-256 simple', async () => {
    const { createHmac } = await import('node:crypto');
    const secreto = 'x'.repeat(40);
    const esperado = createHmac('sha256', secreto).update('VIS-ABCD-2345').digest('hex');
    expect(hashCodigo(' vis-abcd-2345', secreto)).toBe(esperado);
    expect(hashCodigo('VIS-ABCD-2345', secreto)).not.toBe(hashCodigo('VIS-ABCD-2345'));
  });
});
