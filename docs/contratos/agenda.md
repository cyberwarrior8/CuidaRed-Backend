# Contrato API — Agenda de cuidado, ejecución y evidencias (fase 4, bloque 4b)

## Alcance y estado

Contrato de la API Express del bloque **4b** de [Visitas y Seguimiento](../../PLAN-DESARROLLO-BACKEND.md) (ID04): agenda de tareas puntuales y repetitivas, ejecución por el cuidador asignado y evidencias privadas con validación. Trazabilidad: RF-16, RF-10 (agenda), RS-013 (archivos), RS-005/016 (trazabilidad) y CR-162 ([convenciones](../CONVENCIONES-API.md)).

**Estado: código y pruebas listos; persistencia como propuesta SQL sin aplicar** ([`fase-4b-agenda.sql`](../propuestas/fase-4b-agenda.sql)), que requiere revisión y aprobación expresa. Reglas V2 y [CONTEXTO-BACKEND.md](../../CONTEXTO-BACKEND.md) prevalecen. Lo todavía abierto se marca **«Propuesta técnica (Dxx)»** y no es una regla confirmada.

Todas las rutas cuelgan de `/api/v1/cuentas/:cuentaId` y pasan antes por `requireSession` y `requireCuenta`. La cuenta viaja en la ruta y nunca concede acceso por sí sola: cada RPC vuelve a autorizar en la base (membresía activa, permiso, alcance sobre el adulto y acceso operativo, `CR_CUENTA_SIN_ACCESO` si la cuenta está vencida). Una tarea o evidencia de otra cuenta se responde como inexistente (404).

## Permisos

| Acción                                | Permiso              | Quién (V2)                                                                            |
| ------------------------------------- | -------------------- | ------------------------------------------------------------------------------------- |
| Consultar tareas y evidencias         | `agenda:ver`         | Familia: Coordinador y Cuidador. Organización: Administrador, Coordinador y Cuidador. |
| Crear, editar y cancelar tareas       | `agenda:gestionar`   | Familia: Coordinador. Organización: Administrador o Coordinador.                      |
| Iniciar, completar, subir y registrar | `agenda:ejecutar`    | Cuidador, y solo sobre las tareas asignadas a su perfil Cuidador en esa cuenta.       |
| Validar o rechazar evidencias         | `evidencias:validar` | Familia: Coordinador. Organización: Administrador o Coordinador.                      |

El **Cuidador** ve solo las tareas de su perfil; quien gestiona ve todas las de los adultos a su alcance. Familiar y Voluntario no tienen acceso a la agenda. El actor, el estado, el validador y la cuenta nunca se aceptan del cuerpo: salen de la sesión, de la ruta y de la base.

## Endpoints

| Método y ruta                             | Permiso              | Éxito | Descripción                                                       |
| ----------------------------------------- | -------------------- | ----- | ----------------------------------------------------------------- |
| `GET /tareas`                             | `agenda:ver`         | 200   | Listado paginado con filtros y orden.                             |
| `POST /tareas`                            | `agenda:gestionar`   | 201   | Crea una tarea, o una por ocurrencia si hay repetición (máx. 60). |
| `GET /tareas/:tareaId`                    | `agenda:ver`         | 200   | Detalle.                                                          |
| `PATCH /tareas/:tareaId`                  | `agenda:gestionar`   | 200   | Edita una tarea **pendiente** (esta o esta y las siguientes).     |
| `POST /tareas/:tareaId/cancelar`          | `agenda:gestionar`   | 200   | Cancela con motivo (esta o esta y las siguientes).                |
| `POST /tareas/:tareaId/iniciar`           | `agenda:ejecutar`    | 200   | `pendiente` → `en_progreso`.                                      |
| `POST /tareas/:tareaId/completar`         | `agenda:ejecutar`    | 200   | Completa; si requiere evidencia, exige una **validada** (D12).    |
| `POST /tareas/:tareaId/evidencias/subida` | `agenda:ejecutar`    | 200   | Autoriza y devuelve la URL firmada de subida al bucket privado.   |
| `POST /tareas/:tareaId/evidencias`        | `agenda:ejecutar`    | 201   | Registra la evidencia `pendiente` de un archivo ya subido.        |
| `GET /tareas/:tareaId/evidencias`         | `agenda:ver`         | 200   | Evidencias con URL firmada de descarga de 5 minutos.              |
| `POST /evidencias/:evidenciaId/validar`   | `evidencias:validar` | 200   | Valida; completa la tarea abierta que la requiere.                |
| `POST /evidencias/:evidenciaId/rechazar`  | `evidencias:validar` | 200   | Rechaza con motivo; la tarea en progreso vuelve a pendiente.      |

