/* Contrato CR-162 de colecciones sin base real. © 2026 Equipo CuidaRed – INTEC. */
import { parse } from 'node:querystring';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { createCollectionQuery, paginatedResponse } from '../src/lib/collection-query.js';

const read = createCollectionQuery({
  sortableFields: ['fecha_creacion', 'nombres', 'id'],
  defaultSort: '-fecha_creacion',
  tieBreaker: 'id',
  filterSchemas: {
    estado: z.enum(['activo', 'inactivo']),
    edad: z.string().regex(/^\d+$/).transform(Number),
  },
});

describe('CR-162: consulta de colecciones', () => {
  it('aplica valores acordados y desempate estable', () => {
    expect(read({})).toEqual({
      page: 1,
      limit: 20,
      offset: 0,
      sort: [
        { field: 'fecha_creacion', direction: 'desc' },
        { field: 'id', direction: 'asc' },
      ],
      filters: {},
    });
  });
  it('interpreta parámetros codificados por URLSearchParams y filtros tipados', () => {
    const query = new URLSearchParams({
      page: '2',
      limit: '100',
      sort: '-fecha_creacion,nombres',
      'filter[estado]': 'activo',
      'filter[edad]': '70',
    });
    expect(read(parse(query.toString()))).toEqual({
      page: 2,
      limit: 100,
      offset: 100,
      sort: [
        { field: 'fecha_creacion', direction: 'desc' },
        { field: 'nombres', direction: 'asc' },
        { field: 'id', direction: 'asc' },
      ],
      filters: { estado: 'activo', edad: 70 },
    });
  });
  it('respeta un desempate explícito sin duplicarlo', () => {
    expect(read({ sort: '-id' }).sort).toEqual([{ field: 'id', direction: 'desc' }]);
  });
  it.each([
    'page=0',
    'page=-1',
    'page=1.5',
    'page=1e2',
    'page=',
    'page=9007199254740992',
    'page=9007199254740991&limit=100',
    'limit=0',
    'limit=101',
    'limit=20&limit=30',
    'sort=',
    'sort=correo',
    'sort=nombres,-nombres',
    'sort=nombres,',
    'filter[estado]=otro',
    'filter[estado]=activo&filter[estado]=inactivo',
    'filter[correo]=test',
    'filter[estado][eq]=activo',
    'filter[__proto__]=test',
    'filter[edad]=70%20OR%201%3D1',
    'filter=estado:activo',
    'unknown=value',
  ])('rechaza la consulta inválida %s con 422 sin usar sus valores como SQL', (query) => {
    expect(() => read(parse(query))).toThrow(
      expect.objectContaining({ status: 422, code: 'INVALID_INPUT' }),
    );
  });
  it('no hereda filtros de prototipos', () => {
    expect(() => read({ 'filter[constructor]': 'test' })).toThrow(
      expect.objectContaining({ status: 422 }),
    );
  });
});

describe('CR-162: respuesta paginada', () => {
  it('representa una colección vacía sin 404', () => {
    expect(paginatedResponse([], { page: 1, limit: 20, total: 0 })).toEqual({
      data: [],
      meta: { page: 1, limit: 20, total: 0, totalPages: 0 },
    });
  });
  it('conserva los metadatos de una página fuera del conjunto', () => {
    expect(paginatedResponse([], { page: 8, limit: 20, total: 21 })).toEqual({
      data: [],
      meta: { page: 8, limit: 20, total: 21, totalPages: 2 },
    });
  });
  it('calcula el total de páginas sin redondear hacia abajo', () => {
    expect(
      paginatedResponse([{ id: 'fixture' }], { page: 2, limit: 20, total: 21 }).meta.totalPages,
    ).toBe(2);
  });
  it('rechaza resultados inconsistentes del repositorio', () => {
    expect(() => paginatedResponse([{ id: 'fixture' }], { page: 8, limit: 20, total: 21 })).toThrow(
      'Resultado paginado inconsistente.',
    );
  });
});
