/* Caché en memoria con vencimiento para catálogos · CR-165. © 2026 Equipo CuidaRed – INTEC. */

export const CATALOGO_TTL_MS = 5 * 60 * 1000;

/**
 * Caché por clave con TTL (5 minutos en los catálogos). Guarda la promesa de la carga, así que varias peticiones
 * simultáneas a la misma clave comparten una sola llamada a la base; si la carga falla, no se guarda el error.
 * Solo debe contener datos comunes a todos los usuarios (los catálogos lo son). La cantidad de claves está acotada
 * porque los filtros vienen del cliente: al llenarse se descartan las más antiguas.
 */
export function createTtlCache({ ttlMs = CATALOGO_TTL_MS, maxEntries = 500, now = Date.now } = {}) {
  const entradas = new Map();

  function purgar(ahora) {
    // Las entradas se insertan en orden de vencimiento: basta recorrer desde la más antigua.
    for (const [clave, entrada] of entradas) {
      if (entrada.expira > ahora && entradas.size <= maxEntries) break;
      entradas.delete(clave);
    }
  }

  return {
    async get(clave, cargar) {
      const ahora = now();
      const existente = entradas.get(clave);
      if (existente && existente.expira > ahora) return existente.valor;
      entradas.delete(clave);
      const valor = Promise.resolve().then(cargar);
      entradas.set(clave, { expira: ahora + ttlMs, valor });
      valor.catch(() => {
        if (entradas.get(clave)?.valor === valor) entradas.delete(clave);
      });
      purgar(ahora);
      return valor;
    },
    get size() {
      return entradas.size;
    },
  };
}
