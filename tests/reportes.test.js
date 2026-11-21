/* Contrato HTTP de resumen de casos, reportes, exportaciones e informe médico · ID07/RF-07/RF-08. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { celda } from '../src/modules/reportes/reportes-csv.js';
import {
  conSesion,
  contextoVencido,
  crearApp,
  cuentaCon,
  rpcPorNombre,
  usuarioId,
} from './cuentas-support.js';
import { salidas } from './reportes-datos.js';

const prefijo = '/api/v1/cuentas/7';
const adultoId = salidas.informe.identificacion.envejeciente_id;
const todas = ['dashboard_metricas', 'reportes_avanzados', 'registro_visitas'];
const soloDashboard = ['dashboard_metricas', 'registro_visitas'];
const clonar = (x) => structuredClone(x);
const negocio =
  (code, message = 'privado') =>
  () => {
    throw mapRpcError({ code, message });
  };
const manejadores = () => ({
  api_resumen_casos_listar: () => clonar(salidas.resumen),
  api_resumen_casos_indicadores: () => clonar(salidas.indicadores),
  api_reporte: ({ p_tipo }) => clonar(salidas[p_tipo]),
  api_reporte_avanzado: () => clonar(salidas.avanzado),
  api_exportar_reporte_csv: ({ p_tipo }) => ({
    exportacion: { ...clonar(salidas.csv_visitas.exportacion), tipo: p_tipo },
    reporte: clonar(salidas[p_tipo]),
  }),
  api_registrar_exportacion_reporte: () => clonar(salidas.exportacion),
  api_informe_medico: () => clonar(salidas.informe),
});
const app = (rol = 'coordinador', tipo = 'organizacion', funcionalidades = todas, extra = {}) =>
  crearApp({ rpc: cuentaCon(rol, tipo, manejadores(), { funcionalidades, ...extra }) });
const sinRpc = (rpc) =>
  expect(rpc.mock.calls.filter(([nombre]) => nombre !== 'api_contexto_cuenta')).toEqual([]);

// Cada ruta del contrato con una petición válida.
const rutas = {
  resumen: ['get', `${prefijo}/resumen-casos`],
  indicadores: ['get', `${prefijo}/resumen-casos/indicadores`],
  adultos: ['get', `${prefijo}/reportes/adultos`],
  visitas: ['get', `${prefijo}/reportes/visitas`],
  necesidades: ['get', `${prefijo}/reportes/necesidades`],
  casos: ['get', `${prefijo}/reportes/casos-prioritarios`],
  avanzado: ['get', `${prefijo}/reportes/analisis-avanzado`],
  csv: ['get', `${prefijo}/reportes/adultos/exportacion?formato=csv`],
  pdf: ['post', `${prefijo}/reportes/exportaciones`, { tipo: 'adultos', formato: 'pdf' }],
  xlsx: ['post', `${prefijo}/reportes/exportaciones`, { tipo: 'adultos', formato: 'xlsx' }],
  informe: ['get', `${prefijo}/envejecientes/${adultoId}/informe-medico`],
};
const llamar = (aplicacion, [metodo, ruta, cuerpo]) => {
  const peticion = conSesion(request(aplicacion)[metodo](ruta));
  return cuerpo === undefined ? peticion : peticion.send(cuerpo);
};
const binario = (res, callback) => {
  const partes = [];
  res.on('data', (parte) => partes.push(parte));
  res.on('end', () => callback(null, Buffer.concat(partes)));
};
const csvDe = (aplicacion, ruta) =>
  conSesion(request(aplicacion).get(ruta)).buffer(true).parse(binario);

describe('fase 7 · resumen de casos (RF-07)', () => {
  it('pagina con el orden predeterminado y proyecta solo los campos del contrato', async () => {
    const extra = clonar(salidas.resumen);
    extra.items[0].cedula = '00112345678';
    const rpc = cuentaCon('coordinador', 'familia', {
      api_resumen_casos_listar: () => extra,
    });
    const { app: aplicacion } = crearApp({ rpc });
    const res = await conSesion(request(aplicacion).get(`${prefijo}/resumen-casos`)).expect(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.meta).toEqual({ page: 1, limit: 20, total: 2, totalPages: 1 });
    expect(res.body.data).toEqual(salidas.resumen.items);
    expect(res.body.data[0]).not.toHaveProperty('cedula');
    expect(rpc).toHaveBeenCalledWith('api_resumen_casos_listar', {
      p_cuenta_id: '7',
      p_filtros: {},
      p_orden: ['prioridad'],
      p_limite: 20,
      p_desplazamiento: 0,
    });
  });

  it('traduce filtros y orden de CR-162 sin el desempate interno', async () => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_resumen_casos_listar: () => ({ items: [clonar(salidas.resumen.items[1])], total: 2 }),
    });
    const { app: aplicacion } = crearApp({ rpc });
    const asignado = '5d7c8a8e-1a4b-4f0e-9a3e-7e0d1b2c3f40';
    await conSesion(
      request(aplicacion).get(`${prefijo}/resumen-casos`).query({
        page: '2',
        limit: '1',
        sort: '-riesgo,nombre',
        'filter[estado_atencion]': 'alerta_pendiente',
        'filter[prioridad]': 'alta',
        'filter[riesgo]': 'sin_evaluacion',
        'filter[municipio_cod]': '0101',
        'filter[zona]': ' Centro ',
        'filter[asignado]': asignado,
        'filter[q]': 'arias',
      }),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_resumen_casos_listar', {
      p_cuenta_id: '7',
      p_filtros: {
        estado_atencion: 'alerta_pendiente',
        prioridad: 'alta',
        riesgo: 'sin_evaluacion',
        municipio_cod: '0101',
        zona: 'Centro',
        asignado,
        q: 'arias',
      },
      p_orden: ['-riesgo', 'nombre'],
      p_limite: 1,
      p_desplazamiento: 1,
    });
  });

  it.each([
    ['sort=envejeciente_id'],
    ['sort=prioridad,riesgo,nombre'],
    ['sort=fecha'],
    ['sort=riesgo,-riesgo'],
    ['limit=101'],
    ['filter[estado_atencion]=en_atencion'],
    ['filter[asignado]=alguien'],
    ['filter[q]=a'],
    ['filter[municipio_cod]=01'],
    ['filter[desconocido]=1'],
    ['filter[prioridad]=alta&filter[prioridad]=baja'],
  ])('rechaza %s con 422 sin consultar la base', async (consulta) => {
    const { app: aplicacion, rpc } = app();
    const res = await conSesion(
      request(aplicacion).get(`${prefijo}/resumen-casos?${consulta}`),
    ).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    sinRpc(rpc);
  });

  it('indicadores: alertas y adultos prioritarios por separado; sin parámetros', async () => {
    const { app: aplicacion, rpc } = app('coordinador', 'familia', []);
    const res = await conSesion(
      request(aplicacion).get(`${prefijo}/resumen-casos/indicadores`),
    ).expect(200);
    expect(res.body.data).toEqual(salidas.indicadores);
    expect(rpc).toHaveBeenCalledWith('api_resumen_casos_indicadores', { p_cuenta_id: '7' });
    await conSesion(
      request(aplicacion).get(`${prefijo}/resumen-casos/indicadores?filter[riesgo]=alto`),
    ).expect(422);
  });
});

describe('fase 7 · reportes estadísticos (RF-08)', () => {
  it.each([
    ['adultos', 'adultos'],
    ['visitas', 'visitas'],
    ['necesidades', 'necesidades'],
    ['casos-prioritarios', 'casos_prioritarios'],
  ])('GET /reportes/%s publica el reporte del contrato', async (ruta, tipo) => {
    const { app: aplicacion, rpc } = app('administrador', 'organizacion', soloDashboard);
    const res = await conSesion(request(aplicacion).get(`${prefijo}/reportes/${ruta}`)).expect(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.data).toEqual(salidas[tipo]);
    expect(rpc).toHaveBeenCalledWith('api_reporte', {
      p_cuenta_id: '7',
      p_tipo: tipo,
      p_filtros: {},
    });
  });

  it('envía los filtros con sus tipos y admite la categoría solo en necesidades', async () => {
    const { app: aplicacion, rpc } = app();
    await conSesion(
      request(aplicacion).get(
        `${prefijo}/reportes/necesidades?filter[desde]=2026-03-01&filter[hasta]=2026-03-31&filter[tipo_necesidad_id]=2&filter[riesgo]=alto&filter[zona]=Centro&filter[municipio_cod]=0101`,
      ),
    ).expect(200);
    expect(rpc).toHaveBeenCalledWith('api_reporte', {
      p_cuenta_id: '7',
      p_tipo: 'necesidades',
      p_filtros: {
        desde: '2026-03-01',
        hasta: '2026-03-31',
        tipo_necesidad_id: 2,
        riesgo: 'alto',
        zona: 'Centro',
        municipio_cod: '0101',
      },
    });
  });

  it('un reporte vacío es una respuesta válida', async () => {
    const rpc = cuentaCon(
      'coordinador',
      'organizacion',
      { api_reporte: () => clonar(salidas.vacio_necesidades) },
      { funcionalidades: soloDashboard },
    );
    const { app: aplicacion } = crearApp({ rpc });
    const res = await conSesion(request(aplicacion).get(`${prefijo}/reportes/necesidades`)).expect(
      200,
    );
    expect(res.body.data.vacio).toBe(true);
    expect(res.body.data.detalle).toEqual([]);
    expect(res.body.data.indicadores.mas_frecuente).toBeNull();
  });

  it.each([
    ['adultos?filter[tipo_necesidad_id]=1'],
    ['adultos?filter[desde]=2026-05-02&filter[hasta]=2026-05-01'],
    ['adultos?filter[desde]=2026-02-30'],
    ['adultos?filter[riesgo]=critico'],
    ['adultos?filter[zona]=' + 'x'.repeat(61)],
    ['necesidades?filter[tipo_necesidad_id]=0'],
    ['visitas?page=1'],
    ['visitas?formato=csv'],
    ['casos-prioritarios?filter[desde]=2026-01-01&filter[desde]=2026-01-02'],
  ])('GET /reportes/%s es 422 sin consultar la base', async (consulta) => {
    const { app: aplicacion, rpc } = app();
    await conSesion(request(aplicacion).get(`${prefijo}/reportes/${consulta}`)).expect(422);
    sinRpc(rpc);
  });

  it('un tipo desconocido es 404 sin consultar la base', async () => {
    const { app: aplicacion, rpc } = app('familiar');
    await conSesion(request(aplicacion).get(`${prefijo}/reportes/usuarios`)).expect(404);
    await conSesion(
      request(aplicacion).get(`${prefijo}/reportes/usuarios/exportacion?formato=csv`),
    ).expect(404);
    sinRpc(rpc);
  });

  it('una salida que rompe el contrato es 503', async () => {
    const roto = clonar(salidas.adultos);
    delete roto.indicadores.registrados;
    const rpc = cuentaCon(
      'coordinador',
      'organizacion',
      { api_reporte: () => roto },
      { funcionalidades: todas },
    );
    const { app: aplicacion } = crearApp({ rpc });
    const res = await conSesion(request(aplicacion).get(`${prefijo}/reportes/adultos`)).expect(503);
    expect(res.body.error.code).toBe('DEPENDENCY_UNAVAILABLE');
  });

  it('análisis avanzado con reportes_avanzados; no admite la categoría', async () => {
    const { app: aplicacion, rpc } = app('administrador');
    const res = await conSesion(
      request(aplicacion).get(`${prefijo}/reportes/analisis-avanzado?filter[zona]=Centro`),
    ).expect(200);
    expect(res.body.data).toEqual(salidas.avanzado);
    expect(rpc).toHaveBeenCalledWith('api_reporte_avanzado', {
      p_cuenta_id: '7',
      p_filtros: { zona: 'Centro' },
    });
    await conSesion(
      request(aplicacion).get(`${prefijo}/reportes/analisis-avanzado?filter[tipo_necesidad_id]=1`),
    ).expect(422);
  });
});

describe('fase 7 · permisos, plan y vigencia', () => {
  const casos = [
    // rol, tipo de cuenta, rutas permitidas (con todas las funcionalidades del plan)
    ['administrador', 'organizacion', Object.keys(rutas).filter((r) => r !== 'informe')],
    ['coordinador', 'organizacion', Object.keys(rutas)],
    ['cuidador', 'organizacion', ['informe']],
    ['familiar', 'organizacion', []],
    ['voluntario', 'organizacion', []],
    ['coordinador', 'familia', Object.keys(rutas).filter((r) => r !== 'visitas')],
    ['cuidador', 'familia', ['informe']],
    ['familiar', 'familia', []],
  ];
  it.each(casos)('%s de %s: matriz de permisos', async (rol, tipo, permitidas) => {
    for (const [nombre, ruta] of Object.entries(rutas)) {
      const { app: aplicacion, rpc } = app(rol, tipo, todas);
      const res = await llamar(aplicacion, ruta);
      const esperado = permitidas.includes(nombre) ? (ruta[0] === 'post' ? 201 : 200) : 403;
      expect([nombre, res.status]).toEqual([nombre, esperado]);
      if (esperado === 403) {
        expect(res.body.error.code).toBe('FORBIDDEN');
        sinRpc(rpc);
      }
    }
  });

  it('Organización en prueba: reportes y PDF sí; avanzado y Excel no (403 por plan)', async () => {
    for (const [nombre, esperado] of [
      ['adultos', 200],
      ['csv', 200],
      ['pdf', 201],
      ['avanzado', 403],
      ['xlsx', 403],
    ]) {
      const { app: aplicacion, rpc } = app('administrador', 'organizacion', soloDashboard);
      const res = await llamar(aplicacion, rutas[nombre]);
      expect([nombre, res.status]).toEqual([nombre, esperado]);
      if (esperado === 403) sinRpc(rpc);
    }
    const { app: aplicacion, rpc } = app('administrador', 'organizacion', soloDashboard);
    await llamar(aplicacion, [
      'post',
      rutas.pdf[1],
      { tipo: 'analisis_avanzado', formato: 'pdf' },
    ]).expect(403);
    sinRpc(rpc);
  });

  it('Familia en prueba sin dashboard_metricas: resumen e informe sí, reportes y exportaciones no', async () => {
    for (const [nombre, esperado] of [
      ['resumen', 200],
      ['indicadores', 200],
      ['informe', 200],
      ['adultos', 403],
      ['csv', 403],
      ['pdf', 403],
      ['avanzado', 403],
    ]) {
      const { app: aplicacion } = app('coordinador', 'familia', ['registro_visitas']);
      const res = await llamar(aplicacion, rutas[nombre]);
      expect([nombre, res.status]).toEqual([nombre, esperado]);
    }
  });

  it('Familia con métricas: el reporte de visitas exige visitas:ver (solo Organización)', async () => {
    const { app: aplicacion, rpc } = app('coordinador', 'familia', todas);
    await llamar(aplicacion, rutas.visitas).expect(403);
    await llamar(aplicacion, ['get', `${prefijo}/reportes/visitas/exportacion?formato=csv`]).expect(
      403,
    );
    await llamar(aplicacion, ['post', rutas.pdf[1], { tipo: 'visitas', formato: 'pdf' }]).expect(
      403,
    );
    sinRpc(rpc);
  });

  it('cuenta vencida: todo el módulo responde SUBSCRIPTION_INACTIVE', async () => {
    for (const [nombre, ruta] of Object.entries(rutas)) {
      const rpc = rpcPorNombre({
        api_contexto_cuenta: () => contextoVencido('coordinador', 'organizacion'),
      });
      const { app: aplicacion } = crearApp({ rpc });
      const res = await llamar(aplicacion, ruta);
      expect([nombre, res.status, res.body.error.code]).toEqual([
        nombre,
        403,
        'SUBSCRIPTION_INACTIVE',
      ]);
      sinRpc(rpc);
    }
  });

  it('la base tiene la última palabra: 42501 y CR_CUENTA_SIN_ACCESO de la RPC', async () => {
    const rpc = cuentaCon(
      'coordinador',
      'organizacion',
      {
        api_reporte: negocio('42501'),
        api_resumen_casos_indicadores: negocio('P0001', 'CR_CUENTA_SIN_ACCESO'),
      },
      { funcionalidades: todas },
    );
    const { app: aplicacion } = crearApp({ rpc });
    expect((await llamar(aplicacion, rutas.adultos).expect(403)).body.error.code).toBe('FORBIDDEN');
    expect((await llamar(aplicacion, rutas.indicadores).expect(403)).body.error.code).toBe(
      'SUBSCRIPTION_INACTIVE',
    );
  });
});

describe('fase 7 · exportaciones', () => {
  it('CSV auditado: cabeceras, BOM, CRLF y nombre con la fecha de negocio', async () => {
    const rpc = cuentaCon('coordinador', 'organizacion', manejadores(), {
      funcionalidades: soloDashboard,
    });
    // 21/11 a las 02:00 UTC sigue siendo 20/11 en Santo Domingo.
    const { app: aplicacion, audit } = crearApp({
      rpc,
      now: () => new Date('2026-11-21T02:00:00Z'),
    });
    const res = await csvDe(
      aplicacion,
      `${prefijo}/reportes/visitas/exportacion?formato=csv&filter[desde]=2026-01-01`,
    ).expect(200);
    expect(res.headers['content-type']).toBe('text/csv; charset=utf-8');
    expect(res.headers['content-disposition']).toBe(
      'attachment; filename="reporte-visitas-2026-11-20.csv"',
    );
    expect(res.headers['cache-control']).toBe('no-store');
    const bytes = res.body;
    expect([...bytes.subarray(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
    const texto = bytes.toString('utf8').slice(1);
    const lineas = texto.split('\r\n');
    expect(texto).not.toMatch(/[^\r]\n/);
    expect(lineas[0]).toBe('Reporte CuidaRed,Visitas realizadas');
    expect(lineas).toContain('Generado por,Laura Mejía');
    expect(lineas).toContain('Fecha filtrada,fecha_visita');
    expect(lineas).toContain('Indicador,Valor');
    expect(lineas).toContain('visitas_realizadas,2');
    expect(lineas).toContain('Clave,Etiqueta,Valor,Porcentaje');
    expect(lineas).toContain(
      'Fecha,Hora inicio,Hora fin,Razón,Origen,Responsables,Adultos atendidos,Estados observados',
    );
    expect(lineas).toContain(
      '2026-11-19,09:00,09:30,Ronda,interna,Laura Mejía,Rosa Arias | Lucía Castro,estable | sin_registro',
    );
    expect(rpc).toHaveBeenCalledWith('api_exportar_reporte_csv', {
      p_cuenta_id: '7',
      p_tipo: 'visitas',
      p_filtros: { desde: '2026-01-01' },
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId: usuarioId,
        action: 'reporte.exportado_csv',
        result: 'success',
      }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('2026-01-01');
  });

  it('neutraliza fórmulas y entrecomilla separadores en el CSV', async () => {
    const exportado = clonar(salidas.csv_visitas);
    exportado.reporte.detalle[0].razon = '=HYPERLINK("http://x","y")';
    exportado.reporte.detalle[0].responsables[0].nombres = '+Laura';
    exportado.reporte.detalle[1].razon = 'Ronda, "casa"; patio\nfondo';
    exportado.reporte.detalle_truncado = true;
    exportado.reporte.detalle_total = 9;
    const rpc = cuentaCon(
      'coordinador',
      'organizacion',
      { api_exportar_reporte_csv: () => exportado },
      { funcionalidades: soloDashboard },
    );
    const { app: aplicacion } = crearApp({ rpc });
    const res = await csvDe(
      aplicacion,
      `${prefijo}/reportes/visitas/exportacion?formato=csv`,
    ).expect(200);
    const texto = res.body.toString('utf8');
    expect(texto).toContain(`"'=HYPERLINK(""http://x"",""y"")"`);
    expect(texto).toContain("'+Laura Mejía");
    expect(texto).toContain('"Ronda, ""casa""; patio\nfondo"');
    expect(texto).toContain('Detalle recortado,2 de 9\r\n');
    expect(celda('-1')).toBe("'-1");
    expect(celda('@x')).toBe("'@x");
    expect(celda('\tx')).toBe("'\tx");
    expect(celda(-50)).toBe('-50');
    expect(celda(null)).toBe('');
  });

  it('un CSV sin datos conserva cabecera e indicadores', async () => {
    const exportado = {
      exportacion: clonar(salidas.csv_visitas.exportacion),
      reporte: clonar(salidas.vacio_necesidades),
    };
    exportado.exportacion.tipo = 'necesidades';
    const rpc = cuentaCon(
      'coordinador',
      'organizacion',
      { api_exportar_reporte_csv: () => exportado },
      { funcionalidades: soloDashboard },
    );
    const { app: aplicacion } = crearApp({ rpc });
    const texto = (
      await csvDe(aplicacion, `${prefijo}/reportes/necesidades/exportacion?formato=csv`).expect(200)
    ).body.toString('utf8');
    expect(texto).toContain('Categoría,Todas\r\n');
    expect(texto).toContain('registradas,0\r\n');
    expect(texto).toContain('mas_frecuente,\r\n');
    expect(texto).toContain('Sin datos para los filtros seleccionados.\r\n');
    expect(texto).not.toContain('Detalle\r\n');
  });

  it.each([['formato=pdf'], [''], ['formato=csv&formato=csv'], ['formato=csv&filter[x]=1']])(
    'GET exportacion?%s es 422',
    async (consulta) => {
      const { app: aplicacion, rpc } = app();
      await conSesion(
        request(aplicacion).get(`${prefijo}/reportes/adultos/exportacion?${consulta}`),
      ).expect(422);
      sinRpc(rpc);
    },
  );

  it('POST /reportes/exportaciones registra el PDF o el Excel con filtros normalizados', async () => {
    const { app: aplicacion, rpc, audit } = app('coordinador', 'organizacion', todas);
    const cuerpo = {
      tipo: 'necesidades',
      formato: 'xlsx',
      filtros: { desde: '2026-11-01', hasta: null, tipo_necesidad_id: 1 },
    };
    const res = await llamar(aplicacion, ['post', rutas.pdf[1], cuerpo]).expect(201);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.data).toEqual(salidas.exportacion);
    expect(rpc).toHaveBeenCalledWith('api_registrar_exportacion_reporte', {
      p_cuenta_id: '7',
      // `hasta: null` equivale a omitir la clave y no se reenvía.
      p_datos: { ...cuerpo, filtros: { desde: '2026-11-01', tipo_necesidad_id: 1 } },
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'reporte.exportacion_registrada' }),
    );
  });

  it.each([
    [{ tipo: 'adultos', formato: 'csv' }],
    [{ tipo: 'adultos' }],
    [{ tipo: 'usuarios', formato: 'pdf' }],
    [{ tipo: 'adultos', formato: 'pdf', extra: true }],
    [{ tipo: 'adultos', formato: 'pdf', filtros: { tipo_necesidad_id: 1 } }],
    [{ tipo: 'adultos', formato: 'pdf', filtros: { desde: '2026-05-02', hasta: '2026-05-01' } }],
    [{ tipo: 'adultos', formato: 'pdf', filtros: { otro: 1 } }],
    [{ tipo: 'adultos', formato: 'pdf', filtros: { desde: '2026-13-01' } }],
  ])('POST /reportes/exportaciones %j es 422', async (cuerpo) => {
    const { app: aplicacion, rpc } = app();
    await llamar(aplicacion, ['post', rutas.pdf[1], cuerpo]).expect(422);
    sinRpc(rpc);
  });
});

describe('fase 7 · informe médico', () => {
  it('Coordinador: informe auditado, sin caché ni contenido en la bitácora técnica', async () => {
    const extra = clonar(salidas.informe);
    extra.identificacion.direccion = 'Calle privada 1';
    const rpc = cuentaCon('coordinador', 'organizacion', { api_informe_medico: () => extra });
    const { app: aplicacion, audit } = crearApp({ rpc });
    const res = await llamar(aplicacion, rutas.informe).expect(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.body.data).toEqual(salidas.informe);
    expect(res.body.data.identificacion).not.toHaveProperty('direccion');
    expect(rpc).toHaveBeenCalledWith('api_informe_medico', {
      p_cuenta_id: '7',
      p_envejeciente_id: adultoId,
    });
    expect(audit).toHaveBeenCalledWith(
      expect.objectContaining({ actorId: usuarioId, action: 'informe_medico.generado' }),
    );
    expect(JSON.stringify(audit.mock.calls)).not.toContain('Obs');
  });

  it('secciones omitidas llegan como null', async () => {
    const omitido = { ...clonar(salidas.informe), riesgo: null, indicaciones: null, visitas: null };
    omitido.secciones_omitidas = ['indicaciones', 'riesgo', 'visitas'];
    const rpc = cuentaCon('cuidador', 'familia', { api_informe_medico: () => omitido });
    const { app: aplicacion } = crearApp({ rpc });
    const res = await llamar(aplicacion, rutas.informe).expect(200);
    expect(res.body.data.secciones_omitidas).toEqual(['indicaciones', 'riesgo', 'visitas']);
    expect(res.body.data.riesgo).toBeNull();
  });

  it('fuera de alcance, de otra cuenta o inexistente es 404; un id mal formado no llega a la base', async () => {
    const rpc = cuentaCon('cuidador', 'organizacion', { api_informe_medico: negocio('P0002') });
    const { app: aplicacion } = crearApp({ rpc });
    expect((await llamar(aplicacion, rutas.informe).expect(404)).body.error.code).toBe('NOT_FOUND');
    rpc.mockClear();
    await llamar(aplicacion, ['get', `${prefijo}/envejecientes/no-es-uuid/informe-medico`]).expect(
      404,
    );
    await llamar(aplicacion, ['get', `${rutas.informe[1]}?filter[x]=1`]).expect(422);
    sinRpc(rpc);
  });
});

describe('fase 7 · auditoría de la cuenta', () => {
  it('acepta la acción `exportacion` y conserva las anteriores', async () => {
    const items = [
      {
        auditoria_id: '3',
        actor: 'Laura Mejía',
        accion: 'exportacion',
        entidad: 'informe_medico',
        fecha: '2026-11-20T10:00:00-04:00',
        resultado: 'confirmado',
      },
      {
        auditoria_id: '2',
        actor: 'Laura Mejía',
        accion: 'exportacion',
        entidad: 'exportacion_reporte',
        fecha: '2026-11-20T09:00:00-04:00',
        resultado: 'confirmado',
      },
      {
        auditoria_id: '1',
        actor: null,
        accion: 'alta',
        entidad: 'envejeciente',
        fecha: '2026-11-20T08:00:00-04:00',
        resultado: 'confirmado',
      },
    ];
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_auditoria_cuenta: () => ({ items, total: 3 }),
    });
    const { app: aplicacion } = crearApp({ rpc });
    const res = await conSesion(request(aplicacion).get(`${prefijo}/auditoria`)).expect(200);
    expect(res.body.data.map((e) => e.accion)).toEqual(['exportacion', 'exportacion', 'alta']);
  });

  it('una acción desconocida sigue siendo un contrato roto', async () => {
    const rpc = cuentaCon('administrador', 'organizacion', {
      api_auditoria_cuenta: () => ({
        items: [
          {
            auditoria_id: '1',
            actor: null,
            accion: 'borrado',
            entidad: 'x',
            fecha: '2026-11-20T08:00:00Z',
            resultado: 'confirmado',
          },
        ],
        total: 1,
      }),
    });
    const { app: aplicacion } = crearApp({ rpc });
    await conSesion(request(aplicacion).get(`${prefijo}/auditoria`)).expect(503);
  });
});

describe('fase 7 · revisión independiente', () => {
  it('neutraliza fórmulas tras espacios y en su forma de ancho completo', () => {
    expect(celda('  =1+1')).toBe("'  =1+1");
    expect(celda(' +A1')).toBe("' +A1");
    expect(celda('　-2')).toBe("'　-2");
    expect(celda('＝SUM(A1:A9)')).toBe("'＝SUM(A1:A9)");
    expect(celda('＋1')).toBe("'＋1");
    expect(celda('－1')).toBe("'－1");
    expect(celda('＠x')).toBe("'＠x");
    expect(celda('a=b')).toBe('a=b');
    expect(celda('  texto')).toBe('  texto');
  });

  it('POST /reportes/exportaciones acepta los filtros normalizados con claves en null', async () => {
    const { app: aplicacion, rpc } = app('coordinador', 'organizacion', soloDashboard);
    const normalizados = { ...salidas.adultos.filtros, desde: '2026-11-01' };
    expect(normalizados.tipo_necesidad_id).toBeNull();
    await llamar(aplicacion, [
      'post',
      rutas.pdf[1],
      { tipo: 'adultos', formato: 'pdf', filtros: { ...normalizados, otro: null } },
    ]).expect(201);
    expect(rpc).toHaveBeenCalledWith('api_registrar_exportacion_reporte', {
      p_cuenta_id: '7',
      p_datos: { tipo: 'adultos', formato: 'pdf', filtros: { desde: '2026-11-01' } },
    });
    await llamar(aplicacion, [
      'post',
      rutas.pdf[1],
      { tipo: 'adultos', formato: 'pdf', filtros: { tipo_necesidad_id: 1 } },
    ]).expect(422);
  });

  it('el análisis avanzado admite métricas de visitas en null (sin visitas:ver)', async () => {
    const sinVisitas = clonar(salidas.avanzado);
    for (const fila of [...sinVisitas.comparativo_zonas, ...sinVisitas.comparativo_municipios]) {
      fila.visitas_realizadas = null;
      fila.visitas_por_adulto = null;
    }
    for (const mes of sinVisitas.tendencias) {
      mes.visitas_realizadas = null;
      mes.variacion_visitas = null;
    }
    const rpc = cuentaCon(
      'coordinador',
      'familia',
      { api_reporte_avanzado: () => sinVisitas },
      { funcionalidades: todas },
    );
    const { app: aplicacion } = crearApp({ rpc });
    const res = await llamar(aplicacion, rutas.avanzado).expect(200);
    expect(res.body.data.comparativo_zonas[0].visitas_realizadas).toBeNull();
    expect(res.body.data.tendencias.every((m) => m.visitas_realizadas === null)).toBe(true);
  });

  it('el informe admite factores y niveles heredados sin código', async () => {
    const heredado = clonar(salidas.informe);
    heredado.riesgo.vigentes[0].factor.codigo = null;
    heredado.riesgo.vigentes[0].nivel.codigo = null;
    heredado.riesgo.historial[0].factor.codigo = null;
    heredado.riesgo.nivel_vigente = null;
    const rpc = cuentaCon('coordinador', 'organizacion', { api_informe_medico: () => heredado });
    const { app: aplicacion } = crearApp({ rpc });
    const res = await llamar(aplicacion, rutas.informe).expect(200);
    expect(res.body.data.riesgo.vigentes[0].factor).toEqual({
      codigo: null,
      nombre: 'Riesgo de caída',
    });
  });
});
