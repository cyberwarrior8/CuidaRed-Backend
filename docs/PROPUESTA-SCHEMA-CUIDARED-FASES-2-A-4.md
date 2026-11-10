# Propuesta de cambios al esquema `cuidared`

Fases 2 a 4 de CuidaRed. Inventario de los nueve bloques SQL de la rama `Edgardo-CuidaRed-Desarrollo` aplicados en Supabase CuidaRed el 09/11/2026. El [registro del esquema](CAMBIOS-SCHEMA-CUIDARED.md) enlaza las versiones aplicadas y su verificación.

Las tablas y referencias de este documento pertenecen a `cuidared` salvo indicación expresa. **PK** significa clave primaria y **FK** significa clave foránea. `timestamptz` representa un instante independiente de la zona con que se ingresó. `time` indica una hora sin zona horaria.

## Tablas nuevas

### `plan_funcionalidad` · bloque 2a

Relaciona un plan comercial con sus funcionalidades. La propuesta crea la estructura y reserva la carga comercial para la fase 8.

| Campo           | Tipo       | Regla                                                                |
| --------------- | ---------- | -------------------------------------------------------------------- |
| `plan_id`       | `smallint` | Obligatorio. FK a `plan.plan_id` y parte de la PK.                   |
| `funcionalidad` | `varchar`  | Obligatorio. Código en minúsculas con guiones bajos. Parte de la PK. |

### `prueba_funcionalidad` · bloque 2a

Define las funcionalidades del nivel básico que se habilitan durante una prueba vigente.

| Campo            | Tipo       | Regla                                                                |
| ---------------- | ---------- | -------------------------------------------------------------------- |
| `tipo_cuenta_id` | `smallint` | Obligatorio. FK a `tipo_cuenta.tipo_cuenta_id` y parte de la PK.     |
| `funcionalidad`  | `varchar`  | Obligatorio. Código en minúsculas con guiones bajos. Parte de la PK. |

### `rol_permiso` · bloque 2a

Vincula las acciones de la matriz de permisos con el rol y el tipo de cuenta.

| Campo            | Tipo       | Regla                                                            |
| ---------------- | ---------- | ---------------------------------------------------------------- |
| `rol_id`         | `smallint` | Obligatorio. FK a `rol.rol_id` y parte de la PK.                 |
| `tipo_cuenta_id` | `smallint` | Obligatorio. FK a `tipo_cuenta.tipo_cuenta_id` y parte de la PK. |
| `accion`         | `varchar`  | Obligatorio. Código como `adultos:ver`. Parte de la PK.          |

### `evaluacion_riesgo` · bloque 3b

Guarda cada cuestionario, su resultado y el factor de riesgo que generó.

| Campo                    | Tipo          | Regla                                                                   |
| ------------------------ | ------------- | ----------------------------------------------------------------------- |
| `evaluacion_riesgo_id`   | `bigint`      | PK generada por identidad.                                              |
| `envejeciente_id`        | `uuid`        | Obligatorio. FK a `envejeciente`.                                       |
| `respuestas`             | `jsonb`       | Obligatorio. Objeto de respuestas.                                      |
| `puntaje`                | `smallint`    | Obligatorio. De 0 a 100.                                                |
| `desglose`               | `jsonb`       | Obligatorio. Arreglo con el desglose del puntaje.                       |
| `nivel_riesgo_id`        | `smallint`    | Obligatorio. FK a `nivel_riesgo`.                                       |
| `version_cuestionario`   | `varchar`     | Obligatorio. Versión como `v1`.                                         |
| `envejeciente_riesgo_id` | `bigint`      | Opcional. FK a `envejeciente_riesgo`.                                   |
| `usuario_id`             | `uuid`        | Obligatorio. FK a `usuario`, identifica a quien registró la evaluación. |
| `fecha`                  | `timestamptz` | Obligatoria. Valor inicial `now()`.                                     |

### `solicitud_visita` · bloque 4a

Conserva la solicitud, su revisión y su relación con la visita. El flujo público queda deshabilitado hasta la revisión de seguridad.

