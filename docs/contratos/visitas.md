# Contrato de Visitas y Solicitudes de Visita — fase 4, bloque 4a

## Estado y alcance

ID04; RF-02 y base de RF-10. Código, pruebas y **propuesta SQL sin aplicar** ([fase-4a-visitas.sql](../propuestas/fase-4a-visitas.sql)); no hay migración ni cambio de base de datos hasta recibir aprobación expresa. Incluye programación con autorización, inicio, registro de realización, cancelación, historial y solicitudes de visita de personas externas. Quedan fuera de este bloque las evidencias de visita (D13), la agenda y las tareas (4b) y la sincronización offline (4c), que se construye sobre `cuidared_interno.registrar_visita_realizada` y `cuidared_interno.iniciar_visita`.

Las convenciones de errores, paginación, orden y filtros son las de [CR-162](../CONVENCIONES-API.md). Todos los cuerpos usan `snake_case` y Zod `strictObject`: un campo desconocido es 422. Los filtros del historial usan la sintaxis acordada `filter[campo]=valor`.

## Decisiones

| Tema                             | Decisión                                                                                                                                                                                                                        | Origen                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Quién autoriza                   | Coordinador en Familia; Administrador o Coordinador en Organización. Programar equivale a autorizar y exige `visitas:programar` y `visitas:autorizar`.                                                                          | D05, confirmada                              |
| Contacto efectivo                | Solo una visita **completada** cuenta. Programada, en curso o cancelada no.                                                                                                                                                     | D05/§7.2, confirmada                         |
| Voluntario                       | Inicia sesión y solo registra que la visita ocurrió más una observación; `estado_general` y `checklist` son opcionales para él (el servidor decide por el rol real, no por lo que diga el cuerpo).                              | D03, confirmada                              |
| Solicitud de personas externas   | El visitante no es un rol ni tiene cuenta. Pide la visita, un usuario principal la autoriza o rechaza y el visitante deja su observación con su código. Las cuentas Familia nunca se listan ni reciben.                         | V2 y flujo aprobado por la PM en el frontend |
| Una visita, una cuenta           | Una visita pertenece a una sola cuenta (`visita.cuenta_id`, inmutable) y todos sus adultos son de esa cuenta.                                                                                                                   | **Propuesta técnica (D05)**                  |
| Cancelar y revocar               | Cancela un usuario principal (`visitas:programar`) una visita programada o en curso, con motivo. Cancelar es también la forma de revocar una autorización.                                                                      | **Propuesta técnica (D05)**                  |
| Quién opera la visita            | Iniciar y registrar exigen `visitas:registrar` y ser participante, o ser gestor (Administrador o Coordinador) con ese permiso. El Administrador no tiene `visitas:registrar`, así que no opera visitas.                         | **Propuesta técnica (D05)**                  |
| Visita realizada sin programar   | Personal con `visitas:registrar` puede registrar una visita ya ocurrida (`origen = sin_programar`, sin autorizador) para adultos que alcanza. Contradice «autorización previa obligatoria» de V2; ver abajo.                    | **Propuesta técnica (D05)**, a confirmar     |
| Transiciones                     | `programada → en_curso → completada`; `programada` o `en_curso → cancelada`. `completada` y `cancelada` son terminales: no se reabren. Solicitud: `pendiente → autorizada \| rechazada`; `autorizada → realizada \| cancelada`. | **Propuesta técnica (D10)**                  |
| Checklist                        | `alimentacion`, `medicamentos`, `higiene`, `vivienda`, `animo`, `movilidad` (catálogo del frontend, no oficial).                                                                                                                | **Propuesta técnica (D14)**                  |
| Retención de datos del visitante | No hay política: la cédula y el teléfono se conservan en `solicitud_visita` sin vencimiento hasta que se decida.                                                                                                                | Pendiente (D15)                              |

