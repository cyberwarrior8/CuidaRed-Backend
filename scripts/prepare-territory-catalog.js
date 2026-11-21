/* Prepara el catálogo ONE aprobado, sin red ni escrituras en BD · ID02. © 2026 Equipo CuidaRed – INTEC. */
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

const catalogUrl = new URL('../docs/catalogos/one-2021.propuesta.json', import.meta.url);
const sqlUrl = new URL('../docs/propuestas/fase-2-territorio-one-2021.sql', import.meta.url);
const locationSchema = z.object({
  region_cod: z.string().regex(/^\d{2}$/),
  provincia_cod: z.string().regex(/^\d{2}$/),
  nombre: z.string().trim().min(1),
  pagina_fuente: z.number().int().min(19).max(505),
});
const catalogSchema = z.object({
  fuente: z.object({
    edicion: z.literal(2021),
    fecha_corte_declarada: z.literal('2021-06-30'),
    sha256_pdf: z.literal('98fae470271cec43297df31f0df118a35b8188baa486f66062ed7b00b96d2b40'),
  }),
  provincias: z.array(locationSchema).length(32),
  municipios: z
    .array(
      locationSchema.extend({
        municipio_par_one: z.string().regex(/^(?!00)\d{2}$/),
        municipio_cod_propuesto: z.string().regex(/^\d{4}$/),
      }),
    )
    .length(158),
});

const literal = (value) => `'${value.replaceAll("'", "''")}'`;

export function prepareTerritoryCatalog(raw) {
  const catalog = catalogSchema.parse(raw);
  const provinces = new Map(catalog.provincias.map((item) => [item.provincia_cod, item]));
  const municipalities = new Set();
  if (provinces.size !== 32 || new Set(catalog.provincias.map((p) => p.nombre)).size !== 32) {
    throw new Error('Catálogo provincial duplicado.');
  }
  for (const municipality of catalog.municipios) {
    const province = provinces.get(municipality.provincia_cod);
    const expectedCode = municipality.provincia_cod + municipality.municipio_par_one;
    if (
      !province ||
      province.region_cod !== municipality.region_cod ||
      expectedCode !== municipality.municipio_cod_propuesto ||
      municipalities.has(expectedCode)
    ) {
      throw new Error('Jerarquía o código municipal inválido.');
    }
    municipalities.add(expectedCode);
  }
  // Fija los nombres/códigos revisados y aprobados; los conteos no detectan defectos de extracción.
  const approvedRows = {
    provincias: catalog.provincias
      .map((p) => [p.provincia_cod, p.nombre])
      .sort((a, b) => a[0].localeCompare(b[0])),
    municipios: catalog.municipios
      .map((m) => [m.municipio_cod_propuesto, m.nombre, m.provincia_cod])
      .sort((a, b) => a[0].localeCompare(b[0])),
  };
  const fingerprint = createHash('sha256').update(JSON.stringify(approvedRows)).digest('hex');
  if (fingerprint !== '2d2a1c3ab04e26ee95c21551b1a368b52695532e1900bfa978226851bdb1156f') {
    throw new Error('El catálogo difiere de la versión de nombres y códigos aprobada.');
  }
  const provinceValues = catalog.provincias
    .map((p) => `  (${literal(p.provincia_cod)}, ${literal(p.nombre)})`)
    .join(',\n');
  const municipalityValues = catalog.municipios
    .map(
      (m) =>
        `  (${literal(m.municipio_cod_propuesto)}, ${literal(m.nombre)}, ${literal(m.provincia_cod)})`,
    )
    .join(',\n');
  return `-- PROPUESTA SIN APLICAR. Requiere aprobación expresa antes de ejecutarse.
-- ID02; ONE, División Territorial 2021, corte declarado 2021-06-30.
-- Fuente, páginas y SHA-256: docs/catalogos/one-2021.propuesta.json.
-- Regenerar: node scripts/prepare-territory-catalog.js --write-sql
-- CUIDARED-003. No actualiza ni elimina registros, ni modifica tablas permanentes.
begin;
lock table cuidared.provincia, cuidared.municipio in share row exclusive mode;

create temporary table one_2021_provincia (
  provincia_cod varchar(2) primary key,
  nombre text not null unique
) on commit drop;
create temporary table one_2021_municipio (
  municipio_cod varchar(4) primary key,
  nombre text not null,
  provincia_cod varchar(2) not null references one_2021_provincia(provincia_cod)
) on commit drop;

insert into pg_temp.one_2021_provincia(provincia_cod, nombre) values
${provinceValues};

insert into pg_temp.one_2021_municipio(municipio_cod, nombre, provincia_cod) values
${municipalityValues};

-- Abortamos ante datos diferentes: no mezclar ediciones ni corregir nombres en silencio.
do $$
begin
  if exists (
    select 1 from cuidared.provincia p
    left join pg_temp.one_2021_provincia s using (provincia_cod)
    where s.provincia_cod is null or p.nombre is distinct from s.nombre
  ) or exists (
    select 1 from cuidared.municipio m
    left join pg_temp.one_2021_municipio s using (municipio_cod)
    where s.municipio_cod is null or m.nombre is distinct from s.nombre
       or m.provincia_cod is distinct from s.provincia_cod
  ) then
    raise exception using errcode = '22023',
      message = 'El catálogo existente difiere de la propuesta ONE 2021. Revisar antes de cargar.';
  end if;
end;
$$;

insert into cuidared.provincia(provincia_cod, nombre)
select provincia_cod, nombre from pg_temp.one_2021_provincia
on conflict (provincia_cod) do nothing;

insert into cuidared.municipio(municipio_cod, nombre, provincia_cod)
select municipio_cod, nombre, provincia_cod from pg_temp.one_2021_municipio
on conflict (municipio_cod) do nothing;

do $$
begin
  if (select count(*) from cuidared.provincia) <> 32
     or (select count(*) from cuidared.municipio) <> 158 then
    raise exception using errcode = '22023', message = 'Conteos territoriales inesperados.';
  end if;
end;
$$;
commit;
`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    if (process.argv.slice(2).some((arg) => arg !== '--write-sql')) {
      throw new Error('Argumento no permitido.');
    }
    const sql = prepareTerritoryCatalog(JSON.parse(await readFile(catalogUrl, 'utf8')));
    if (process.argv.includes('--write-sql')) await writeFile(sqlUrl, sql, 'utf8');
    console.log(
      'Catálogo local validado: 32 registros provinciales y 158 municipios. BD sin cambios.',
    );
  } catch {
    console.error('No se preparó el catálogo. Revisa el archivo fuente y los argumentos.');
    process.exitCode = 1;
  }
}