| Campo                                      | Tipo          | Regla                                                                                                      |
| ------------------------------------------ | ------------- | ---------------------------------------------------------------------------------------------------------- |
| `solicitud_visita_id`                      | `uuid`        | PK generada con `gen_random_uuid()`.                                                                       |
| `cuenta_id`                                | `bigint`      | Obligatorio. FK a `cuenta`.                                                                                |
| `visitante_nombres`, `visitante_apellidos` | `varchar`     | Obligatorios. Entre 2 y 60 caracteres cada uno.                                                            |
| `visitante_cedula`                         | `varchar`     | Obligatoria. 11 dígitos.                                                                                   |
| `visitante_telefono`                       | `varchar`     | Obligatorio. De 10 a 15 dígitos con prefijo `+` opcional.                                                  |
| `visitante_correo`                         | `varchar`     | Opcional. Correo de hasta 254 caracteres.                                                                  |
| `persona_a_visitar`                        | `varchar`     | Obligatorio. Nombre informado, de 3 a 120 caracteres.                                                      |
| `fecha_propuesta`                          | `date`        | Obligatoria.                                                                                               |
| `hora_propuesta`                           | `time`        | Obligatoria.                                                                                               |
| `motivo`                                   | `varchar`     | Obligatorio. De 3 a 300 caracteres.                                                                        |
| `estado`                                   | `varchar`     | Obligatorio. `pendiente` por defecto. También admite `autorizada`, `rechazada`, `realizada` y `cancelada`. |
| `codigo_hash`                              | `varchar`     | Obligatorio y único. Huella hexadecimal de 64 caracteres.                                                  |
| `fecha_creacion`                           | `timestamptz` | Obligatoria. Valor inicial `now()`.                                                                        |
| `revisada_por`                             | `uuid`        | FK opcional a `usuario`. Se exige en los estados revisados.                                                |
| `revisada_en`                              | `timestamptz` | Fecha de revisión. Admite nulo.                                                                            |
| `motivo_rechazo`                           | `text`        | Se exige al rechazar. De 3 a 300 caracteres.                                                               |
| `envejeciente_id`                          | `uuid`        | FK a `envejeciente`. Se exige al vincular la solicitud con una visita.                                     |
| `visita_id`                                | `uuid`        | FK única a `visita`. Se exige para los estados que representan una visita creada.                          |
| `observacion_visitante`                    | `text`        | Opcional. De 3 a 600 caracteres.                                                                           |
| `observacion_en`                           | `timestamptz` | Fecha opcional de la observación.                                                                          |

### `operacion_sync` · bloque 4c

Guarda la identidad y el resultado de cada operación offline. El identificador del cliente permite reconocer reintentos.

| Campo                     | Tipo          | Regla                                                            |
| ------------------------- | ------------- | ---------------------------------------------------------------- |
| `id_cliente`              | `uuid`        | PK enviada por el cliente.                                       |
| `usuario_id`              | `uuid`        | Obligatorio. FK a `usuario`.                                     |
| `cuenta_id`               | `bigint`      | Obligatorio. FK a `cuenta`.                                      |
| `entidad`                 | `varchar`     | Obligatorio. Código de entidad, como `visita`.                   |
| `tipo`                    | `varchar`     | Obligatorio. Código de operación, como `registrar`.              |
| `registro_id`             | `uuid`        | Obligatorio. Identificador del registro afectado.                |
| `resultado`               | `varchar`     | Obligatorio. `aplicada`, `duplicada`, `conflicto` o `rechazada`. |
| `motivo`                  | `varchar`     | Código obligatorio cuando el resultado es `rechazada`.           |
| `gana`                    | `varchar`     | Solo en conflictos. `local` o `servidor`.                        |
| `actualizado_en_cliente`  | `timestamptz` | Obligatorio. Instante enviado por el cliente.                    |
| `base_actualizado_en`     | `timestamptz` | Opcional. Versión del servidor que conocía el cliente.           |
| `actualizado_en_servidor` | `timestamptz` | Opcional. Versión efectiva tras procesar.                        |
| `procesada_en`            | `timestamptz` | Obligatorio. Valor inicial `now()`.                              |

### `evidencia_visita` · bloque 4d

Registra los metadatos de archivos privados de una visita. La autorización de lectura comprueba el alcance sobre todos sus adultos.

