# Registro de esquema de Suscripciones y Stripe Sandbox

Registro recibido de `origin/Integracion` el 25/11/2026. Se separa para conservar la eliminación local previa del documento histórico sin perder las entradas nuevas CUIDARED-013 a CUIDARED-018. Este pull no vuelve a aplicar las migraciones ni modifica Supabase.

## CUIDARED-018 — Verificación de la versión de la tarifa

**Estado: aplicado y verificado.** El usuario autorizó la aplicación con «Aprobar y aplicar en Supabase». Supabase CuidaRed registró la versión `20261125051832` el 25/11/2026. Alcance ID08 y RF-20. [Migración aplicada](../supabase/migrations/20261125051832_fase_8g_version_tarifas_stripe_cuidared_018.sql) · [Propuesta SQL](propuestas/fase-8g-version-tarifas-stripe.sql)

**Funciones y permisos.** `cuidared_interno.stripe_version_oferta()` deriva una versión opaca y estable para cada precio directo y conserva la versión de las cotizaciones publicadas. `cuidared_api.api_stripe_gestion()` devuelve la versión de cada oferta. `cuidared_interno.stripe_exigir_version()` valida la versión revisada antes de preparar un pago o cambio y mantiene la compatibilidad de clientes anteriores en tarifas directas. Un intento en curso conserva su precio. Las versiones se calculan en lectura y este cambio conserva tablas, RLS, datos y permisos de acceso.

**Verificación y reversión.** La prueba SQL local cubrió la publicación de una nueva tarifa, el rechazo de versiones antiguas en Checkout y en cambio de plan y la reanudación del intento original. En Supabase se confirmaron las seis ofertas existentes, sus seis versiones distintas, el uso de la función en Gestión y la ausencia de acceso anónimo al cálculo. Una reversión puede restaurar las dos definiciones del bloque anterior mediante una nueva migración.

## CUIDARED-017 — Contratación y cupos por organización

**Estado: aplicado y verificado.** El usuario confirmó conservar las funcionalidades de Operación Base, incluidas las visitas, y pactar todos los tipos de cupos para Gestión Comunitaria Avanzada. Autorizó la aplicación con «Aprobar y aplicar en Supabase». Supabase CuidaRed registró la versión `20261124052239` el 24/11/2026. Alcance ID08 y RF-20. [Migración aplicada](../supabase/migrations/20261124052239_fase_8f_planes_organizacion_cuidared_017.sql) · [Propuesta SQL](propuestas/fase-8f-planes-organizacion.sql)

**Tablas y datos.** `cuidared.stripe_oferta` incorpora `limites_cotizados` (JSONB con los cuatro cupos) y `version_cotizacion` (UUID único). `cuidared.stripe_cotizacion` incorpora los recuentos observados `usuarios` y `familiares`. Las columnas nuevas conservan nulos para los registros heredados. Las ofertas privadas de Base y las ofertas avanzadas anteriores sin cupos pactados dejan de aceptar nuevas contrataciones. Los registros, Price, suscripciones, pagos e intentos anteriores se conservan. Operación Base queda disponible para publicación mensual o anual, con su plan general y sus límites vigentes.

**Funciones y permisos.** El catálogo distingue ofertas generales y cotizadas. Los límites efectivos se leen del Price vinculado al contrato y se validan al contratar, programar cambios y registrar altas. Una nueva versión de una cotización conserva los términos del Price contratado. CuidaRed envía la versión que revisó el titular. Backoffice conserva la comprobación de superadministrador con MFA y la auditoría. Los nuevos campos se exponen mediante los RPC de suscripción y Backoffice. La propuesta conserva RLS y los permisos de las tablas y no agrega disparadores.

**Verificación y reversión.** Las pruebas SQL locales comprobaron la separación de modalidades, los cupos versionados, el aislamiento por cuenta y la aplicación de límites efectivos. En Supabase se confirmó que solo Avanzada es cotizable y que Operación Base conserva 15 adultos mayores, 20 integrantes y sus cuatro funcionalidades. Operación Base quedó sin tarifas publicadas. Antes de revertir tras aceptar una nueva suscripción, se debe preservar su Price y su capacidad pactada mediante una migración posterior.

