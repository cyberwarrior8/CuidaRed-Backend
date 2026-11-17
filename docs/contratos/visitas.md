# Contrato de Visitas y Solicitudes de Visita — fase 4, bloque 4a

## Estado y alcance

ID04; RF-02 y RF-10. Los bloques de integración 4a a 4d están aplicados. El cierre agrega series autorizadas, refuerza el registro del Voluntario y conecta solo la bandeja interna. Consultar [estado de despliegue](../CAMBIOS-SCHEMA-CUIDARED.md).

Las convenciones de errores, paginación, orden y filtros son las de [CR-162](../CONVENCIONES-API.md). Todos los cuerpos usan `snake_case` y Zod `strictObject`: un campo desconocido es 422. Los filtros del historial usan la sintaxis acordada `filter[campo]=valor`.

## Decisiones

| Tema                             | Decisión                                                                                                                                                                                                                        | Origen                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Quién autoriza                   | Coordinador en Familia; Administrador o Coordinador en Organización. Programar equivale a autorizar y exige `visitas:programar` y `visitas:autorizar`.                                                                          | D05, confirmada                              |
| Contacto efectivo                | Solo una visita **completada** cuenta. Programada, en curso o cancelada no.                                                                                                                                                     | D05/§7.2, confirmada                         |
| Voluntario | Confirma la visita y deja observaciones. Puede adjuntar y consultar evidencias autorizadas. | Confirmada |
| Solicitudes existentes | La bandeja interna permite autorizar o rechazar. | Confirmada |
| Una visita, una cuenta           | Una visita pertenece a una sola cuenta (`visita.cuenta_id`, inmutable) y todos sus adultos son de esa cuenta.                                                                                                                   | **Propuesta técnica (D05)**                  |
| Cancelar y revocar               | Cancela un usuario principal (`visitas:programar`) una visita programada o en curso, con motivo. Cancelar es también la forma de revocar una autorización.                                                                      | **Propuesta técnica (D05)**                  |
| Quién opera la visita | Iniciar y registrar exigen permiso, participación autorizada y alcance sobre todos los adultos. | Confirmada |
| Transiciones                     | `programada → en_curso → completada`; `programada` o `en_curso → cancelada`. `completada` y `cancelada` son terminales: no se reabren. Solicitud: `pendiente → autorizada \| rechazada`; `autorizada → realizada \| cancelada`. | **Propuesta técnica (D10)**                  |
| Checklist                        | `alimentacion`, `medicamentos`, `higiene`, `vivienda`, `animo`, `movilidad` (catálogo del frontend, no oficial).                                                                                                                | **Propuesta técnica (D14)**                  |
| Retención de datos del visitante | No hay política: la cédula y el teléfono se conservan en `solicitud_visita` sin vencimiento hasta que se decida.                                                                                                                | Pendiente (D15)                              |

Toda visita que se registra debe haber sido programada y autorizada, incluso al sincronizar.

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
| POST `/visitas/recurrentes` | `visitas:programar` + `visitas:autorizar` | Entrada de programación más `repeticion` | 201 con `serie_id` y `visitas` |
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
- Si a un cuidador o voluntario le falta un vínculo vigente con un adulto, `cuidared_interno.seg_vincular` abre un periodo y registra a quien programa como autorizador. El permiso `adultos:asignar` es obligatorio. Los periodos revocados se conservan.
- Crea `registro_visita` con `autorizada_por_usuario_id = actor` para cada participante y un `detalle_visita` por adulto. El actor, el autorizador y la cuenta nunca se aceptan del cuerpo.

### Registrar la realización

- `detalles` cubre **todos** los adultos de la visita (1 a 4, sin repetir) y quien registra alcanza a cada uno; si no, 422 o 403. `observacion` es de 3 a 1000 caracteres. `estado_general` (`estable`, `requiere_atencion`, `situacion_critica`) es obligatorio salvo para el Voluntario.
- `checklist` (catálogo arriba, sin repetir) es opcional. `hora_inicio` y `hora_fin` (`HH:MM`) son opcionales: si faltan, el inicio es el registrado al iniciar (o el programado) y, si la visita es de hoy, el fin es la hora actual. `hora_fin` no puede ser anterior a `hora_inicio`.
- La fecha de la visita no puede ser futura (`CR_ESTADO_INVALIDO`). Una visita completada o cancelada responde `CR_VISITA_CERRADA`.
- Si algún `estado_general` es `situacion_critica`, se crea una notificación para los gestores de la cuenta, salvo quien la reportó. El aviso nombra al adulto y la fecha, no copia la observación, y no se repite si se reintenta. La alerta formal es de la fase 6.

