# Registro de cambios del esquema cuidared

## Regla de mantenimiento

Por instrucción del usuario del **01/11/2026**, este archivo registra por separado los cambios propuestos y aplicados al esquema `cuidared`. Complementa `CAMBIOS-ACTUALES.md`, que mantiene el historial de código, y las migraciones SQL. Documentar un cambio no autoriza a aplicarlo. No incluir credenciales, códigos ni datos personales.

Cada entrada debe indicar: objetivo y requisito/fase, objetos afectados, comportamiento anterior y propuesto, permisos/RLS, compatibilidad e impacto en datos, archivo SQL, aprobación expresa, estado de ejecución, verificación y estrategia de reversión. Registrar efectos relacionados en `cuidared_api` cuando formen parte del mismo cambio.

Estados: **En diseño**, **Propuesto sin aplicar**, **Aprobado sin aplicar**, **Aplicado**, **Verificado**. La aprobación debe identificar la propuesta concreta; el estado solo avanza con evidencia de la operación correspondiente.

## CUIDARED-001 — Control de sesiones de fase 1

**Registro retrospectivo. Estado: aplicado y verificado el 25/10/2026.** Fuente: [migración registrada](../supabase/migrations/20261025041944_fase_1_acceso.sql) e [informe de verificación](VERIFICACION-FASE-1-SUPABASE.md). No implica una ejecución nueva el 01/11/2026.

| Aspecto              | Registro                                                                                                                                                                                |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Objetivo             | ID01/RF-09: límites de sesión, actividad y revocación verificadas en servidor.                                                                                                          |
| Tabla nueva          | `cuidared.sesion_acceso`: `sesion_id` UUID, PK/FK hacia `auth.sessions(id)` con borrado en cascada; `ultima_actividad` timestamptz obligatorio; `revocada_en` timestamptz opcional.     |
| Tabla existente      | `cuidared.usuario`: se activó RLS; no se creó ni reemplazó la tabla.                                                                                                                    |
| Privilegios          | Acceso directo a esas dos tablas revocado a PUBLIC, anon y authenticated. Acceso autorizado mediante RPC que comprueban identidad y sesión.                                             |
| Objetos relacionados | Esquema `cuidared_api`; funciones `api_sesion`, `api_mi_perfil`, `api_actualizar_mi_perfil`; ejecución para authenticated con ruta de búsqueda vacía y sin ejecución pública/anónima.   |
| Exposición API       | Solo `cuidared_api` mediante configuración de PostgREST en el rol authenticator. El esquema interno no se expuso.                                                                       |
| Compatibilidad       | Se conservaron perfiles y trigger de alta Auth; no se alteraron las otras 37 tablas existentes.                                                                                         |
| Aprobación           | Usuario: «Apruebo aplicar esa propuesta y exponer cuidared_api», recibida el 25/10/2026.                                                                                                |
| Ejecución            | Migración `20261025041944_fase_1_acceso`.                                                                                                                                               |
| Verificación         | Informe y SQL de verificación vinculados arriba: permisos, RLS, rechazos y exposición HTTPS. No equivale a certificar todos los recorridos con sesiones reales.                         |
| Reversión            | No hay rollback automático autorizado. Requiere revisión específica de datos de sesión y privilegios; no desactivar RLS ni devolver privilegios generales para revertir una incidencia. |

## CUIDARED-002 — Preparación de fase 2

**Estado: en diseño; sin SQL aprobado ni aplicado.**

El alta externa y el inicio manual de este diseño quedaron sustituidos el 07/11/2026. CUIDARED-004 registra la conciliación con el autorregistro del titular y el inicio automático de la prueba por 168 horas exactas.

Alcance por revisar: `cuenta`, `membresia`, `cuidador`, configuración por cuenta, catálogos relacionados, prueba única y controles de acceso. La cuenta inicial la crea un administrador externo y designa su titular, por confirmación del usuario del 01/11/2026. No se implementará autorregistro público de cuentas.