**Discrepancia que requiere confirmación.** V2 exige programación y autorización previas; el frontend aprobado admite registrar una visita ya realizada sin programar y el encargo del bloque pide `POST /visitas/realizada`. Se implementó con `origen = sin_programar`, sin `autorizada_por_usuario_id` y solo para adultos que el usuario alcanza, de modo que la falta de autorización previa queda registrada y se puede auditar o excluir. Si se decide que no debe existir, basta retirar la ruta y la RPC `api_registrar_visita_realizada`; la función interna se conserva para 4c.

## Alcance de lectura

| Rol                        | Visitas que ve                                                                               | Adultos y observaciones dentro de la visita            |
| -------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Administrador, Coordinador | Todas las de la cuenta.                                                                      | Todos los adultos de la cuenta.                        |
| Cuidador, Voluntario       | Las que participan o con algún adulto que alcanzan (vínculo `cuidador/voluntario_asignado`). | Solo los adultos que alcanzan.                         |
| Familiar                   | Las que incluyen algún adulto autorizado para él.                                            | Solo los adultos autorizados (`alcanza_envejeciente`). |

El alcance sobre un adulto lo define `cuidared_interno.alcanza_envejeciente`, que desde 3b exige un vínculo **no revocado** (`fecha_revocacion is null`) para todos los tipos; este bloque no consulta `vinculo` por su cuenta. Una visita, solicitud o adulto de otra cuenta se trata igual que uno inexistente: `P0002` (404) para recursos de la ruta y `42501` (403) para adultos o participantes enviados en el cuerpo. Filtrar el historial por un adulto fuera de alcance responde 404, como un adulto inexistente.

## API de cuenta

Prefijo `/api/v1/cuentas/:cuentaId`, tras `requireCuenta`. Los identificadores de la ruta son UUID; otro valor es 404 sin consultar la base. Cada RPC vuelve a autorizar.

| Método y ruta                                     | Permiso                                      | Entrada                                                                                                | Respuesta                                                   |
| ------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| GET `/visitas`                                    | `visitas:ver`                                | `page`, `limit`, `sort`, `filter[estado]`, `filter[envejeciente_id]`, `filter[desde]`, `filter[hasta]` | 200 `{data, meta}`, sin observaciones por adulto            |
| GET `/visitas/:visitaId`                          | `visitas:ver`                                | Ninguna                                                                                                | 200 visita con observación por adulto, filtrada por alcance |
| POST `/visitas`                                   | `visitas:programar` y `visitas:autorizar`    | `fecha`, `hora_programada`, `razon`, `notas?`, `envejeciente_ids` (1 a 4), `participante_ids` (1 a 3)  | 201 visita `programada`                                     |
| POST `/visitas/realizada`                         | `visitas:registrar`                          | `visita_id?`, `fecha?`, `razon?`, `detalles`, `checklist?`, `hora_inicio?`, `hora_fin?`                | 201 al crear; 200 si repite el mismo `visita_id`            |
| POST `/visitas/:visitaId/iniciar`                 | `visitas:registrar` y participar o gestionar | Ninguna                                                                                                | 200 visita `en_curso` (idempotente)                         |
| POST `/visitas/:visitaId/registrar`               | `visitas:registrar` y participar o gestionar | `detalles`, `checklist?`, `hora_inicio?`, `hora_fin?`                                                  | 200 visita `completada`                                     |
| POST `/visitas/:visitaId/cancelar`                | `visitas:programar`                          | `motivo` (3 a 300)                                                                                     | 200 visita `cancelada`                                      |
| GET `/solicitudes-visita`                         | `visitas:autorizar`                          | `page`, `limit`, `sort` (`fecha_creacion`, `fecha_propuesta`), `filter[estado]`                        | 200 `{data, meta}`, pendientes primero                      |
| POST `/solicitudes-visita/:solicitudId/autorizar` | `visitas:autorizar`                          | `envejeciente_id`, `fecha`, `hora`                                                                     | 201 visita `programada` con `origen = solicitud`            |
| POST `/solicitudes-visita/:solicitudId/rechazar`  | `visitas:autorizar`                          | `motivo` (3 a 300)                                                                                     | 200 solicitud `rechazada`                                   |

