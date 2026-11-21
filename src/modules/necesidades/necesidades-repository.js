/* Persistencia de necesidades por RPC · ID05/RF-03. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { paginatedResponse } from '../../lib/collection-query.js';
import { unavailable } from '../../lib/errors.js';
import { candidatoDto, necesidadDto, necesidadEventoDto } from './necesidades-schemas.js';

const paginaNecesidades = z.object({ items: z.array(necesidadDto), total: z.int().min(0) });
const paginaEventos = z.object({ items: z.array(necesidadEventoDto), total: z.int().min(0) });
const paginaCandidatos = z.object({ items: z.array(candidatoDto), total: z.int().min(0) });

function leer(schema, resultado) {
  const parsed = schema.safeParse(resultado);
  if (!parsed.success) throw unavailable();
  return parsed.data;
}

function pagina(schema, resultado, query) {
  const { items, total } = leer(schema, resultado);
  try {
    return paginatedResponse(items, { ...query, total });
  } catch {
    throw unavailable();
  }
}

const paramsPagina = ({ limit, offset, sort }) => ({
  p_limite: limit,
  p_desplazamiento: offset,
  p_orden: sort.map(({ field, direction }) => (direction === 'desc' ? `-${field}` : field)),
});

export function createNecesidadesRepository(rpc, cuentaId) {
  const llamar = (nombre, params) => rpc(nombre, { p_cuenta_id: cuentaId, ...params });
  const ocurrencia = async (nombre, params) => leer(necesidadDto, await llamar(nombre, params));
  return {
    async listar(query) {
      const resultado = await llamar('api_necesidades_listar', {
        p_filtros: { ...query.filters },
        ...paramsPagina(query),
      });
      return pagina(paginaNecesidades, resultado, query);
    },
    async obtener(necesidadId) {
      return ocurrencia('api_necesidad_obtener', { p_necesidad_id: necesidadId });
    },
    async historial(necesidadId, query) {
      const resultado = await llamar('api_necesidad_historial', {
        p_necesidad_id: necesidadId,
        ...paramsPagina(query),
      });
      return pagina(paginaEventos, resultado, query);
    },
    async candidatos(adultoId, query) {
      const resultado = await llamar('api_necesidad_candidatos', {
        p_envejeciente_id: adultoId,
        ...paramsPagina(query),
      });
      return pagina(paginaCandidatos, resultado, query);
    },
    crear(adultoId, datos) {
      return ocurrencia('api_necesidad_crear', { p_envejeciente_id: adultoId, p_datos: datos });
    },
    actualizar(necesidadId, datos) {
      return ocurrencia('api_necesidad_actualizar', {
        p_necesidad_id: necesidadId,
        p_datos: datos,
      });
    },
    cambiarEstado(necesidadId, datos) {
      return ocurrencia('api_necesidad_estado', { p_necesidad_id: necesidadId, p_datos: datos });
    },
  };
}