La primera consulta remota de lectura del 01/11/2026 fue rechazada. Posteriormente el usuario autorizó expresamente inspeccionar metadatos, funciones, permisos y catálogos; esa inspección se completó mediante SELECT. La [consulta de metadatos](verificacion/fase-2-inspeccion.sql) es de lectura. Esta autorización no permite aplicar cambios ni cargar catálogos.

**Hallazgos verificados el 01/11/2026:** cuenta y membresía tienen cero filas; no hay pruebas anteriores. Están vacíos los catálogos de tipos de cuenta, roles, categorías, tipos de cuidado, parámetros, planes/categorías de plan, provincias y municipios. `cuenta.plan_id` y `municipio_cod` son obligatorios y referencian catálogos vacíos. Las fechas de prueba son date; suscripción por defecto es activa y su CHECK no incluye sin_iniciar. Cuenta, membresía, cuidador y configuración tienen RLS desactivado, pero los SELECT inspeccionados de anon/authenticated están denegados: no se infiere exposición pública de ese dato.

Las funciones existentes `sp_registrar_cuenta` (autorregistro, plan gratuito y rol administrador fijo), `sp_iniciar_prueba_gratuita` (solo administrador, fechas date y fallback de 30 días), `fn_es_gestor_cuenta` (incluye trabajador_social) y `fn_trg_membresia_limite` (cupo global de usuarios) no implementan las reglas aprobadas. No se reutilizaron, reemplazaron ni expusieron automáticamente. El asesor conserva 15 avisos de search_path anteriores y las dos observaciones esperadas de RLS sin políticas en las tablas privadas de fase 1.

**Reglas ya confirmadas:** titular Coordinador en Familia/Administrador en Organización; esos roles gestionan datos, configuración y membresías. Coordinador de Organización solo gestiona perfiles de cuidadores en esta matriz administrativa. Prueba de inicio manual por el gestor, exactas 168 horas UTC, una sola vez y con capacidades del plan básico del tipo de cuenta. Contexto por URL y bigint como texto.

**Confirmaciones adicionales:** territorio ONE 2021 para el MVP; perfil Cuidador único y global, editable por los gestores autorizados de cualquiera de sus cuentas; una membresía activa por usuario/cuenta; cambio de rol mediante cierre y alta de otra membresía; baja y cambio de rol del titular bloqueados hasta definir transferencia. Solo las membresías activas consumen cupo. Sin prueba vigente, conservar lectura de cuenta y gestión de suscripción, bloqueando cambios de miembros, configuración y cuidadores. TipoCuidado queda aplazado por el usuario. La aprobación de estas reglas no autoriza DDL, semillas ni escrituras de prueba.

**Diseño físico por conciliar, sin aplicar:**

- Un registro persistente y único por cuenta para conservar inicio/fin de prueba con precisión timestamptz. Las columnas date del exportado no representan una ventana exacta de 168 horas. Debe impedir reinicio/ampliación también en BD y serializar inicios concurrentes. La tabla/columnas finales y cualquier compatibilidad con datos anteriores se decidirán tras inspeccionar la base viva.
- Resolver `plan_id` obligatorio antes de que exista un plan comercial contratado, sin crear un plan Trial ni inventar precios. El cambio concreto de nulabilidad/garantías debe formar parte del SQL revisable, con adaptación del trigger de compatibilidad si corresponde.
- Conciliar estados anteriores con una cuenta cuya prueba todavía no comenzó. `sin_iniciar` forma parte del DTO propuesto; no se ha alterado el CHECK de `cuenta` ni se asume que ese valor exista en la tabla actual.
- Revisar RLS y privilegios de cuenta, membresía, configuración, cuidador y catálogos, sin exponer directamente el esquema interno.
- Funciones propuestas de `cuidared_api`: `api_mis_cuentas`, `api_contexto_cuenta` y `api_iniciar_prueba_cuenta`. Deben verificar sesión, identidad, membresía, compatibilidad de rol y límites sin confiar en los datos del cliente; la última consume la prueba en una transacción atómica.
- Catálogos/capacidades básicas y aprovisionamiento externo: no adoptar IDs, códigos, precios ni valores demo como datos aprobados. Los límites básicos de V2 deben representarse sin confundir familiares, staff y todos los usuarios.
- Unicidad de membresía activa por `(usuario_id, cuenta_id)` y serialización del cambio de rol para que cerrar/crear suceda en una sola transacción. Preservar las filas históricas y proteger al titular también en BD, sin permitir eludirlo llamando directamente a una RPC.
- Unicidad del perfil global de Cuidador por `usuario_id`, sin añadir `cuenta_id` como propietario del perfil. La edición por gestores autorizados de sus cuentas debe comprobar pertenencia y vigencia sin conceder lectura de otras cuentas.
- Carga territorial versionada con códigos oficiales de la ONE, conservación de ceros iniciales, procedencia y fecha de corte. La fuente encontrada es División Territorial 2021; no se declara actualizada a 2026 ni se carga automáticamente.