### Series de visitas

El plan debe incluir `visitas_recurrentes`. El objeto `repeticion` contiene `frecuencia` (`diaria` o `semanal`), `hasta` (inclusive) y `dias_semana` para semanal (días ISO del 1 al 7). Permite hasta 60 visitas con la misma autorización. Una ocurrencia inválida revierte la serie completa.

## Solicitudes de visita existentes

El acceso público está cerrado en Express y en la Data API. La bandeja permite revisar las solicitudes que existan en la cuenta.

### Gestión (`visitas:autorizar`)

`GET /solicitudes-visita` queda restringido a quienes autorizan. `autorizar` confirma adulto activo, fecha, hora y `participante_id` con rol y permiso para registrar. La API admite omitir este campo cuando el gestor puede participar. Se aplican las mismas reglas que al programar una visita interna. La visita de origen `solicitud` muestra el nombre del visitante. Una solicitud ya revisada devuelve 409. Si se completa o cancela la visita, el disparador de la base actualiza la solicitud a `realizada` o `cancelada`.

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

- `visita`: cuenta, hora programada, creador, datos de cancelación, checklist, notas, origen (`interna` o `solicitud`), solicitud relacionada y `serie_id` para las ocurrencias. La cuenta es inmutable y la solicitud sigue el estado de su visita.
- `detalle_visita` registra responsable y fecha de registro. `registro_visita` conserva autorización por participante.
- `solicitud_visita` (nueva): datos del visitante, `persona_a_visitar`, fecha y hora propuestas, `motivo`, `estado`, `codigo_hash` único, revisión, `envejeciente_id`, `visita_id` y observación del visitante, con una restricción que liga la revisión al estado.
- Las cuatro tablas llevan RLS y `revoke` a `public`, `anon` y `authenticated`: solo se accede por RPC.
- RPC de cuenta (`security definer`, `search_path` vacío, `authenticated`): `api_listar_visitas`, `api_obtener_visita`, `api_programar_visita`, `api_programar_visitas_recurrentes`, `api_iniciar_visita`, `api_registrar_visita`, `api_cancelar_visita`, `api_listar_solicitudes_visita`, `api_autorizar_solicitud_visita`, `api_rechazar_solicitud_visita`.
- Las RPC del flujo público permanecen revocadas.
- Bloqueos con orden único (solicitud y luego visita) para evitar interbloqueos entre cancelar, registrar y la observación del visitante; un bloqueo asesor por `visita_id` serializa los reintentos.

## Función interna para la sincronización (bloque 4c)

```sql
cuidared_interno.registrar_visita_realizada(
  p_cuenta_id  bigint,
  p_usuario_id uuid,   -- quien registra; la sesión ya la autenticó el llamador
  p_visita_id  uuid,   -- id de la visita existente
  p_datos      jsonb   -- {detalles, checklist?, hora_inicio?, hora_fin?}
) returns jsonb        -- {visita_id, ya_registrada, estado}
```

- Registra una visita preexistente, programada y autorizada. La operación de sincronización revisa la fecha, el estado y los permisos vigentes.
- **Idempotente respecto de `p_visita_id`**: si ya está completada devuelve `ya_registrada = true` sin modificar nada ni repetir avisos. Visita cancelada: `CR_VISITA_CERRADA`; id de otra cuenta: `CR_CONFLICTO`. Un bloqueo asesor por id serializa reintentos simultáneos.
- Revalida membresía activa, `visitas:registrar`, acceso operativo, alcance sobre cada adulto y participación o gestión, de modo que una captura offline no autoriza a quien perdió el acceso.
- `cuidared_interno.iniciar_visita(p_cuenta_id, p_usuario_id, p_visita_id)` hace lo propio con el inicio (`ya_iniciada`).
- Para LWW, cada cambio actualiza `visita.fecha_actualizacion`. El contrato del lote, el reloj y el desempate siguen en D16.

## Frontend

El usuario consulta Hoy, Próximas e Historial. El Voluntario autorizado envía la observación por adulto y puede adjuntar y consultar evidencias con alcance sobre todo el grupo. La bandeja interna muestra los datos necesarios para confirmar el adulto y la fecha de la visita.

## Pruebas y trazabilidad

`tests/visitas.test.js` (HTTP con gateway real y transporte simulado: validación, permisos, mapeo de errores, privacidad de la auditoría), `tests/publico.test.js` (código, hash, límites, privacidad, 404 genérico y superficie pública) y las dos pruebas SQL. Trazan a ID04 y RF-02. Estas pruebas no certifican RLS ni Auth de Supabase: el SQL se valida en un PostgreSQL local con esquema `auth` simulado.
