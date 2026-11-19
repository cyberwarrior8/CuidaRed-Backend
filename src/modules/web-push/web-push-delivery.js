/* Cifrado y entrega de avisos Web Push · RF-18. © 2026 Equipo CuidaRed – INTEC. */
import { createECDH } from 'node:crypto';
import { generateRequestDetails } from 'web-push';
import { z } from 'zod';
import { createSystemClient } from '../../lib/supabase-admin.js';
import {
  esClavePublicaPush,
  esEndpointPush,
  esSecretoAutenticacionPush,
} from '../../lib/web-push-validation.js';

const entregasSchema = z.array(
  z.object({
    entrega_id: z.uuid(),
    reserva_id: z.uuid(),
    notificacion_id: z.uuid(),
    cuenta_id: z.string().regex(/^[1-9][0-9]{0,18}$/),
    endpoint: z.string(),
    p256dh: z.string(),
    auth: z.string(),
    ttl: z.number().int().min(0).max(86400),
  }),
);

const asuntoValido = (subject) => {
  if (subject?.startsWith('mailto:')) return z.email().safeParse(subject.slice(7)).success;
  try {
    const url = new URL(subject);
    return url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash;
  } catch {
    return false;
  }
};

export function leerVapid(env, variables) {
  const privateKey = variables.WEB_PUSH_PRIVATE_KEY;
  const subject = variables.WEB_PUSH_VAPID_SUBJECT;
  const publicKey = env.WEB_PUSH_PUBLIC_KEY;
  if (
    !env.SUPABASE_SECRET_KEY ||
    !publicKey ||
    !asuntoValido(subject) ||
    !/^[A-Za-z0-9_-]{43}$/.test(privateKey ?? '')
  ) {
    throw new Error(
      'Configura SUPABASE_SECRET_KEY, WEB_PUSH_PUBLIC_KEY, WEB_PUSH_PRIVATE_KEY y WEB_PUSH_VAPID_SUBJECT.',
    );
  }
  const bytes = Buffer.from(privateKey, 'base64url');
  try {
    const curva = createECDH('prime256v1');
    curva.setPrivateKey(bytes);
    if (
      bytes.toString('base64url') !== privateKey ||
      curva.getPublicKey('base64url') !== publicKey
    ) {
      throw new Error();
    }
  } catch {
    throw new Error('Las claves VAPID no forman un par válido.');
  }
  return { subject, publicKey, privateKey };
}

export function crearColaPush(env, fetchImpl = globalThis.fetch) {
  const cliente = createSystemClient(env, fetchImpl).schema('cuidared_api');
  return {
    async reservar() {
      const { data, error } = await cliente.rpc('api_push_reservar_entregas', { p_limite: 8 });
      const resultado = entregasSchema.safeParse(data);
      if (error || !resultado.success) throw new Error('No se pudo reservar el lote Web Push.');
      return resultado.data;
    },
    async finalizar(entrega, resultado) {
      const { error } = await cliente.rpc('api_push_finalizar_entrega', {
        p_entrega_id: entrega.entrega_id,
        p_reserva_id: entrega.reserva_id,
        p_resultado: resultado,
      });
      if (error) throw new Error('No se pudo registrar el resultado de una entrega Web Push.');
    },
  };
}

export function crearEmisorPush(vapidDetails, fetchImpl = globalThis.fetch) {
  return async (entrega) => {
    if (
      !esEndpointPush(entrega.endpoint) ||
      !esClavePublicaPush(entrega.p256dh) ||
      !esSecretoAutenticacionPush(entrega.auth)
    )
      return 'caducada';

    // Generar cifrado y autenticación con la librería y limitar la solicitud completa, incluidos los redireccionamientos.
    const solicitud = generateRequestDetails(
      { endpoint: entrega.endpoint, keys: { p256dh: entrega.p256dh, auth: entrega.auth } },
      JSON.stringify({ cuenta_id: entrega.cuenta_id, aviso_id: entrega.notificacion_id }),
      {
        vapidDetails,
        TTL: entrega.ttl,
        topic: entrega.notificacion_id.replaceAll('-', ''),
        contentEncoding: 'aes128gcm',
      },
    );
    if (solicitud.endpoint !== entrega.endpoint) return 'fallida';

    let respuesta;
    try {
      respuesta = await fetchImpl(solicitud.endpoint, {
        method: 'POST',
        headers: solicitud.headers,
        body: solicitud.body,
        redirect: 'manual',
        signal: AbortSignal.timeout(8_000),
      });
    } catch {
      return 'reintentar';
    }
    await respuesta.body?.cancel().catch(() => {});
    if (respuesta.ok) return 'enviada';
    if (respuesta.status === 404 || respuesta.status === 410) return 'caducada';
    return respuesta.status === 408 || respuesta.status === 429 || respuesta.status >= 500
      ? 'reintentar'
      : 'fallida';
  };
}

export async function despacharLotePush(cola, enviar) {
  const lote = await cola.reservar();
  const resultados = await Promise.allSettled(
    lote.map(async (entrega) => {
      const resultado = await enviar(entrega).catch(() => 'fallida');
      await cola.finalizar(entrega, resultado);
      return resultado;
    }),
  );
  return {
    entregadas: resultados.filter((r) => r.status === 'fulfilled' && r.value === 'enviada').length,
    fallos: resultados.filter((r) => r.status === 'rejected' || r.value === 'fallida').length,
  };
}
