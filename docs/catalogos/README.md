# Catálogo territorial ONE 2021

## Procedencia y alcance

El usuario confirmó usar **División Territorial 2021** para el MVP el 01/11/2026. Autor: Oficina Nacional de Estadística de República Dominicana. La presentación declara corte al **30/06/2021**; esta propuesta no certifica vigencia a 2026.

- [Publicación de la ONE](https://www.one.gob.do/publicaciones/2021/division-territorial-2021/).
- [Copia del documento de la ONE alojada por INDOTEL](https://indotel.gob.do/wp-content/uploads/2022/09/division-territorial-2021.pdf), consultada porque la descarga directa presentó una verificación de navegador.
- PDF de 519 páginas; SHA-256: `98fae470271cec43297df31f0df118a35b8188baa486f66062ed7b00b96d2b40`.

## Datos cargados y verificados

[one-2021.propuesta.json](one-2021.propuesta.json) contiene **32 registros de nivel provincial, incluido Distrito Nacional, y 158 municipios**. Cada fila conserva los pares oficiales de región/provincia/municipio, nombre y página de origen.

Se extrajeron las tablas detalladas por provincia: municipio distinto de cero, distrito municipal/sección/barrio/sub-barrio en cero. La página 7 explica esa jerarquía. El apéndice de la página 507 declara «Actualizada Julio del 2019»; por esa discrepancia no se utilizó como origen de los datos. No se añadieron distritos municipales como municipios ni códigos del prototipo. La página 486 se comprobó visualmente para verificar columnas y ceros.

`municipio_cod_propuesto` concatena los pares de provincia y municipio conservando ceros: provincia `01`, municipio `01` → `0101`. Es la representación propuesta para `cuidared.municipio.municipio_cod`, compatible con su dominio de cuatro a seis dígitos; esta representación fue aprobada y aplicada el 01/11/2026.

## Validación y carga

Desde la raíz del backend:

```powershell
node scripts/prepare-territory-catalog.js
node scripts/prepare-territory-catalog.js --write-sql
```

El primer comando valida localmente conteos, unicidad, jerarquía, códigos y fuente. El segundo regenera [el SQL propuesto](../propuestas/fase-2-territorio-one-2021.sql). Ninguno se conecta a servicios ni ejecuta SQL.

El SQL inserta únicamente provincias/municipios; admite repetir una carga idéntica y aborta si encuentra otro catálogo o nombres distintos. No sobrescribe ni elimina datos. Los objetos de preparación son temporales; no crea tablas permanentes ni cambia permisos.

**Aplicado y verificado el 01/11/2026:** tras aprobar la carga, el usuario confirmó las 37 correcciones de extracción y Sánchez Ramírez con tilde. Se cargaron 32 registros provinciales y 158 municipios; la comparación completa con el catálogo aprobado dio cero diferencias. El JSON conserva nombre_extraido en las 38 filas corregidas. [Informe y SQL de verificación](../VERIFICACION-TERRITORIO-ONE-2021.md); registro [CUIDARED-003](../CAMBIOS-SCHEMA-CUIDARED.md). El generador comprueba la huella de las filas aprobadas para impedir que se reintroduzcan nombres defectuosos. Una nueva ejecución requiere aprobación previa.
