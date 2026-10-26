/* Diagnósticos locales de invitación sin credenciales ni red · ID01. © 2026 Equipo CuidaRed – INTEC. */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const script = fileURLToPath(new URL('../scripts/invite-test-user.js', import.meta.url));
const profile = JSON.stringify({
  email: 'test@example.invalid',
  cedula: '00000000000',
  nombres: 'Prueba',
  apellidos: 'Local',
});

function run({
  key = '',
  input = profile,
  send = true,
  url = 'https://auth.example.invalid',
  cwd,
} = {}) {
  const env = {
    ...process.env,
    SUPABASE_URL: url,
    SUPABASE_ADMIN_KEY: key,
    INVITATION_PROFILE_JSON: input,
  };
  if (url === null) delete env.SUPABASE_URL;
  return spawnSync(process.execPath, [script, ...(send ? ['--send'] : [])], {
    encoding: 'utf8',
    timeout: 10_000,
    env,
    cwd,
  });
}

describe('ID01: diagnósticos seguros de la invitación administrativa', () => {
  it.each(['', '*', 'sb_publishable_test_private_marker', 'sb_secret_invalid!private_marker'])(
    'rechaza una clave mal configurada antes del envío sin mostrarla',
    (key) => {
      const result = run({ key });
      expect(result.error).toBeUndefined();
      expect(result.status).toBe(1);
      expect(result.stderr).toContain('SUPABASE_ADMIN_KEY debe contener');
      if (key) expect(result.stderr).not.toContain(key);
      expect(result.stderr).not.toContain('test@example.invalid');
    },
  );

  it('distingue JSON inválido sin revelar su contenido', () => {
    const result = run({ input: 'sensitive_input_marker' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('Define INVITATION_PROFILE_JSON');
    expect(result.stderr).not.toContain('sensitive_input_marker');
  });

  it('valida el perfil sin necesitar clave ni enviar correo cuando falta --send', () => {
    const result = run({ send: false });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
    expect(result.stdout).toContain('no se contacta Supabase');
    expect(result.stderr).toBe('');
  });

  it.each([
    '',
    'http://auth.example.invalid',
    'https://user:sensitive_url_marker@auth.example.invalid',
  ])('rechaza una URL ausente o insegura antes de usar la clave administrativa', (url) => {
    const result = run({ url, key: 'sb_secret_test_private_marker' });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('Configura SUPABASE_URL en .env');
    expect(result.stderr).not.toContain('sensitive_url_marker');
    expect(result.stderr).not.toContain('sb_secret_test_private_marker');
  });

  it('carga SUPABASE_URL desde .env sin necesitar configuración heredada ni red', () => {
    const directory = mkdtempSync(join(tmpdir(), 'cuidared-invite-'));
    const envFile = join(directory, '.env');
    try {
      writeFileSync(envFile, 'SUPABASE_URL=https://auth.example.invalid\n');
      const result = run({ cwd: directory, url: null, send: false });
      expect(result.error).toBeUndefined();
      expect(result.status).toBe(0);
      expect(result.stdout).toContain('no se contacta Supabase');
      expect(result.stderr).toBe('');
    } finally {
      unlinkSync(envFile);
      rmdirSync(directory);
    }
  });
});
