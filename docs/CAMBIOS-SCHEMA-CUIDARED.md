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

## CUIDARED-008 — Correcciones de las fases 2 a 4

**Estado.** El usuario aprobó la aplicación el 13/11/2026. Los cinco bloques se aplicaron en una sola transacción en Supabase CuidaRed. La [migración aplicada](../supabase/migrations/20261114022629_cierre_fases_2_a_4_cuidared_008.sql) quedó registrada como `20261114022629` (UTC).

### Tabla nueva en `cuidared`

| Tabla | Campos |
| --- | --- |
| `evidencia_indicacion` | `evidencia_indicacion_id uuid` PK, `indicacion_medica_id uuid` FK, `registrada_por uuid` FK a usuario, `ruta text` única, `nombre_archivo text`, `tipo_mime text`, `tamano_bytes integer`, `fecha_registro timestamptz`. Todos obligatorios. RLS y acceso por RPC. |

### Tablas existentes

| Tabla | Cambio |
| --- | --- |
| `envejeciente` | `consentimiento_retirado_en timestamptz`, `consentimiento_retirado_por uuid` FK y `consentimiento_retiro_motivo text` opcional. Restricción de coherencia e índice parcial por cuenta y fecha de retiro. |
| `visita` | `serie_id uuid` para las ocurrencias nuevas y un índice parcial por cuenta/serie. |
| `riesgo` | Cinco factores de V2 por nombre y código. Se conserva el catálogo previo. |
| `auditoria` | Nuevos eventos para evaluación, solicitud y evidencias mediante disparadores que guardan la referencia de la fila y su contenedor. |

### Funciones, disparadores y orden de aplicación

1. [Correcciones](propuestas/cierre-2-4-correcciones.sql). Revisa alcance, candidatos, asignaciones y registro de visitas (incluye sincronización). Agrega una variante de `api_guardar_cuidador_miembro` que permite conservar el empleador global. La firma previa sigue siendo válida.
2. [Retiro de consentimiento](propuestas/cierre-2-4-consentimiento.sql). Añade las RPC `api_retirar_consentimiento` y `api_consentimientos_retirados`. Actualiza el alcance de expedientes, visitas e historial y el acceso a tareas. Los disparadores `envejeciente_retiro_inmutable` y `tarea_requiere_consentimiento` protegen el retiro y el trabajo nuevo. La misma transacción cancela las visitas y tareas operativas abiertas y cierra las alertas abiertas. Una visita grupal vinculada al expediente retirado queda fuera del historial operativo de todos sus participantes y se conserva para custodia.
3. [Series de visitas](propuestas/cierre-2-4-visitas-recurrentes.sql). `api_programar_visitas_recurrentes` vuelve a comprobar vigencia, funcionalidad del plan y autorización de cada visita. Si falla una ocurrencia, se revierte la serie.
4. [Adjuntos de indicaciones](propuestas/cierre-2-4-indicaciones-adjuntos.sql). RPC para preparar subida, registrar y listar. Dos políticas nuevas en `storage.objects` basadas en `cuidared_storage.evidencia_indicacion_permitida`. Reutiliza el bucket privado `evidencias` con 5 MiB y JPG, PNG, WebP o PDF.
5. [Auditoría](propuestas/cierre-2-4-auditoria.sql). `api_auditoria_cuenta` consulta los cambios confirmados cuya cuenta es verificable. `trg_auditoria_referencia` se instala en `evaluacion_riesgo`, `solicitud_visita`, `evidencia_visita` y `evidencia_indicacion`. La respuesta omite los valores de las filas. Los eventos globales que carecen de cuenta verificable y las peticiones técnicas rechazadas quedan fuera de esta consulta.

**Conservación.** Mantener el consentimiento original, la constancia, el expediente y los archivos. Revisar caso por caso cualquier eliminación, incluida la de archivos que quedaron sin registrar tras una subida interrumpida. Las URL privadas emitidas antes de un retiro vencen en un máximo de cinco minutos. Las solicitudes de nuevas URLs vuelven a comprobar permisos. Si hay que corregir un despliegue, preparar una migración que conserve las constancias, series y referencias de archivos que ya se hayan creado.

**Verificación.** El [juego local de cierre](verificacion/local/pruebas-cierre-2-4.sql) pasó en PostgreSQL desechable con Auth y Storage simulados. En Supabase se confirmaron cinco factores, cuatro columnas, seis disparadores y dos políticas de Storage. La tabla nueva tiene RLS y solo se consulta por RPC. Las siete RPC nuevas verificadas exigen autenticación y las RPC públicas siguen revocadas. El bucket es privado y conserva el límite de 5 MiB. El historial remoto registró la huella MD5 `b45f62359b874fd7f833ff984cea3069` sobre las sentencias que conserva Supabase. Queda por verificar el envío de correo y la subida y descarga real de archivos.

## CUIDARED-009 — Necesidades y alertas

**Estado.** Aplicado el 15/11/2026 al proyecto Supabase CuidaRed, con aprobación expresa del usuario. La revisión previa encontró los catálogos de Necesidades vacíos, el tipo `ausencia_visitas` existente y automatismos antiguos para alertas de riesgo, necesidades y visitas.

