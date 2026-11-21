/* Contratos de suscripciones Web Push · RF-18. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import {
  esClavePublicaPush,
  esEndpointPush,
  esSecretoAutenticacionPush,
} from '../../lib/web-push-validation.js';
import { AppError } from '../../lib/errors.js';

const endpoint = z.string().refine(esEndpointPush);

export const registroSchema = z.strictObject({
  endpoint,
  keys: z.strictObject({
    p256dh: z.string().refine(esClavePublicaPush),
    auth: z.string().refine(esSecretoAutenticacionPush),
  }),
});

export const dispositivoSchema = z.strictObject({ endpoint });
export const estadoSchema = z.object({ activa: z.boolean() });

export function leerSuscripcion(schema, valor) {
  const resultado = schema.safeParse(valor);
  if (!resultado.success) {
    throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos de la suscripción.');
  }
  return resultado.data;
}