| Campo                 | Tipo          | Regla                                          |
| --------------------- | ------------- | ---------------------------------------------- |
| `evidencia_visita_id` | `uuid`        | PK generada con `gen_random_uuid()`.           |
| `visita_id`           | `uuid`        | Obligatorio. FK a `visita`.                    |
| `registrada_por`      | `uuid`        | Obligatorio. FK a `usuario`.                   |
| `ruta`                | `text`        | Obligatoria y única. Ruta interna del archivo. |
| `nombre_archivo`      | `text`        | Obligatorio. De 1 a 150 caracteres.            |
| `tipo_mime`           | `text`        | Obligatorio. JPEG, PNG, WebP o PDF.            |
| `tamano_bytes`        | `integer`     | Obligatorio. De 1 a 5 242 880 bytes.           |
| `fecha_registro`      | `timestamptz` | Obligatoria. Valor inicial `now()`.            |

Las siete tablas nuevas tienen RLS habilitado y acceso directo revocado para `PUBLIC`, `anon` y `authenticated`.

## Tablas existentes modificadas

| Tabla                                                            | Campos agregados                                                                                                                                                                                                                                                                                                                                                            | Otros cambios                                                                                                                                                                                                                            |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tipo_cuenta`                                                    | `codigo varchar`, `prueba_limite_envejecientes integer`, `prueba_limite_usuarios integer`, `prueba_limite_familiares integer`                                                                                                                                                                                                                                               | Código único. Los límites informados deben ser positivos.                                                                                                                                                                                |
| `categoria_cuenta`                                               | `tipo_cuenta_id smallint`                                                                                                                                                                                                                                                                                                                                                   | FK a `tipo_cuenta`.                                                                                                                                                                                                                      |
| `prioridad`                                                      | `codigo varchar`                                                                                                                                                                                                                                                                                                                                                            | Código único.                                                                                                                                                                                                                            |
| `plan`                                                           | `limite_familiares integer`, `resumen varchar`                                                                                                                                                                                                                                                                                                                              | El límite de familiares informado debe ser positivo.                                                                                                                                                                                     |
| `cuenta`                                                         | `fecha_fin_vigencia date`, `fecha_inicio_prueba timestamptz`, `fecha_fin_prueba timestamptz`, `prueba_historica boolean NOT NULL DEFAULT false`                                                                                                                                                                                                                             | Las columnas `date` originales se renombran a `fecha_inicio_prueba_historica` y `fecha_fin_prueba_historica`. `plan_id` admite nulo salvo en suscripciones activas. El estado inicial pasa a `prueba`. RLS y acceso directo restringido. |
| `vinculo`                                                        | `vinculo_id bigint` generado por identidad, `autorizado_por_usuario_id uuid` (FK a `usuario`), `fecha_autorizacion timestamptz`, `fecha_revocacion timestamptz`, `motivo_revocacion varchar`                                                                                                                                                                                | La PK pasa a `vinculo_id`. Un índice parcial permite un solo vínculo vigente por adulto y usuario y conserva los anteriores. RLS y acceso directo restringido.                                                                           |
| `envejeciente`                                                   | `zona varchar`, `autonomia varchar`, `condiciones text[] NOT NULL DEFAULT '{}'`, `nota_condicion varchar`, `consentimiento_otorgado boolean`, `consentimiento_otorgado_por varchar`, `consentimiento_representante varchar`, `consentimiento_fecha timestamptz`, `consentimiento_registrado_por uuid` (FK a `usuario`), `motivo_estado varchar`, `fecha_estado timestamptz` | Cédula obligatoria y única en toda la plataforma. El consentimiento completo se exige por restricción. Índices por cuenta y estado, RLS y acceso directo restringido.                                                                    |
| `nivel_riesgo`, `riesgo`                                         | `codigo varchar` en cada tabla                                                                                                                                                                                                                                                                                                                                              | Un índice único por código en cada tabla.                                                                                                                                                                                                |
| `envejeciente_riesgo`                                            | `registrado_por uuid`, `fecha_resolucion timestamptz`, `resuelto_por uuid`                                                                                                                                                                                                                                                                                                  | Ambas referencias de usuario son FK a `usuario`. Un factor activo por adulto y tipo de riesgo.                                                                                                                                           |
| `indicacion_medica`                                              | `registrado_por uuid`, `actualizado_por uuid`                                                                                                                                                                                                                                                                                                                               | Ambas son FK a `usuario`. Índice por adulto y estado.                                                                                                                                                                                    |
| `visita`                                                         | `cuenta_id bigint` (FK a `cuenta`), `hora_programada time`, `creada_por uuid` y `cancelada_por uuid` (FK a `usuario`), `motivo_cancelacion text`, `fecha_cancelacion timestamptz`, `checklist text[] NOT NULL DEFAULT '{}'`, `notas text`, `origen varchar NOT NULL DEFAULT 'interna'`, `solicitud_visita_id uuid` (FK a `solicitud_visita`)                                | Cuenta obligatoria en escrituras nuevas. Índices y controles para cuenta, solicitud, horas y cancelación. RLS y acceso directo restringido.                                                                                              |
| `detalle_visita`                                                 | `registrado_por uuid` (FK a `usuario`), `fecha_registro timestamptz`                                                                                                                                                                                                                                                                                                        | Índice por adulto. El trigger verifica la cuenta. RLS y acceso directo restringido.                                                                                                                                                      |
| `tarea_agenda`                                                   | `serie_id uuid`, `motivo_cancelacion text`, `cancelada_por uuid`, `completada_por uuid`, `fecha_completada timestamptz`, `actualizado_por uuid`, `es_historica boolean NOT NULL DEFAULT false`                                                                                                                                                                              | Los campos de actor son FK a `usuario`. Se agregan índices y controles de cierre. RLS y acceso directo restringido.                                                                                                                      |
| `evidencia`                                                      | `registrada_por uuid`, `nombre_archivo varchar`, `tipo_mime varchar`, `tamano_bytes integer`, `validada_por uuid`, `fecha_validacion timestamptz`, `motivo_rechazo text`, `es_historica boolean NOT NULL DEFAULT false`                                                                                                                                                     | Ambos actores son FK a `usuario`. Los metadatos son obligatorios para las evidencias nuevas. La ruta es única entre evidencias operativas. RLS y acceso directo restringido.                                                             |
| `membresia`, `cuidador`                                          | Sin columnas nuevas.                                                                                                                                                                                                                                                                                                                                                        | Una membresía pendiente o activa por usuario y cuenta. Un solo perfil global de cuidador por usuario. RLS y acceso directo restringido en ambas tablas.                                                                                  |
| `configuracion_cuenta`, `contacto_emergencia`, `registro_visita` | Sin columnas nuevas.                                                                                                                                                                                                                                                                                                                                                        | RLS y acceso directo restringido. Índice parcial para un máximo de un contacto principal por adulto e índice de participantes por usuario. La operación de alta de expediente exige exactamente un contacto principal.                   |

Los cambios de datos iniciales afectan a `tipo_cuenta`, `categoria_cuenta`, `rol`, `tipo_cuidado`, `prioridad`, `tipo_vinculo`, `parametro`, `nivel_riesgo`, `riesgo` y `tipo_indicacion`. La carga territorial ONE 2021 corresponde a una ejecución anterior.

## Funciones y triggers

Se listan las funciones de `cuidared` y todos los triggers sobre sus tablas. Las funciones que implementan esos triggers conservan su esquema real en la tabla.

| Bloque | Trigger y tabla                                                                                              | Función                                                | Acción                                                                                                                   |
| ------ | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| 2a     | `trg_cuenta_valida_plan` en `cuenta`                                                                         | `cuidared.fn_trg_cuenta_valida_plan()`                 | Reemplaza el trigger y la función existentes. Comprueba que el plan corresponda al tipo de cuenta y esté activo.         |
| 2a     | `trg_cuenta_prueba_inmutable` en `cuenta`                                                                    | `cuidared.fn_prueba_inmutable()`                       | Nuevo. Impide marcar cuentas nuevas como históricas y protege las fechas y el indicador de prueba contra cambios.        |
| 2c     | `trg_membresia_limite` en `membresia`                                                                        | `cuidared.fn_trg_membresia_limite()`                   | Reemplaza el trigger y la función existentes. Aplica los cupos según el rol, el tipo de cuenta y las membresías activas. |
| 4a     | `trg_visita_cuenta_inmutable` en `visita`                                                                    | `cuidared_interno.trg_visita_cuenta_inmutable()`       | Nuevo. Impide cambiar la cuenta de una visita una vez asignada.                                                          |
| 4a     | `trg_visita_sincroniza_solicitud` en `visita`                                                                | `cuidared_interno.trg_visita_sincroniza_solicitud()`   | Nuevo. Propaga la cancelación o realización a la solicitud de origen autorizada.                                         |
| 4a     | `trg_detalle_visita_misma_cuenta` en `detalle_visita`                                                        | `cuidared_interno.trg_detalle_visita_misma_cuenta()`   | Nuevo. Exige una cuenta identificada y común a la visita y al adulto al insertar o actualizar el detalle.                |
| 4b     | `trg_tarea_coherencia` en `tarea_agenda`                                                                     | `cuidared_interno.tarea_coherencia()`                  | Nuevo. Verifica que el cuidador pertenezca a la cuenta y que la indicación corresponda al adulto.                        |
| 4b     | `trg_tarea_historica_solo_lectura` en `tarea_agenda` y `trg_evidencia_historica_solo_lectura` en `evidencia` | `cuidared_interno.trg_agenda_historica_solo_lectura()` | Nuevos. Bloquean actualizaciones y borrados de filas históricas e impiden insertar filas nuevas con la marca histórica.  |

Las RPC residen en `cuidared_api` y sus auxiliares en `cuidared_interno`. Los puntos que gobiernan la conservación de datos son `acceso_operativo`, `alcanza_envejeciente`, `api_cambiar_rol_miembro`, `seg_vincular`, `seg_revocar`, `historial_eventos`, `tarea_cargar` y `evidencia_json`. El permiso de descarga de archivos de tarea se comprueba también en `cuidared_storage.evidencia_permitida`. El bucket y sus políticas pertenecen a `storage`.

## Tratamiento de registros existentes

1. **Pruebas por fecha.** El bloque 2a conserva las fechas originales y deja vacíos los instantes exactos. Las cuentas quedan sin acceso operativo por esa prueba y conservan el acceso autorizado a cuenta y suscripción. Revisar cada caso con una fuente verificable antes de decidir su vigencia. Si hay suscripciones activas previas, verificar su fecha de vigencia por separado.
2. **Expedientes.** El bloque 3a detiene y revierte su transacción si hay cédulas ausentes, inválidas o duplicadas, expedientes sin exactamente un contacto principal o consentimientos sin respaldo. La preparación de datos requiere identificar los registros afectados y aprobar una corrección con evidencia verificable antes de reintentar. La ruta técnica permite preparar los campos de consentimiento antes de instalar y validar las restricciones.
3. **Vínculos.** Un cambio de rol revoca los vínculos incompatibles de esa cuenta. Una autorización posterior abre otro periodo. Un vínculo familiar previo sin autorizador documentado se conserva como historial y queda fuera de los accesos vigentes.
4. **Visitas.** Se asigna la cuenta únicamente cuando todos los adultos vinculados pertenecen a la misma cuenta. Las visitas sin cuenta verificable permanecen en la base y quedan fuera de los listados, operaciones e historial de cuentas. El bloque reporta cuántas requieren revisión.
5. **Tareas y evidencias.** El bloque 4b conserva las filas anteriores como históricas, incluso cuando su estado carece de trazabilidad. Se pueden consultar dentro del alcance autorizado. Los archivos históricos quedan sin enlace de descarga y necesitan revisión de ruta y permisos para habilitarse en una propuesta posterior.

Aplicar los bloques en orden `2a → 2b → 2c → 3a → 3b → 4a → 4b → 4c → 4d`. Si 3a se detiene, sus bloques dependientes esperan. Cada bloque usa su propia transacción. Verificar el modelo y los permisos en un entorno autorizado antes de aplicar los SQL revisados.

[SQL 2a](propuestas/fase-2a-base.sql) · [SQL 2b](propuestas/fase-2b-cuentas.sql) · [SQL 2c](propuestas/fase-2c-miembros.sql) · [SQL 3a](propuestas/fase-3a-envejecientes.sql) · [SQL 3b](propuestas/fase-3b-seguimiento.sql) · [SQL 4a](propuestas/fase-4a-visitas.sql) · [SQL 4b](propuestas/fase-4b-agenda.sql) · [SQL 4c](propuestas/fase-4c-sync.sql) · [SQL 4d](propuestas/fase-4d-evidencias-visita.sql)