### Tablas y campos de `cuidared`

| Tabla | Cambios propuestos |
| --- | --- |
| `tipo_necesidad` y `necesidad` | Añade `tipo_necesidad.codigo text` único y siembra cinco tipos con su ítem general. Conserva el catálogo previo y comprueba que cada ítem general coincide con su tipo. |
| `envejeciente_necesidad` | Añade `registrado_por uuid` y `resuelto_por uuid` con referencias a `usuario`. Amplía `cantidad` de `numeric(10,2)` a `numeric` sin escala fija y `unidad_medida` de `varchar(30)` a `varchar(64)`, según la decisión del 15/11/2026. Los registros previos conservan sus valores. Habilita RLS, agrega un índice por expediente y fecha y garantiza que `fecha_actualizacion` avance en cada cambio para comparar versiones al sincronizar. |
| `necesidad_evento` (nueva) | `necesidad_evento_id uuid` PK, `envejeciente_necesidad_id uuid` FK, `usuario_id uuid` FK, `fecha timestamptz`, `estado_anterior text`, `estado text`, `prioridad_anterior_id smallint` y `prioridad_id smallint` FK, `responsable_anterior_id uuid` y `responsable_id uuid` FK, `motivo text`. RLS e índice por ocurrencia y fecha. |
| `alerta_envejeciente` | Añade `fuente_riesgo_id bigint`, `fuente_necesidad_id uuid`, `fuente_visita_id uuid` (FK compuesta con adulto), `fuente_perfil_id uuid`, `cierre_automatico boolean` y `sin_fuente_historica boolean`. Agrega RLS, verificación de fuente y restricciones para el cierre. Cuatro índices únicos parciales reemplazan la deduplicación antigua por tipo. |
| `tipo_alerta` y `notificacion` | Incorpora los códigos de alerta vigentes, conserva el tipo de seguimiento y reutiliza un aviso por destinatario. RLS e índice de bandeja para notificaciones de alerta. |

### Funciones y orden

1. [Fase 5, necesidades](propuestas/fase-5-necesidades.sql). RPC de listado, detalle, historial, candidatos, registro, actualización y estado. `necesidad_registrar_evento` registra las operaciones de la ocurrencia. `trg_envejeciente_necesidad_fecha_actualizacion` usa la función interna `necesidad_fijar_version` para producir versiones distintas incluso cuando coinciden los milisegundos. El cambio de tipos restaura la vista `v_necesidades_activas` con su definición y `security_invoker`, y reinstala el disparador anterior de alertas hasta que el bloque 6b lo sustituye. Se conserva el control de cupos instalado.
2. [Fase 5, sincronización](propuestas/fase-5-sync-necesidades.sql). Extiende `api_sync_aplicar_operacion` y `api_sync_obtener_operacion`. `sync_necesidad` aplica idempotencia, versión y permisos con los mismos validadores del flujo en línea. Reutiliza `operacion_sync`.
3. [Fase 6a, consultas](propuestas/fase-6a-alertas-consulta.sql). RPC de listado, detalle, gestión, casos prioritarios y lectura de avisos. Los casos agrupan por adulto y mantienen las fuentes individuales.
4. [Fase 6b, motor](propuestas/fase-6b-alertas-motor.sql). Reemplaza los disparadores antiguos, revoca acceso a generadores antiguos y agrega comprobación de fuente, generación por riesgo y medicamentos, y avisos internos sin datos de salud. `alertas_evaluar_diario` reconcilia datos existentes y ventanas sin visita.
5. [Fase 6z, auditoría](propuestas/fase-6z-auditoria-necesidades-alertas.sql). Extiende `api_auditoria_cuenta` a las ocurrencias y a las alertas. Reemplaza `trg_envejeciente_necesidad_auditoria` y `trg_alerta_envejeciente_auditoria` para guardar referencias a las filas y al expediente mediante `trg_auditoria_referencia`. Se conservan las entradas históricas y los disparadores de Backoffice.

### Aplicación y verificación en Supabase

- [Migración `20261115231642`](../supabase/migrations/20261115231642_fases_5_y_6_cuidared_009.sql). Reúne los cinco bloques en una transacción. Se verificaron las cinco categorías cargadas y RLS en `envejeciente_necesidad`, `necesidad_evento`, `alerta_envejeciente` y `notificacion`.
- [Prueba transaccional](verificacion/fases-5-y-6-supabase.sql). Con datos sintéticos y sesión simulada, comprobó el alta sincronizada y su reintento idempotente, la conservación de `0.004` y una unidad de 64 caracteres, las alertas de riesgo y medicamentos agrupadas por adulto, la lectura del aviso, el cierre automático y la auditoría por referencia. Se revirtieron las filas de prueba y se confirmó que la identidad temporal, su necesidad y sus eventos no quedaron en la base.
- [Migración `20261115231810`](../supabase/migrations/20261115231810_cron_alertas_cuidared_009.sql). Aplicó por separado la [evaluación inicial y programación diaria](propuestas/operacion-fase-6-cron.sql). La evaluación inicial dejó una alerta y un aviso para datos existentes. El trabajo `cuidared_alertas_diarias` quedó activo con `5 4 * * *` en GMT, a las 00:05 de República Dominicana. Al verificar el despliegue, aún no había ocurrido la primera ejecución programada.

