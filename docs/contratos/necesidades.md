# Contrato de necesidades del adulto mayor

ID05 de Prototipos, RF-03 y CU-07/CU-08 del SRS, y reglas V2 de TipoNecesidad, Necesidad y Env_Necesidad. Usa CR-162 y las convenciones de autorización de las fases anteriores. El [SQL de fase 5](../propuestas/fase-5-necesidades.sql) se prepara sobre CUIDARED-008.

## Permisos y alcance

Los roles Coordinador y Cuidador de Familia y Administrador, Coordinador y Cuidador de Organización registran y actualizan según V2. Para el Cuidador se exige perfil vigente y asignación. El Familiar autorizado consulta las necesidades de sus adultos vinculados. El Voluntario carece de los permisos del módulo. Cada operación comprueba sesión, cuenta activa, vigencia y alcance efectivo. Un expediente de otra cuenta, retirado o fuera de alcance responde 404.

## Consultas conectadas

Prefijo `/api/v1/cuentas/:cuentaId`. `:necesidadId` es el UUID de la ocurrencia `envejeciente_necesidad_id`. El catálogo usa el identificador numérico `necesidad_id`.

| Método y ruta                             | Permiso           | Resultado                                                                 |
| ----------------------------------------- | ----------------- | ------------------------------------------------------------------------- |
| GET `/necesidades`                        | `necesidades:ver` | Colección paginada de ocurrencias de expedientes visibles.                |
| GET `/necesidades/:necesidadId`           | `necesidades:ver` | Detalle de una ocurrencia visible.                                        |
| GET `/necesidades/:necesidadId/historial` | `necesidades:ver` | Eventos paginados de creación, cambio de prioridad, responsable o estado. |
| GET `/envejecientes/:envejecienteId/necesidades/candidatos` | `necesidades:registrar` o `necesidades:actualizar` | Lista paginada de responsables elegibles para ese adulto. |

- Listado. Orden por defecto `-fecha_necesidad`. También acepta `prioridad` (de mayor urgencia a menor en ascendente), `estado` y `envejeciente_necesidad_id`. Filtros `envejeciente_id`, `estado`, `activas=true`, `prioridad_id` y `tipo_necesidad_id`. `activas=true` incluye `pendiente` y `en_proceso`. El identificador de la ocurrencia desempata.
- Fila. Identificadores y nombres de expediente, ítem, tipo y prioridad, estado de la ocurrencia, descripción, cantidad/unidad, fechas de registro/actualización y resolución, motivo, responsable, indicación relacionada y referencias de autoría cuando existen. Incluye `envejeciente_estado` (`activo`, `inactivo` o `fallecido`) para habilitar cambios solo en expedientes activos. La indicación se incluye solo si es del mismo expediente y el lector puede verla. Los responsables y actores visibles pertenecen o han pertenecido a la cuenta.
- Historial. Por defecto `-fecha` con desempate por `necesidad_evento_id`; emite actor, fechas, estado, prioridad y responsable anteriores y actuales, además del motivo de resolución cuando consta. Se conservan las ocurrencias previas. Los datos sin constancia histórica permanecen vacíos.
- Catálogos. `GET /api/v1/catalogos/tipos-necesidad`, `/catalogos/necesidades?tipo_necesidad_id=<id>` y `/catalogos/prioridades` reutilizan la capa común de catálogos.

## Registro, prioridad y estado

| Método y ruta | Permiso | Entrada | Resultado |
| --- | --- | --- | --- |
| POST `/envejecientes/:envejecienteId/necesidades` | `necesidades:registrar` | Ítem y prioridad de catálogo, descripción y campos opcionales. | 201 con la ocurrencia creada. |
| PATCH `/necesidades/:necesidadId` | `necesidades:actualizar` | `prioridad_id`, `usuario_responsable_id` o ambos. | 200 con la ocurrencia actualizada. |
| POST `/necesidades/:necesidadId/estado` | `necesidades:actualizar` | `estado`. `motivo` al cerrar. | 200 con la ocurrencia actualizada. |

- Alta. `necesidad_id` y `prioridad_id` son números de catálogo. La descripción es obligatoria, de 5 a 500 caracteres. La cantidad opcional admite decimales mayores que cero y hasta 10.000. Se guarda el valor recibido sin redondearlo a dos decimales. Si se informa cantidad, se exige `unidad_medida` de 1 a 64 caracteres y viceversa. `es_recurrente` es informativo. Cada aparición genera un UUID nuevo, incluso con el mismo catálogo.
- Catálogo inicial. Medicamentos, Alimentación, Transporte, Compañía y Otros apoyos, cada una con una opción «(general)». Se preserva el catálogo previo y se detiene la propuesta si un nombre general ya existe con otro tipo o inactivo. La gestión de necesidades institucionales del plan avanzado queda pendiente.
- Responsable opcional. Solo se admite una persona activa de la cuenta que pueda actualizar necesidades de ese expediente. La consulta de candidatos retorna `usuario_id` y `nombre`, con orden por `nombre` o `usuario_id`. En PATCH enviar `usuario_responsable_id: null` quita la asignación. La indicación opcional debe pertenecer al mismo expediente y estar al alcance del actor.
- Ciclo. Parte en `pendiente` y puede pasar a `en_proceso`, `resuelta` o `cancelada`. Desde `en_proceso` puede pasar a `resuelta` o `cancelada`. Los dos estados de cierre son terminales y requieren motivo de 3 a 500 caracteres. Se guardan fecha y actor de resolución. Un expediente debe estar activo y conservar consentimiento para registrar cambios. El cierre impide modificar la prioridad o el responsable de esa ocurrencia.
- Captura sin conexión. Registrar y cambiar estado reutilizan las mismas reglas de mutación en la base. El contrato de la cola y del lote corresponde a [sincronización](sync.md).

## Verificación

`tests/necesidades.test.js` valida el contrato HTTP. `docs/verificacion/local/pruebas-fase-5.sql` comprueba recurrencias como ocurrencias separadas, filtros, roles, historial y el aislamiento de expedientes tras retirar consentimiento.
