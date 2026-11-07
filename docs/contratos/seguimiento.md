# Contrato API — Seguimiento del adulto mayor (fase 3, bloque 3b)

## Alcance y estado

ID03 · RF-12, RF-13, RF-14, RF-15 y RF-3.4 (CU-06) · Reglas de Negocio V2. Cubre asignaciones de cuidadores y voluntarios, permiso familiar explícito, evaluación y factores de riesgo, indicaciones médicas e historial consolidado. El perfil, los contactos y la baja del adulto pertenecen al bloque 3a.

**Estado:** código y pruebas con gateway simulado (`tests/seguimiento.test.js`) y persistencia como **propuesta SQL sin aplicar** (`docs/propuestas/fase-3b-seguimiento.sql`, validada solo en un PostgreSQL local con `auth` simulado; no certifica RLS ni Auth de Supabase). Nada de esto toca la base remota. Las decisiones abiertas se marcan «Propuesta técnica (Dxx)» y esperan confirmación.

Aplican `docs/CONVENCIONES-API.md` (CR-162) y el contexto de cuenta de la fase 2: todas las rutas cuelgan de `/api/v1/cuentas/:cuentaId`, exigen `Authorization: Bearer <access_token>` y pasan por `requireCuenta`. La cuenta **nunca** concede acceso por sí misma, y el actor, la cuenta efectiva, el rol o los resultados calculados (puntaje, nivel) **nunca** se aceptan del cuerpo: los cuerpos son `strictObject` y un campo extra se rechaza con 422.

## Autorización

En cada ruta primero se exige el permiso de la matriz (`requirePermiso`, respuesta temprana 403) y después se llama a una RPC de `cuidared_api` que vuelve a autorizar en la base con la membresía real y el **alcance sobre el adulto**:

| Rol                            | Alcance (`alcanza_envejeciente`)                                                                                                                                            |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Administrador, Coordinador     | todos los adultos de su cuenta                                                                                                                                              |
| Cuidador                       | adultos con vínculo `cuidador_asignado` **no revocado**                                                                                                                     |
| Voluntario (solo Organización) | adultos con vínculo `voluntario_asignado` no revocado                                                                                                                       |
| Familiar                       | adultos con vínculo `familiar_responsable` no revocado, es decir, autorizado de forma explícita (V2: el vínculo por sí solo no basta; el permiso lo concede quien autoriza) |

Un adulto de otra cuenta, inexistente o fuera del alcance del usuario produce la **misma respuesta**: 403 `FORBIDDEN` en las rutas con `:envejecienteId`, y 404 `NOT_FOUND` en las rutas por id de factor o indicación (`/riesgos/:id/resolver`, `/indicaciones/:id…`). Un id malformado en la ruta es 404 y no llega a la base. Con la cuenta sin prueba ni plan vigente, la lectura y la escritura operativas se bloquean (403 `SUBSCRIPTION_INACTIVE`, D07).

## Endpoints

Base: `/api/v1/cuentas/:cuentaId`. Éxito de recurso: `{ "data": … }`; listas: `{ "data": [], "meta": { page, limit, total, totalPages } }`; acciones sin representación: `204`. Fechas y horas en UTC (`2026-11-06T14:00:00.000Z`); fechas de calendario `YYYY-MM-DD`; campos en `snake_case`.

