# Contrato de alertas y notificaciones

ID06 de Prototipos, RF-04, RF-05 y RF-18 del SRS, y reglas V2. Validación de sesión, vigencia, cuenta y alcance en cada operación. El Coordinador de Familia y el Administrador o Coordinador de Organización gestionan alertas. El Cuidador vigente puede consultarlas y resolverlas para sus expedientes asignados.

## API

Prefijo `/api/v1/cuentas/:cuentaId`. Los listados usan CR-162, con desempate por identificador. Las acciones devuelven `{data}`.

| Ruta | Entrada y resultado |
| --- | --- |
| GET `/alertas` | Filtros `estado`, `tipo`, `envejeciente_id`. Orden por `fecha_alerta` (descendente por defecto) o ID. |
| GET `/alertas/:alertaId` | Estado, prioridad, fecha, tipo, descripción y fuente. Al resolver incluye `accion_tomada`, `fecha_atencion` y `atendida_por` si el actor tiene historial en esa cuenta. `cierre_automatico` identifica los cierres del motor. |
| POST `/alertas/:alertaId/en-atencion` | Cuerpo vacío. Gestor autorizado pasa de `pendiente` a `en_proceso`. |
| POST `/alertas/:alertaId/resolver` | `accion_tomada` obligatoria de hasta 500 caracteres. Gestor o Cuidador con alcance pasa una alerta abierta a `resuelta`. |
| GET `/casos-prioritarios` | Agrupa alertas abiertas de riesgo y medicamentos por expediente. Devuelve una fila por adulto, su conteo y sus alertas individuales. Permite filtrar por `envejeciente_id`. |
| GET `/notificaciones-alerta` | Avisos propios de la cuenta. Permite filtrar por `estado` (no leída, leída o archivada) y ordenar por fecha o ID. |
| POST `/notificaciones-alerta/:notificacionId/leer` | Cuerpo vacío. Conserva la primera fecha de lectura. |

Avisos internos a Coordinadores y Administradores de Organización con permiso y acceso al caso. La generación de avisos de casos prioritarios respeta el ajuste de cuenta `notificar_casos_prioritarios`. El texto nuevo es genérico. Al consultar o marcar leído se comprueban el destinatario y el alcance vigente.

Las bandejas operativas consultan expedientes activos con consentimiento vigente. Al inactivar un expediente se conservan las alertas en su historial, consultable según alcance. El retiro del consentimiento conserva ese registro bajo custodia y lo excluye de las consultas operativas.

## Motor

- Riesgo alto genera una alerta por factor vigente de nivel alto. Medicamentos genera una alerta por ocurrencia con estado pendiente. Ambas fuentes tienen prioridad alta. Generación y aviso interno se realizan al registrar el cambio.
- Seguimiento familiar cuenta días calendario en Santo Domingo desde la última visita completada de la cuenta, o desde el alta si no existe. Usa `dias_sin_visita_alerta` efectivo, con valor predeterminado 15. El día 15 no genera; el día 16 sí. La evaluación diaria también cierra la alerta anterior cuando hubo una visita efectiva.
- El cambio de condición resuelve automáticamente una alerta abierta, con fecha y motivo. Resolver manualmente preserva la fuente. Solo otra ocurrencia de riesgo o medicamento, o una nueva ventana tras otra visita efectiva, puede generar una alerta nueva.
- Los [bloques 6a](../propuestas/fase-6a-alertas-consulta.sql) y [6b](../propuestas/fase-6b-alertas-motor.sql) conservan alertas históricas. El motor sustituye disparadores antiguos de generación y el índice que impedía más de una alerta del mismo tipo por adulto. Las alertas nuevas tienen una sola fuente y las funciones programadas son internas.

La migración operativa comprueba los catálogos, evalúa las fuentes que ya existen y programa un ciclo diario a las 00:05 de República Dominicana. Un operador puede repetir `select cuidared_interno.alertas_evaluar_diario();` sin duplicar alertas y revisar las ejecuciones en [Supabase Cron](https://supabase.com/docs/guides/cron). El estado de la instalación está en [CUIDARED-009](../CAMBIOS-SCHEMA-CUIDARED.md#cuidared-009--necesidades-y-alertas).