Orden de `/visitas`: `fecha`, `hora_programada`, `estado`, `fecha_creacion`, `visita_id`; predeterminado `-fecha,-hora_programada` con `visita_id` como desempate. `estado` admite `programada`, `en_curso`, `completada`, `cancelada`; `desde` y `hasta` son fechas `YYYY-MM-DD` inclusivas.

### Programar (`POST /visitas`)

- `fecha` no anterior a hoy (fecha de negocio de República Dominicana) y, si es hoy, `hora_programada` no pasada; `razon` de 3 a 120 caracteres.
- `envejeciente_ids`: adultos **activos** de la cuenta y al alcance de quien programa, sin repetir. Un adulto de otra cuenta o inexistente responde 403 igual.
- `participante_ids`: miembros activos con rol cuidador, voluntario o coordinador (el Administrador y el Familiar no participan), sin repetir. Otro caso: `CR_PARTICIPANTE_INVALIDO`. Un participante con otra visita no cancelada a la misma fecha y hora: `CR_PARTICIPANTE_OCUPADO`.
- Si a un cuidador o voluntario le falta el vínculo **vigente** con un adulto (no existe o fue revocado), se crea o renueva con `cuidared_interno.seg_vincular` de 3b, que registra a quien programa como autorizador y limpia la revocación; eso exige `adultos:asignar`, que tiene el gestor.
- Crea `registro_visita` con `autorizada_por_usuario_id = actor` para cada participante y un `detalle_visita` por adulto. El actor, el autorizador y la cuenta nunca se aceptan del cuerpo.

### Registrar la realización

- `detalles` cubre **todos** los adultos de la visita (1 a 4, sin repetir) y quien registra alcanza a cada uno; si no, 422 o 403. `observacion` es de 3 a 1000 caracteres. `estado_general` (`estable`, `requiere_atencion`, `situacion_critica`) es obligatorio salvo para el Voluntario.
- `checklist` (catálogo arriba, sin repetir) es opcional. `hora_inicio` y `hora_fin` (`HH:MM`) son opcionales: si faltan, el inicio es el registrado al iniciar (o el programado) y, si la visita es de hoy, el fin es la hora actual. `hora_fin` no puede ser anterior a `hora_inicio`.
- La fecha de la visita no puede ser futura (`CR_ESTADO_INVALIDO`). Una visita completada o cancelada responde `CR_VISITA_CERRADA`.
- Si algún `estado_general` es `situacion_critica`, se crea una notificación para los gestores de la cuenta, salvo quien la reportó. El aviso nombra al adulto y la fecha, no copia la observación, y no se repite si se reintenta. La alerta formal es de la fase 6.

### Visita realizada sin programar (`POST /visitas/realizada`)

Crea la visita ya `completada` con `origen = sin_programar`. `visita_id` (UUID generado por el cliente) hace idempotente el reintento: repetir la misma petición devuelve 200 con la misma visita y no duplica visita, participante, detalle ni avisos. Un `visita_id` que ya existe como otra visita, de otra cuenta o de otra persona es `CR_CONFLICTO` (409). `fecha` (por defecto hoy) no puede ser futura; `razon` por defecto es «Visita de seguimiento».

## Solicitudes de visita de personas externas

### Rutas públicas (`/api/v1/publico`, sin sesión)

Montadas antes de `requireSession`. Usan el cliente anon del gateway, que solo acepta `api_publico_*`, y su propio límite de **10 peticiones por minuto por IP**; la creación tiene además **10 por hora por IP**. Cualquier otra ruta o método bajo `/publico` es 404.