**Ejecución de cambios y verificación de persistencia nueva:** no realizadas. La implementación local y los mocks no modifican esquema ni garantizan políticas o concurrencia PostgreSQL. La inspección remota es evidencia de lectura, no una prueba de las RPC propuestas. La edición territorial, la edición compartida del cuidador y el bloqueo administrativo sin vigencia están confirmados. Las 20 plazas de Organización cuentan solo Administrador, Coordinador y Cuidador activos, excluyendo Familiar, Voluntario y pendientes. TipoCuidado queda aplazado; los contratos administrativos completos continúan en preparación.

Cuando exista una propuesta concreta, completar aquí objetos, garantías de historial y unicidad, restricciones, permisos/RLS, SQL, impacto, verificaciones y reversión; solicitar aprobación antes de ejecutar cualquier cambio.

## CUIDARED-003 — Catálogo territorial ONE 2021

**Estado: verificado; aplicado el 01/11/2026.** ID02. El usuario aprobó la carga original y después confirmó «Aplicar las 37 correcciones y usar Sánchez Ramírez con tilde». Se cargó la versión corregida en Supabase CuidaRed y se verificaron sus 190 registros completos.

| Aspecto                     | Registro                                                                                                                                                                                                                                                       |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Objetos                     | Datos de `cuidared.provincia` y `cuidared.municipio`; sin DDL permanente. Tablas temporales de preparación solo durante la transacción.                                                                                                                        |
| Antes                       | La inspección autorizada encontró ambos catálogos vacíos.                                                                                                                                                                                                      |
| Propuesta                   | Insertar 32 registros de nivel provincial, incluido Distrito Nacional, y 158 municipios de las tablas provinciales de la ONE 2021. Conservar códigos como texto y ceros iniciales; municipio representado por concatenación de pares provincia/municipio.      |
| Fuente y corte              | [Procedencia, extracción y advertencias](catalogos/README.md); corte declarado 30/06/2021, sin afirmar vigencia a 2026. El apéndice con fecha de 2019 no se usó como origen.                                                                                   |
| SQL                         | [fase-2-territorio-one-2021.sql](propuestas/fase-2-territorio-one-2021.sql), generado localmente por `scripts/prepare-territory-catalog.js`.                                                                                                                   |
| Integridad y compatibilidad | Transacción y bloqueo de tablas; aborta ante catálogo diferente, nombres/códigos contradictorios o conteos inesperados. Repetir una carga idéntica no duplica filas. No actualiza ni borra datos.                                                              |
| Privilegios/RLS             | No se cambian permisos, políticas, exposición API ni funciones.                                                                                                                                                                                                |
| Aprobación                  | Edición, carga y códigos de cuatro dígitos aprobados expresamente el 01/11/2026; también las 37 correcciones de extracción y Sánchez Ramírez con tilde.                                                                                                        |
| Ejecución                   | Ejecutada una vez en Supabase CuidaRed mediante conector SQL, en transacción. Copia exacta: supabase/seeds/territorio-one-2021.sql. SHA-256: 44be66c873d847a3d7fbc4a11d90b597eaa126b0a7ef71bffd15d0370ab475a1. Sin nueva versión de migración.                 |
| Verificación                | 32 registros provinciales y 158 municipios; cero diferencias contra las 190 filas aprobadas, cero códigos inválidos, cero municipios huérfanos y cero tablas temporales restantes. RLS, ACL explícitas y número de políticas iguales a los valores anteriores. |
| Reversión                   | Un error antes del commit revierte la transacción. Tras aplicar, no hay borrado automático autorizado: revisar referencias de cuentas/adultos y solicitar aprobación específica antes de retirar datos.                                                        |