Solo `GET`, `POST` y `PATCH`; JSON `snake_case`; éxito individual `{ "data": … }`. Los identificadores de ruta deben ser UUID: uno mal formado responde `404 NOT_FOUND` sin consultar la base. Cada cuerpo es un `strictObject`: un campo desconocido se rechaza con `422 INVALID_INPUT`.

### `GET /tareas`

Paginación y orden de CR-162 (`page`, `limit` ≤ 100, `sort`). Orden permitido: `fecha_programada`, `hora_programada`, `estado`, `prioridad`, `fecha_creacion`, `tarea_id` (desempate). Orden predeterminado: `fecha_programada,hora_programada`.

Filtros de igualdad, con la forma `filter[campo]=valor`:

| Filtro                    | Valor                                                    |
| ------------------------- | -------------------------------------------------------- |
| `filter[desde]`           | Fecha `YYYY-MM-DD`; incluye `fecha_programada >= desde`. |
| `filter[hasta]`           | Fecha `YYYY-MM-DD`; incluye `fecha_programada <= hasta`. |
| `filter[estado]`          | `pendiente`, `en_progreso`, `completada` o `cancelada`.  |
| `filter[envejeciente_id]` | UUID del adulto.                                         |
| `filter[cuidador_id]`     | Id entero del perfil Cuidador.                           |

`desde` posterior a `hasta`, parámetros desconocidos o repetidos y valores inválidos responden `422`. El `total` cuenta solo las tareas autorizadas que cumplen los filtros.

### `POST /tareas`

```json
{
  "envejeciente_id": "uuid",
  "cuidador_id": 12,
  "titulo": "Medir la presión",
  "indicacion_medica_id": "uuid",
  "prioridad_id": 2,
  "fecha_programada": "2026-11-07",
  "hora_programada": "08:00",
  "requiere_evidencia": true,
  "repeticion": { "frecuencia": "semanal", "dias_semana": [1, 3], "hasta": "2026-12-07" }
}
```

`indicacion_medica_id`, `hora_programada` y `repeticion` son opcionales. `cuidador_id` es el id del **perfil Cuidador** de la cuenta, no el del usuario. Respuesta: `{ "data": { "serie_id": "uuid|null", "tareas": [Tarea…] } }`.

- El adulto debe ser de la cuenta, estar activo y al alcance de quien crea. `fecha_programada` no puede ser anterior a hoy (fecha de negocio de Santo Domingo).
- El cuidador debe tener perfil vigente en la cuenta, membresía activa con `agenda:ejecutar` y alcance sobre el adulto (vínculo `cuidador_asignado` no revocado, evaluado con `cuidared_interno.alcanza_envejeciente`); si no, `CR_CUIDADOR_NO_ASIGNADO`. Un perfil inexistente o de otra cuenta recibe el mismo error.
- La indicación debe pertenecer al mismo adulto (`CR_INDICACION_NO_CORRESPONDE`).
- Se avisa al cuidador (tabla `notificacion`) salvo que sea quien crea.

