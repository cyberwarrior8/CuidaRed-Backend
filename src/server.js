/* Inicio y cierre ordenado del servidor · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
import 'dotenv/config';
import { createApp } from './app.js';
import { readEnv } from './config/env.js';
import { createAuditSink } from './lib/audit.js';
import { createAdminGateway } from './lib/supabase-admin.js';
import { createSupabaseGateway } from './modules/access/supabase-gateway.js';
import { iniciarAvisosVisita } from './modules/visitas/avisos-visita.js';

const env = readEnv(process.env);
const audit = createAuditSink();
const adminGateway = createAdminGateway(env);
const app = createApp({
  env,
  gateway: createSupabaseGateway(env),
  adminGateway,
  audit,
});
const detenerAvisos = iniciarAvisosVisita({ env, adminGateway, audit });
const server = app.listen(env.PORT, (error) => {
  if (error) {
    detenerAvisos();
    audit({
      action: 'server.start',
      result: 'error',
      code: error.code === 'EADDRINUSE' ? 'PORT_IN_USE' : 'SERVER_START_FAILED',
    });
    process.exitCode = 1;
    return;
  }
  audit({ action: 'server.started', result: 'success' });
});
server.requestTimeout = 30_000;
server.headersTimeout = 15_000;

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    detenerAvisos();
    server.close(() => {
      process.exitCode = 0;
    });
    server.closeIdleConnections();
    setTimeout(() => {
      server.closeAllConnections();
    }, 10_000).unref();
  });
}
