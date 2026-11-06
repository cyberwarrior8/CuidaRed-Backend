/* Valida las propuestas SQL en un PostgreSQL LOCAL desechable · herramientas. © 2026 Equipo CuidaRed – INTEC. */
/*
 * Uso:  node scripts/validar-propuestas-local.js [--conservar] [--solo=2b,3a]
 * Requiere `psql` en el PATH y un PostgreSQL local accesible con las variables estándar (PGHOST, PGUSER,
 * PGPASSWORD…; por defecto localhost/postgres). Crea la base `cuidared_validacion_local`, carga en orden:
 *   1. docs/verificacion/local/supabase-stub.sql  (esquema auth y roles simulados)
 *   2. docs/DB.sql                                (modelo base; se corrigen los `character` sin longitud)
 *   3. docs/verificacion/local/trigger-perfil-stub.sql
 *   4. supabase/migrations/*.sql                  (fase 1 aplicada)
 *   5. docs/propuestas/fase-*.sql                 (excepto fase-1, ya incluida en la migración), en orden
 *   6. docs/verificacion/local/pruebas-*.sql      (cada una dentro de una transacción con ROLLBACK)
 * y borra la base al final (salvo --conservar). NUNCA apunta al proyecto Supabase: se niega si PGHOST no es local.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const raiz = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const host = process.env.PGHOST ?? 'localhost';
if (!['localhost', '127.0.0.1', '::1'].includes(host)) {
  console.error('Solo se permite un PostgreSQL local (PGHOST=localhost).');
  process.exit(2);
}
// Base propia por ejecución: varias validaciones pueden correr a la vez sin pisarse.
const base = `cuidared_validacion_local_${process.pid}`;
const conservar = process.argv.includes('--conservar');
// --solo=2b,3a: además de la base (2a y ayudas), carga solo las propuestas y pruebas con esos prefijos.
const soloArg = process.argv.find((a) => a.startsWith('--solo='));
const solo = soloArg ? ['2a', '00', ...soloArg.slice(7).split(',').filter(Boolean)] : null;
const incluido = (codigo) => !solo || solo.some((p) => codigo.startsWith(p));
const env = { ...process.env, PGHOST: host, PGUSER: process.env.PGUSER ?? 'postgres' };

const psql = (args, opciones = {}) =>
  execFileSync('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-q', ...args], {
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    ...opciones,
  });

function ejecutarArchivo(ruta, etiqueta) {
  try {
    psql(['-d', base, '-f', ruta]);
    console.log(`  ok  ${etiqueta}`);
  } catch (error) {
    console.error(`  ERROR en ${etiqueta}:\n${(error.stderr || error.message).trim()}`);
    throw new Error(etiqueta, { cause: error });
  }
}

const tmp = mkdtempSync(join(tmpdir(), 'cuidared-sql-'));
const ordenados = (dir, filtro) =>
  existsSync(dir)
    ? readdirSync(dir)
        .filter(filtro)
        .sort()
        .map((f) => join(dir, f))
    : [];

let fallo = false;
try {
  psql(['-d', 'postgres', '-c', `drop database if exists ${base}`]);
  psql(['-d', 'postgres', '-c', `create database ${base}`]);
  console.log(`Base local ${base} creada.`);
  ejecutarArchivo(join(raiz, 'docs/verificacion/local/supabase-stub.sql'), 'stub de Supabase');
  // DB.sql es una exportación de contexto: crear el esquema y dar longitud a los `character` sin ella.
  const modelo = readFileSync(join(raiz, 'docs/DB.sql'), 'utf8')
    .replace(/\bcedula character\b/g, 'cedula character(11)')
    .replace(/\bmoneda character\b/g, 'moneda character(3)');
  const modeloTmp = join(tmp, 'modelo.sql');
  writeFileSync(modeloTmp, `create schema cuidared;\n${modelo}`);
  ejecutarArchivo(modeloTmp, 'docs/DB.sql');
  ejecutarArchivo(
    join(raiz, 'docs/verificacion/local/trigger-perfil-stub.sql'),
    'trigger de perfil (stub)',
  );
  for (const f of ordenados(join(raiz, 'supabase/migrations'), (n) => n.endsWith('.sql')))
    ejecutarArchivo(f, f.slice(raiz.length));
  for (const f of ordenados(
    join(raiz, 'docs/propuestas'),
    (n) =>
      /^fase-\d/.test(n) && !n.startsWith('fase-1') && n.endsWith('.sql') && incluido(n.slice(5)),
  )) {
    ejecutarArchivo(f, f.slice(raiz.length));
  }
  for (const f of ordenados(
    join(raiz, 'docs/verificacion/local'),
    (n) => /^pruebas-.*\.sql$/.test(n) && incluido(n.slice(8)),
  )) {
    ejecutarArchivo(f, f.slice(raiz.length));
  }
  console.log('Validación local completada sin errores.');
} catch {
  fallo = true;
} finally {
  if (!conservar) {
    try {
      psql(['-d', 'postgres', '-c', `drop database if exists ${base}`]);
    } catch {
      /* la base queda para inspección manual */
    }
  }
}
process.exit(fallo ? 1 : 0);
