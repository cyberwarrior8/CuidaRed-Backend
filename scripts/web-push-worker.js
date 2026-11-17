/* Proceso de envío Web Push · RF-18/RF-21. © 2026 Equipo CuidaRed – INTEC. */
import 'dotenv/config';
import { setTimeout as esperar } from 'node:timers/promises';
import { readEnv } from '../src/config/env.js';
import { createAuditSink } from '../src/lib/audit.js';
import {
  crearColaPush,
  crearEmisorPush,
  despacharLotePush,
  leerVapid,
} from '../src/modules/web-push/web-push-delivery.js';

async function iniciar() {
  const env = readEnv(process.env);
  const auditar = createAuditSink();
  if (!env.WEB_PUSH_ENABLED) {
    console.log('Web Push desactivado por configuración.');
    return;
  }
  const enviar = crearEmisorPush(leerVapid(env, process.env));
  const cola = crearColaPush(env);
  const detener = new AbortController();
  for (const senal of ['SIGINT', 'SIGTERM']) process.once(senal, () => detener.abort());
  auditar({ action: 'web_push.worker.started', result: 'success' });
  while (!detener.signal.aborted) {
    try {
      const lote = await despacharLotePush(cola, enviar);
      if (lote.entregadas) auditar({ action: 'web_push.worker.delivered', result: 'success' });
      if (lote.fallos) auditar({ action: 'web_push.worker.delivery', result: 'error' });
    } catch {
      auditar({ action: 'web_push.worker.queue', result: 'error' });
    }
    await esperar(5000, null, { signal: detener.signal }).catch(() => {});
  }
}

iniciar().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