| Método y ruta                                                         | Permiso (+ alcance)                                 | Entrada                                                              | Respuesta                                       |
| --------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------- |
| `GET /envejecientes/:envejecienteId/asignaciones`                     | `adultos:ver` + alcance                             | —                                                                    | 200 `{ cuidadores, voluntarios, familiares? }`  |
| `POST /envejecientes/:envejecienteId/asignaciones`                    | `adultos:asignar` + alcance                         | `{ tipo: 'cuidador_asignado' \| 'voluntario_asignado', usuario_id }` | 201 asignación                                  |
| `POST /envejecientes/:envejecienteId/asignaciones/:usuarioId/revocar` | `adultos:asignar` + alcance                         | `{ motivo? }` (≤ 300)                                                | 204                                             |
| `POST /envejecientes/:envejecienteId/familiares`                      | `familiares:autorizar` + alcance                    | `{ usuario_id }`                                                     | 201 asignación (`tipo: 'familiar_responsable'`) |
| `POST /envejecientes/:envejecienteId/familiares/:usuarioId/revocar`   | `familiares:autorizar` + alcance                    | `{ motivo? }` (≤ 300)                                                | 204                                             |
| `GET /envejecientes/:envejecienteId/riesgo`                           | `adultos:ver-sensible` + alcance                    | —                                                                    | 200 estado de riesgo                            |
| `POST /envejecientes/:envejecienteId/evaluaciones`                    | `adultos:evaluar` + alcance                         | `{ respuestas }`                                                     | 201 evaluación                                  |
| `POST /envejecientes/:envejecienteId/riesgos`                         | `adultos:evaluar` + alcance                         | `{ riesgo_id, nivel, motivo, observacion? }`                         | 201 `{ factor, nivel_vigente }`                 |
| `POST /riesgos/:envejecienteRiesgoId/resolver`                        | `adultos:evaluar` + alcance                         | `{ observacion? }`                                                   | 200 `{ factor, nivel_vigente }`                 |
| `GET /envejecientes/:envejecienteId/indicaciones`                     | `indicaciones:ver` + alcance                        | `page`, `limit`, `sort`, `filter[estado]`                            | 200 paginada                                    |
| `POST /envejecientes/:envejecienteId/indicaciones`                    | `indicaciones:gestionar` + alcance                  | ver abajo                                                            | 201 indicación                                  |
| `PATCH /indicaciones/:indicacionId`                                   | `indicaciones:gestionar` + alcance                  | campos editables                                                     | 200 indicación                                  |
| `POST /indicaciones/:indicacionId/estado`                             | `indicaciones:gestionar` + alcance                  | `{ estado }`                                                         | 200 indicación                                  |
| `GET /envejecientes/:envejecienteId/historial`                        | `adultos:ver` + alcance (y el permiso de cada tipo) | `page`, `limit`, `sort`, `filter[tipo]`                              | 200 paginada                                    |

Los permisos resultan de la matriz de la fase 2 (`src/modules/cuentas/permisos.js`): `adultos:asignar` lo tienen Administrador y Coordinador; `familiares:autorizar`, el Coordinador en Familia y **solo el Administrador** en Organización; `adultos:evaluar`, Administrador y Coordinador (el Cuidador consulta, no modifica); `adultos:ver-sensible`, Administrador, Coordinador y Cuidador; `indicaciones:ver`, todos salvo el Voluntario; `indicaciones:gestionar`, Coordinador y Cuidador (el Administrador de Organización consulta, no gestiona).

### Asignaciones y permiso familiar (RF-12, RF-13)

- **Consultar.** Los gestores (`adultos:asignar` o `familiares:autorizar`) reciben `cuidadores`, `voluntarios` y `familiares`, cada uno con `{ envejeciente_id, usuario_id, tipo, nombres, apellidos, autorizado_por_usuario_id, fecha_autorizacion }`. El resto recibe solo `cuidadores` y `voluntarios` con `{ nombres, apellidos }` (sin ids, contacto ni familiares). Solo aparecen vínculos vigentes de quien conserva su membresía activa con el rol esperado.
- **Asignar.** El usuario debe tener una **membresía activa con el rol correspondiente** en la cuenta (cuidador para `cuidador_asignado`, voluntario para `voluntario_asignado`) o se responde 422 `ROLE_NOT_COMPATIBLE` (no se distingue «no existe»). El voluntario solo existe en Organización: en Familia, 422 `ROLE_NOT_ALLOWED`. La PK `(envejeciente, usuario)` permite un único vínculo por pareja: **reasignar actualiza la fila**, registra al nuevo autorizador y limpia la revocación; si ya está vigente con el mismo tipo no cambia nada. Todos los cuidadores asignados están al mismo nivel (sin cuidador principal).
- **Autorizar familiar.** Debe ser un miembro activo con rol familiar (422 `ROLE_NOT_COMPATIBLE`). El permiso es por adulto, lo registra quien autoriza y es revocable.
- **Revocar.** Conserva fila, fecha y motivo (`fecha_revocacion`, `motivo_revocacion`); el acceso se pierde de inmediato. Revocar algo inexistente, ya revocado o de otro tipo es 404.
- Un adulto no activo no admite asignaciones nuevas (409 `ADULT_INACTIVE`); revocar siempre se permite.

