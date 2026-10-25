/* Auditoría técnica minimizada · seguridad RF-21. © 2026 Equipo CuidaRed – INTEC. */
export function createAuditSink(write = (line) => process.stdout.write(`${line}\n`)) {
  return (event) => {
    // Lista cerrada: excluir cabeceras, cuerpos, correo, cédula, tokens y contraseñas.
    write(
      JSON.stringify({
        timestamp: new Date().toISOString(),
        requestId: event.requestId,
        actorId: event.actorId,
        action: event.action,
        result: event.result,
        code: event.code,
      }),
    );
  };
}
