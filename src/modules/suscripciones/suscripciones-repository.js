/* Persistencia de suscripciones y Stripe Sandbox · ID08/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';
import { createSystemClient } from '../../lib/supabase-admin.js';
import { mapRpcError } from '../access/supabase-gateway.js';

registerBusinessErrors({
  CR_STRIPE_CHECKOUT_EN_CURSO: {
    status: 409,
    publicCode: 'CHECKOUT_IN_PROGRESS',
    message: 'Ya tienes un pago de prueba en curso. Retómalo desde la misma oferta.',
  },
  CR_STRIPE_COTIZACION_ACTUALIZADA: {
    status: 409,
    publicCode: 'QUOTE_UPDATED',
    message: 'La oferta cambió. Revisa el precio y los cupos antes de continuar.',
  },
  CR_STRIPE_SUSCRIPCION_EN_CURSO: {
    status: 409,
    publicCode: 'SUBSCRIPTION_IN_PROGRESS',
    message: 'La cuenta ya tiene una suscripción en curso.',
  },
  CR_STRIPE_CANCELACION_REQUERIDA: {
    status: 409,
    publicCode: 'TRANSFER_CANCELLATION_REQUIRED',
    message: 'Confirma la cancelación de la próxima renovación antes de transferir la titularidad.',
  },
  CR_STRIPE_CAMBIO_EN_CURSO: {
    status: 409,
    publicCode: 'PLAN_CHANGE_IN_PROGRESS',
    message: 'Hay un cambio de plan pendiente de confirmación.',
  },
  CR_STRIPE_SUSCRIPCION_NO_MODIFICABLE: {
    status: 409,
    publicCode: 'PLAN_CHANGE_NOT_ALLOWED',
    message: 'La suscripción no permite cambiar de plan en su estado actual.',
  },
  CR_STRIPE_SUPERA_LIMITE: {
    status: 409,
    publicCode: 'PLAN_CAPACITY_EXCEEDED',
    message: 'El uso actual supera el límite del plan seleccionado.',
  },
  CR_STRIPE_ACTIVACION_REQUERIDA: {
    status: 409,
    publicCode: 'STRIPE_ACTIVATION_REQUIRED',
    message: 'La activación de un plan pagado requiere un pago confirmado en Stripe Sandbox.',
  },
});

const operacionesSistema = new Set([
  'api_stripe_asociar_checkout',
  'api_stripe_procesar_evento',
  'api_stripe_asociar_cambio',
  'api_stripe_asociar_programacion',
  'api_stripe_descartar_prevision',
  'api_stripe_programacion_completada',
  'api_stripe_confirmar_cancelacion',
]);

// Los registros autenticados usan el JWT de quien opera. Solo el coordinador del webhook usa esta conexión.
export function createStripeSystemRpc(env) {
  if (!env.STRIPE_SANDBOX_ENABLED) return null;
  const client = createSystemClient(env);
  if (!client) return null;
  return async (name, params) => {
    if (!operacionesSistema.has(name)) throw new Error('RPC Stripe no permitida.');
    const { data, error } = await client.rpc(name, params).retry(false);
    if (error) throw mapRpcError(error);
    return data;
  };
}
