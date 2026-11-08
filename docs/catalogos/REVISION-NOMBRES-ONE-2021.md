# Revisión de nombres del catálogo ONE 2021

## Estado y motivo

**01/11/2026: revisión aprobada y carga aplicada/verificada.** El usuario confirmó «Aplicar las 37 correcciones y usar Sánchez Ramírez con tilde».

El usuario aprobó la carga territorial original. Antes de ejecutarla se detectaron errores de extracción que la comprobación inicial de conteos/códigos no había identificado. Se compararon visualmente las 190 filas con sus páginas del PDF oficial (32 de nivel provincial y 158 municipios). Los códigos, cantidades y relaciones no cambian.

La revisión propone estas **37 correcciones de espacios y capitalización** para reproducir los nombres impresos en las tablas del PDF. Se mantiene la grafía de los conectores tal como está impresa (por ejemplo, «Jamao Al Norte» y «Sabana de La Mar»), sin renombrar municipios ni sustituirlos por el prototipo. P identifica provincia; M identifica municipio.

| Registro | Extracción original   | Propuesta verificada visualmente | Página |
| -------- | --------------------- | -------------------------------- | ------ |
| P02      | a zua                 | Azua                             | 38     |
| M0201    | a zua                 | Azua                             | 38     |
| M0208    | t ábara a rriba       | Tábara Arriba                    | 47     |
| M0303    | t amayo               | Tamayo                           | 58     |
| M0402    | cabral                | Cabral                           | 70     |
| M0407    | la ciénaga            | La Ciénaga                       | 75     |
| M0409    | las Salinas           | Las Salinas                      | 77     |
| M0502    | loma de cabrera       | Loma de Cabrera                  | 84     |
| M0602    | arenoso               | Arenoso                          | 103    |
| M0603    | castillo              | Castillo                         | 104    |
| M0605    | Villa riva            | Villa Riva                       | 106    |
| M0606    | las Guáranas          | Las Guáranas                     | 109    |
| M0701    | comendador            | Comendador                       | 115    |
| M0703    | El llano              | El Llano                         | 119    |
| M0902    | cayetano Germosén     | Cayetano Germosén                | 145    |
| M0904    | Jamao al Norte        | Jamao Al Norte                   | 148    |
| M1102    | San rafael del Yuma   | San Rafael del Yuma              | 172    |
| M1402    | cabrera               | Cabrera                          | 215    |
| M1501    | Monte cristi          | Monte Cristi                     | 225    |
| M1602    | oviedo                | Oviedo                           | 236    |
| M1802    | altamira              | Altamira                         | 262    |
| M1804    | imbert                | Imbert                           | 265    |
| M1805    | los Hidalgos          | Los Hidalgos                     | 266    |
| M1808    | Villa isabela         | Villa Isabela                    | 270    |
| M1902    | t enares              | Tenares                          | 279    |
| M2003    | las t errenas         | Las Terrenas                     | 293    |
| M2104    | cambita Garabitos     | Cambita Garabitos                | 306    |
| M2302    | los llanos            | Los Llanos                       | 347    |
| M2304    | consuelo              | Consuelo                         | 351    |
| M2404    | Villa la Mata         | Villa La Mata                    | 366    |
| M2506    | t amboril             | Tamboril                         | 400    |
| M2509    | Sabana iglesia        | Sabana Iglesia                   | 404    |
| M2703    | laguna Salada         | Laguna Salada                    | 427    |
| M3002    | Sabana de la Mar      | Sabana de La Mar                 | 469    |
| M3102    | Sabana larga          | Sabana Larga                     | 479    |
| M3202    | Santo Domingo oeste   | Santo Domingo Oeste              | 491    |
| M3205    | San antonio de Guerra | San Antonio de Guerra            | 499    |

## Discrepancia adicional de tilde

Provincia 24, página 358: la tabla imprime **Sanchez Ramírez**, mientras el encabezado de la misma página imprime **Sánchez Ramírez**. La extracción original reproduce la tabla sin la primera tilde. El usuario confirmó usar **Sánchez Ramírez**, conforme al encabezado; se aplicó esa grafía. Esta decisión es adicional a las correcciones de extracción anteriores.

## Alcance aplicado

Se aplicaron las correcciones listadas y la tilde aprobada; después se regeneró y ejecutó la carga autorizada. Se conserva nombre_extraido en las 38 filas modificadas para trazabilidad. No cambia el alcance de tablas (cuidared.provincia y cuidared.municipio), códigos de dos/cuatro dígitos, cantidades, restricciones, política de no sobrescritura ni permisos.

La verificación posterior confirmó 32 registros provinciales y 158 municipios, sin diferencias contra las filas aprobadas. Las dos autorizaciones y los resultados se registran en CUIDARED-003 y en el informe de verificación territorial. No hubo commits.
