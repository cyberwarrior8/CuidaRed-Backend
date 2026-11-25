/* Entrega de avisos de visitas públicas. © 2026 Equipo CuidaRed – INTEC. */
import { correoVisitaConfigurado } from '../../config/env.js';
import { enviarCorreoSmtp } from './correo-smtp.js';
import { generarCodigoSeguimiento } from '../publico/codigo-seguimiento.js';
const asuntos = {
  recibida: 'Recibimos tu solicitud de visita',
  nueva_solicitud: 'Nueva solicitud de visita por revisar',
  autorizada: 'Tu visita fue autorizada',
  rechazada: 'Tu solicitud de visita no fue autorizada',
  reprogramada: 'La organización cambió el horario de tu visita',
  cancelada: 'Tu visita fue cancelada',
  recordatorio: 'Recordatorio de tu visita',
  observaciones: 'Ya puedes compartir las observaciones de tu visita',
  realizada: 'La organización confirmó la realización de tu visita',
};
const formato = new Intl.DateTimeFormat('es-DO', {
  timeZone: 'America/Santo_Domingo',
  dateStyle: 'full',
  timeStyle: 'short',
});

/** La aceptación del proveedor no confirma todavía la entrega al buzón. */
export async function enviarCorreoVisita(
  mensaje,
  config,
  idempotencia,
  fetchImpl = globalThis.fetch,
) {
  if (config.VISITAS_CORREO_PROVEEDOR === 'smtp') {
    return enviarCorreoSmtp(mensaje, config, idempotencia);
  }
  const respuesta = await fetchImpl('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${config.VISITAS_RESEND_API_KEY}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': idempotencia,
    },
    body: JSON.stringify({ ...mensaje, from: config.VISITAS_CORREO_REMITENTE }),
    signal: AbortSignal.timeout(10000),
  });
  const datos = await respuesta.json().catch(() => ({}));
  const id = typeof datos?.id === 'string' && /^[0-9a-f-]{36}$/i.test(datos.id) ? datos.id : null;
  // No devolver mensajes del proveedor: podrían contener direcciones o datos de la petición.
  const codigo =
    typeof datos?.name === 'string' && /^[a-z_]{1,64}$/.test(datos.name) ? datos.name : null;
  return {
    resultado: respuesta.ok
      ? 'enviado'
      : [408, 409, 429].includes(respuesta.status) || respuesta.status >= 500
        ? 'reintentar'
        : 'fallido',
    httpStatus: respuesta.status,
    proveedorId: id,
    codigo,
  };
}

export async function enviarAviso(autorizacion, config, fetchImpl = globalThis.fetch) {
  const asunto = asuntos[autorizacion.evento];
  const mostrarHorario = [
    'recibida',
    'nueva_solicitud',
    'autorizada',
    'reprogramada',
    'recordatorio',
    'observaciones',
    'realizada',
  ].includes(autorizacion.evento);
  const fecha =
    mostrarHorario && autorizacion.cita ? formato.format(new Date(autorizacion.cita)) : null;
  const codigo =
    autorizacion.referencia_codigo && config.CODIGO_SEGUIMIENTO_SECRETO
      ? generarCodigoSeguimiento(autorizacion.referencia_codigo, config.CODIGO_SEGUIMIENTO_SECRETO)
      : null;
  const entrega = await enviarCorreoVisita(
    {
      to: [autorizacion.correo],
      subject: asunto,
      text: [
        asunto,
        `Organización: ${autorizacion.organizacion}`,
        ...(fecha
          ? [
              `${['recibida', 'nueva_solicitud'].includes(autorizacion.evento) ? 'Horario solicitado' : 'Horario'}: ${fecha}${autorizacion.fin ? ` hasta las ${autorizacion.fin}` : ''} (República Dominicana).`,
            ]
          : []),
        ...(autorizacion.evento === 'recibida'
          ? [
              'La organización revisará tu solicitud. El horario todavía no está confirmado. Guarda el código que recibiste al enviar el formulario.',
            ]
          : []),
        ...(autorizacion.motivo && ['rechazada', 'cancelada'].includes(autorizacion.evento)
          ? [`Motivo: ${autorizacion.motivo}`]
          : []),
        ...(autorizacion.destinatario !== 'organizacion' && codigo
          ? [`Tu código de seguimiento: ${codigo}`]
          : []),
        ...(['observaciones', 'realizada'].includes(autorizacion.evento)
          ? [
              'Comparte lo que observaste y, si lo deseas, hasta tres fotografías. Ingresa tu código de seguimiento en el enlace. Tus observaciones no sustituyen la confirmación de la organización.',
              `Agregar observaciones y evidencias: ${config.PWA_ORIGIN}/solicitud-visita#observaciones`,
            ]
          : []),
        autorizacion.destinatario === 'organizacion'
          ? `Inicia sesión y abre Visitas → Solicitudes para revisar la solicitud en ${config.PWA_ORIGIN}/inicio.`
          : `Consulta el estado de tu visita con tu código en ${config.PWA_ORIGIN}/solicitud-visita.`,
      ].join('\n\n'),
    },
    config,
    `cuidared-visita/${autorizacion.id}`,
    fetchImpl,
  );
  return entrega.resultado;
}

export function iniciarAvisosVisita({ env, adminGateway, audit }) {
  if (env.VISITAS_CORREO_HABILITADO === false || !correoVisitaConfigurado(env) || !adminGateway)
    return () => {};
  let activo = false;
  const procesar = async () => {
    if (activo) return;
    activo = true;
    try {
      const avisos = await adminGateway.visitaPublicaRpc('api_visita_reclamar_avisos', {});
      for (const aviso of avisos) {
        const resultado = await enviarAviso(aviso, env).catch(() => 'reintentar');
        await adminGateway.visitaPublicaRpc('api_visita_cerrar_aviso', {
          p_id: aviso.id,
          p_reclamo: aviso.reclamo,
          p_resultado: resultado,
        });
        audit({
          action: 'visita.correo',
          result: resultado === 'enviado' ? 'success' : 'error',
          ...(resultado !== 'enviado' ? { code: 'VISIT_EMAIL_UNAVAILABLE' } : {}),
        });
      }
    } catch {
      audit({
        action: 'visita.cola_correo',
        result: 'error',
        code: 'VISIT_EMAIL_QUEUE_UNAVAILABLE',
      });
    } finally {
      activo = false;
    }
  };
  const reloj = setInterval(() => {
    void procesar();
  }, 30_000);
  reloj.unref();
  void procesar();
  return () => clearInterval(reloj);
}
