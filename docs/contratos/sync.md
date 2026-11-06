# Contrato de sincronización de visitas sin conexión — fase 4, bloque 4c

## Estado y alcance

ID04; RF-10 (CU-14), RF-4.5 y RNF-4.2. Código, pruebas y **propuesta SQL sin aplicar** ([fase-4c-sync.sql](../propuestas/fase-4c-sync.sql)); no hay migración ni cambio de base de datos hasta recibir aprobación expresa. Sincroniza **solo visitas** (registrar una visita realizada o iniciarla). Las necesidades son de la fase 5: el diseño es extensible por `entidad` y cualquier otra se rechaza por operación con `ENTIDAD_NO_SOPORTADA`.

Se construye sobre `cuidared_interno.registrar_visita_realizada` e `iniciar_visita` del [bloque 4a](visitas.md#función-interna-para-la-sincronización-bloque-4c), que ya son idempotentes por `visita_id` y revalidan membresía, permiso, acceso operativo, alcance y participación. Este bloque añade la idempotencia por operación, Last-Write-Wins y el protocolo de lote que consume el cliente aprobado (`src/domain/sync.ts` del frontend: lotes de 25, `claveCliente`, reintentos con espera exponencial y LWW por instante UTC).

Las convenciones de errores y cuerpos son las de [CR-162](../CONVENCIONES-API.md); los cuerpos usan `snake_case` y Zod `strictObject`.

## Decisiones

**D16 sigue abierta** en `CONTEXTO-BACKEND.md` §15.2. Lo que sigue es una **propuesta técnica** para discutirla, no una decisión acordada; cambiar cualquiera de estas reglas no toca el contrato de visitas.

| Tema                          | Decisión                                                                                                                                                                                                                                                                                                                                           | Origen                                                  |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Regla de conflicto            | Last-Write-Wins por marca de modificación UTC, conservando la versión más reciente. Sin duplicados al reintentar. Permisos revalidados al sincronizar. Cuenta vencida: sin escrituras operativas.                                                                                                                                                  | V2/SRS RF-10 y D07, confirmado                          |
| Qué sincroniza                | Visitas: `registrar` (crea la visita realizada sin programar o completa una programada o en curso) e `iniciar`. Roles con `sync:usar`: Coordinador, Cuidador y Voluntario. Administrador y Familiar no.                                                                                                                                            | **Propuesta técnica (D16)**; matriz D04                 |
| Atomicidad                    | Una transacción por operación (una RPC por operación). El lote **no** es atómico: una operación rechazada no revierte las demás.                                                                                                                                                                                                                   | **Propuesta técnica (D16)**                             |
| Orden y dependencias          | Se procesan en el orden recibido (el orden de captura del cliente): `iniciar` y luego `registrar` de la misma visita funcionan en un mismo lote.                                                                                                                                                                                                   | **Propuesta técnica (D16)**                             |
| Límites                       | 1 a 25 operaciones por lote (el tamaño del cliente) y 64 KB por operación en la base. El cuerpo de toda la API está limitado a 16 kB: ver [límites conocidos](#límites-conocidos-y-cambios-necesarios-fuera-del-bloque).                                                                                                                           | **Propuesta técnica (D16)**                             |
| Idempotencia                  | `id_cliente` (UUID de la operación, la `claveCliente` del cliente) se guarda en `operacion_sync`. Un reintento de una operación ya resuelta devuelve su resultado como `duplicada` sin aplicar nada. La clave no se puede reutilizar por otro usuario, en otra cuenta ni para otra operación (`ID_CLIENTE_EN_USO`).                                | **Propuesta técnica (D16)**                             |
| Reloj                         | La marca de escritura es la del dispositivo (`actualizado_en`, ISO 8601 UTC con `Z`). Una marca (o la versión base) con más de **5 minutos en el futuro** se rechaza (`RELOJ_INVALIDO`). No hay límite inferior: un reloj atrasado solo hace perder los conflictos. La comparación es en milisegundos, que es lo que conserva el cliente.          | **Propuesta técnica (D16)**                             |
| Desempate                     | En empate de marcas gana el servidor (resultado estable al reintentar).                                                                                                                                                                                                                                                                            | Comportamiento del cliente aprobado; **propuesta**      |
| Granularidad                  | El conflicto es de la **visita completa**, no por campo. Una visita `completada` o `cancelada` es terminal (D10) y nunca se modifica, aunque la marca del cliente sea más reciente.                                                                                                                                                                | **Propuesta técnica (D16, D10)**                        |
| Marca del servidor            | La versión base es `visita.fecha_actualizacion`. Si esa versión la produjo una operación sincronizada, se compara la marca del dispositivo de esa operación (no la hora en que llegó); así el orden de llegada de un lote no decide quién escribió después, y una operación posterior de la misma persona sobre su propia versión no es conflicto. | **Propuesta técnica (D16)**                             |
| Confirmación al cliente       | Un resultado por operación con `actualizado_en_servidor` (la versión del servidor tras resolver). La versión ganadora completa se lee con `GET /visitas/:visitaId`.                                                                                                                                                                                | **Propuesta técnica (D16)**                             |
| Reintentos y rechazos         | `aplicada`, `conflicto` y `duplicada` son definitivas. Una `rechazada` **se vuelve a evaluar** al reintentar con la misma clave (puede haberse renovado la cuenta, corregido el reloj o restablecido el permiso); los efectos siguen siendo idempotentes por `visita_id`.                                                                          | **Propuesta técnica (D16)**                             |
| Cuenta vencida o permisos     | Una cuenta vencida rechaza todas las operaciones con `SUBSCRIPTION_INACTIVE` y queda constancia, sin escribir nada operativo. El cliente conserva su cola y reintenta al renovar. La falta de permiso o de alcance es `FORBIDDEN`, sin revelar datos.                                                                                              | D07 confirmado; conservación y reintento: **propuesta** |
| Contenido descartado          | El servidor no conserva el contenido de la operación que pierde (ni de ninguna): solo qué se pidió, qué se resolvió y con qué marcas. El cliente decide cuándo limpiar su copia local.                                                                                                                                                             | **Propuesta técnica (D16)**; RS-018                     |
| Zona horaria de negocio       | Las marcas son UTC. La fecha de negocio sigue siendo `America/Santo_Domingo` (`cuidared_interno.hoy()`), como en 4a.                                                                                                                                                                                                                               | Ya aplicada en 2a/4a                                    |
| Retención de `operacion_sync` | No hay política: las filas se conservan sin vencimiento hasta que se decida.                                                                                                                                                                                                                                                                       | Pendiente (D15)                                         |

## API

Prefijo `/api/v1/cuentas/:cuentaId`, tras `requireCuenta`. Cada RPC vuelve a autorizar.

| Método y ruta          | Permiso     | Entrada                    | Respuesta                                                       |
| ---------------------- | ----------- | -------------------------- | --------------------------------------------------------------- |
| POST `/sync`           | `sync:usar` | `{ operaciones: [1..25] }` | 200 `{ data: { resultados: [...] } }`, un resultado por entrada |
| GET `/sync/:idCliente` | `sync:usar` | Ninguna                    | 200 `{ data: resultado }` de una operación propia               |

### Operación

```json
{
  "id_cliente": "c0000000-0000-4000-8000-000000000001",
  "entidad": "visita",
  "tipo": "registrar",
  "registro_id": "3f6b8a1e-5c2d-4e7a-9b10-2d4c6e8f0a12",
  "datos": {
    "detalles": [
      { "envejeciente_id": "…", "estado_general": "estable", "observacion": "Todo bien." }
    ]
  },
  "actualizado_en": "2026-11-06T15:00:00.123Z",
  "base_actualizado_en": "2026-11-06T09:00:00.456Z"
}
```

- `id_cliente`: UUID de la operación (clave de idempotencia). `registro_id`: UUID de la visita, generado por el cliente al crearla. `entidad` y `tipo`: nombres en minúsculas y guion bajo (hasta 30 caracteres).
- `actualizado_en`: instante UTC de la modificación en el dispositivo. `base_actualizado_en` (opcional): el `actualizado_en_servidor` que tenía la visita cuando el cliente la editó; ausente si la visita es nueva para él.
- Un campo desconocido en el sobre o en la operación es inválido. El usuario, la cuenta, el rol y el estado nunca se aceptan del cuerpo: salen de la sesión y de la ruta.

| `entidad` | `tipo`      | `datos`                                                                                                                                                                 | Equivale a                                                      |
| --------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `visita`  | `registrar` | `{ detalles (1 a 4), checklist?, hora_inicio?, hora_fin?, fecha?, razon? }`, igual que [`POST /visitas/realizada`](visitas.md#registrar-la-realización) sin `visita_id` | Crea la visita realizada sin programar, o completa la existente |
| `visita`  | `iniciar`   | `{}` (sin datos)                                                                                                                                                        | `POST /visitas/:visitaId/iniciar`                               |
| otra      | cualquiera  | No se interpreta ni se envía a la base                                                                                                                                  | Rechazada `ENTIDAD_NO_SOPORTADA` (necesidades: fase 5)          |

Un `tipo` desconocido de `visita` se rechaza con `TIPO_NO_SOPORTADO`.

### Respuesta

```json
{
  "data": {
    "resultados": [
      {
        "id_cliente": "c0000000-0000-4000-8000-000000000001",
        "resultado": "conflicto",
        "registro_id": "3f6b8a1e-5c2d-4e7a-9b10-2d4c6e8f0a12",
        "motivo": "SERVIDOR_MAS_RECIENTE",
        "gana": "servidor",
        "actualizado_en_servidor": "2026-11-06T16:00:00.789Z"
      }
    ]
  }
}
```

Los resultados salen en el mismo orden que las operaciones. Los campos pasan por una lista cerrada: `id_cliente`, `resultado`, `registro_id` y `actualizado_en_servidor` (nulo si no hay versión que informar, p. ej. un rechazo) siempre; `motivo`, `gana` y `resultado_original` solo cuando existen.

| `resultado` | Significado                                                                                                                                                                                                                       | El cliente                                                                                                        |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `aplicada`  | Se aplicó sin conflicto.                                                                                                                                                                                                          | La da por sincronizada y toma `actualizado_en_servidor` como nueva base.                                          |
| `duplicada` | Ya estaba resuelta. Si es un reintento de la misma clave, trae `resultado_original` (y su `motivo`/`gana`); si es la misma captura con otra clave, `YA_REGISTRADA` o `YA_INICIADA`; iniciar una visita en curso es `YA_INICIADA`. | La da por sincronizada (sale de la cola) sin avisar de un error.                                                  |
| `conflicto` | El servidor había cambiado la visita. `gana` dice qué versión se conservó: `servidor` (no se aplicó nada) o `local` (se aplicó).                                                                                                  | La da por sincronizada, avisa al usuario y, si ganó el servidor, refresca la visita con `GET /visitas/:visitaId`. |
| `rechazada` | No se aplicó. `motivo` explica por qué. Queda registrada y se puede reintentar con la misma clave.                                                                                                                                | La conserva como fallida; ver la tabla de motivos.                                                                |

HTTP siempre 200 si el lote se pudo evaluar, aunque todas las operaciones se rechacen.

### Motivos

| `motivo`                       | Resultado                 | Cuándo                                                                                                                                   | Reintento                               |
| ------------------------------ | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| `SUBSCRIPTION_INACTIVE`        | `rechazada`               | La cuenta no tiene prueba o plan vigente (D07). Rechaza todas las operaciones, también las ya resueltas.                                 | Al renovar la cuenta.                   |
| `RELOJ_INVALIDO`               | `rechazada`               | `actualizado_en` o `base_actualizado_en` con más de 5 minutos en el futuro.                                                              | Tras corregir el reloj del dispositivo. |
| `FORBIDDEN`                    | `rechazada`               | Sin permiso, sin alcance sobre algún adulto, sin participar en la visita, o la visita o el adulto son de otra cuenta. Nunca revela cuál. | No automático; decide el usuario.       |
| `NOT_FOUND`                    | `rechazada`               | `iniciar` sobre una visita inexistente, ajena o fuera de su alcance (igual que el 404 en línea).                                         | No automático.                          |
| `INVALID_INPUT`                | `rechazada`               | Datos inválidos (forma, textos, checklist, estado general obligatorio, horas…).                                                          | No: hay que corregir la captura.        |
| `INVALID_STATE`                | `rechazada`               | Fecha futura al registrar o iniciar, o adulto inactivo.                                                                                  | No automático.                          |
| `VISIT_CLOSED`                 | `rechazada` o `conflicto` | La visita ya está completada o cancelada y no cambió desde la base del cliente (`rechazada`), o cambió (`conflicto`, gana el servidor).  | No.                                     |
| `SERVIDOR_MAS_RECIENTE`        | `conflicto`               | Otra escritura más reciente (o igual) en el servidor; gana el servidor.                                                                  | No: el resultado es definitivo.         |
| `ENTIDAD_NO_SOPORTADA`         | `rechazada`               | Entidad distinta de `visita` (necesidades llegan en la fase 5).                                                                          | Cuando el servidor la soporte.          |
| `TIPO_NO_SOPORTADO`            | `rechazada`               | Tipo desconocido para la entidad.                                                                                                        | No.                                     |
| `ID_CLIENTE_EN_USO`            | `rechazada`               | La clave ya pertenece a otra persona, otra cuenta u otra operación. No revela nada de la fila existente.                                 | No: generar otra clave.                 |
| `YA_REGISTRADA`, `YA_INICIADA` | `duplicada`               | La misma captura (misma marca de dispositivo) ya se resolvió con otra clave, o la visita ya está en curso.                               | —                                       |

### GET `/sync/:idCliente`

Para el cliente que perdió la respuesta de un lote. Devuelve el resultado **guardado** de una operación propia (`aplicada`, no `duplicada`), con `entidad`, `tipo` y `procesada_en` además de los campos del resultado. La operación de otra persona, de otra cuenta o inexistente responde el mismo 404; un identificador que no es UUID, 404 sin consultar la base. Como toda lectura operativa, en una cuenta vencida es 403 `SUBSCRIPTION_INACTIVE`.

### Errores HTTP

Además de la tabla de CR-162:

| Situación                                                                                         | HTTP | Código público                    | Qué hacer                                                                  |
| ------------------------------------------------------------------------------------------------- | ---- | --------------------------------- | -------------------------------------------------------------------------- |
| Sesión inválida o caducada                                                                        | 401  | `INVALID_SESSION`, `UNAUTHORIZED` | Reautenticar; la cola se conserva. Lo ya resuelto vuelve como `duplicada`. |
| El rol no tiene `sync:usar` (Administrador, Familiar)                                             | 403  | `FORBIDDEN`                       | No volver a intentar.                                                      |
| Sobre inválido (no hay 1 a 25 operaciones, campos extra) o alguna operación sin `id_cliente` UUID | 422  | `INVALID_INPUT`                   | Corregir; no se aplicó ninguna operación del lote.                         |
| Cuerpo mayor que el límite de la API                                                              | 413  | `BODY_TOO_LARGE`                  | Reducir el lote.                                                           |
| Falla de la base o contrato roto                                                                  | 503  | `DEPENDENCY_UNAVAILABLE`          | Reintentar el lote completo con las mismas claves (espera exponencial).    |

Una operación mal formada pero con `id_cliente` se responde `rechazada` / `INVALID_INPUT` y **no** tumba el lote ni llega a la base. Si la base falla a mitad del lote, se interrumpe con su error: lo ya resuelto queda guardado y al reintentar el lote completo vuelve como `duplicada` (con su `resultado_original`).

## Cómo se resuelve una operación

La RPC `api_sync_aplicar_operacion` evalúa, en este orden y en una sola transacción por operación:

1. Sesión vigente (28000) y membresía activa con `sync:usar` (42501; nada se guarda).
2. Forma de la operación (22023). La clave `id_cliente` se serializa con un bloqueo asesor.
3. Si la clave ya existe con otro usuario, otra cuenta u otra operación: `rechazada` / `ID_CLIENTE_EN_USO`, sin tocar la fila.
4. Cuenta sin acceso operativo: `rechazada` / `SUBSCRIPTION_INACTIVE`.
5. Clave ya resuelta (`aplicada`, `conflicto` o `duplicada`): `duplicada` con `resultado_original`, sin aplicar nada.
6. Entidad o tipo no soportados; marcas con más de 5 minutos en el futuro (`RELOJ_INVALIDO`).
7. Sobre la visita, con bloqueo (el mismo orden de bloqueos que 4a, sin interbloqueos): se revalida membresía, `visitas:registrar`, visibilidad y participación **antes** de revelar su versión; luego:

| Visita en el servidor      | Condición                                                                                         | Resultado                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| No existe                  | `registrar`                                                                                       | `aplicada`: se crea realizada, sin programar, con el `registro_id` del cliente |
| No existe                  | `iniciar`                                                                                         | `rechazada` / `NOT_FOUND`                                                      |
| Otra cuenta                | —                                                                                                 | `rechazada` / `FORBIDDEN` (`NOT_FOUND` al iniciar)                             |
| Cualquiera                 | La misma captura (misma `actualizado_en`) ya se resolvió con otra clave                           | `duplicada` / `YA_REGISTRADA` o `YA_INICIADA`                                  |
| `completada` o `cancelada` | La versión del servidor cambió desde la base del cliente                                          | `conflicto`, gana el servidor / `VISIT_CLOSED`                                 |
| `completada` o `cancelada` | No cambió                                                                                         | `rechazada` / `VISIT_CLOSED`                                                   |
| `en_curso`                 | `iniciar`                                                                                         | `duplicada` / `YA_INICIADA`                                                    |
| `programada` o `en_curso`  | No cambió desde la base del cliente                                                               | `aplicada`                                                                     |
| `programada` o `en_curso`  | Cambió y la versión la produjo una operación anterior de **la misma persona** no posterior a esta | `aplicada` (cadena propia, no es conflicto)                                    |
| `programada` o `en_curso`  | Cambió y la marca de escritura del servidor ≥ `actualizado_en`                                    | `conflicto`, gana el servidor / `SERVIDOR_MAS_RECIENTE` (no se aplica nada)    |
| `programada` o `en_curso`  | Cambió y la marca de escritura del servidor < `actualizado_en`                                    | `conflicto`, gana el cliente: se aplica                                        |

«Cambió» es: no hay `base_actualizado_en`, o `visita.fecha_actualizacion` (en milisegundos) es posterior a la base. La marca de escritura del servidor es la del dispositivo de la operación que produjo esa versión, o `fecha_actualizacion` si fue una escritura en línea.

Aplicar una operación puede fallar por las reglas de 4a (alcance, datos, fecha futura, adulto inactivo); entonces la operación queda `rechazada` con ese motivo y la subtransacción deshace cualquier escritura parcial. Una excepción que la base no clasifica no se oculta: se propaga como 503 para que el cliente reintente con la misma clave.

## Permisos

- `sync:usar` es necesario para el endpoint (Coordinador, Cuidador, Voluntario). Sin él: 403.
- Cada operación vuelve a exigir lo mismo que la API en línea: `visitas:registrar`, alcance sobre **cada** adulto, y ser participante o gestor de la visita. Una captura sin conexión no autoriza a quien perdió el vínculo, la membresía o el rol.
- La visita o el adulto de otra cuenta, o fuera del alcance, se tratan igual que uno inexistente y no revelan datos ni la versión del servidor.
- El Voluntario registra solo la observación (el estado general es opcional para él); lo decide el rol real del servidor, no el cuerpo.

## Auditoría

Express registra una línea por resultado con la auditoría minimizada (`requestId`, `actorId`, `action`, `result`, `code`), igual que el cliente. Nunca lleva contenido, ids de operación ni de visita.

| Resultado   | `action`         | `result`  | `code`                                   |
| ----------- | ---------------- | --------- | ---------------------------------------- |
| `aplicada`  | `sync.registro`  | `success` | —                                        |
| `conflicto` | `sync.conflicto` | `success` | `SERVER_WINS` o `LOCAL_WINS`             |
| `rechazada` | `sync.error`     | `denied`  | el `motivo`                              |
| `duplicada` | —                | —         | No repite la auditoría de la primera vez |

La trazabilidad persistente es la tabla `operacion_sync`.

## Cómo lo usa el cliente aprobado

| Cliente (`OpCola`, `sync.ts`)                    | API                                                                                                                                                                                                                                    |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claveCliente`                                   | `id_cliente`                                                                                                                                                                                                                           |
| `registroId`                                     | `registro_id` (el id de la visita; el cliente lo genera)                                                                                                                                                                               |
| `entidad: 'visita'`                              | `entidad: 'visita'` (`'necesidad'` se rechaza hasta la fase 5)                                                                                                                                                                         |
| `tipo: 'crear'`                                  | `tipo: 'registrar'`, sin `base_actualizado_en`                                                                                                                                                                                         |
| `tipo: 'actualizar'` y estado `en_curso`         | `tipo: 'iniciar'`, con `datos: {}`                                                                                                                                                                                                     |
| `tipo: 'actualizar'` y estado `completada`       | `tipo: 'registrar'`, con `base_actualizado_en`                                                                                                                                                                                         |
| `baseActualizadoEn`                              | `base_actualizado_en`: el `actualizado_en_servidor` recibido la última vez; tras un `aplicada` o `conflicto`, se actualiza la base de las operaciones pendientes del mismo registro                                                    |
| `actualizadoEn`                                  | `actualizado_en` (`new Date().toISOString()`)                                                                                                                                                                                          |
| `datos` (`Visita`)                               | `detalles`: adulto principal (`adultoId`, `estadoAdulto`, `observaciones`) y cada uno de `detallesAdicionales`; `checklist`; `hora_inicio` y `hora_fin` (de `inicio` y `fin`, `HH:MM` hora de República Dominicana); `fecha`; `razon`  |
| `usuarioId`                                      | No viaja: sale de la sesión                                                                                                                                                                                                            |
| Lotes de `TAMANO_LOTE` = 25, en orden de captura | `POST /sync` con ≤ 25 operaciones; se procesan en ese orden                                                                                                                                                                            |
| `aplicada`, `duplicada`                          | Confirmadas: salen de la cola (`confirmados`, `duplicados`)                                                                                                                                                                            |
| `conflicto`                                      | Confirmada y avisada (`conflictos`, `gana`)                                                                                                                                                                                            |
| `rechazada`                                      | Fallida (`fallidos`, `errores`): se queda con su `motivo` y la espera exponencial. `SUBSCRIPTION_INACTIVE` y `RELOJ_INVALIDO` se reintentan al corregirse; el resto detiene la operación hasta que el usuario la descarte o la corrija |
| Respuesta perdida                                | Reintentar el lote con las mismas claves (devuelve `duplicada`) o consultar `GET /sync/:idCliente`                                                                                                                                     |

Dos ajustes de adaptador que el contrato exige y el frontend actual no hace: `estado_general` es obligatorio por adulto para el Coordinador y el Cuidador y `detallesAdicionales` solo guarda la observación (falta capturar el estado de cada adulto; sin él la operación se rechaza con `INVALID_INPUT`), y la visita nueva del cliente conserva `registro_id` como su `id` para que el reintento no duplique.

## Persistencia propuesta

Esquema en [fase-4c-sync.sql](../propuestas/fase-4c-sync.sql); verificación local en `docs/verificacion/local/pruebas-4c-*.sql`. Depende de 2a y de 3b y 4a: `node scripts/validar-propuestas-local.js --solo=3a,3b,4a,4c`.

- `cuidared.operacion_sync` (nueva, RLS y `revoke` a `public`, `anon` y `authenticated`): `id_cliente` (clave primaria, la clave de idempotencia), `usuario_id`, `cuenta_id`, `entidad`, `tipo`, `registro_id`, `resultado`, `motivo`, `gana`, `actualizado_en_cliente`, `base_actualizado_en`, `actualizado_en_servidor` y `procesada_en`. Restricciones: un rechazo siempre trae motivo; solo un conflicto trae `gana`; nombres en minúsculas y `motivo` en mayúsculas. No guarda el contenido de la operación (observaciones, adultos).
- RPC de cuenta (`security definer`, `search_path` vacío, solo `authenticated`): `api_sync_aplicar_operacion(p_cuenta_id, p_operacion)` y `api_sync_obtener_operacion(p_cuenta_id, p_id_cliente)`.
- Funciones internas (no expuestas): `sync_visita` (LWW sobre una visita), `sync_registrar` (guarda el resultado; no pisa lo ya resuelto y solo reevalúa una rechazada del mismo usuario y cuenta), `sync_item`, `sync_iso`, `sync_ms` y `v_marca`.
- Bloqueos con orden único: clave de la operación, luego (como 4a) bloqueo asesor de la visita → solicitud → visita. La versión se compara con la visita bloqueada: no hay carrera entre leer y escribir.
- No se concede nada a `anon`: la prueba `pruebas-4c-esquema.sql` lo verifica, incluida la imposibilidad de llamar las RPC sin sesión.

## Límites conocidos y cambios necesarios fuera del bloque

- **Límite de cuerpo.** `src/app.js` limita el JSON de toda la API a 16 kB. Un lote de 25 visitas con observaciones largas puede superarlo y recibiría 413 completo, de modo que el cliente reintentaría el mismo lote sin éxito. Hace falta un límite mayor (p. ej. 256 kB) solo para `/api/v1/cuentas/:cuentaId/sync`, montando un `express.json({ limit })` para esa ruta **antes** del analizador global. Mientras no exista, el cliente debe reducir el tamaño del lote ante un 413.
- **Concurrencia.** Los bloqueos asesores y de fila no se pueden ejercitar con una sola sesión de `psql`: las pruebas SQL verifican la lógica secuencial (como 4a). Conviene una prueba con dos sesiones antes de aplicar la migración.
- **Reintento en la cola del cliente cuando se pierde un permiso o la cuenta vence.** La propuesta conserva la cola del cliente (`rechazada`, reevaluable); qué política seguir con operaciones de quien perdió el acceso de forma definitiva sigue en D16.
- **Retención.** La de `operacion_sync` es una decisión pendiente (D15).
- **Marcas del dispositivo.** Un reloj adelantado hasta 5 minutos gana los conflictos recientes; un reloj atrasado los pierde. La tolerancia y el origen de la hora son parte de D16.

## Pruebas y trazabilidad

- `tests/sync.test.js` (HTTP con gateway real y transporte simulado): lote y orden, una RPC por operación, lista cerrada de campos, validación del sobre y de cada operación, permisos y cuenta vencida, errores de la base, auditoría y `GET`.
- `pruebas-4c-esquema.sql`, `pruebas-4c-operaciones.sql`, `pruebas-4c-lww.sql` y `pruebas-4c-permisos.sql`: esquema y privilegios, idempotencia y reutilización de claves, LWW (conflicto, empate, milisegundos, cadena propia, versión producida por otra operación, visitas cerradas) y revalidación de permisos con aislamiento entre cuentas.

Trazan a ID04, RF-10/RF-4.5 y RNF-4.2. Estas pruebas no certifican RLS ni Auth de Supabase: el SQL se valida en un PostgreSQL local con esquema `auth` simulado.
