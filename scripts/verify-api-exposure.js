/* Verificación HTTPS sin identidad real ni escrituras · ID01/RF-09. © 2026 Equipo CuidaRed – INTEC. */
import assert from 'node:assert/strict';

const base = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_PUBLISHABLE_KEY;
assert(base && new URL(base).protocol === 'https:', 'Configura SUPABASE_URL con HTTPS.');
assert(key?.startsWith('sb_publishable_'), 'Configura una clave publicable de Supabase.');

let stage = 'schema-exposure';
let diagnostic;
try {
  for (const schema of ['cuidared', 'public']) {
    // La raíz OpenAPI exige clave secreta. Probar una RPC conocida con otro esquema
    // permite comprobar exposición usando solo clave publicable, sin pedir secretos.
    const response = await fetch(`${base}/rest/v1/rpc/api_sesion`, {
      method: 'POST',
      headers: { apikey: key, 'Content-Profile': schema, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_accion: 'validar' }),
      signal: AbortSignal.timeout(15_000),
    });
    const body = await response.json();
    diagnostic = { status: response.status, code: body.code, schema };
    if (response.status === 401 && typeof body.message === 'string') {
      diagnostic.message = body.message.replaceAll(key, '[redacted]').slice(0, 180);
    }
    assert.equal(response.status, 406);
    assert.equal(body.code, 'PGRST106');
  }
  stage = 'anonymous-rpc';
  const response = await fetch(`${base}/rest/v1/rpc/api_sesion`, {
    method: 'POST',
    headers: { apikey: key, 'Content-Profile': 'cuidared_api', 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_accion: 'validar' }),
    signal: AbortSignal.timeout(15_000),
  });
  const body = await response.json();
  diagnostic = { status: response.status, code: body.code };
  assert([401, 403].includes(response.status));
  assert.equal(body.code, '42501');
  process.stdout.write(
    `${JSON.stringify({
      checkedSchema: 'cuidared_api',
      rejectedSchemas: ['cuidared', 'public'],
      internalSchemaHidden: true,
      anonymousRpcDenied: true,
      realUsersCreated: false,
    })}\n`,
  );
} catch {
  // Excluir credenciales y respuestas completas del proveedor de los logs.
  process.stderr.write(`${JSON.stringify({ failedStage: stage, ...diagnostic })}\n`);
  process.exitCode = 1;
}