### Riesgo (RF-14, D11)

`GET …/riesgo` devuelve:

```json
{
  "nivel_vigente": "alto | medio | bajo | null",
  "texto": "Sin evaluación vigente | Riesgo alto | Riesgo medio | Riesgo bajo",
  "factores_vigentes": [
    {
      "envejeciente_riesgo_id": 12,
      "riesgo_id": 3,
      "riesgo": "Riesgo de caídas",
      "es_evaluacion": false,
      "nivel": "alto",
      "estado": "activo",
      "motivo": "…",
      "observacion": null,
      "fecha_riesgo": "…Z",
      "registrado_por": "uuid",
      "fecha_resolucion": null,
      "resuelto_por": null
    }
  ],
  "historial": [/* factores resueltos o reemplazados, más reciente primero, máximo 50 */],
  "ultima_evaluacion": {
    "evaluacion_riesgo_id": 4,
    "puntaje": 62,
    "nivel": "alto",
    "version_cuestionario": "v1",
    "desglose": [],
    "respuestas": {},
    "fecha": "…Z",
    "usuario_id": "uuid",
    "vigente": true
  }
}
```

- **Nivel agregado = máximo de los factores vigentes** (`estado = 'activo'`). Sin factores vigentes: `nivel_vigente: null` y `texto: "Sin evaluación vigente"`; no se conserva el último nivel ni se asume «bajo». `ultima_evaluacion` es historia (`vigente: false` si su factor ya no está activo) y es `null` si nunca hubo.
- **Evaluar.** El servidor calcula puntaje, desglose y nivel (el cliente no los envía). Guarda la evaluación y crea el factor «Evaluación de riesgo» activo; el factor activo anterior del mismo tipo pasa a `reemplazado`. Respuesta 201: `{ evaluacion_riesgo_id, envejeciente_id, puntaje, nivel, version_cuestionario, desglose, respuestas, fecha, usuario_id, factor, nivel_vigente }`.
- **Registrar factor.** `riesgo_id` del catálogo (no el de evaluación), `nivel` bajo/medio/alto, `motivo` 5–200, `observacion` ≤ 300. Reemplaza al factor activo del mismo `riesgo_id`. La evaluación y los factores no se anulan entre sí: el nivel del adulto es el máximo de todos los vigentes.
- **Resolver factor.** Solo desde `activo` (409 `INVALID_STATE` si ya está resuelto o reemplazado). La nota se agrega a `observacion` como `Resolución: …`. Tras resolver el último queda «Sin evaluación vigente».

**Cuestionario v1 (100 puntos).** Claves en `snake_case` (el frontend usa camelCase: `ingresosFijos` → `ingresos_fijos`, `viveSolo` → `vive_solo`). Puntos por respuesta, portados de `features/gestion/lib/riesgo.ts` y definidos solo en la base:

