/* Pruebas API CR-165/RF-06: catálogos con caché de 5 minutos, sin base real. © 2026 Equipo CuidaRed – INTEC. */
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';
import { mapRpcError } from '../src/modules/access/supabase-gateway.js';
import { createTtlCache } from '../src/modules/catalogos/catalogos-cache.js';
import { CATALOGOS } from '../src/modules/catalogos/catalogos-config.js';
import { conSesion, crearApp, rpcPorNombre } from './cuentas-support.js';

const provincias = [
  { provincia_cod: '01', nombre: 'Distrito Nacional' },
  { provincia_cod: '02', nombre: 'Azua' },
];
const municipios = [
  { municipio_cod: '0201', nombre: 'Azua de Compostela', provincia_cod: '02' },
  { municipio_cod: '0202', nombre: 'Las Charcas', provincia_cod: '02' },
];

const catalogo = (items, total = items.length) => ({ items, total });
const pedir = (app, ruta) => conSesion(request(app).get(`/api/v1/catalogos/${ruta}`));
const llamadasAlCatalogo = (rpc) => rpc.mock.calls.filter(([nombre]) => nombre === 'api_catalogo');

describe('CR-165: GET /catalogos/:catalogo', () => {
  it('lista un catálogo con {data} y caché privada de 5 minutos', async () => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo(provincias) });
    const res = await pedir(crearApp({ rpc }).app, 'provincias').expect(200);
    expect(res.body).toEqual({ data: provincias });
    expect(res.headers['cache-control']).toBe('private, max-age=300');
    expect(rpc).toHaveBeenCalledWith('api_catalogo', { p_nombre: 'provincias', p_filtro: {} });
  });

  it('exige sesión pero no cuenta', async () => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo(provincias) });
    const { app } = crearApp({ rpc });
    const res = await request(app).get('/api/v1/catalogos/provincias').expect(401);
    expect(res.headers['cache-control']).toBe('no-store');
    await pedir(app, 'provincias').expect(200);
    expect(rpc).not.toHaveBeenCalledWith('api_contexto_cuenta', expect.anything());
  });

  it('publica exactamente los 16 catálogos acordados y nada más', async () => {
    expect(Object.keys(CATALOGOS).sort()).toEqual(
      [
        'provincias',
        'municipios',
        'tipos-cuenta',
        'categorias-cuenta',
        'roles',
        'planes',
        'tipos-cuidado',
        'tipos-vinculo',
        'prioridades',
        'niveles-riesgo',
        'riesgos',
        'tipos-necesidad',
        'necesidades',
        'tipos-alerta',
        'tipos-indicacion',
        'metodos-pago',
      ].sort(),
    );
    const rpc = rpcPorNombre({ api_catalogo: ({ p_nombre }) => catalogo([{ nombre: p_nombre }]) });
    const { app } = crearApp({ rpc });
    for (const nombre of Object.keys(CATALOGOS)) {
      const res = await pedir(app, nombre).expect(200);
      expect(res.headers['cache-control']).toBe('private, max-age=300');
    }
  });

  it.each([
    'usuarios',
    'cuenta',
    'parametros',
    'constructor',
    '__proto__',
    'Provincias',
    'tipos_cuenta',
  ])('un catálogo fuera de la lista (%s) es 404 y no llega a la base', async (nombre) => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo([]) });
    const res = await pedir(crearApp({ rpc }).app, nombre).expect(404);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(rpc).not.toHaveBeenCalled();
  });

  it('los filtros se validan y se envían tipados a la base', async () => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo([]) });
    const { app } = crearApp({ rpc });
    await pedir(app, 'categorias-cuenta?tipo=familia').expect(200);
    await pedir(app, 'planes?tipo=organizacion').expect(200);
    await pedir(app, 'necesidades?tipo_necesidad_id=3').expect(200);
    expect(rpc).toHaveBeenCalledWith('api_catalogo', {
      p_nombre: 'categorias-cuenta',
      p_filtro: { tipo: 'familia' },
    });
    expect(rpc).toHaveBeenCalledWith('api_catalogo', {
      p_nombre: 'planes',
      p_filtro: { tipo: 'organizacion' },
    });
    expect(rpc).toHaveBeenCalledWith('api_catalogo', {
      p_nombre: 'necesidades',
      p_filtro: { tipo_necesidad_id: 3 },
    });
  });

  it.each([
    'categorias-cuenta?tipo=hogar',
    'categorias-cuenta?tipo=',
    'categorias-cuenta?tipo=familia&tipo=organizacion',
    'planes?tipo=FAMILIA',
    'necesidades?tipo_necesidad_id=abc',
    'necesidades?tipo_necesidad_id=0',
    'necesidades?tipo_necesidad_id=1.5',
    'necesidades?tipo_necesidad_id=100000',
    'provincias?tipo=familia',
    'provincias?page=1',
    'roles?limit=5',
    'roles?sort=nombre',
    'planes?filter%5Btipo%5D=familia',
    'municipios?provincia_cod=2',
    'municipios?provincia_cod=ab',
    'municipios?provincia_cod=02&provincia_cod=03',
    'municipios?tipo=familia',
  ])('rechaza con 422 sin tocar la base: %s', async (ruta) => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo([]) });
    const res = await pedir(crearApp({ rpc }).app, ruta).expect(422);
    expect(res.body.error.code).toBe('INVALID_INPUT');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(rpc).not.toHaveBeenCalled();
  });

  describe('municipios (paginado, CR-162)', () => {
    it('devuelve data y meta, y envía página, orden y filtro a la base', async () => {
      const rpc = rpcPorNombre({ api_catalogo: () => catalogo(municipios, 2) });
      const res = await pedir(crearApp({ rpc }).app, 'municipios?provincia_cod=02').expect(200);
      expect(res.body).toEqual({
        data: municipios,
        meta: { page: 1, limit: 20, total: 2, totalPages: 1 },
      });
      expect(res.headers['cache-control']).toBe('private, max-age=300');
      expect(rpc).toHaveBeenCalledWith('api_catalogo', {
        p_nombre: 'municipios',
        p_filtro: {
          provincia_cod: '02',
          limit: 20,
          offset: 0,
          sort: [
            { field: 'nombre', direction: 'asc' },
            { field: 'municipio_cod', direction: 'asc' },
          ],
        },
      });
    });

    it('acepta page, limit y sort permitidos y calcula el desplazamiento', async () => {
      const rpc = rpcPorNombre({ api_catalogo: () => catalogo([municipios[1]], 30) });
      const res = await pedir(
        crearApp({ rpc }).app,
        'municipios?page=2&limit=25&sort=-municipio_cod',
      ).expect(200);
      expect(res.body.meta).toEqual({ page: 2, limit: 25, total: 30, totalPages: 2 });
      expect(rpc).toHaveBeenCalledWith('api_catalogo', {
        p_nombre: 'municipios',
        p_filtro: { limit: 25, offset: 25, sort: [{ field: 'municipio_cod', direction: 'desc' }] },
      });
    });

    it('una página fuera del conjunto devuelve 200 con data vacía', async () => {
      const rpc = rpcPorNombre({ api_catalogo: () => catalogo([], 2) });
      const res = await pedir(crearApp({ rpc }).app, 'municipios?page=9').expect(200);
      expect(res.body).toEqual({ data: [], meta: { page: 9, limit: 20, total: 2, totalPages: 1 } });
    });

    it.each([
      'municipios?page=0',
      'municipios?page=x',
      'municipios?limit=101',
      'municipios?limit=0',
      'municipios?sort=provincia_cod',
      'municipios?sort=nombre,nombre',
      'municipios?filter%5Bprovincia_cod%5D=02',
      'municipios?q=azua',
      'municipios?page=1&page=2',
    ])('rechaza con 422: %s', async (ruta) => {
      const rpc = rpcPorNombre({ api_catalogo: () => catalogo(municipios, 2) });
      await pedir(crearApp({ rpc }).app, ruta).expect(422);
      expect(rpc).not.toHaveBeenCalled();
    });

    it('una paginación incoherente de la base es indisponibilidad', async () => {
      const rpc = rpcPorNombre({ api_catalogo: () => catalogo(municipios, 1) });
      await pedir(crearApp({ rpc }).app, 'municipios').expect(503);
    });
  });

  describe('errores de la base', () => {
    it.each([
      [{ code: '28000' }, 401],
      [{ code: 'P0002' }, 404],
      [{ code: '22023' }, 422],
      [{ code: 'PGRST202' }, 503],
    ])('traduce %j a %i', async (error, estado) => {
      const rpc = vi.fn().mockRejectedValue(mapRpcError(error));
      await pedir(crearApp({ rpc }).app, 'provincias').expect(estado);
    });

    it.each([
      null,
      {},
      { items: 'x', total: 1 },
      { items: [], total: -1 },
      { items: [1], total: 1 },
    ])('un contrato roto (%j) es indisponibilidad, no un catálogo vacío', async (roto) => {
      const rpc = rpcPorNombre({ api_catalogo: () => roto });
      await pedir(crearApp({ rpc }).app, 'provincias').expect(503);
    });
  });
});

