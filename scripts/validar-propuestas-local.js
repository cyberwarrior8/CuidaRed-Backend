/* Valida las propuestas SQL en un PostgreSQL LOCAL desechable · herramientas. © 2026 Equipo CuidaRed – INTEC. */
/*
 * Uso:  node scripts/validar-propuestas-local.js [--conservar] [--solo=2b,3a|--solo=integracion]
 * Requiere `psql` en el PATH y un PostgreSQL local accesible con las variables estándar (PGHOST, PGUSER,
 * PGPASSWORD…; por defecto localhost/postgres). Crea la base `cuidared_validacion_local`, carga en orden:
 *   1. docs/verificacion/local/supabase-stub.sql  (esquema auth y roles simulados)
 *   2. docs/DB.sql                                (modelo base; se corrigen los `character` sin longitud)
 *   3. docs/verificacion/local/trigger-perfil-stub.sql
 *   4. supabase/migrations/*.sql                  (migraciones base previas a las propuestas)
 *   5. docs/propuestas/fase-2a-* a fase-4d-*      (bloques de esquema, sin la carga territorial), en orden
 *   6. docs/verificacion/local/pruebas-*.sql      (cada una dentro de una transacción con ROLLBACK)
 * y borra la base al final (salvo --conservar). NUNCA apunta al proyecto Supabase: se niega si PGHOST no es local.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const raiz = fileURLToPath(new URL('..', import.meta.url));
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
const soloIntegracion = !soloArg || soloArg === '--solo=integracion';
const solo =
  soloArg && !soloIntegracion ? ['2a', '00', ...soloArg.slice(7).split(',').filter(Boolean)] : null;
const incluido = (codigo) => !solo || solo.some((p) => codigo.startsWith(p));
const esMigracionBase = (nombre) =>
  nombre.endsWith('.sql') && !/^\d{14}_fase_(2[abc]|3[ab]|4[abcd])_/.test(nombre);
const esPruebaSeleccionada = (n) =>
  /^pruebas-.*\.sql$/.test(n) &&
  (soloIntegracion
    ? ['pruebas-00-ayudas.sql', 'pruebas-integracion-2-4.sql'].includes(n)
    : incluido(n.slice(8)));
const env = { ...process.env, PGHOST: host, PGUSER: process.env.PGUSER ?? 'postgres' };
// Evita que libpq priorice una dirección o un servicio remoto sobre PGHOST.
delete env.PGHOSTADDR;
delete env.PGSERVICE;
delete env.PGSERVICEFILE;

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
let creada = false;
try {
  psql(['-d', 'postgres', '-c', `create database ${base}`]);
  creada = true;
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
  // Las fases 2 a 4 se prueban desde las propuestas, aunque sus versiones aplicadas también estén archivadas.
  for (const f of ordenados(join(raiz, 'supabase/migrations'), esMigracionBase))
    ejecutarArchivo(f, f.slice(raiz.length));
  if (soloIntegracion) {
    ejecutarArchivo(
      join(raiz, 'docs/verificacion/local/datos-previos-integracion.sql'),
      'datos previos de integración',
    );
  }
  for (const f of ordenados(
    join(raiz, 'docs/propuestas'),
    (n) => /^fase-(2[abc]|3[ab]|4[abcd])-.*\.sql$/.test(n) && incluido(n.slice(5)),
  )) {
    ejecutarArchivo(f, f.slice(raiz.length));
  }
  for (const f of ordenados(join(raiz, 'docs/verificacion/local'), esPruebaSeleccionada)) {
    ejecutarArchivo(f, f.slice(raiz.length));
  }
  console.log('Validación local completada sin errores.');
} catch {
  fallo = true;
} finally {
  if (creada && !conservar) {
    try {
      psql(['-d', 'postgres', '-c', `drop database if exists ${base}`]);
    } catch {
      /* la base queda para inspección manual */
    }
  }
}
process.exit(fallo ? 1 : 0);
