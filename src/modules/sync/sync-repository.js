/* Persistencia de la sincronización de visitas mediante RPC · RF-10, RNF-4.2. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from '../../lib/errors.js';
import { RESULTADOS } from './sync-schemas.js';

const esObjeto = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const texto = (value) => (typeof value === 'string' ? value : null);

/**
 * Lista cerrada de campos que salen hacia el cliente. Un contrato roto de la base (no es un objeto, resultado desconocido,
 * identificadores ausentes) es indisponibilidad (503), nunca un resultado inventado. `motivo`, `gana` y `resultado_original`
 * solo aparecen cuando existen; `actualizado_en_servidor` siempre sale (nulo si no hay versión que informar).
 */
export function leerResultado(item) {
  if (
    !esObjeto(item) ||
    !RESULTADOS.includes(item.resultado) ||
    typeof item.id_cliente !== 'string' ||
    typeof item.registro_id !== 'string'
  ) {
    throw unavailable();
  }
  const resultado = {
    id_cliente: item.id_cliente,
    resultado: item.resultado,
    registro_id: item.registro_id,
  };
  if (texto(item.motivo)) resultado.motivo = item.motivo;
  if (item.gana === 'local' || item.gana === 'servidor') resultado.gana = item.gana;
  if (RESULTADOS.includes(item.resultado_original)) {
    resultado.resultado_original = item.resultado_original;
  }
  resultado.actualizado_en_servidor = texto(item.actualizado_en_servidor);
  return resultado;
}

/**
 * Cada operación llama una RPC de `cuidared_api` con el JWT del usuario. La identidad nunca viaja en los parámetros: la RPC
 * la toma de auth.uid() y vuelve a autorizar. Contrato SQL: docs/propuestas/fase-4c-sync.sql.
 */
export function createSyncRepository(rpc) {
  return {
    /** Resuelve UNA operación en su propia transacción. */
    async aplicar(cuentaId, operacion) {
      return leerResultado(
        await rpc('api_sync_aplicar_operacion', { p_cuenta_id: cuentaId, p_operacion: operacion }),
      );
    },
    async obtener(cuentaId, idCliente) {
      const item = await rpc('api_sync_obtener_operacion', {
        p_cuenta_id: cuentaId,
        p_id_cliente: idCliente,
      });
      const resultado = leerResultado(item);
      if (typeof item.entidad !== 'string' || typeof item.tipo !== 'string') throw unavailable();
      return {
        ...resultado,
        entidad: item.entidad,
        tipo: item.tipo,
        procesada_en: texto(item.procesada_en),
      };
    },
  };
}