Las pruebas SQL locales se pueden repetir con `npm run validar:sql -- --solo=fases-5-6` en una base desechable. La prueba remota valida las funciones y los datos, y las pruebas manuales del navegador cubren el recorrido con una sesión real.

## CUIDARED-010 — Suscripciones Web Push

**Estado.** Aplicado el 16/11/2026 con autorización del usuario. Registro de dispositivos y cola de entregas Web Push.

- La tabla nueva `cuidared.push_suscripcion` guarda `endpoint text`, `endpoint_hash bytea` generado y usado como PK, `usuario_id uuid` con FK a `usuario`, `sesion_id uuid`, `p256dh text`, `auth text`, `creada_en timestamptz` y `actualizada_en timestamptz`. Usa índices por usuario y sesión, RLS y acceso mediado por la API. El cierre manual elimina el registro mediante un disparador en `sesion_acceso`.
- La tabla nueva `cuidared.push_entrega` guarda `entrega_id uuid` como PK, `notificacion_id uuid` y `endpoint_hash bytea` como FKs, `estado text`, `intentos smallint`, `reserva_id uuid`, `version_suscripcion timestamptz`, `disponible_en timestamptz`, `creada_en timestamptz` y `terminada_en timestamptz`. Usa RLS, una restricción única por aviso y dispositivo, y un índice de pendientes.
- `cuidared_interno.push_endpoint_valido` comprueba el formato y los proveedores admitidos. Las funciones `cuidared_api.api_push_registrar_suscripcion`, `api_push_estado_suscripcion` y `api_push_revocar_suscripcion` exigen la sesión vigente y limitan las operaciones a la persona autenticada.
- El disparador en `notificacion` encola entregas de alertas nuevas. `cuidared_interno.push_aviso_elegible` revalida permisos y vigencia del aviso. `cuidared_api.api_push_reservar_entregas` y `api_push_finalizar_entrega` están reservadas a `service_role`.
- [SQL de suscripciones](propuestas/web-push-suscripciones.sql), [SQL de entregas](propuestas/web-push-entregas.sql) y [prueba local del motor](verificacion/local/pruebas-web-push-entregas.sql).
- [Migración `20261116043610`](../supabase/migrations/20261116043610_web_push_cuidared_010.sql). La [prueba transaccional en Supabase](verificacion/web-push-supabase.sql) comprobó que una alerta genera una reserva única, su finalización y la revocación al cerrar sesión. Los datos de prueba se revirtieron, la revisión diaria de alertas sigue activa y ambas tablas tienen RLS. El emisor queda apagado mientras está pendiente el contacto VAPID.

## CUIDARED-011 — Alertas por necesidades prioritarias

**Estado.** Aplicado el 17/11/2026 en Supabase CuidaRed con aprobación del usuario. [Propuesta SQL](propuestas/fase-6c-alertas-necesidades-prioritarias.sql) y [migración `20261117044316`](../supabase/migrations/20261117044316_alertas_necesidades_prioritarias_cuidared_011.sql).

| Objeto | Cambio |
| --- | --- |
| `cuidared.tipo_alerta` | Agrega el registro `necesidad_prioritaria` («Necesidad prioritaria»). |
| `cuidared.envejeciente_necesidad` | Agrega el disparador `alertas_necesidad_prioritaria` para altas y cambios de estado, catálogo o prioridad. |
| `cuidared_interno` | Actualiza `alerta_es_prioritaria`, `trg_alerta_fuente_consistente`, `alertas_fuentes_vigentes` y `alertas_reconciliar_adulto`. Reutiliza la fuente de necesidad y su índice único. |

La evaluación inicial busca ocurrencias pendientes de prioridad alta en expedientes activos con consentimiento vigente y acceso operativo. Cada alerta se agrupa por adulto y usa los permisos y preferencias existentes para avisos internos y Web Push. Los medicamentos pendientes siguen su regla RF-04 con su tipo propio. El cambio usa las tablas, columnas, rutas y permisos existentes.

**Verificación local.** La [regresión SQL](verificacion/local/pruebas-6c-necesidades-prioritarias.sql) verificó alta y cambio de prioridad, agrupación, filtro por tipo, destinatarios, cierre automático y deduplicación. La evaluación inicial creó una alerta y un aviso para una necesidad sintética preexistente. La [prueba Web Push](verificacion/local/pruebas-web-push-entregas.sql) verificó que una alerta de Transporte encola una entrega para el Coordinador de Familia. Las pruebas usaron PostgreSQL desechable con Supabase simulado.

**Verificación en Supabase.** El disparador está activo. La evaluación inicial creó una alerta pendiente para la única necesidad de Transporte elegible, un aviso interno para el administrador autorizado y una entrega Web Push. El emisor registró esa entrega como enviada.