**Repetición — Propuesta técnica (D12).** `frecuencia` `diaria` (todos los días entre `fecha_programada` y `hasta`) o `semanal` con `dias_semana` ISO 8601 (1 = lunes … 7 = domingo). Cada ocurrencia es una tarea individual con `es_repetitiva = true` y un `serie_id` común. Máximo 60 ocurrencias y un plazo de hasta 730 días. Una repetición inválida (frecuencia desconocida, semanal sin días, `diaria` con días, fin anterior al inicio, sin ocurrencias o más de 60) responde `CR_REPETICION_INVALIDA`; la operación es atómica, nunca quedan tareas parciales.

### `PATCH /tareas/:tareaId`

Campos opcionales (al menos uno además de `alcance`): `titulo`, `cuidador_id`, `indicacion_medica_id` (`null` la quita), `prioridad_id`, `fecha_programada`, `hora_programada` (`null` la quita), `requiere_evidencia` y `alcance` (`esta` por omisión, o `siguientes`). Solo tareas `pendiente`; otra cosa responde `CR_ESTADO_INVALIDO`. Con `siguientes` los cambios se aplican también a las ocurrencias pendientes posteriores de la serie, y la fecha solo puede cambiarse en `esta`. Reasignar avisa al cuidador nuevo y al anterior.

### `POST /tareas/:tareaId/cancelar`

`{ "motivo": "3 a 300 caracteres", "alcance": "esta" | "siguientes" }` (`esta` por omisión). Cancela tareas abiertas (`pendiente` o `en_progreso`); con `siguientes`, esta y las abiertas posteriores de la serie. Guarda `motivo_cancelacion` y `cancelada_por`, y avisa una vez a cada cuidador afectado. Respuesta: `{ "data": { "canceladas": n, "tarea": Tarea } }`. La cancelación en cascada cuando un adulto pasa a inactivo o fallecido pertenece a la fase 3 (`api_estado_envejeciente`) y no se duplica aquí.

### Ejecución

`iniciar` y `completar` no llevan cuerpo. Solo el cuidador asignado, con alcance sobre el adulto, puede ejecutar; otro cuidador no ve la tarea (404) y quien no tiene `agenda:ejecutar` recibe 403.

**D12 (resuelta).** Si `requiere_evidencia`, `completar` exige al menos una evidencia en estado `validada` (`CR_EVIDENCIA_REQUERIDA`, 409). Una evidencia pendiente o rechazada no basta. El estado nunca lo envía el cliente. `completar` admite tareas `pendiente` o `en_progreso`.

## Evidencias privadas

### Flujo de subida

1. `POST /tareas/:tareaId/evidencias/subida` con `{ nombre_archivo, tipo_mime, tamano_bytes }`. La base autoriza (cuidador asignado, tarea abierta, cupo) y **genera la ruta** `cuenta/<cuenta_id>/tarea/<tarea_id>/<uuid>.<ext>`; el cliente nunca la elige. La API firma esa ruta con `storage('evidencias').signedUploadUrl` usando el JWT del usuario (la política de Storage decide de nuevo). Respuesta: `ruta`, `url_subida`, `token`, `bucket`, `expira_en_segundos` (7200), `tipos_permitidos` y `tamano_maximo_bytes`.
2. El cliente sube el archivo con `uploadToSignedUrl(ruta, token, archivo, { contentType })` o con `PUT` a `url_subida`.
3. `POST /tareas/:tareaId/evidencias` con `{ ruta, observacion?, nombre_archivo, tipo_mime, tamano_bytes }`. La base comprueba que la ruta sea de esa cuenta y esa tarea, que la extensión corresponda al tipo y que el objeto **exista** en el bucket; si Storage informa tamaño y tipo, deben coincidir con lo declarado (por eso `tipo_mime` y `tamano_bytes` describen el archivo realmente subido, p. ej. la imagen ya reducida). Nace `pendiente` con `registrada_por` tomado de la sesión.
4. Quien tiene `evidencias:validar` la valida o la rechaza.

