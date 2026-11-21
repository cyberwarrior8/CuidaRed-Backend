/* Contrato HTTP de alertas internas · ID06/RF-04/RF-18. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { conSesion, crearApp, cuentaCon, usuarioId } from './cuentas-support.js';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';

const prefijo = '/api/v1/cuentas/7';
const alertaId = '55555555-5555-4555-8555-555555555555';
const avisoId = '88888888-8888-4888-8888-888888888888';
const adulto = {
  envejeciente_id: '11111111-1111-4111-8111-111111111111',
  nombres: 'Juana',
  apellidos: 'Prueba',
};
const fecha = '2026-11-14T14:15:00Z';
const alerta = {
  ...adulto,
  alerta_envejeciente_id: alertaId,
  tipo: { codigo: 'riesgo_alto', nombre: 'Riesgo alto' },
  prioridad: { nombre: 'Alta', orden: 1 },
  descripcion: 'Caso de prueba.',
  origen: 'sistema',
  estado: 'pendiente',
  fecha_alerta: fecha,
  fecha_atencion: null,
  atendida_por: null,
  cierre_automatico: false,
  accion_tomada: null,
  fuente: { tipo: 'riesgo', referencia_id: '9007199254740995' },
  es_prioritaria: true,
};
const otroAdulto = '22222222-2222-4222-8222-222222222222';
const enProceso = { ...alerta, estado: 'en_proceso' };
const resuelta = {
  ...alerta,
  estado: 'resuelta',
  fecha_atencion: fecha,
  atendida_por: 'Persona de prueba',
  accion_tomada: 'Se hizo seguimiento.',
};
const aviso = {
  notificacion_id: avisoId,
  alerta_envejeciente_id: alertaId,
  mensaje: 'Hay una alerta de caso prioritario por revisar.',
  estado: 'no_leida',
  fecha_notificacion: fecha,
  fecha_lectura: null,
};
const paginaDe =
  (items, total = items.length) =>
  () => ({ items, total });
// Los errores sí quedan en la bitácora general (api.request); ninguna acción de alertas se registra.
const sinAuditoriaDeAlertas = (audit) =>
  expect(
    audit.mock.calls.map(([evento]) => evento.action).filter((a) => a !== 'api.request'),
  ).toEqual([]);
// Tras resolver la cuenta no debe haberse llamado a ninguna RPC de alertas.
const sinRpcDeAlertas = (rpc) =>
  expect(rpc.mock.calls.filter(([nombre]) => nombre !== 'api_contexto_cuenta')).toEqual([]);

// Las siete rutas del contrato (cuatro lecturas y tres escrituras), con un cuerpo válido para cada una.
const lecturas = [
  ['get', `${prefijo}/alertas`],
  ['get', `${prefijo}/alertas/${alertaId}`],
  ['get', `${prefijo}/casos-prioritarios`],
  ['get', `${prefijo}/notificaciones-alerta`],
];
const escrituras = [
  ['post', `${prefijo}/alertas/${alertaId}/en-atencion`, {}],
  ['post', `${prefijo}/alertas/${alertaId}/resolver`, { accion_tomada: 'Se hizo seguimiento.' }],
  ['post', `${prefijo}/notificaciones-alerta/${avisoId}/leer`, {}],
];
const todas = [...lecturas.map(([m, r]) => [m, r, undefined]), ...escrituras];
const llamar = (app, [metodo, ruta, cuerpo]) => {
  const peticion = conSesion(request(app)[metodo](ruta));
  return cuerpo === undefined ? peticion : peticion.send(cuerpo);
};

describe('fase 6', () => {
  it('pagina por caso y proyecta solo campos públicos de las alertas', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_casos_prioritarios_listar: () => ({
        items: [
          {
            ...adulto,
            fecha_alerta: fecha,
            total_alertas: 2,
            alertas: [
              { ...alerta, datos_clinicos: 'dato privado' },
              { ...alerta, alerta_envejeciente_id: avisoId },
            ],
          },
        ],
        total: 1,
      }),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/casos-prioritarios`)).expect(200);
    expect(res.body.meta.total).toBe(1);
    expect(res.body.data[0].alertas).toHaveLength(2);
    expect(res.body.data[0].alertas[0]).toEqual(alerta);
  });

  it('el Cuidador resuelve con acción registrada, pero no inicia atención', async () => {
    const rpc = cuentaCon('cuidador', 'familia', {
      api_alerta_resolver: () => ({
        ...alerta,
        estado: 'resuelta',
        fecha_atencion: fecha,
        atendida_por: 'Persona de prueba',
        accion_tomada: 'Se hizo seguimiento.',
      }),
    });
    const { app, audit } = crearApp({ rpc });
    await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/en-atencion`)).expect(403);
    await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: ' ' })
      .expect(422);
    const res = await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: 'Se hizo seguimiento.' })
      .expect(200);
    expect(res.body.data.atendida_por).toBe('Persona de prueba');
    expect(rpc).toHaveBeenCalledWith('api_alerta_resolver', {
      p_cuenta_id: '7',
      p_alerta_id: alertaId,
      p_accion: 'Se hizo seguimiento.',
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'alerta.resuelta' }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('Se hizo seguimiento.');
  });

  it('un aviso ajeno no revela su existencia ni acepta un destinatario en el cuerpo', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_notificacion_alerta_leer: () => {
        throw mapRpcError({ code: 'P0002', message: 'privado' });
      },
    });
    const { app } = crearApp({ rpc });
    const marca = `${prefijo}/notificaciones-alerta/${avisoId}/leer`;
    await conSesion(request(app).post(marca)).send({ usuario_id: usuarioId }).expect(422);
    const res = await conSesion(request(app).post(marca)).expect(404);
    expect(JSON.stringify(res.body)).not.toContain('privado');
  });
});

describe('consulta de alertas', () => {
  it('envía los filtros permitidos, ordena por fecha descendente y pagina', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_alertas_listar: paginaDe([{ ...alerta, datos_clinicos: 'dato privado' }], 21),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(
      request(app).get(`${prefijo}/alertas`).query({
        'filter[estado]': 'pendiente',
        'filter[tipo]': 'riesgo_alto',
        'filter[envejeciente_id]': adulto.envejeciente_id,
        page: '2',
        limit: '20',
      }),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_alertas_listar', {
      p_cuenta_id: '7',
      p_filtros: {
        estado: 'pendiente',
        tipo: 'riesgo_alto',
        envejeciente_id: adulto.envejeciente_id,
      },
      p_orden: ['-fecha_alerta', 'alerta_envejeciente_id'],
      p_limite: 20,
      p_desplazamiento: 20,
    });
    expect(res.body).toEqual({
      data: [alerta],
      meta: { page: 2, limit: 20, total: 21, totalPages: 2 },
    });
  });

  it('sin filtros consulta con el orden y la página predeterminados', async () => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_alertas_listar: paginaDe([alerta, { ...alerta, alerta_envejeciente_id: avisoId }]),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/alertas`)).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_alertas_listar', {
      p_cuenta_id: '7',
      p_filtros: {},
      p_orden: ['-fecha_alerta', 'alerta_envejeciente_id'],
      p_limite: 20,
      p_desplazamiento: 0,
    });
    expect(res.body.meta).toEqual({ page: 1, limit: 20, total: 2, totalPages: 1 });
    expect(res.body.data).toHaveLength(2);
  });

  it.each([
    ['fecha_alerta', ['fecha_alerta', 'alerta_envejeciente_id']],
    ['-alerta_envejeciente_id', ['-alerta_envejeciente_id']],
    ['-fecha_alerta,alerta_envejeciente_id', ['-fecha_alerta', 'alerta_envejeciente_id']],
  ])('ordena por %s y siempre desempata por identificador', async (sort, esperado) => {
    const rpc = cuentaCon('coordinador', 'familia', { api_alertas_listar: paginaDe([alerta]) });
    const { app } = crearApp({ rpc });
    await conSesion(request(app).get(`${prefijo}/alertas`).query({ sort })).expect(200);
    expect(rpc).toHaveBeenCalledWith(
      'api_alertas_listar',
      expect.objectContaining({ p_orden: esperado }),
    );
  });

  it('devuelve el detalle con la fuente, la acción tomada y quién la atendió', async () => {
    const rpc = cuentaCon('cuidador', 'organizacion', { api_alerta_obtener: () => resuelta });
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/alertas/${alertaId}`)).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_alerta_obtener', {
      p_cuenta_id: '7',
      p_alerta_id: alertaId,
    });
    expect(res.body).toEqual({ data: resuelta });
  });

  it('conserva la marca de cierre automático y una alerta sin fuente histórica', async () => {
    const historica = {
      ...resuelta,
      cierre_automatico: true,
      atendida_por: null,
      fuente: null,
      es_prioritaria: false,
    };
    const rpc = cuentaCon('coordinador', 'familia', { api_alerta_obtener: () => historica });
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/alertas/${alertaId}`)).expect(200);
    expect(res.body.data).toMatchObject({ cierre_automatico: true, fuente: null });
  });

  it('agrupa los casos prioritarios con orden, paginación y filtro por adulto', async () => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_casos_prioritarios_listar: paginaDe(
        [{ ...adulto, fecha_alerta: fecha, total_alertas: 1, alertas: [alerta] }],
        3,
      ),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(
      request(app)
        .get(`${prefijo}/casos-prioritarios`)
        .query({ 'filter[envejeciente_id]': adulto.envejeciente_id, page: '3', limit: '1' }),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_casos_prioritarios_listar', {
      p_cuenta_id: '7',
      p_filtros: { envejeciente_id: adulto.envejeciente_id },
      p_orden: ['-fecha_alerta', 'envejeciente_id'],
      p_limite: 1,
      p_desplazamiento: 2,
    });
    expect(res.body.meta).toEqual({ page: 3, limit: 1, total: 3, totalPages: 3 });
    expect(res.body.data[0].alertas).toEqual([alerta]);
  });

  it('un caso prioritario sin alertas o con un total inválido es un fallo del servicio', async () => {
    for (const caso of [
      { ...adulto, fecha_alerta: fecha, total_alertas: 1, alertas: [] },
      { ...adulto, fecha_alerta: fecha, total_alertas: 0, alertas: [alerta] },
    ]) {
      const rpc = cuentaCon('coordinador', 'familia', {
        api_casos_prioritarios_listar: paginaDe([caso]),
      });
      const { app } = crearApp({ rpc });
      const res = await conSesion(request(app).get(`${prefijo}/casos-prioritarios`)).expect(503);
      expect(res.body.error.code).toBe('DEPENDENCY_UNAVAILABLE');
    }
  });
});

describe('gestión de alertas', () => {
  it.each([
    ['coordinador', 'familia'],
    ['coordinador', 'organizacion'],
    ['administrador', 'organizacion'],
  ])('el %s de %s inicia la atención y queda auditado sin datos del caso', async (rol, tipo) => {
    const rpc = cuentaCon(rol, tipo, { api_alerta_en_atencion: () => enProceso });
    const { app, audit } = crearApp({ rpc });
    const url = `${prefijo}/alertas/${alertaId}/en-atencion`;
    const res = await conSesion(request(app).post(url)).expect(200);
    expect(res.body).toEqual({ data: enProceso });
    expect(rpc).toHaveBeenCalledWith('api_alerta_en_atencion', {
      p_cuenta_id: '7',
      p_alerta_id: alertaId,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'alerta.en_atencion' }),
    );
    // Acepta también el cuerpo vacío explícito, pero ningún campo adicional.
    await conSesion(request(app).post(url)).send({}).expect(200);
    await conSesion(request(app).post(url)).send({ estado: 'resuelta' }).expect(422);
    expect(rpc.mock.calls.filter(([nombre]) => nombre === 'api_alerta_en_atencion')).toHaveLength(
      2,
    );
  });

  it.each([
    ['coordinador', 'familia'],
    ['administrador', 'organizacion'],
    ['cuidador', 'organizacion'],
  ])('el %s de %s resuelve con la acción tomada recortada', async (rol, tipo) => {
    const rpc = cuentaCon(rol, tipo, { api_alerta_resolver: () => resuelta });
    const { app, audit } = crearApp({ rpc });
    const res = await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: '  Se hizo seguimiento.  ' })
      .expect(200);
    expect(res.body).toEqual({ data: resuelta });
    expect(rpc).toHaveBeenCalledWith('api_alerta_resolver', {
      p_cuenta_id: '7',
      p_alerta_id: alertaId,
      p_accion: 'Se hizo seguimiento.',
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'alerta.resuelta' }),
    );
  });

  it('exige una acción tomada válida para resolver', async () => {
    const rpc = cuentaCon('coordinador', 'familia', { api_alerta_resolver: () => resuelta });
    const { app, audit } = crearApp({ rpc });
    const url = `${prefijo}/alertas/${alertaId}/resolver`;
    const invalidos = [
      undefined,
      {},
      { accion_tomada: '' },
      { accion_tomada: ' \n ' },
      { accion_tomada: 42 },
      { accion_tomada: 'x'.repeat(501) },
      { accion_tomada: 'Texto con\u0000control' },
      { accion_tomada: 'Se hizo seguimiento.', estado: 'resuelta' },
    ];
    for (const cuerpo of invalidos) {
      const peticion = conSesion(request(app).post(url));
      await (cuerpo === undefined ? peticion : peticion.send(cuerpo)).expect(422);
    }
    sinRpcDeAlertas(rpc);
    sinAuditoriaDeAlertas(audit);
    // El límite es de 500 caracteres y se aceptan saltos de línea.
    await conSesion(request(app).post(url))
      .send({ accion_tomada: `${'x'.repeat(488)}\nSeguimiento` })
      .expect(200);
  });

  it('una alerta cerrada o una transición inválida responde 409 sin auditar', async () => {
    const estadoInvalido = () => {
      throw mapRpcError({ code: 'P0001', message: 'CR_ESTADO_INVALIDO' });
    };
    const rpc = cuentaCon('coordinador', 'familia', {
      api_alerta_resolver: estadoInvalido,
      api_alerta_en_atencion: estadoInvalido,
    });
    const { app, audit } = crearApp({ rpc });
    for (const [ruta, cuerpo] of [
      ['resolver', { accion_tomada: 'Se hizo seguimiento.' }],
      ['en-atencion', {}],
    ]) {
      const res = await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/${ruta}`))
        .send(cuerpo)
        .expect(409);
      expect(res.body.error.code).toBe('INVALID_STATE');
    }
    sinAuditoriaDeAlertas(audit);
  });

  it('una alerta fuera de alcance es inexistente y un permiso revocado en la base es 403', async () => {
    const noExiste = () => {
      throw mapRpcError({ code: 'P0002' });
    };
    const sinPermiso = () => {
      throw mapRpcError({ code: '42501' });
    };
    const rpc = cuentaCon('cuidador', 'familia', {
      api_alerta_obtener: noExiste,
      api_alerta_resolver: sinPermiso,
    });
    const { app, audit } = crearApp({ rpc });
    await conSesion(request(app).get(`${prefijo}/alertas/${alertaId}`)).expect(404);
    await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: 'Se hizo seguimiento.' })
      .expect(403);
    sinAuditoriaDeAlertas(audit);
  });

  it('una respuesta que rompe el contrato no se publica ni se audita', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_alerta_resolver: () => ({ ...resuelta, estado: 'atendida' }),
    });
    const { app, audit } = crearApp({ rpc });
    const res = await conSesion(request(app).post(`${prefijo}/alertas/${alertaId}/resolver`))
      .send({ accion_tomada: 'Se hizo seguimiento.' })
      .expect(503);
    expect(res.body.error.code).toBe('DEPENDENCY_UNAVAILABLE');
    sinAuditoriaDeAlertas(audit);
  });
});

describe('avisos internos de alertas', () => {
  it('lista los avisos propios con filtro por lectura, orden y paginación', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_notificaciones_alerta_listar: paginaDe([{ ...aviso, usuario_id: 'privado' }], 2),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(
      request(app)
        .get(`${prefijo}/notificaciones-alerta`)
        .query({ 'filter[estado]': 'no_leida', sort: 'fecha_notificacion', limit: '1' }),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_notificaciones_alerta_listar', {
      p_cuenta_id: '7',
      p_filtros: { estado: 'no_leida' },
      p_orden: ['fecha_notificacion', 'notificacion_id'],
      p_limite: 1,
      p_desplazamiento: 0,
    });
    expect(res.body).toEqual({
      data: [aviso],
      meta: { page: 1, limit: 1, total: 2, totalPages: 2 },
    });
  });

  it.each(['no_leida', 'leida', 'archivada'])('acepta el estado %s del aviso', async (estado) => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_notificaciones_alerta_listar: paginaDe([]),
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(
      request(app).get(`${prefijo}/notificaciones-alerta`).query({ 'filter[estado]': estado }),
    ).expect(200);
    expect(res.body).toEqual({ data: [], meta: { page: 1, limit: 20, total: 0, totalPages: 0 } });
    expect(rpc).toHaveBeenCalledWith(
      'api_notificaciones_alerta_listar',
      expect.objectContaining({
        p_filtros: { estado },
        p_orden: ['-fecha_notificacion', 'notificacion_id'],
      }),
    );
  });

  it('marca un aviso como leído, conserva la primera fecha de lectura y audita', async () => {
    const primera = '2026-11-14T15:00:00Z';
    const leida = { ...aviso, estado: 'leida', fecha_lectura: primera };
    const rpc = cuentaCon('coordinador', 'organizacion', {
      api_notificacion_alerta_leer: () => leida,
    });
    const { app, audit } = crearApp({ rpc });
    const url = `${prefijo}/notificaciones-alerta/${avisoId}/leer`;
    const primero = await conSesion(request(app).post(url)).expect(200);
    const segundo = await conSesion(request(app).post(url)).send({}).expect(200);
    expect(primero.body).toEqual({ data: leida });
    expect(segundo.body.data.fecha_lectura).toBe(primera);
    expect(rpc).toHaveBeenCalledWith('api_notificacion_alerta_leer', {
      p_cuenta_id: '7',
      p_notificacion_id: avisoId,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'notificacion_alerta.leida' }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('alerta de caso prioritario');
  });
});

describe('autorización de alertas', () => {
  it.each([
    ['voluntario', 'organizacion'],
    ['familiar', 'organizacion'],
    ['familiar', 'familia'],
  ])('el %s de %s no consulta ni gestiona alertas', async (rol, tipo) => {
    const rpc = cuentaCon(rol, tipo);
    const { app, audit } = crearApp({ rpc });
    for (const ruta of todas) {
      const res = await llamar(app, ruta).expect(403);
      expect(res.body.error.code).toBe('FORBIDDEN');
    }
    sinRpcDeAlertas(rpc);
    sinAuditoriaDeAlertas(audit);
  });

  it('el cuidador consulta y resuelve, pero no inicia la atención', async () => {
    const rpc = cuentaCon('cuidador', 'organizacion', {
      api_alertas_listar: paginaDe([alerta]),
      api_alerta_obtener: () => alerta,
      api_casos_prioritarios_listar: paginaDe([]),
      api_notificaciones_alerta_listar: paginaDe([]),
      api_alerta_resolver: () => resuelta,
      api_notificacion_alerta_leer: () => ({ ...aviso, estado: 'leida', fecha_lectura: fecha }),
    });
    const { app } = crearApp({ rpc });
    for (const ruta of todas) {
      const [, url] = ruta;
      if (url.endsWith('/en-atencion')) await llamar(app, ruta).expect(403);
      else await llamar(app, ruta).expect(200);
    }
    expect(rpc.mock.calls.map(([nombre]) => nombre)).not.toContain('api_alerta_en_atencion');
  });

  it.each(['administrador', 'coordinador', 'cuidador'])(
    'una cuenta sin acceso operativo bloquea al %s en todas las rutas',
    async (rol) => {
      const rpc = cuentaCon(rol, 'organizacion', {}, { acceso_operativo: false });
      const { app, audit } = crearApp({ rpc });
      for (const ruta of todas) {
        const [, url] = ruta;
        // El cuidador conserva el 403 por permiso en la atención; el resto es por la suscripción.
        const res = await llamar(app, ruta).expect(403);
        expect(res.body.error.code).toBe(
          rol === 'cuidador' && url.endsWith('/en-atencion')
            ? 'FORBIDDEN'
            : 'SUBSCRIPTION_INACTIVE',
        );
      }
      sinRpcDeAlertas(rpc);
      sinAuditoriaDeAlertas(audit);
    },
  );

  it('si la base rechaza la cuenta sin acceso operativo, la API responde 403 con su código', async () => {
    const rpc = cuentaCon('coordinador', 'familia', {
      api_alertas_listar: () => {
        throw mapRpcError({ code: 'P0001', message: 'CR_CUENTA_SIN_ACCESO' });
      },
    });
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/alertas`)).expect(403);
    expect(res.body.error.code).toBe('SUBSCRIPTION_INACTIVE');
  });

  it('una cuenta ajena o con identificador inválido no revela alertas', async () => {
    const ajena = cuentaCon('coordinador', 'familia', { api_contexto_cuenta: () => null });
    const { app } = crearApp({ rpc: ajena });
    await conSesion(request(app).get(`${prefijo}/alertas`)).expect(404);
    await conSesion(request(app).get('/api/v1/cuentas/abc/alertas')).expect(404);
    sinRpcDeAlertas(ajena);
  });
});

describe('validación de alertas', () => {
  it.each([
    ['get', `${prefijo}/alertas/3`],
    ['get', `${prefijo}/alertas/no-es-uuid`],
    ['post', `${prefijo}/alertas/3/en-atencion`],
    ['post', `${prefijo}/alertas/3/resolver`],
    ['post', `${prefijo}/notificaciones-alerta/3/leer`],
  ])(
    '%s %s con un identificador que no es UUID responde 404 sin llamar a la base',
    async (metodo, ruta) => {
      const rpc = cuentaCon('coordinador', 'familia');
      const { app, audit } = crearApp({ rpc });
      // El cuerpo es válido: solo el identificador de la ruta debe causar el rechazo.
      const res = await conSesion(request(app)[metodo](ruta))
        .send(ruta.endsWith('/resolver') ? { accion_tomada: 'Se hizo seguimiento.' } : {})
        .expect(404);
      expect(res.body.error.code).toBe('NOT_FOUND');
      sinRpcDeAlertas(rpc);
      sinAuditoriaDeAlertas(audit);
    },
  );

  it.each([
    ['alertas', { 'filter[estado]': 'atendida' }],
    ['alertas', { 'filter[estado]': 'archivada' }],
    ['alertas', { 'filter[tipo]': 'Riesgo Alto' }],
    ['alertas', { 'filter[tipo]': '1riesgo' }],
    ['alertas', { 'filter[envejeciente_id]': 'no-es-uuid' }],
    ['alertas', { 'filter[prioridad]': 'alta' }],
    ['alertas', { estado: 'pendiente' }],
    ['alertas', { sort: 'tipo' }],
    ['alertas', { sort: 'fecha_alerta,fecha_alerta' }],
    ['alertas', { page: '0' }],
    ['alertas', { limit: '101' }],
    ['casos-prioritarios', { 'filter[estado]': 'pendiente' }],
    ['casos-prioritarios', { 'filter[envejeciente_id]': otroAdulto.slice(1) }],
    ['casos-prioritarios', { sort: 'total_alertas' }],
    ['notificaciones-alerta', { 'filter[estado]': 'pendiente' }],
    ['notificaciones-alerta', { 'filter[envejeciente_id]': otroAdulto }],
    ['notificaciones-alerta', { sort: 'mensaje' }],
  ])('%s rechaza la consulta %j con 422 sin llamar a la base', async (ruta, consulta) => {
    const rpc = cuentaCon('coordinador', 'familia');
    const { app } = crearApp({ rpc });
    const res = await conSesion(request(app).get(`${prefijo}/${ruta}`).query(consulta)).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    sinRpcDeAlertas(rpc);
  });

  it('el filtro por adulto distingue a cada adulto y se pasa tal cual a la base', async () => {
    const rpc = cuentaCon('coordinador', 'familia', { api_alertas_listar: paginaDe([]) });
    const { app } = crearApp({ rpc });
    await conSesion(
      request(app).get(`${prefijo}/alertas`).query({ 'filter[envejeciente_id]': otroAdulto }),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith(
      'api_alertas_listar',
      expect.objectContaining({ p_filtros: { envejeciente_id: otroAdulto } }),
    );
  });
});