## CUIDARED-016 — Excel y análisis avanzado en Cuidado Integral

**Estado: aplicado y verificado.** El usuario confirmó incluir Excel y el análisis avanzado en Cuidado Integral y autorizó la ejecución con «Aprobar y aplicar en Supabase». Supabase CuidaRed registró la versión `20261124040230` el 24/11/2026. Alcance RF-07, RF-08 y RF-20. [Migración aplicada](../supabase/migrations/20261124040230_fase_8e_reportes_integral_cuidared_016.sql) · [Propuesta SQL](propuestas/fase-8e-reportes-integral.sql)

**Datos y funciones.** Se agrega la capacidad `reportes_avanzados` al registro de Cuidado Integral en `cuidared.plan_funcionalidad`. La función interna `stripe_catalogo_modelo()` y los datos iniciales de Backoffice incluyen el mismo beneficio para instalaciones nuevas. La propuesta conserva precios, suscripciones, tablas, políticas y permisos. El acceso sigue sujeto a vigencia, rol y cuenta. Visitas es exclusivo de Organización.

**Verificación y reversión.** Las pruebas SQL locales comprobaron catálogo, contexto de cuenta, análisis y Excel con Cuidado Integral, así como las restricciones de Visitas y de rol. En Supabase se confirmó que una cuenta activa con Cuidado Integral tiene la capacidad efectiva y que los planes básicos conservan su configuración. Para revertir, una migración posterior debe retirar la capacidad del plan familiar y restaurar su definición en el modelo.

## CUIDARED-015 — Catálogo dinámico y cupo de cuidadores

**Estado: aplicado y verificado.** El usuario confirmó cinco cuidadores activos como cupo inicial de Básico Familiar y autorizó la aplicación con «Aprobar y aplicar en Supabase». Supabase CuidaRed registró la versión `20261123031023` el 22/11/2026 a las 11:10:23 p. m., hora de República Dominicana. La prueba de Familia toma el cupo del mismo plan. Cuidado Integral conserva cuidadores ilimitados. Alcance ID08 y RF-20. [Migración aplicada](../supabase/migrations/20261123031023_fase_8d_catalogo_cupos_cuidared_015.sql) · [Propuesta SQL](propuestas/fase-8d-catalogo-cupos.sql)

**Esquema y datos.** `cuidared.plan` agrega `limite_cuidadores` entero positivo y nullable. Básico Familiar requiere un valor. La propuesta conserva la configuración de los planes existentes, establece el cupo inicial y crea entradas informativas faltantes en entornos sin tarifas publicadas. No crea precios de Stripe, cobros ni membresías.

**Funciones y permisos.** El validador existente de membresías aplica el cupo al sumar cuidadores activos y conserva las plazas ya ocupadas si Backoffice reduce el límite. La contratación comprueba el uso frente al plan de destino. El catálogo por cuenta devuelve límites, beneficios y precios familiares de referencia a quienes tengan `cuenta:suscripcion`. Backoffice edita el cupo de Básico Familiar con `super_admin` y MFA. Cada modificación se audita. La consulta administrativa conserva las comprobaciones de sesión y permisos existentes.

**Verificación y reversión.** Las pruebas locales comprobaron las invitaciones pendientes, el bloqueo del sexto cuidador, la edición auditada, la actualización del catálogo y la autorización. En Supabase se confirmaron los cuatro planes activos, el valor cinco para Básico Familiar y las pruebas de Familia, Cuidado Integral sin cupo, la restricción validada y los permisos de ambas API. La cantidad de tarifas publicadas se conservó. Cualquier reversión alojada requiere revisión y aprobación para conservar los límites editados y la trazabilidad.

## CUIDARED-014 — Retiro del plan gratuito de Backoffice

**Estado: aplicado y verificado.** El usuario autorizó CUIDARED-014 con «Aprobar y aplicar en Supabase». CuidaRed registró la versión `20261123024158` el 22/11/2026 a las 10:41:58 p. m., hora de República Dominicana. La prueba gratuita queda como única modalidad sin pago y se retira la excepción de CUIDARED-013. Alcance ID08 y RF-20. [Migración aplicada](../supabase/migrations/20261123024158_fase_8c_retirar_plan_gratuito_cuidared_014.sql) · [Propuesta SQL](propuestas/fase-8c-retirar-plan-gratuito.sql)

