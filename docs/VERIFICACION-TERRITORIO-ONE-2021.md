# Verificación de la carga territorial ONE 2021

## Autorización y alcance

**Aplicada y verificada el 01/11/2026 en Supabase CuidaRed.** Registro: CUIDARED-003.

El usuario autorizó «Aprobar esta carga territorial» y, al descubrir diferencias en nombres antes de ejecutarla, confirmó «Aplicar las 37 correcciones y usar Sánchez Ramírez con tilde».

Se insertaron únicamente datos en `cuidared.provincia` y `cuidared.municipio`. Los códigos provinciales tienen dos dígitos; los municipales concatenan los pares provincia/municipio y tienen cuatro, conservando ceros iniciales. No se crearon tablas permanentes ni se modificaron permisos, políticas, funciones o usuarios.

## Fuente y correcciones

ONE, División Territorial 2021, corte declarado 30/06/2021, [copia publicada por INDOTEL](https://indotel.gob.do/wp-content/uploads/2022/09/division-territorial-2021.pdf). No certifica vigencia territorial a 2026.

La revisión visual de las 190 filas permitió corregir 37 diferencias de espacios/capitalización introducidas por la extracción. Además se adoptó Sánchez Ramírez con tilde, conforme al encabezado de la página 358 y la decisión del usuario. [Detalle de correcciones](catalogos/REVISION-NOMBRES-ONE-2021.md). El [catálogo](catalogos/one-2021.propuesta.json) conserva `nombre_extraido` en las 38 filas modificadas.

## SQL ejecutado

- [Copia exacta de la carga](../supabase/seeds/territorio-one-2021.sql), equivalente al archivo revisado de `docs/propuestas/`.
- SHA-256 del texto UTF-8 ejecutado: `44be66c873d847a3d7fbc4a11d90b597eaa126b0a7ef71bffd15d0370ab475a1`.
- Ejecutado una vez mediante el conector SQL, en una transacción con bloqueo de las dos tablas. No se creó una versión en el historial de migraciones; es una carga de datos, no una migración de esquema permanente.
- El encabezado «PROPUESTA SIN APLICAR» se conserva como parte del SQL original ejecutado para mantener su huella; este informe y CUIDARED-003 registran su estado actual. Cualquier nueva ejecución requiere aprobación previa.

## Comprobaciones realizadas

Antes de la carga, ambas tablas tenían cero filas. La transacción terminó correctamente. Después se ejecutó [la comparación completa de solo lectura](verificacion/fase-2-territorio-one-2021.sql), contrastando cada código, nombre y provincia contra el conjunto aprobado.

| Comprobación                                             | Resultado |
| -------------------------------------------------------- | --------- |
| Registros provinciales, incluido Distrito Nacional       | 32        |
| Municipios                                               | 158       |
| Diferencias respecto a provincias aprobadas              | 0         |
| Diferencias respecto a municipios aprobados              | 0         |
| Códigos provinciales inválidos                           | 0         |
| Códigos municipales inválidos o con prefijo incompatible | 0         |
| Municipios sin provincia                                 | 0         |
| Tablas temporales restantes de la carga                  | 0         |

En ambas tablas, RLS permaneció desactivado, la ACL explícita siguió nula y el número de políticas se mantuvo en cero, igual que antes. Esta operación no expone las tablas mediante la API ni certifica los controles de fase 2 aún pendientes. No se reejecutó la carga para probar idempotencia; se comprobó el resultado íntegro de la ejecución autorizada.

## Estado del desarrollo

El backend aprobó 139 pruebas, incluidas cuatro que comprueban reproducción del SQL y rechazo de regresiones reales de extracción/tilde. ESLint y formato de archivos afectados correctos. Las dos copias SQL conservan el SHA-256 de la ejecución. Estas comprobaciones locales no reejecutan la carga ni escriben datos en Supabase.

La dependencia territorial quedó cargada y verificada. Las RPC de cuentas/prueba, aprovisionamiento externo, demás catálogos y administración completa de miembros/configuración/cuidadores siguen pendientes. No se realizaron commits.
