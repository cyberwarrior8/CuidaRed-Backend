/* Persistencia de suscripciones Web Push con el JWT del usuario. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from '../../lib/errors.js';
import { estadoSchema } from './web-push-schemas.js';

const conflicto = {
  code: 'PUSH_SUBSCRIPTION_CONFLICT',
  message: 'No se pudo activar Web Push en este dispositivo. Vuelve a activar los avisos.',
};

export function createWebPushRepository(rpc) {
  return {
    async registrar({ endpoint, keys }) {
      await rpc(
        'api_push_registrar_suscripcion',
        { p_endpoint: endpoint, p_p256dh: keys.p256dh, p_auth: keys.auth },
        { conflict: conflicto },
      );
    },
    async estado(endpoint) {
      const raw = await rpc('api_push_estado_suscripcion', { p_endpoint: endpoint });
      const resultado = estadoSchema.safeParse(raw);
      if (!resultado.success) throw unavailable();
      return resultado.data;
    },
    async revocar(endpoint) {
      await rpc('api_push_revocar_suscripcion', { p_endpoint: endpoint });
    },
  };
}
