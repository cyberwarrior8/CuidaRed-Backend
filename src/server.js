/* Inicio y cierre ordenado del servidor · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
import 'dotenv/config';
import { createApp } from './app.js';
import { readEnv } from './config/env.js';
import { createAuditSink } from './lib/audit.js';
import { createSupabaseGateway } from './modules/access/supabase-gateway.js';

const env = readEnv(process.env);
const audit = createAuditSink();
const app = createApp({ env, gateway: createSupabaseGateway(env), audit });
const server = app.listen(env.PORT, () => {
  audit({ action: 'server.started', result: 'success' });
});
server.requestTimeout = 30_000;
server.headersTimeout = 15_000;

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    server.close(() => {
      process.exitCode = 0;
    });
    server.closeIdleConnections();
    setTimeout(() => {
      server.closeAllConnections();
    }, 10_000).unref();
  });
}
