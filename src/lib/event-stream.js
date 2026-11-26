/* Señales SSE sin datos de negocio, compartidas por marca, backoffice y soporte. © 2026 Equipo CuidaRed – INTEC. */
import { unavailable } from './errors.js';

export function streamSignals(res, gateway, temas, duration = 120000) {
  if (!gateway) throw unavailable();
  res.status(200).set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders();
  const send = (tema) => {
    if (!res.writableEnded && !res.destroyed)
      res.write('data: ' + JSON.stringify({ tema }) + '\n\n');
  };
  send('conexion');
  const unsubscribe = gateway.watchBackoffice((tema) => {
    if (temas.has(tema)) send(tema);
  });
  const heartbeat = setInterval(() => {
    if (!res.writableEnded && !res.destroyed) res.write(': latido\n\n');
  }, 15000);
  const timeout = setTimeout(() => res.end(), duration);
  res.on('close', () => {
    unsubscribe();
    clearInterval(heartbeat);
    clearTimeout(timeout);
  });
}
