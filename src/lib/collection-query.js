/* Paginación, orden y filtros de colecciones · CR-162. © 2026 Equipo CuidaRed – INTEC. */
import { AppError } from './errors.js';

export const DEFAULT_PAGE = 1;
export const DEFAULT_LIMIT = 20;
export const MAX_LIMIT = 100;
const fieldPattern = /^[a-z][a-z0-9_]*$/;
const invalid = () => new AppError(422, 'INVALID_INPUT', 'Revisa los parámetros de consulta.');

function integer(value, fallback, maximum = Number.MAX_SAFE_INTEGER) {
  if (value === undefined) return fallback;
  if (typeof value !== 'string' || !/^[1-9]\d*$/.test(value)) throw invalid();
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number > maximum) throw invalid();
  return number;
}

// La configuración viene del servidor; nunca usar columnas u operadores del cliente como SQL.
export function createCollectionQuery({
  sortableFields,
  defaultSort,
  tieBreaker,
  filterSchemas = {},
}) {
  const fields = new Set(sortableFields);
  if (
    !fields.size ||
    [...fields].some((field) => !fieldPattern.test(field)) ||
    !fields.has(tieBreaker) ||
    typeof defaultSort !== 'string' ||
    Object.entries(filterSchemas).some(
      ([field, schema]) => !fieldPattern.test(field) || typeof schema?.safeParse !== 'function',
    )
  ) {
    throw new Error('Configuración de colección inválida.');
  }
  const parseSort = (value) => {
    if (typeof value !== 'string') throw invalid();
    const seen = new Set();
    const sort = value.split(',').map((token) => {
      const descending = token.startsWith('-');
      const field = descending ? token.slice(1) : token;
      if (!fields.has(field) || seen.has(field)) throw invalid();
      seen.add(field);
      return { field, direction: descending ? 'desc' : 'asc' };
    });
    if (!seen.has(tieBreaker)) sort.push({ field: tieBreaker, direction: 'asc' });
    return sort;
  };
  // Un orden predeterminado incorrecto es un fallo del contrato, no de la petición.
  try {
    parseSort(defaultSort);
  } catch {
    throw new Error('Orden predeterminado de colección inválido.');
  }

  return (query = {}) => {
    if (!query || typeof query !== 'object' || Array.isArray(query)) throw invalid();
    const page = integer(query.page, DEFAULT_PAGE);
    const limit = integer(query.limit, DEFAULT_LIMIT, MAX_LIMIT);
    const offset = (page - 1) * limit;
    if (!Number.isSafeInteger(offset)) throw invalid();
    const filters = Object.create(null);
    for (const [key, value] of Object.entries(query)) {
      if (['page', 'limit', 'sort'].includes(key)) continue;
      const match = /^filter\[([a-z][a-z0-9_]*)\]$/.exec(key);
      if (!match || !Object.hasOwn(filterSchemas, match[1]) || typeof value !== 'string')
        throw invalid();
      const result = filterSchemas[match[1]].safeParse(value);
      if (!result.success) throw invalid();
      filters[match[1]] = result.data;
    }
    return { page, limit, offset, sort: parseSort(query.sort ?? defaultSort), filters };
  };
}

// Los datos y el total deben proceder del mismo conjunto autorizado y filtrado.
export function paginatedResponse(data, { page, limit, total }) {
  if (
    !Array.isArray(data) ||
    !Number.isSafeInteger(page) ||
    page < 1 ||
    !Number.isSafeInteger(limit) ||
    limit < 1 ||
    limit > MAX_LIMIT ||
    !Number.isSafeInteger(total) ||
    total < 0 ||
    data.length > limit ||
    data.length > total ||
    (data.length > 0 && (page - 1) * limit >= total)
  ) {
    throw new Error('Resultado paginado inconsistente.');
  }
  return { data, meta: { page, limit, total, totalPages: Math.ceil(total / limit) } };
}