**Origen e impacto.** La migración inicial de Backoffice creó los planes gratuitos de Familia y Organización. CUIDARED-013 detuvo la asignación automática y conservó las asignaciones existentes. La revisión de solo lectura confirmó dos cuentas familiares con plan gratuito, prueba vencida y sin pagos completados. El retiro cancela esa asignación y deja su suscripción vencida y su acceso operativo bloqueado. El estado administrativo, la membresía, las fechas de prueba y el historial se conservan.

**Objetos afectados.** `cuidared.cuenta` deja de referenciar el plan gratuito. Cuando una prueba sigue vigente, se conserva su fecha de fin. `cuidared.plan` conserva las filas históricas en estado inactivo y la restricción `ck_plan_gratuito_historico` impide reactivarlas. El trigger de validación existente rechaza asignar un plan inactivo. Se revoca la ejecución de `cuidared_api.api_bo_stripe_plan_gratuito` a los roles de aplicación. La auditoría de Backoffice registra cada retiro. Los planes pagados y la configuración de las pruebas quedan fuera del cambio.

**Verificación.** La prueba de PostgreSQL aislado cubrió tres asignaciones anteriores con prueba vencida, prueba vigente y suscripción suspendida. Las pruebas de suscripciones y Backoffice pasaron con el catálogo retirado. En Supabase se verificaron las dos familias sin plan, con suscripción vencida y acceso operativo bloqueado. Las fechas de prueba coinciden con el inventario previo. La restricción quedó validada, los dos planes están archivados, la RPC quedó revocada para los tres roles de aplicación y se registraron dos eventos de auditoría. Backoffice recibe el estado de suscripción vencida y el plan vacío.

**Reversión.** La transacción se detiene si detecta una vigencia pagada superpuesta o si falla un paso. Tras aplicarla, cualquier cambio de acceso requiere revisión y aprobación. Los registros de planes y auditoría quedan disponibles para consulta histórica.

## CUIDARED-013 — Suscripciones y pagos de prueba (fase 8)

**Aprobación.** El usuario autorizó la aplicación de los dos bloques de la fase 8 el 22/11/2026 con «Aplica los cambios de supabase». Alcance ID08, RF-20, RF-21 y CU-20. [Contrato de suscripciones](contratos/suscripciones.md)