**RS-013:** JPG, PNG, WEBP o PDF, de 1 byte a 5 MB (5 242 880 bytes). Se comprueba en Zod, en la RPC, en las restricciones de la tabla y en el límite del bucket. `observacion` admite hasta 300 caracteres.

**Propuesta técnica (D13).** Máximo 5 evidencias no rechazadas por tarea (`CR_LIMITE_EVIDENCIAS`); solo evidencias de tarea (las de visita e indicación quedan fuera de este bloque); una tarea completada o cancelada no admite evidencias. No hay borrado ni retención definida: ni la API ni las políticas permiten borrar o sobrescribir archivos. Sin cobertura offline: subir exige conexión. Los objetos subidos y nunca registrados quedan huérfanos en el bucket; su limpieza periódica está pendiente.

### `GET /tareas/:tareaId/evidencias`

Devuelve el arreglo `data` (sub-colección acotada por tarea, sin paginar). Cada evidencia incluye `url_descarga` (URL firmada de **5 minutos**) y `url_expira_en`; la ruta interna del bucket no se devuelve. Si el objeto ya no existe, `url_descarga` es `null`. Solo lo consulta quien ve la tarea (el Cuidador, solo la suya).

### Validar y rechazar

`validar` no lleva cuerpo; `rechazar` exige `{ "motivo": "5 a 200 caracteres" }`. Guardan `validada_por` y `fecha_validacion` (siempre de la sesión), avisan a quien registró la evidencia y al cuidador de la tarea (sin avisar a quien decide) y se auditan. Solo se revisan evidencias `pendiente` de tareas no canceladas (`CR_ESTADO_INVALIDO` si no).

- **Validada:** si la tarea requiere evidencia y sigue abierta, queda `completada` (`completada_por` = quien valida, `fecha_completada`). Respuesta: `{ evidencia, tarea, tarea_completada }`.
- **Rechazada:** si la tarea requiere evidencia y estaba `en_progreso`, vuelve a `pendiente` y el rechazo queda visible en la tarea (`ultimo_motivo_rechazo`) hasta que se registre una evidencia nueva.
- Con varias evidencias basta **una validada** para completar. Rechazar o validar tras el cierre no reabre la tarea (**propuesta técnica D12**; reapertura y cambios posteriores siguen abiertos).

## Estados

```text
pendiente ──iniciar──▶ en_progreso ──completar──▶ completada (terminal)
   │  ▲                     │
   │  └──rechazo de evidencia┘   (solo si la tarea requiere evidencia)
   └──completar / validar────────────────────────▶ completada
pendiente | en_progreso ──cancelar──▶ cancelada (terminal)
```

`completada` y `cancelada` son terminales: no se editan, no se reinician y no admiten evidencias.

## Representación

**Tarea** (`tarea_id`, `envejeciente_id`, `envejeciente_nombre`, `cuidador_id`, `cuidador_nombre`, `indicacion_medica_id`, `indicacion_titulo`, `prioridad_id`, `prioridad`, `titulo`, `fecha_programada`, `hora_programada` `HH:MM|null`, `estado`, `requiere_evidencia`, `es_repetitiva`, `serie_id`, `motivo_cancelacion`, `completada_por`, `fecha_completada`, `evidencias: { pendientes, validadas, rechazadas }`, `ultimo_motivo_rechazo`, `usuario_creador_id`, `fecha_creacion`, `fecha_actualizacion`).

**Evidencia** (`evidencia_id`, `tarea_id`, `nombre_archivo`, `tipo_mime`, `tamano_bytes`, `observacion`, `estado_validacion` `pendiente|validada|rechazada`, `motivo_rechazo`, `registrada_por`, `registrada_por_nombre`, `fecha_registro`, `validada_por`, `validada_por_nombre`, `fecha_validacion`).

Marcas temporales en UTC/ISO 8601.

## Errores

