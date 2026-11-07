/* Catálogos con caché para formularios · CR-165/RF-06. © 2026 Equipo CuidaRed – INTEC. */
import { Router } from 'express';
import { AppError, unavailable } from '../../lib/errors.js';
import { createCollectionQuery, paginatedResponse } from '../../lib/collection-query.js';
import { createTtlCache } from './catalogos-cache.js';
import { CATALOGOS } from './catalogos-config.js';
import { createCatalogosRepository } from './catalogos-repository.js';

const consultaInvalida = () =>
  new AppError(422, 'INVALID_INPUT', 'Revisa los parámetros de consulta.');
const noEncontrado = () => new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');

// Lector de page/limit/sort de cada catálogo paginado (CR-162), creado una vez.
const lectores = new Map(
  Object.entries(CATALOGOS)
    .filter(([, config]) => config.paginacion)
    .map(([nombre, config]) => [nombre, createCollectionQuery(config.paginacion)]),
);

/**
 * Separa los filtros propios del catálogo de la paginación y valida ambos con lista cerrada: un parámetro
 * desconocido, repetido o inválido es 422. Devuelve el filtro que recibe la RPC y la paginación (o null).
 */
function leerConsulta(nombre, query) {
  const { filtros = {} } = CATALOGOS[nombre];
  const filtro = {};
  const resto = {};
  for (const [clave, valor] of Object.entries(query ?? {})) {
    if (!Object.hasOwn(filtros, clave)) {
      resto[clave] = valor;
      continue;
    }
    const leido = typeof valor === 'string' ? filtros[clave].safeParse(valor) : { success: false };
    if (!leido.success) throw consultaInvalida();
    filtro[clave] = leido.data;
  }
  const lector = lectores.get(nombre);
  if (!lector) {
    if (Object.keys(resto).length) throw consultaInvalida();
    return { filtro, paginacion: null };
  }
  const paginacion = lector(resto);
  return {
    filtro: {
      ...filtro,
      limit: paginacion.limit,
      offset: paginacion.offset,
      sort: paginacion.sort,
    },
    paginacion,
  };
}

// GET /catalogos/:catalogo. Requiere sesión (la valida app.js), no cuenta: son datos de referencia comunes a todos.
export function createCatalogosRouter(deps) {
  const router = Router({ mergeParams: true });
  // Un solo caché por instancia de la API; la clave incluye catálogo, filtros y página, nunca datos del usuario.
  const cache = createTtlCache({ now: () => (deps.now?.() ?? new Date()).getTime() });

  router.get('/catalogos/:catalogo', async (req, res) => {
    const { catalogo } = req.params;
    if (!Object.hasOwn(CATALOGOS, catalogo)) throw noEncontrado();
    const { filtro, paginacion } = leerConsulta(catalogo, req.query);
    const repositorio = createCatalogosRepository(res.locals.access.repository.rpc);
    const { items, total } = await cache.get(JSON.stringify([catalogo, filtro]), () =>
      repositorio.catalogo(catalogo, filtro),
    );
    let cuerpo;
    try {
      cuerpo = paginacion ? paginatedResponse(items, { ...paginacion, total }) : { data: items };
    } catch {
      throw unavailable();
    }
    // La API responde `no-store` por defecto; los catálogos son referencia y pueden guardarse 5 minutos.
    res.set('Cache-Control', 'private, max-age=300');
    res.json(cuerpo);
  });

  return router;
}
