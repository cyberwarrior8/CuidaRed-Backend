/* Casos de uso de la sincronización de visitas sin conexión (LWW, idempotencia) · RF-10, RF-4.5, RNF-4.2. © 2026 Equipo CuidaRed – INTEC. */
import { AppError } from '../../lib/errors.js';
import { leerOperacion } from './sync-schemas.js';

const rechazoLote = () => new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');

/**
 * Orquesta el lote: las reglas de fondo (idempotencia, Last-Write-Wins, reloj, permisos, alcance y estados) viven en la RPC,
 * que las aplica en una transacción por operación. Aquí solo se valida la forma, se respeta el orden de captura y se deja la
 * auditoría minimizada de cada resultado.
 */
export function createSyncService(repository, { audit }) {
  /** Una línea de auditoría por resultado, como el cliente (sync.registro, sync.conflicto, sync.error). Sin contenido. */
  function auditar(ctx, resultado) {
    // Un reintento (duplicada) no repite la auditoría: ya quedó registrada al resolverse la operación.
    if (resultado.resultado === 'duplicada') return;
    const evento = { requestId: ctx.requestId, actorId: ctx.actorId };
    if (resultado.resultado === 'aplicada') {
      audit({ ...evento, action: 'sync.registro', result: 'success' });
    } else if (resultado.resultado === 'conflicto') {
      audit({
        ...evento,
        action: 'sync.conflicto',
        result: 'success',
        code: resultado.gana === 'local' ? 'LOCAL_WINS' : 'SERVER_WINS',
      });
    } else {
      audit({ ...evento, action: 'sync.error', result: 'denied', code: resultado.motivo });
    }
  }

  return {
    /**
     * Procesa las operaciones en el orden recibido (el orden de captura del cliente): una operación puede depender de otra
     * del mismo registro (iniciar y luego registrar). Una operación rechazada no detiene las siguientes. Una falla de la
     * base (sesión, indisponibilidad) interrumpe el lote con su error: lo ya resuelto queda guardado y el cliente reintenta
     * el lote completo con las mismas claves, de modo que lo resuelto vuelve como `duplicada` sin repetirse.
     */
    async procesar(cuentaId, operaciones, ctx) {
      const leidas = operaciones.map(leerOperacion);
      // Sin id_cliente no hay forma de responder esa operación: se rechaza el lote antes de aplicar nada.
      if (leidas.some((leida) => leida.invalida && !leida.invalida.idCliente)) throw rechazoLote();

      const resultados = [];
      for (const leida of leidas) {
        let resultado;
        if (leida.invalida) {
          // Mal formada pero identificable: se responde rechazada y el lote sigue. No llega a la base.
          resultado = {
            id_cliente: leida.invalida.idCliente,
            resultado: 'rechazada',
            registro_id: leida.invalida.registroId,
            motivo: 'INVALID_INPUT',
            actualizado_en_servidor: null,
          };
        } else {
          resultado = await repository.aplicar(cuentaId, leida.operacion);
        }
        auditar(ctx, resultado);
        resultados.push(resultado);
      }
      return resultados;
    },

    obtener: (cuentaId, idCliente) => repository.obtener(cuentaId, idCliente),
  };
}