| Sección (máx.)      | Pregunta         | Puntos                                                    |
| ------------------- | ---------------- | --------------------------------------------------------- |
| Socioeconómica (30) | `ingresos_fijos` | sí 0 · no 10                                              |
|                     | `vivienda`       | propia 0 · alquilada 4 · cedida 6 · precaria 10           |
|                     | `vive_solo`      | sí 10 · no 0                                              |
| Salud (40)          | `cronica`        | sí 12 · no 0                                              |
|                     | `movilidad`      | independiente 0 · apoyo 5 · reducida 10 · encamado 16     |
|                     | `medicamentos`   | sí 12 · no 0                                              |
| Red de apoyo (30)   | `familiares`     | sí 0 · no 10                                              |
|                     | `frecuencia`     | diaria 0 · semanal 3 · mensual 6 · ocasional 8 · nunca 10 |
|                     | `cuidador`       | sí 0 · no 10                                              |

Nivel: 0–29 bajo, 30–54 medio, 55–100 alto. Los sí/no son booleanos JSON. **Respuestas incompletas** (pregunta ausente, `null` o cadena vacía en las de selección) se rechazan con 422 `EVALUATION_INCOMPLETE` (Propuesta técnica D11). Una clave desconocida, un tipo o una opción fuera del cuestionario es 422 `INVALID_INPUT`. `desglose` es una lista por sección `{ id: 'socio' | 'salud' | 'apoyo', puntos, max, detalle: [{ clave, respuesta, puntos }] }`.

### Indicaciones médicas (RF-15)

La plataforma solo transcribe lo indicado por personal de salud; no determina tratamientos.

- **Crear.** `{ tipo_indicacion_id, titulo (3–80), descripcion? (≤ 300), frecuencia_horario? (≤ 60), fecha_inicio (YYYY-MM-DD), fecha_fin? (≥ inicio) }`. Nace `activa`; guarda `registrado_por` y `actualizado_por`. Un vacío equivale a `null`.
- **Editar (PATCH).** Mismos campos, todos opcionales y al menos uno; `null` limpia un campo opcional, omitirlo lo conserva. No cambia el estado. Una indicación `finalizada` no se edita (409 `INVALID_STATE`).
- **Estado (Propuesta técnica D10).** `activa ⇄ suspendida`; `activa | suspendida → finalizada`; `finalizada` es terminal. Repetir el estado actual no cambia nada.
- **Listar.** Orden `sort` por `fecha_inicio` (predeterminado, descendente), `fecha_creacion` o `indicacion_medica_id`, con desempate fijo por `indicacion_medica_id`; un orden de varios campos o un desempate descendente se rechaza con 422. `filter[estado]` (igualdad). El familiar autorizado consulta; el voluntario no tiene el permiso. No se expone `evidencia_url` (archivos: D13 pendiente).
- Cada indicación: `{ indicacion_medica_id, envejeciente_id, tipo_indicacion_id, tipo, titulo, descripcion, frecuencia_horario, fecha_inicio, fecha_fin, estado, registrado_por, actualizado_por, fecha_creacion, fecha_actualizacion }`.

### Historial consolidado (RF-3.4 / CU-06)

Cada evento es `{ tipo, fecha, titulo, detalle, referencia_id }`, de más reciente a más antiguo (`sort=fecha` lo invierte; desempate fijo por tipo y referencia, sin repetir ni omitir eventos entre páginas). `filter[tipo]` (igualdad): `riesgo`, `evaluacion`, `indicacion`, `visita`, `necesidad`, `alerta`. Solo se calculan los tipos que el rol puede consultar (Propuesta técnica D04); sin permiso no se lee ni una fila:

| Tipo                   | Permiso                | Eventos                                                                                                                                        |
| ---------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `riesgo`, `evaluacion` | `adultos:ver-sensible` | factor registrado y resuelto (el factor que genera un cuestionario no se duplica) · evaluación con puntaje y nivel                             |
| `indicacion`           | `indicaciones:ver`     | registrada y actualizada (si cambió después de crearse)                                                                                        |
| `visita`               | `visitas:ver`          | realizadas y canceladas; las programadas o en curso pertenecen a la agenda. La observación y el estado general solo con `adultos:ver-sensible` |
| `necesidad`            | `necesidades:ver`      | registrada y resuelta/cancelada                                                                                                                |
| `alerta`               | `alertas:ver`          | generada y atendida                                                                                                                            |