Además de los genéricos de CR-162 (`401`, `403 FORBIDDEN`, `404 NOT_FOUND`, `422 INVALID_INPUT`, `409 CONFLICT` por una ruta ya registrada, `403 SUBSCRIPTION_INACTIVE`), las RPC señalan reglas de negocio con `raise exception 'CR_…' using errcode = 'P0001'` y solo se traducen estos códigos (registrados en `src/modules/agenda/agenda-errors.js`):

| Código en la base              | HTTP | Código público           | Cuándo                                                        |
| ------------------------------ | ---- | ------------------------ | ------------------------------------------------------------- |
| `CR_CUIDADOR_NO_ASIGNADO`      | 422  | `CAREGIVER_NOT_ASSIGNED` | Cuidador sin perfil vigente, sin rol ejecutor o sin vínculo.  |
| `CR_REPETICION_INVALIDA`       | 422  | `INVALID_REPETITION`     | Repetición mal formada o de más de 60 ocurrencias.            |
| `CR_INDICACION_NO_CORRESPONDE` | 422  | `INDICATION_MISMATCH`    | La indicación es de otro adulto.                              |
| `CR_EVIDENCIA_REQUERIDA`       | 409  | `EVIDENCE_REQUIRED`      | Completar sin evidencia validada (D12).                       |
| `CR_ARCHIVO_INVALIDO`          | 422  | `INVALID_FILE`           | Tipo, tamaño, nombre, ruta o metadatos de Storage no válidos. |
| `CR_ARCHIVO_NO_SUBIDO`         | 409  | `FILE_NOT_UPLOADED`      | La ruta no existe todavía en el bucket.                       |
| `CR_LIMITE_EVIDENCIAS`         | 409  | `EVIDENCE_LIMIT_REACHED` | La tarea ya tiene 5 evidencias no rechazadas.                 |
| `CR_ESTADO_INVALIDO` (común)   | 409  | `INVALID_STATE`          | Estado de la tarea o de la evidencia no admite la operación.  |
| `CR_CUENTA_SIN_ACCESO` (común) | 403  | `SUBSCRIPTION_INACTIVE`  | Prueba o plan vencidos (D07).                                 |

Los errores de repetición y de archivo detectados ya en Express (Zod) usan los mismos códigos públicos.

## Persistencia propuesta

[`docs/propuestas/fase-4b-agenda.sql`](../propuestas/fase-4b-agenda.sql), **sin aplicar**. Depende de [`fase-2a-base.sql`](../propuestas/fase-2a-base.sql) (`exigir`, `alcanza_envejeciente`, `hoy`, `cuidador.cuenta_id`) y de un catálogo `prioridad` poblado por otra fase.

- **`tarea_agenda`:** `serie_id`, `motivo_cancelacion`, `cancelada_por`, `completada_por`, `fecha_completada`, `actualizado_por`; restricciones de título, serie y cierre; índices por adulto, cuidador y serie; trigger de coherencia (el cuidador trabaja en la cuenta del adulto; la indicación es del mismo adulto).
- **`evidencia`:** `registrada_por`, `validada_por`, `fecha_validacion`, `motivo_rechazo`, `nombre_archivo`, `tipo_mime` (cuatro tipos), `tamano_bytes` ≤ 5 MB y `archivo_url` con la **ruta** en el bucket (restricción de formato y de coherencia con la tarea; única). La revisión (`pendiente`/`validada`/`rechazada`) exige quién, cuándo y, al rechazar, el motivo.
- Ambas tablas con RLS y `revoke` a `public`, `anon` y `authenticated`: solo se accede por RPC.
- **RPC en `cuidared_api`** (`security definer`, `search_path = ''`, `revoke` a `public`/`anon` y `grant` a `authenticated`): `api_tareas_listar`, `api_tarea_obtener`, `api_tarea_crear`, `api_tarea_actualizar`, `api_tarea_cancelar`, `api_tarea_iniciar`, `api_tarea_completar`, `api_evidencia_preparar_subida`, `api_evidencia_registrar`, `api_evidencias_listar`, `api_evidencia_validar` y `api_evidencia_rechazar`. Todas autorizan con `cuidared_interno.exigir`, validan sus entradas y usan `CR_*`, `P0002` (inexistente o de otra cuenta), `42501` y `22023`.
- Las utilidades internas llevan prefijo (`agenda_`, `tarea_`, `evidencia_`) para no chocar con otros bloques y no se exponen.