Detalle: [revisión de nombres](catalogos/REVISION-NOMBRES-ONE-2021.md) e [informe de verificación](VERIFICACION-TERRITORIO-ONE-2021.md). El catálogo conserva el texto extraído de las 38 filas corregidas. La validación inicial no había detectado todos los defectos; se amplió a una comparación visual de las 190 filas antes de aplicar la carga.

## CUIDARED-004 — Conciliación de propuestas de fases 2 a 4

**Estado: en revisión, sin SQL nuevo aprobado ni aplicado.** El historial de Supabase consultado el 07/11/2026 solo registra fase 1. Las RPC de listado y contexto de cuenta están ausentes. La carga ya aplicada CUIDARED-003 permanece con 32 provincias y 158 municipios.

| Bloque | Cambios revisados en la rama de Katriel                                                                                                                                                                         | Condición para una nueva propuesta                                                                                                                                                                                                         |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2a–2c  | Catálogos, `cuenta`, `membresia`, `cuidador` y configuración. Tablas `rol_permiso`, `plan_funcionalidad` y `prueba_funcionalidad`. Funciones internas, RPC en `cuidared_api` y reemplazo de `api_sesion`.       | Conservar trigger de perfil, reconciliar triggers históricos de plan y cupo, prueba automática atómica con instantes UTC, perfil Cuidador global y bloqueo administrativo sin vigencia. Separar precios y `TipoCuidado` pendientes.        |
| 3a–3b  | Cédula única y consentimiento en `envejeciente`, índices de contactos, autorización/revocación en `vinculo`, cambios de riesgo e indicaciones y tabla `evaluacion_riesgo`.                                      | Comprobar datos previos antes de exigir columnas y restricciones, preservar contacto principal e historial y cerrar la política de consentimiento y baja.                                                                                  |
| 4a–4c  | `visita`, `detalle_visita`, `tarea_agenda`, `evidencia`, tablas `solicitud_visita` y `operacion_sync`, bucket privado y políticas de Storage. La propuesta concede a `anon` ejecución de RPC del flujo externo. | Eliminar el camino de visita sin autorización también al sincronizar. Separar las RPC públicas y revisar seguridad/retención. Verificar existencia de datos antes de restricciones, asignación con cuidador global y permisos de archivos. |