describe('CR-165: caché en memoria con TTL de 5 minutos', () => {
  const reloj = () => {
    let ahora = Date.UTC(2026, 10, 6, 12, 0, 0);
    return { now: () => new Date(ahora), avanzar: (ms) => (ahora += ms) };
  };

  it('la segunda petición idéntica no vuelve a la base', async () => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo(provincias) });
    const { app } = crearApp({ rpc });
    const primera = await pedir(app, 'provincias').expect(200);
    const segunda = await pedir(app, 'provincias').expect(200);
    expect(segunda.body).toEqual(primera.body);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(1);
  });

  it('los filtros y las páginas tienen su propia entrada', async () => {
    const rpc = rpcPorNombre({
      api_catalogo: ({ p_filtro }) =>
        catalogo(p_filtro.tipo === 'familia' ? [{ nombre: 'F' }] : [{ nombre: 'O' }]),
    });
    const { app } = crearApp({ rpc });
    const familia = await pedir(app, 'planes?tipo=familia').expect(200);
    const organizacion = await pedir(app, 'planes?tipo=organizacion').expect(200);
    expect(familia.body.data).toEqual([{ nombre: 'F' }]);
    expect(organizacion.body.data).toEqual([{ nombre: 'O' }]);
    await pedir(app, 'planes?tipo=familia').expect(200);
    await pedir(app, 'planes?tipo=organizacion').expect(200);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(2);
  });

  it('el mismo conjunto pedido con parámetros equivalentes comparte entrada', async () => {
    const rpc = rpcPorNombre({
      api_catalogo: ({ p_filtro }) => catalogo(p_filtro.offset === 0 ? municipios : [], 2),
    });
    const { app } = crearApp({ rpc });
    await pedir(app, 'municipios').expect(200);
    await pedir(app, 'municipios?page=1&limit=20&sort=nombre').expect(200);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(1);
    await pedir(app, 'municipios?page=2').expect(200);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(2);
  });

  it('vence a los 5 minutos y entonces recarga de la base', async () => {
    const tiempo = reloj();
    let version = 1;
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo([{ version: version++ }]) });
    const { app } = crearApp({ rpc, now: tiempo.now });
    expect((await pedir(app, 'riesgos').expect(200)).body.data).toEqual([{ version: 1 }]);
    tiempo.avanzar(5 * 60 * 1000 - 1);
    expect((await pedir(app, 'riesgos').expect(200)).body.data).toEqual([{ version: 1 }]);
    tiempo.avanzar(2);
    expect((await pedir(app, 'riesgos').expect(200)).body.data).toEqual([{ version: 2 }]);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(2);
  });

  it('un fallo de la base no se guarda: la siguiente petición reintenta', async () => {
    const rpc = vi
      .fn()
      .mockRejectedValueOnce(mapRpcError({ code: 'PGRST202' }))
      .mockResolvedValue(catalogo(provincias));
    const { app } = crearApp({ rpc });
    await pedir(app, 'provincias').expect(503);
    await pedir(app, 'provincias').expect(200);
    await pedir(app, 'provincias').expect(200);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(2);
  });

  it('las peticiones simultáneas comparten una sola carga', async () => {
    let liberar;
    const espera = new Promise((resolver) => {
      liberar = resolver;
    });
    const rpc = rpcPorNombre({
      api_catalogo: async () => {
        await espera;
        return catalogo(provincias);
      },
    });
    const { app } = crearApp({ rpc });
    const pendientes = [1, 2, 3].map(() => pedir(app, 'provincias').then((res) => res.status));
    await vi.waitFor(() => expect(llamadasAlCatalogo(rpc)).toHaveLength(1));
    liberar();
    expect(await Promise.all(pendientes)).toEqual([200, 200, 200]);
    expect(llamadasAlCatalogo(rpc)).toHaveLength(1);
  });

  it('una petición sin sesión no se beneficia de la caché ya cargada', async () => {
    const rpc = rpcPorNombre({ api_catalogo: () => catalogo(provincias) });
    const { app } = crearApp({ rpc });
    await pedir(app, 'provincias').expect(200);
    await request(app).get('/api/v1/catalogos/provincias').expect(401);
    await request(app)
      .get('/api/v1/catalogos/provincias')
      .set('Authorization', 'Bearer')
      .expect(401);
  });

  describe('createTtlCache', () => {
    it('acota la cantidad de claves descartando las más antiguas', async () => {
      const cache = createTtlCache({ maxEntries: 3, now: () => 0 });
      for (const clave of ['a', 'b', 'c', 'd', 'e']) await cache.get(clave, async () => clave);
      expect(cache.size).toBe(3);
      const cargar = vi.fn(async () => 'nuevo');
      await cache.get('a', cargar);
      expect(cargar).toHaveBeenCalledTimes(1);
      await cache.get('e', cargar);
      expect(cargar).toHaveBeenCalledTimes(1);
    });

    it('descarta lo vencido al insertar', async () => {
      let ahora = 0;
      const cache = createTtlCache({ ttlMs: 10, now: () => ahora });
      await cache.get('a', async () => 1);
      await cache.get('b', async () => 2);
      ahora = 11;
      await cache.get('c', async () => 3);
      expect(cache.size).toBe(1);
    });

    it('trata como fallo una carga que lanza de forma síncrona', async () => {
      const cache = createTtlCache();
      await expect(
        cache.get('x', () => {
          throw new Error('boom');
        }),
      ).rejects.toThrow('boom');
      expect(await cache.get('x', async () => 'ok')).toBe('ok');
    });
  });
});
