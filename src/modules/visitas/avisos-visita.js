/* Entrega de avisos de visitas públicas. © 2026 Equipo CuidaRed – INTEC. */
const asuntos = {
  autorizada: 'Tu visita fue autorizada',
  rechazada: 'Tu solicitud de visita no fue autorizada',
  reprogramada: 'La organización cambió el horario de tu visita',
  cancelada: 'Tu visita fue cancelada',
  recordatorio: 'Recordatorio de tu visita',
};
const formato = new Intl.DateTimeFormat('es-DO', {
  timeZone: 'America/Santo_Domingo',
  dateStyle: 'full',
  timeStyle: 'short',
});

export async function enviarAviso(autorizacion, config, fetchImpl = globalThis.fetch) {
  const asunto = asuntos[autorizacion.evento];
  const mostrarHorario = ['autorizada', 'reprogramada', 'recordatorio'].includes(
    autorizacion.evento,
  );
  const fecha =
    mostrarHorario && autorizacion.cita ? formato.format(new Date(autorizacion.cita)) : null;
  const respuesta = await fetchImpl('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${config.VISITAS_RESEND_API_KEY}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': `cuidared-visita/${autorizacion.id}`,
    },
    body: JSON.stringify({
      from: config.VISITAS_CORREO_REMITENTE,
      to: [autorizacion.correo],
      subject: asunto,
      text: [
        asunto,
        `Organización: ${autorizacion.organizacion}`,
        ...(fecha
          ? [
              `Horario: ${fecha}${autorizacion.fin ? ` hasta las ${autorizacion.fin}` : ''} (República Dominicana).`,
            ]
          : []),
        `Consulta el estado de tu visita con tu código en ${config.PWA_ORIGIN}/solicitud-visita.`,
      ].join('\n\n'),
    }),
    signal: AbortSignal.timeout(10000),
  });
  if (respuesta.body) await respuesta.body.cancel().catch(() => {});
  if (respuesta.ok) return 'enviado';
  return [408, 409, 429].includes(respuesta.status) || respuesta.status >= 500
    ? 'reintentar'
    : 'fallido';
}

export function iniciarAvisosVisita({ env, adminGateway, audit }) {
  if (!env.VISITAS_RESEND_API_KEY || !adminGateway) return () => {};
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