[SQL revisado, fijado al commit cb0c4d8](https://github.com/cyberwarrior8/CuidaRed-Backend/tree/cb0c4d85bd7c2b992b22a03e6810b4965b5c89a7/docs/propuestas). [Hallazgos y orden de integración](REVISION-INTEGRACION-FASES-2-A-4.md).

**Permisos, impacto y reversión pendientes.** Las propuestas incluyen funciones privilegiadas y cambios de RLS. No se verificó su funcionamiento contra el esquema real ni se autorizó cambiar Auth, exponer RPC anónimas o crear el bucket. Preparar una propuesta por bloque con precondiciones de datos, privilegios efectivos y reversión que preserve los datos de seguimiento. La aprobación deberá identificar el SQL concreto. El catálogo ONE archivado se incorpora como evidencia de CUIDARED-003 y queda fuera de ese despliegue.

## CUIDARED-005 — Propuesta integrada de fases 2 a 4

**Estado: propuesta revisable sin aplicar.** Sustituye los borradores del inventario anterior. CUIDARED-006 actualiza el tratamiento de datos históricos. [Contratos y recorrido](INTEGRACION-FASES-2-A-4.md).

| Bloque           | Archivos y cambios                                                                                                                                                                                                                                                                                                                                                                     | Precondiciones y verificación                                                                                                                                                                                                                                 |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cuentas          | [2a](propuestas/fase-2a-base.sql), [2b](propuestas/fase-2b-cuentas.sql), [2c](propuestas/fase-2c-miembros.sql). Instantes de prueba en `timestamptz`, ventana inmutable de 168 h, una prueba vigente por titular, roles/cupos, perfil global, transferencia e invitaciones propias. RPC de listados y contexto, y reconciliación de los triggers reales de plan y límite de membresía. | Abortar ante pruebas históricas con fechas sin hora o perfiles de cuidador duplicados. Verificar unicidad, expiración, compatibilidad de roles y activación concurrente. El catálogo ONE cargado queda intacto. No se siembran precios ni planes comerciales. |
| Expediente       | [3a](propuestas/fase-3a-envejecientes.sql), [3b](propuestas/fase-3b-seguimiento.sql). Unicidad global de cédula, consentimiento, contacto principal, relaciones autorizadas, riesgo e indicaciones. Catálogo de cuatro tipos de indicación aprobado.                                                                                                                                   | Revisar cédulas nulas/duplicadas, contactos y consentimientos previos. Validar con y sin autorización familiar. No inventar consentimientos para datos existentes.                                                                                            |
| Visitas y agenda | [4a](propuestas/fase-4a-visitas.sql), [4b](propuestas/fase-4b-agenda.sql), [4c](propuestas/fase-4c-sync.sql), [4d](propuestas/fase-4d-evidencias-visita.sql). Visitas autorizadas, agenda con perfil global, sync y `cuidared.evidencia_visita`. Bucket privado y políticas separadas por tipo de evidencia.                                                                           | Comprobar precondiciones de tablas existentes y configuración del bucket. La consulta de evidencias verifica a todos los adultos de la visita. Las RPC públicas quedan revocadas para `anon` y `authenticated`.                                               |

**Aprobación y ejecución.** Los acuerdos funcionales permiten preparar el código. La aplicación de los nueve bloques de SQL, la activación de registro por correo y los cambios de Storage requieren aprobación sobre esta propuesta y verificación en un entorno autorizado. Solo se usó PostgreSQL en memoria con datos sintéticos y consultas de metadatos de solo lectura contra Supabase.

**Reversión.** Cada bloque usa una transacción. Ante incompatibilidad, abortar el bloque y revisar los ya aplicados antes de reintentar. Una vez existan cuentas, autorizaciones o archivos, cualquier reversión debe conservar datos e historial, restaurar los triggers y permisos anteriores según una propuesta específica y desactivar primero las rutas afectadas. No borrar tablas ni volver a fechas sin hora como reversión automática.

## CUIDARED-006 — Conservación de datos previos en fases 2 a 4

**Estado: diseño validado localmente.** La aplicación se registra en CUIDARED-007. El usuario confirmó conservar las fechas históricas de prueba, detener el bloque de expedientes ante datos no verificables y preservar en modo de consulta las tareas y evidencias anteriores. Las visitas sin una cuenta verificable quedan fuera de las consultas de cuenta.

- [2a](propuestas/fase-2a-base.sql), [2c](propuestas/fase-2c-miembros.sql) y [3b](propuestas/fase-3b-seguimiento.sql). Se preservan las fechas de prueba por calendario y se exige un periodo exacto para habilitar acceso por prueba. `vinculo` conserva cada periodo con una PK propia. Cambiar de rol registra la revocación y una nueva autorización crea una fila.
- [3a](propuestas/fase-3a-envejecientes.sql). Se comprueban tipo y formato de cédula, duplicados, contacto principal y consentimiento. Ante un defecto, se revierte el bloque. Las correcciones de expedientes existentes se preparan y aprueban por separado.
- [4a](propuestas/fase-4a-visitas.sql) y [4b](propuestas/fase-4b-agenda.sql). Las visitas ambiguas se conservan fuera de las cuentas, incluido el historial del adulto. Las tareas y evidencias previas se marcan como históricas. Las políticas de Storage impiden descargar archivos históricos aunque se conozca su ruta.

**Verificación.** Nueve bloques y regresiones de integración probados en PostgreSQL local en memoria con datos sintéticos previos. Se comprobó el rollback del bloque 3a ante cédula ausente, duplicados, contacto principal faltante y consentimiento incompleto. Auth y Storage usaron simulaciones locales. El [inventario técnico](PROPUESTA-SCHEMA-CUIDARED-FASES-2-A-4.md) detalla columnas, funciones, triggers y precondiciones.

## CUIDARED-007 — Aplicación de fases 2 a 4 en Supabase

**Estado al 09/11/2026.** Los nueve bloques de fases 2 a 4 están aplicados y registrados en Supabase CuidaRed. El usuario autorizó la aplicación y los ajustes de compatibilidad detectados en el proyecto. La inspección previa encontró 32 provincias, 158 municipios y tablas operativas vacías.

| Bloque | Migración registrada                                                                                            |
| ------ | --------------------------------------------------------------------------------------------------------------- |
| 2a     | [20261109041338_fase_2a_base](../supabase/migrations/20261109041338_fase_2a_base.sql)                           |
| 2b     | [20261109041405_fase_2b_cuentas](../supabase/migrations/20261109041405_fase_2b_cuentas.sql)                     |
| 2c     | [20261109041415_fase_2c_miembros](../supabase/migrations/20261109041415_fase_2c_miembros.sql)                   |
| 3a     | [20261109042249_fase_3a_envejecientes](../supabase/migrations/20261109042249_fase_3a_envejecientes.sql)         |
| 3b     | [20261109042254_fase_3b_seguimiento](../supabase/migrations/20261109042254_fase_3b_seguimiento.sql)             |
| 4a     | [20261109042259_fase_4a_visitas](../supabase/migrations/20261109042259_fase_4a_visitas.sql)                     |
| 4b     | [20261109042302_fase_4b_agenda](../supabase/migrations/20261109042302_fase_4b_agenda.sql)                       |
| 4c     | [20261109042306_fase_4c_sync](../supabase/migrations/20261109042306_fase_4c_sync.sql)                           |
| 4d     | [20261109042310_fase_4d_evidencias_visita](../supabase/migrations/20261109042310_fase_4d_evidencias_visita.sql) |

**Compatibilidad.** 2a reemplazó la regla anterior de prueba y reconoció la PK histórica de `vinculo`. El primer intento de 3a se revirtió por un índice preexistente. Se comprobó la ausencia de sus columnas antes del reintento. Los bloques 3a, 4a y 4b reutilizaron tres índices equivalentes. 4b creó `ix_evidencia_tarea_estado` y conservó el índice simple. 4a reemplazó la restricción de horas para admitir inicio y fin iguales.

**Verificación.** Las nueve copias locales coinciden por MD5 con el historial de Supabase. La [prueba transaccional](verificacion/fases-2-a-4-supabase.sql) confirmó perfil, alta con 168 horas, membresía, perfil de cuidador, expediente, programación de visitas, sincronización idempotente, recurrencia y autorización de evidencias. Las filas de prueba se revirtieron. Se comprobaron RLS y ausencia de acceso directo para las siete tablas nuevas, el bucket privado de 5 MB con cuatro políticas y la exposición limitada a `cuidared_api`. Las RPC representativas de cada fase devolvieron 401 por HTTPS sin sesión. Las funciones públicas de solicitudes permanecen revocadas. Las pruebas simularon las sesiones y comprobaron permisos de Storage sin subir archivos.

**Configuración de Auth.** Con aprobación separada, se habilitó el registro por correo en Supabase y se guardó la plantilla «Confirma tu correo en CuidaRed» con `{{ .Token }}`. El panel confirmó el requisito de confirmar el correo, códigos de 6 dígitos y vigencia de 900 segundos. La comprobación de entrega del correo corresponde a la prueba desde la aplicación.