## Storage: bucket y políticas

El equipo debe crear el bucket **`evidencias`** (el SQL lo hace con un `insert … on conflict` sobre `storage.buckets`; equivale a crearlo en el panel de Supabase):

| Ajuste                | Valor                                                              |
| --------------------- | ------------------------------------------------------------------ |
| Nombre / id           | `evidencias`                                                       |
| Acceso                | **Privado** (`public = false`); nunca URLs públicas                |
| Límite de tamaño      | 5 MB (5 242 880 bytes)                                             |
| Tipos MIME permitidos | `image/jpeg`, `image/png`, `image/webp`, `application/pdf`         |
| Ruta de los objetos   | `cuenta/<cuenta_id>/tarea/<tarea_id>/<uuid>.<jpg\|png\|webp\|pdf>` |

Políticas de `storage.objects` (solo `insert` y `select`; sin `update` ni `delete`), ambas a través de `cuidared_storage.evidencia_permitida(name, modo)`: función `security definer` en un esquema propio, con `USAGE` y `EXECUTE` solo para `authenticated`, de modo que `cuidared_interno` permanece cerrado. PostgREST solo publica `cuidared_api`.

- **Subir** (`insert`): la ruta debe ser `cuenta/<n>/tarea/<uuid>/<uuid>.<ext>`, la tarea debe pertenecer a esa cuenta y estar abierta, y el usuario debe ser el cuidador asignado con `agenda:ejecutar` y alcance sobre el adulto, con sesión vigente (12 h / 30 min) y la cuenta con acceso operativo.
- **Ver** (`select`, necesaria para firmar descargas): quien ve la tarea (`agenda:ver` con alcance; el Cuidador solo la suya), con sesión vigente y cuenta con acceso operativo.

La API nunca recibe ni sirve el contenido de los archivos: solo emite URLs firmadas de corta duración con el JWT del usuario.

## Integración con el frontend

El prototipo (`src/domain/api/agenda.ts`) usa nombres y valores distintos que el adaptador conectado debe traducir:

- Estado `en_curso` ⇄ `en_progreso`; `repetitiva` ⇄ `es_repetitiva`; `serieId` ⇄ `serie_id`; `adultoId` ⇄ `envejeciente_id`; `cuidadorId` ⇄ id del perfil Cuidador (entero); `prioridad` `alta|media|baja` ⇄ `prioridad_id` del catálogo; `requiereEvidencia` ⇄ `requiere_evidencia`.
- `diasSemana` usa 0 = domingo … 6 = sábado; la API usa ISO 8601, 1 = lunes … 7 = domingo (domingo = 7).
- La hora es opcional en la API (el formulario actual la exige).
- Una tarea que requiere evidencia ya no se completa con una evidencia pendiente: la completa quien valida (o el cuidador, si ya hay una validada).
- La evidencia deja de guardarse como miniatura local: se sube el archivo (imagen reducida o PDF) por URL firmada y se registra con su ruta.

## Validación realizada

`npm test` con repository y Storage simulados (`tests/agenda.test.js`); ESLint y Prettier; y `node scripts/validar-propuestas-local.js --solo=4b` sobre un PostgreSQL local con Auth y Storage simulados (`docs/verificacion/local/pruebas-4b-agenda.sql`: alcance por rol, aislamiento entre cuentas, series, estados, D12, validación y rechazo, avisos, privilegios y políticas de Storage). Estas pruebas no certifican RLS ni Storage reales de Supabase: tras aplicar la propuesta hay que repetirlas contra el proyecto con usuarios reales.