Las visitas, necesidades y alertas se leen con las columnas de `docs/DB.sql` (otras fases pueden ampliarlas). `referencia_id` es el identificador del registro de origen como texto.

## Errores

Públicos según CR-162. Los códigos `CR_*` de las RPC se registran en `src/modules/seguimiento/seguimiento-errors.js`; el texto de la base nunca llega al cliente.

| Origen en la RPC                | HTTP | Código público          | Cuándo                                                                                   |
| ------------------------------- | ---- | ----------------------- | ---------------------------------------------------------------------------------------- |
| `42501`                         | 403  | `FORBIDDEN`             | sin permiso, o adulto de otra cuenta / inexistente / fuera de alcance                    |
| `P0002`                         | 404  | `NOT_FOUND`             | factor o indicación de otra cuenta o inexistente; revocar algo no vigente                |
| `22023`, `23514`                | 422  | `INVALID_INPUT`         | entrada inválida                                                                         |
| `CR_ROL_NO_COMPATIBLE`          | 422  | `ROLE_NOT_COMPATIBLE`   | el usuario no tiene en la cuenta el rol requerido                                        |
| `CR_ROL_NO_PERMITIDO` (fase 2)  | 422  | `ROLE_NOT_ALLOWED`      | voluntario en una cuenta Familia                                                         |
| `CR_EVALUACION_INCOMPLETA`      | 422  | `EVALUATION_INCOMPLETE` | faltan respuestas del cuestionario                                                       |
| `CR_ADULTO_INACTIVO`            | 409  | `ADULT_INACTIVE`        | alta de asignación, autorización, factor, evaluación o indicación en un adulto no activo |
| `CR_ESTADO_INVALIDO` (fase 2)   | 409  | `INVALID_STATE`         | factor ya resuelto; indicación finalizada                                                |
| `CR_CUENTA_SIN_ACCESO` (fase 2) | 403  | `SUBSCRIPTION_INACTIVE` | cuenta sin prueba ni plan vigente                                                        |

## Auditoría

`deps.audit` registra actor, acción y resultado (sin identificadores del adulto ni datos de salud): `asignacion.creada`, `asignacion.revocada`, `familiar.autorizado`, `familiar.revocado`, `riesgo.evaluado`, `riesgo.factor_registrado`, `riesgo.factor_resuelto`, `indicacion.creada`, `indicacion.editada`, `indicacion.estado_cambiado`, y las consultas sensibles `riesgo.consultado`, `indicaciones.consultadas` e `historial.consultado`. Los rechazos los registra el manejador global. En la base, cada escritura guarda su autoría (`autorizado_por_usuario_id`, `registrado_por`, `resuelto_por`, `actualizado_por`, `usuario_id` de la evaluación); la auditoría de tabla (`cuidared.auditoria`) no se modifica.

## Esquema propuesto (sin aplicar)

`docs/propuestas/fase-3b-seguimiento.sql`, sobre `fase-2a-base.sql`:

- **`vinculo`**: `autorizado_por_usuario_id`, `fecha_autorizacion` (no nula; los vínculos previos se tratan como concedidos al crearse), `fecha_revocacion`, `motivo_revocacion`; `alcanza_envejeciente` se reemplaza (misma firma y semántica) y exige `fecha_revocacion is null`.
- **`evaluacion_riesgo`** (tabla nueva, RLS y `revoke`): `evaluacion_riesgo_id`, `envejeciente_id`, `respuestas jsonb`, `puntaje smallint` (0–100), `desglose jsonb`, `nivel_riesgo_id`, `version_cuestionario`, `envejeciente_riesgo_id` (factor que la generó), `usuario_id`, `fecha`.
- **`envejeciente_riesgo`**: `registrado_por`, `fecha_resolucion`, `resuelto_por` e índice único parcial: **un solo factor activo por adulto y tipo de factor**.
- **`indicacion_medica`**: `registrado_por`, `actualizado_por`.
- **Catálogos mínimos (Propuesta técnica D14)**: `nivel_riesgo.codigo` (`bajo`, `medio`, `alto`, orden ascendente de gravedad) y `riesgo.codigo` con el factor «Evaluación de riesgo» (`evaluacion`).
- **RPC** (`cuidared_api`, `security definer set search_path = ''`, sin ejecución pública ni anónima): `api_asignaciones_listar`, `api_asignar`, `api_asignacion_revocar`, `api_familiar_autorizar`, `api_familiar_revocar`, `api_riesgo_consultar`, `api_riesgo_evaluar`, `api_riesgo_registrar`, `api_riesgo_resolver`, `api_indicaciones_listar`, `api_indicacion_crear`, `api_indicacion_editar`, `api_indicacion_estado`, `api_historial_listar`. Helpers internos en `cuidared_interno` (no expuesto), incluida `nivel_riesgo_vigente(uuid)` que reutilizarán las alertas de la fase 6.
- Escrituras serializadas por adulto (`for no key update`); la evaluación concurrente deja un solo factor activo.

## Decisiones

| ID  | Estado                 | Decisión                                                                                                                                                                                                                                             |
| --- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D04 | Propuesta técnica      | Persistencia del permiso familiar (columnas de `vinculo`, revocación con motivo); alcance del Voluntario = adultos asignados; el historial exige `adultos:ver-sensible` para riesgo, evaluaciones y observaciones de visita.                         |
| D10 | Propuesta técnica      | Transiciones: factor `activo → resuelto \| reemplazado` (terminales); indicación `activa ⇄ suspendida`, `→ finalizada` (terminal, no editable).                                                                                                      |
| D11 | Confirmada + propuesta | Confirmado: 100 puntos (30/40/30), umbrales 0–29/30–54/55–100, máximo de los vigentes y «Sin evaluación vigente». Propuesta: respuestas incompletas se rechazan; el cuestionario se versiona (`v1`) y se guarda el desglose; claves en `snake_case`. |
| D14 | Propuesta técnica      | Catálogos mínimos con `codigo` (niveles de riesgo y factor de evaluación); el catálogo oficial sigue pendiente.                                                                                                                                      |

**Pendientes de confirmación.** (1) El frontend actual hace que una evaluación también deje superado el factor «Vulnerabilidad social general»; aquí la evaluación solo reemplaza a la evaluación anterior (los demás factores siguen vigentes y cuentan para el máximo). (2) Nombres de riesgo y tipos de indicación: catálogos D14. (3) Archivos de respaldo de la indicación: D13.

## Integración con el frontend

El adaptador debe traducir: `camelCase` → `snake_case` (cuestionario y cuerpos); factor `vigente`/`superado` → `activo`/`resuelto`/`reemplazado`; indicación `vigente` → `activa`; `riesgo` del adulto: usar `nivel_vigente` (null = «Sin evaluación vigente») en lugar de conservar el último nivel; el historial llega paginado y ya filtrado por permisos del servidor.

## Validación

- `npm test`: `tests/seguimiento.test.js` (permisos antes de la RPC, validación estricta, traducción de errores, paginación, contrato con el SQL propuesto). Gateway simulado: no certifica RLS ni la base real.
- `node scripts/validar-propuestas-local.js --solo=3b`: `docs/verificacion/local/pruebas-3b-*.sql` (alcance con vínculo revocado, aislamiento entre cuentas, roles compatibles, cuestionario y umbrales, máximo de factores, «Sin evaluación vigente», transiciones, historial por permisos, permisos de ejecución). Los adultos de prueba se insertan directamente en `cuidared.envejeciente`.
- Pendiente tras la aprobación: aplicar la migración con autorización, pruebas con identidades reales y revisión de RLS en Supabase.