| Método y ruta                                  | Entrada                                                                                                                                  | Respuesta                                                                                                         |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| GET `/publico/organizaciones`                  | Ninguna                                                                                                                                  | 200 `[{cuenta_id, nombre}]` de cuentas **Organización** con acceso operativo; nunca familias                      |
| POST `/publico/solicitudes-visita`             | `cuenta_id`, `nombres`, `apellidos`, `cedula`, `telefono`, `correo?`, `persona_a_visitar`, `fecha_propuesta`, `hora_propuesta`, `motivo` | 201 `{codigo, organizacion, estado, fecha_propuesta, hora_propuesta}`; el código se devuelve **una sola vez**     |
| POST `/publico/solicitudes-visita/consulta`    | `codigo`                                                                                                                                 | 200 `{organizacion, estado, estado_texto, fecha, hora, motivo_rechazo, puede_registrar_observacion, observacion}` |
| POST `/publico/solicitudes-visita/observacion` | `codigo`, `observacion` (3 a 600)                                                                                                        | 200 con el estado público actualizado (`realizada`)                                                               |

- **Código**: `VIS-XXXX-XXXX` generado en Express con `crypto.randomInt` sobre el alfabeto `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (sin 0, O, 1, I; 40 bits). A la base solo llega su huella (hex del código normalizado: mayúsculas, sin espacios) mediante `api_publico_crear_solicitud`: HMAC-SHA256 con `CODIGO_SEGUIMIENTO_SECRETO` (≥ 32 caracteres, obligatorio en producción) o SHA-256 simple en desarrollo y pruebas. Ni la base, ni los logs, ni la auditoría guardan el código. Cambiar el secreto invalida los códigos ya entregados.
- **Entrada**: nombres de 2 a 60 letras; `cedula` de 11 dígitos (se aceptan guiones y espacios y se envía la forma canónica); `telefono` de 10 a 15 dígitos con `+` opcional; `correo` opcional (cadena vacía equivale a ausente); `persona_a_visitar` de 3 a 120; `motivo` de 3 a 300; la fecha propuesta no puede ser anterior a hoy.
- **Cuenta no elegible** (familia, vencida o inexistente): el mismo 422, sin distinguir cuál.
- **Código inexistente o con formato inválido**: el mismo 404 `NOT_FOUND` con el mismo mensaje; un formato inválido ni siquiera consulta la base.
- **Observación**: solo si la solicitud está `autorizada`, la visita sigue abierta, su fecha es hoy o anterior y la cuenta conserva acceso operativo; si no, `CR_SOLICITUD_NO_DISPONIBLE` (409). Deja la visita `completada` (contacto efectivo) con la observación en el detalle del adulto; `registrado_por` queda nulo porque el visitante no es un usuario.
- **Lo que ve el visitante**: estado, organización, fecha y hora vigentes, motivo del rechazo y su propia observación. Nunca el adulto, el personal, la cuenta interna ni otras solicitudes. Las respuestas pasan por una lista cerrada de campos en Express.
- **Frenos en la base** (porque las RPC `anon` también pueden llamarse directamente, sin pasar por Express): 3 solicitudes pendientes por cédula y cuenta (`CR_CONFLICTO`), 500 pendientes y 60 creaciones por hora por cuenta (`CR_SOLICITUD_NO_DISPONIBLE`).

### Gestión (`visitas:autorizar`)

`GET /solicitudes-visita` incluye cédula, teléfono y correo del visitante, que solo ven quienes autorizan. `autorizar` confirma el adulto, valida que sea activo y de la cuenta, y crea una visita `programada` con `origen = solicitud`, participante = quien autoriza y `autorizada_por = quien autoriza`. `fecha` no anterior a hoy. **La cédula y el teléfono del visitante nunca se copian a `visita`, `visita.notas`, `registro_visita`, `detalle_visita`, notificaciones, logs ni auditoría**; la visita solo muestra el nombre del visitante. Una solicitud ya revisada: `CR_SOLICITUD_REVISADA` (409). Si la visita se completa o se cancela, por cualquier vía (también la baja de un adulto, 3a), un disparador de la base pasa la solicitud a `realizada` o `cancelada`.

## Errores

Además de la tabla de CR-162 (`28000`, `42501`, `P0002`, `22023`, `23514`):

| Código SQL (`P0001`)         | HTTP | Código público             | Significado                                                               |
| ---------------------------- | ---- | -------------------------- | ------------------------------------------------------------------------- |
| `CR_VISITA_CERRADA`          | 409  | `VISIT_CLOSED`             | La visita ya fue completada o cancelada.                                  |
| `CR_PARTICIPANTE_INVALIDO`   | 422  | `INVALID_PARTICIPANT`      | Un participante no es miembro activo con rol permitido.                   |
| `CR_PARTICIPANTE_OCUPADO`    | 409  | `PARTICIPANT_BUSY`         | Un participante ya tiene una visita a esa hora.                           |
| `CR_NO_PARTICIPA`            | 403  | `NOT_PARTICIPANT`          | Ve la visita pero no participa ni la gestiona.                            |
| `CR_SOLICITUD_REVISADA`      | 409  | `REQUEST_ALREADY_REVIEWED` | La solicitud ya fue autorizada o rechazada.                               |
| `CR_SOLICITUD_NO_DISPONIBLE` | 409  | `REQUEST_UNAVAILABLE`      | La solicitud no admite esa operación ahora (o la cuenta alcanzó un tope). |

Se reutilizan los transversales `CR_ESTADO_INVALIDO` (adulto inactivo, fecha futura al registrar), `CR_CONFLICTO` y `CR_CUENTA_SIN_ACCESO` (cuenta sin prueba o plan vigente, D07). Los códigos están en `src/modules/visitas/visitas-errors.js`.

## Persistencia propuesta

Esquema en [fase-4a-visitas.sql](../propuestas/fase-4a-visitas.sql); verificación local en `docs/verificacion/local/pruebas-4a-visitas.sql` y `pruebas-4a-solicitudes.sql`. Depende de 2a y de 3b (`seg_vincular`, vínculos con revocación); para validarla sola se cargan los bloques previos: `node scripts/validar-propuestas-local.js --solo=3a,3b,4a`. Los adultos de prueba se crean con la ayuda común `pruebas.envejeciente`.

- `visita`: `cuenta_id` (obligatorio en filas nuevas mediante `check ... not valid`, se valida solo si no quedan filas sin cuenta; se rellena donde es inequívoco), `hora_programada`, `creada_por`, `motivo_cancelacion`, `cancelada_por`, `fecha_cancelacion`, `checklist text[]` (restringido al catálogo), `notas`, `origen` (`interna`, `solicitud`, `sin_programar`), `solicitud_visita_id`. Disparadores: la cuenta no cambia, el adulto de un detalle es de la cuenta de la visita y la solicitud de origen sigue a su visita (cancelada o completada).
- `detalle_visita`: `registrado_por`, `fecha_registro`. `registro_visita`: sin cambios (`autorizada_por_usuario_id` nulo en visitas sin programar).
- `solicitud_visita` (nueva): datos del visitante, `persona_a_visitar`, fecha y hora propuestas, `motivo`, `estado`, `codigo_hash` único, revisión, `envejeciente_id`, `visita_id` y observación del visitante, con una restricción que liga la revisión al estado.
- Las cuatro tablas llevan RLS y `revoke` a `public`, `anon` y `authenticated`: solo se accede por RPC.
- RPC de cuenta (`security definer`, `search_path` vacío, `authenticated`): `api_listar_visitas`, `api_obtener_visita`, `api_programar_visita`, `api_iniciar_visita`, `api_registrar_visita`, `api_registrar_visita_realizada`, `api_cancelar_visita`, `api_listar_solicitudes_visita`, `api_autorizar_solicitud_visita`, `api_rechazar_solicitud_visita`. Autorizan con `cuidared_interno.exigir`, `exigir_envejeciente` o `alcanza_envejeciente`.
- RPC públicas (`anon` y `authenticated`): `api_publico_listar_organizaciones`, `api_publico_crear_solicitud`, `api_publico_consultar_solicitud`, `api_publico_registrar_observacion`.
- Bloqueos con orden único (solicitud y luego visita) para evitar interbloqueos entre cancelar, registrar y la observación del visitante; un bloqueo asesor por `visita_id` serializa los reintentos.

### Exposición que requiere aprobación

Para que las RPC `api_publico_*` sean ejecutables sin sesión, la propuesta concede `USAGE` del esquema `cuidared_api` a `anon`. Ninguna otra función de ese esquema es ejecutable por `anon` (todas hacen `revoke ... from public, anon`) y la prueba `pruebas-4a-solicitudes.sql` lo verifica. `scripts/verify-api-exposure.js` sigue pasando: una RPC privada llamada sin identidad responde `42501`.

**Riesgo conocido.** Quien tenga la clave publicable puede llamar las RPC públicas directamente en PostgREST y esquivar el límite de Express. Los topes de la base acotan el daño por cuenta, pero no sustituyen un límite por IP o un WAF en el proveedor. El código tiene 40 bits: es inviable adivinarlo con consultas en línea, y con el HMAC del servidor una copia filtrada de la tabla tampoco permite probarlo por fuerza bruta sin el secreto.

## Función interna para la sincronización (bloque 4c)

```sql
cuidared_interno.registrar_visita_realizada(
  p_cuenta_id  bigint,
  p_usuario_id uuid,   -- quien registra; la sesión ya la autenticó el llamador
  p_visita_id  uuid,   -- id del cliente; null genera uno
  p_datos      jsonb   -- {detalles, checklist?, hora_inicio?, hora_fin?, fecha?, razon?}
) returns jsonb        -- {visita_id, creada, ya_registrada, estado}
```

- Si la visita existe en la cuenta (programada o en curso) la completa; si no existe, la crea completada con ese id y `origen = sin_programar`. `fecha` y `razon` solo se usan al crear.
- **Idempotente respecto de `p_visita_id`**: si ya está completada devuelve `ya_registrada = true` sin modificar nada ni repetir avisos. Visita cancelada: `CR_VISITA_CERRADA`; id de otra cuenta: `CR_CONFLICTO`. Un bloqueo asesor por id serializa reintentos simultáneos.
- Revalida membresía activa, `visitas:registrar`, acceso operativo, alcance sobre cada adulto y participación o gestión, de modo que una captura offline no autoriza a quien perdió el acceso.
- `cuidared_interno.iniciar_visita(p_cuenta_id, p_usuario_id, p_visita_id)` hace lo propio con el inicio (`ya_iniciada`).
- Para LWW, cada cambio actualiza `visita.fecha_actualizacion`. El contrato del lote, el reloj y el desempate siguen en D16.

## Frontend

`EstadoVisita` `pendiente` equivale a `programada`. `cuidadorId` pasa a `participantes` (IDs de usuario) y `autorizadaPor` a `autorizada_por`. `visitante.nombre` se conserva; el resto del visitante vive solo en la solicitud. El registro mínimo del Voluntario envía solo `observacion` por adulto. El código de seguimiento se muestra una vez, como ya hace la pantalla de solicitud.

## Pruebas y trazabilidad

`tests/visitas.test.js` (HTTP con gateway real y transporte simulado: validación, permisos, mapeo de errores, privacidad de la auditoría), `tests/publico.test.js` (código, hash, límites, privacidad, 404 genérico y superficie pública) y las dos pruebas SQL. Trazan a ID04 y RF-02. Estas pruebas no certifican RLS ni Auth de Supabase: el SQL se valida en un PostgreSQL local con esquema `auth` simulado.
