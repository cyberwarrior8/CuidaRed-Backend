/* Regresión de defectos reales de extracción del catálogo ONE · ID02. © 2026 Equipo CuidaRed – INTEC. */
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { prepareTerritoryCatalog } from '../scripts/prepare-territory-catalog.js';

const catalog = JSON.parse(
  readFileSync(new URL('../docs/catalogos/one-2021.propuesta.json', import.meta.url), 'utf8'),
);

describe('ID02: catálogo territorial aprobado', () => {
  it('reproduce el SQL aplicado usando las filas corregidas', () => {
    const applied = readFileSync(
      new URL('../supabase/seeds/territorio-one-2021.sql', import.meta.url),
      'utf8',
    ).replaceAll('\r\n', '\n');
    expect(prepareTerritoryCatalog(catalog)).toBe(applied);
  });

  it.each([
    ['provincias', '02', 'a zua'],
    ['municipios', '0208', 't ábara a rriba'],
    ['provincias', '24', 'Sanchez Ramírez'],
  ])(
    'rechaza la regresión del nombre de %s %s aunque conserve conteos y códigos',
    (table, code, name) => {
      const changed = structuredClone(catalog);
      const field = table === 'provincias' ? 'provincia_cod' : 'municipio_cod_propuesto';
      changed[table].find((record) => record[field] === code).nombre = name;
      expect(() => prepareTerritoryCatalog(changed)).toThrow(/versión.*aprobada/);
    },
  );
});