La asignación gratuita conservada en este despliegue quedó sustituida en la regla de producto por [CUIDARED-014](#cuidared-014--retiro-del-plan-gratuito-de-backoffice).

**Estado: aplicado y verificado en Supabase CuidaRed el 22/11/2026.** Supabase registró estas versiones en el orden indicado. Las horas corresponden a República Dominicana y los identificadores de migración usan UTC.

| Bloque | Hora local | Migración registrada |
| --- | --- | --- |
| Suscripciones | 21:30:59 | [`20261123013059`](../supabase/migrations/20261123013059_fase_8_suscripciones_cuidared_013.sql) |
| Tarifas y cotizaciones de Backoffice | 21:31:42 | [`20261123013142`](../supabase/migrations/20261123013142_fase_8b_backoffice_cuidared_013.sql) |

El SHA-256 registrado en Supabase coincide con cada copia de la migración y con su propuesta original. [Propuesta de suscripciones](propuestas/fase-8-suscripciones.sql) · [Propuesta de Backoffice](propuestas/fase-8b-backoffice.sql)

| Tabla nueva | Campos |
| --- | --- |
| `stripe_oferta` | `price_id`, `codigo`, `plan_id`, `cuenta_cotizada_id`, `periodicidad`, `importe_centavos`, `moneda`, `divisor_moneda`, `activa`, `creada_en`. |
| `stripe_cliente` | `cuenta_id`, `titular_id`, `customer_id`. El cliente pertenece al pagador de esa cuenta. |
| `stripe_intento` | `intento_id`, `cuenta_id`, `titular_id`, `price_id`, `session_id`, `estado`, `creado_en`, `vence_en`. |
| `stripe_suscripcion` | `subscription_id`, `intento_id`, `cuenta_id`, `titular_id`, `customer_id`, `price_id`, `pendiente_price_id`, `schedule_id`, `estado`, `cancelacion_programada`, `gestionada`, `vigencia_hasta`, `snapshot_en`, `creada_en`, `actualizada_en`. |
| `stripe_cambio` | `cambio_id`, `subscription_id`, `titular_id`, `price_id`, `factura_id`, `schedule_id`, `modo`, `efectivo_en`, `estado`, `creado_en`. |
| `stripe_evento` | `evento_id`, `tipo`, `intento_id`, `fecha_proveedor`, `procesado_en`. Conserva la referencia idempotente del evento. |
| `stripe_reembolso` | `invoice_id`, `subscription_id`, `cargo_id`, `importe_centavos`. |
| `stripe_cotizacion` | `cuenta_id`, `codigo`, `solicitada_por`, `cuidadores`, `envejecientes`, `solicitada_en`, `publicada_por`, `publicada_en`. |

**Tablas existentes.** `pago` agrega `stripe_invoice_id`, `stripe_subscription_id`, `stripe_price_id`, `stripe_periodo_desde`, `stripe_periodo_hasta`, `stripe_cargo_id`, `stripe_importe_centavos` y `stripe_reembolsado_centavos`, con claves de referencia e índice único por factura. Los pagos manuales conservan sus campos. `metodo_pago` incorpora la fila «Stripe Sandbox». El registro de catálogo autorizado reutiliza `plan` y `plan_funcionalidad` y preserva las tarifas históricas.

**Funciones y disparadores.** `acceso_operativo` consulta la vigencia pagada de Stripe con precisión de instante y conserva la vigencia civil de los planes anteriores. `actualizar_vencimientos` registra los vencimientos sin asignar un plan gratuito. Las asignaciones gratuitas anteriores permanecen operativas. Se agrega una guarda de titularidad en `cuenta`. Los RPC autenticados consultan gestión, historial y cotizaciones y preparan Checkout, cambios, cancelación y transferencia. Los RPC de sistema asocian los objetos de Stripe, concilian eventos y validan el Backoffice. Backoffice publica tarifas y cotizaciones y puede conceder manualmente el plan gratuito. La activación de planes pagados se hace por conciliación de Stripe.

**Seguridad.** Las tablas nuevas tienen RLS y quedan detrás de RPC con permisos explícitos. Las operaciones de sistema son exclusivas de `service_role`. Las operaciones de cuenta comprueban sesión y membresía, además del titular en acciones comerciales. El almacenamiento conserva referencias y totales, con el mínimo de información necesario para conciliar.

**Verificación.** Los dos bloques pasaron `pruebas-8-suscripciones.sql` y `pruebas-8b-backoffice.sql` en PostgreSQL aislado con Auth simulado. El comando reproducible con PostgreSQL local es `npm run validar:sql -- --solo=suscripciones`. En Supabase se comprobaron los permisos de las 24 funciones de API, RLS y la ausencia de acceso directo de los roles de aplicación a las ocho tablas nuevas y a `pago`. Cuatro llamadas HTTPS sin sesión devolvieron HTTP 401. Se confirmó que el mantenimiento diario sigue activo, conserva las dos asignaciones gratuitas previas y ya no asigna ese plan automáticamente.

**Configuración de pruebas pendiente.** Al cierre de la verificación, Supabase tenía las cuatro tarifas familiares sugeridas, cero ofertas Stripe publicadas y cero pagos. La configuración del sandbox, la publicación del catálogo y la prueba de Checkout con conciliación por webhook siguen pendientes. [Guía de Stripe Sandbox](FASE-8-SANDBOX.md)

**Reversión.** Para detener el flujo, primero se pausa la creación de Checkout y las modificaciones del catálogo, se concilian los eventos y se revisan las renovaciones sandbox pendientes. Una reversión de esquema debe conservar los pagos y las referencias de auditoría y requiere aprobación.
