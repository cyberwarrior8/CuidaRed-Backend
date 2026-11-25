# Cambios actuales

## 25/11/2026 — Integración reciente y preparación del PR de visitas

- Actualizada la base desde `origin/Integracion` hasta `1226675`, con suscripciones y Stripe Sandbox. Se conciliaron configuración, rutas administrativas, pruebas y selección SQL con el trabajo local de visitas, correo y soporte. Las variables privadas se conservaron sin cambios.
- Los respaldos completos permanecen en Git stash. Se mantiene la eliminación local del documento histórico de esquema; las entradas nuevas CUIDARED-013 a CUIDARED-018 se conservan aparte en `docs/CAMBIOS-SCHEMA-SUSCRIPCIONES.md`. Este pull no aplica migraciones ni modifica Supabase.
- El PR selecciona únicamente visitas y sus dependencias de correo: SMTP con Nodemailer, diagnóstico, migraciones de recepción/buzón y confirmación/aportes. Los cambios locales de soporte y supervisión permanecen fuera del PR. No se incluyen archivos de entorno, credenciales, fotografías ni artefactos de pruebas.
- Verificación tras la combinación: ESLint y 1.375 pruebas aprobadas. La copia exacta del PR pasó 1.349 pruebas en 29 archivos. La entrega real de correos sigue pendiente de la contraseña de aplicación del dueño del Gmail.

## 23/11/2026 — Contacto externo, aportes y confirmación de visitas

- `src/modules/visitas/` incorpora contacto personal/institucional en programación, referencia de seguimiento generada en el servidor y confirmación positiva/negativa por Administrador o Coordinador después del fin. Registrar en campo conserva el informe pendiente; solo confirmar una realización modifica la última visita efectiva. La cuenta Familia permanece excluida.
- `src/modules/publico/` exige correo y fin de horario y permite observaciones desde el inicio de la visita. Las fotografías se validan, normalizan y guardan en un bucket privado, con cuotas e idempotencia. `src/app.js` amplía el límite JSON únicamente para esta carga; `src/lib/supabase-admin.js` limita las operaciones de Storage y RPC al alcance previsto.
- `avisos-visita.js` añade aviso al inicio con enlace a aportes, código reconstruido por HMAC y confirmación de realización. Los rechazos conservan el motivo. No se cambia el remitente ni se activa una cola sin credenciales.
- Aplicada en Supabase la migración `20261124032710_visitas_confirmacion_observaciones_evidencias` bajo la autorización previa del usuario. [Registro de esquema, permisos, alcance y comprobaciones](docs/CAMBIOS-SCHEMA-VISITAS.md).
- Validación: 1.341 pruebas en 28 archivos, ESLint global y Prettier de los archivos de esta entrega correctos. La prueba HTTP verifica la carga de fotografía mayor de 16 KB manteniendo el límite general para consultas y descargas. La prueba SQL alojada con datos sintéticos y ROLLBACK pasó programación, rechazo, avisos, aportes, aislamiento, confirmación positiva/negativa, fechas efectivas y exclusión de Familia/Cuidador. Se actualizan las pruebas SQL locales al nuevo contrato y su selector de migraciones; no se ejecutó esa batería local porque falta PostgreSQL/psql.
- Pendiente externo: `npm run visitas:correo` detecta que falta la contraseña de aplicación del Gmail y la cola está pausada. [Pasos exclusivos del propietario](docs/ACTIVAR-CORREO-PROYECTO.md). No se enviaron correos ni se cargaron fotografías reales. Sin commits ni push en esta entrega.

## 25/11/2026 — Revisión de la compra y pruebas de Stripe

- `src/modules/suscripciones/` conserva el indicador de plan cotizable en el catálogo y devuelve mensajes específicos si vence Checkout o si un intento incierto sigue reservado. Se mantiene la clave de idempotencia del mismo intento al reintentar con Stripe.
- La API comprueba los identificadores del precio, la sesión y la suscripción antes de actuar. Las solicitudes de cotización se auditan después de validar su respuesta.
- CUIDARED-018 devuelve y verifica la versión de las tarifas directas. Las pruebas SQL cubrieron el rechazo de precios desactualizados al comprar y cambiar de plan, y la reanudación con el precio original. Se aplicó `20261125051832` con aprobación y se verificaron las seis ofertas en Supabase.
- `docs/stripe/README.md` documenta la configuración local, la publicación, el recorrido de pago y los resultados esperados. Está enlazado desde el README principal.
- Pasaron 1314 pruebas del backend y las suites SQL locales de fases 7 y 8.

## 24/11/2026 — Contratación y cupos de planes de Organización

- `src/modules/suscripciones/` y `src/modules/backoffice/` distinguen la tarifa directa de Operación Base y la cotización de Gestión Comunitaria Avanzada. La cotización liga precio, periodicidad y cuatro cupos a una versión por organización.
- La propuesta SQL de CUIDARED-017 aplica los términos de la versión asociada al contrato y conserva los registros e intentos anteriores. Su estado figura en `docs/CAMBIOS-SCHEMA-CUIDARED.md`.
- Pasaron 1309 pruebas de backend y las pruebas SQL locales de fases 7 y 8. Se aplicó la migración `20261124052239` con aprobación y se verificó el catálogo en Supabase.

## 24/11/2026 — Reportes avanzados en Cuidado Integral

- `docs/propuestas/fase-8e-reportes-integral.sql` añade Excel y análisis avanzado a Cuidado Integral. El catálogo y la autorización consultan la misma capacidad del plan. Visitas sigue siendo exclusivo de Organización.
- `docs/verificacion/local/pruebas-8-reportes-integral.sql` cubre los beneficios del plan, la exportación y los límites por rol y tipo de cuenta.
- Migración `20261124040230` aplicada con aprobación y capacidad efectiva verificada en Supabase. Pasaron las pruebas SQL locales de reportes de Cuidado Integral y suscripciones.

## 23/11/2026 — Disponibilidad de publicación de tarifas

- La API de tarifas y cotizaciones de Backoffice informa si falta activar Stripe Sandbox o asociar sus productos. Conserva el rechazo de las escrituras mientras falte configuración.
- Pasaron 31 pruebas HTTP de Backoffice y Suscripción, incluida la publicación de una tarifa con Stripe simulado y el rechazo cuando falta configuración.

## 22/11/2026 — Catálogo de suscripción y cupo de cuidadores

- `src/modules/suscripciones/` consulta el catálogo desde el servidor, separado de las ofertas publicadas en Stripe Sandbox.
- Backoffice guarda y audita el cupo de Básico Familiar. Cinco cuidadores activos es el valor inicial, también para la prueba de Familia. El servidor limita altas y cambios de rol al sumar una plaza.
- El cambio de base se registra en [CUIDARED-015](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-015--catálogo-dinámico-y-cupo-de-cuidadores).
- Se aplicó en Supabase como `20261123031023`. La verificación incluyó 29 pruebas HTTP de Suscripción y Backoffice, pruebas SQL aisladas y la comprobación de valores y permisos en Supabase.

## 22/11/2026 — Retiro del plan gratuito

- Se retiró el endpoint administrativo de asignación de plan gratuito de `src/modules/suscripciones/`. Las pruebas vencidas quedan fuera de los módulos operativos salvo una vigencia pagada confirmada.
- Supabase aplicó y verificó CUIDARED-014 como `20261123024158`. Se archivaron los planes gratuitos y las dos familias afectadas quedaron sin plan y con suscripción vencida. Sus fechas de prueba se conservaron y los ajustes quedaron auditados. [Cambios de esquema](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-014--retiro-del-plan-gratuito-de-backoffice)
- Validación completada con 28 pruebas HTTP de suscripción y Backoffice, pruebas de PostgreSQL aislado y compilación de Backoffice.

## 22/11/2026 — Fase 8, suscripciones y pagos de prueba

- Se agregó el módulo `src/modules/suscripciones/` para consultar catálogo, cotizaciones e historial, iniciar Checkout, prorratear aumentos y programar bajas de plan, cambios de ciclo o cancelaciones. Las acciones comerciales requieren titularidad, incluso con acceso operativo vencido.
- El webhook conserva los bytes firmados, valida el modo Sandbox y la relación entre cuenta y objetos del proveedor. La base registra un solo pago por factura y aplica la vigencia tras conciliación.
- El flujo de titularidad programa primero el fin de la renovación asociada a la persona saliente. Las facturas históricas mantienen al pagador original.
- Se incorporaron tarifas en USD y cotizaciones por cuenta desde Backoffice. El primer despliegue desactivó la asignación automática del plan gratuito. El retiro posterior se registra en CUIDARED-014.
- Se prepararon el importador de los cuatro Price familiares, las pruebas HTTP y SQL y la documentación de operación. Supabase registró las migraciones `20261123013059` y `20261123013142` tras la aprobación del usuario. [Registro de esquema](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-013--suscripciones-y-pagos-de-prueba-fase-8) · [Contrato de suscripciones](docs/contratos/suscripciones.md) · [Guía Sandbox](docs/FASE-8-SANDBOX.md)
- Validación local del backend: ESLint, 1.300 pruebas Vitest/Supertest y los dos bloques SQL en PostgreSQL aislado. La prueba de pago conectada queda pendiente de configurar el sandbox y publicar el catálogo.

## 21/11/2026 — Correcciones de Reportes y seguimiento por visitas

- Resumen y Reportes consultan las opciones de filtros de todo el alcance autorizado. Las dos rutas usan una RPC con permisos por cuenta y requisitos de plan por módulo.
- El reporte de visitas cuenta las institucionales completadas por separado. Las atenciones se calculan sobre los expedientes asociados. El informe médico excluye las indicaciones que aún no han comenzado.
- CUIDARED-012 limita el seguimiento por días sin visita a Organización. Familia conserva su historial. La reconciliación existente resuelve las alertas automáticas abiertas con fuente verificable de las cuentas Familia operativas.
- Validación local: 1.280 pruebas del backend, seis bloques SQL y recorrido de la API con PostgreSQL aislado.
- Aplicación autorizada por el usuario y registrada en Supabase el 21/11/2026 como `20261121064256`. Se comprobó el SQL aplicado, los permisos y el cálculo de ausencia por tipo de cuenta. [Registro CUIDARED-012](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-012--reportes-fase-7)

## 20/11/2026 — Fase 7 (Reportes) y cierre de código de la fase 6

**Decisiones del usuario:** formatos CSV y PDF, con Excel solo en el plan avanzado; matriz de permisos actual con el plan comprobado en el servidor; informe médico con el contenido del prototipo. Lo que no definen V2 ni el SRS queda como propuesta técnica D20–D22 en `CONTEXTO-BACKEND.md`.

- **Reportes (fase 7):** el módulo nuevo `src/modules/reportes/` tiene rutas, esquemas Zod, servicio, repositorio y CSV, montados en `src/app.js` bajo `/api/v1/cuentas/:cuentaId`:
  - Resumen de casos (RF-07) con indicadores. Distingue alertas abiertas de adultos prioritarios.
  - Cuatro reportes estadísticos (RF-08): adultos, visitas, necesidades y casos prioritarios.
  - Análisis avanzado por zona, municipio y mes.
  - CSV auditado y registro previo de PDF/Excel.
  - Informe médico por adulto.
  - Todas las respuestas llevan `Cache-Control: no-store` y `Content-Disposition` queda expuesto por CORS. Contrato: [reportes](docs/contratos/reportes.md).
- **Auditoría:** `GET /auditoria` muestra las exportaciones y los informes con la acción `exportacion` (`src/modules/cuentas/cuenta-routes.js`).
- **SQL de Reportes:** la propuesta inicial quedó revisada y aplicada el 21/11/2026. El validador `npm run validar:sql -- --solo=reportes` usa la migración aplicada y las pruebas `docs/verificacion/local/pruebas-7-*.sql`. [Registro CUIDARED-012](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-012--reportes-fase-7)
- **Alertas (fase 6):** `tests/alertas.test.js` pasa de 3 a 59 casos (filtros, orden, detalle, atención, resolución por rol, avisos, lectura, casos prioritarios, permisos, UUID y cuenta vencida). No se encontraron fallos en `src/modules/alertas/`. Nuevo [guion de prueba manual](docs/verificacion/manual-fase-6-alertas.md) por rol, todavía sin ejecutar.
- **Por confirmar:** la evaluación de ausencia de visitas (RF-05) no distingue el tipo de cuenta. Como Familia ya no tiene Visitas, sus adultos tendrían una alerta de seguimiento a los 16 días que solo se cierra a mano.
- **Revisión independiente:** las tendencias se recortan al periodo pedido. Los filtros con valor nulo se aceptan igual en Express y en SQL. Las métricas de visitas del análisis avanzado salen nulas sin `visitas:ver`. Los códigos de catálogo antiguos del informe pueden ser nulos. El CSV neutraliza fórmulas después de espacios y con signos de ancho completo. Las consultas se reescribieron por cuenta en lugar de por adulto.
- **Validación:** `npm run lint` sin errores, 25 archivos y 1277 pruebas aprobadas, y Prettier en los archivos tocados. `validar:sql` pasó con `--solo=reportes`, `fases-5-6`, `visitas`, `web-push`, `cierre` e `integracion`. Con 2.000 adultos y 6.000 visitas, la consulta más lenta tardó 147 ms; la prueba de carga falla si alguna llega a 1,5 s.

## 19/11/2026 — Integración de visitas y Backoffice

- La API combina las visitas programadas, el seguimiento de solicitudes y la validación de evidencias con Backoffice, la sesión protegida del navegador, alertas y Web Push. El formulario público se habilita por entorno.
- Se confirma que Visitas y Solicitudes operan solo para Organización. Las series conservan la autorización previa y requieren un plan habilitado. El contrato de sincronización documenta la recuperación de visitas pendientes en el mismo navegador.
- Las verificaciones locales cubren roles, permisos, sincronización idempotente y el cierre de expedientes con consentimiento retirado.

## 17/11/2026 — Recuperación del envío de solicitudes

- Se comprobó una interrupción de transporte entre Express y Supabase. El catálogo y la creación permiten un reintento limitado. La creación mantiene la huella y la base evita duplicar la solicitud y sus notificaciones.
- El formulario conserva un identificador por intento. El servidor deriva el código con el secreto de seguimiento para recuperarlo al repetir el envío con los mismos datos. La migración `20261118024823_solicitudes_visita_reintentos.sql` quedó aplicada y verificada con `service_role` en una transacción revertida.
- Se retiraron las instancias duplicadas de pruebas del backend. El arranque informa el puerto ocupado como error. La ruta pública local volvió a responder con la validación esperada.
- Validación final con 1,089 pruebas del backend, 114 de acceso conectado y 113 de componentes. Compilación y comprobaciones de caché y apertura offline correctas. Las pruebas SQL verificaron el envío y la repetición con `service_role` y revirtieron los datos sintéticos.

## 17/11/2026 — Visitas personales e institucionales

- El formulario público distingue visitas a una persona mayor y visitas de instituciones o grupos. Recoge el nombre y tipo de entidad, el contacto responsable, el número de visitantes y la actividad o aporte previsto. La coordinación confirma la disponibilidad al revisar la solicitud.
- El recorrido se distribuye en tres pasos cortos. En escritorio con ratón, los campos y botones tienen 40 px de alto, con texto de 14 px. En pantallas táctiles conservan 48 px y campos de 16 px. La tipografía sigue siendo Inter y los iconos son Lucide.
- La aprobación institucional asigna al responsable y agenda el horario. El equipo puede registrar un informe general, adjuntar evidencias, sincronizar y cerrar la visita. Se conserva la observación posterior del visitante.
- La migración `20261118014628_visitas_institucionales.sql` quedó aplicada y verificada en Supabase con datos sintéticos revertidos. También pasó la prueba de PostgreSQL local. Las visitas personales existentes conservan su recorrido.

## 17/11/2026 — Activación del formulario conectado de visitas

- `supabase/migrations/20261117035328_visitas_seguimiento_organizacional.sql` incorpora la compatibilidad con las fases ya alojadas y quedó registrada como aplicada en Supabase CuidaRed. Se verificaron las restricciones de expedientes retirados, sincronización y acceso a la cola.
- `VISITAS_PUBLICAS_HABILITADAS` quedó habilitada en el entorno local. La portada conserva visible el formulario si no hay organizaciones operativas y deja el envío deshabilitado hasta que el catálogo tenga opciones. Pasos de activación y correo en [Visitas y seguimiento comunitario](docs/VISITAS-ORGANIZACION.md).
- El catálogo reintenta una interrupción de Supabase. Al asignar responsables, el portal muestra cómo activar un perfil de cuidador y la API informa de ese requisito si el perfil deja de estar activo. El recorrido de visitas se verificó en el proyecto alojado con una transacción revertida, sin entregar correos.
- El formulario público usa Inter, etiquetas de 14 px, campos y botones de 16 px y objetivos táctiles de 48 px. Las columnas responden al ancho del formulario. El acceso y el registro incluyen regreso a la sección de la portada de origen.
- Validación funcional con 1,086 pruebas del backend, 110 de acceso conectado, 113 de componentes y 101 unitarias del frontend. La migración y las verificaciones de solicitudes, autorizaciones, evidencias y sincronización pasaron en PostgreSQL local. El correo real queda pendiente de `VISITAS_RESEND_API_KEY` y `VISITAS_CORREO_REMITENTE` del propietario.

## 16/11/2026 — Seguimiento de visitas en organizaciones

- El portal y la API distinguen solicitud pública, programación, autorización, reprogramación, registro de campo e historial. Las cuentas de tipo Familia conservan sus tareas de cuidado y quedan fuera del módulo institucional.
- El responsable trabaja con capturas IndexedDB, sincronización UTC y evidencias privadas. Coordinación revisa evidencias y la agenda admite tareas vinculadas a una visita.
- La migración de `supabase/migrations/` se verificó en PostgreSQL local con roles simulados. El backend entrega los avisos mediante una cola transaccional. Configuración y verificación en [Visitas y seguimiento comunitario](docs/VISITAS-ORGANIZACION.md).

## 16/11/2026 — Visitas públicas desde la portada

- `src/app.js`, `src/config/env.js`, `src/modules/publico/` y `src/lib/supabase-admin.js` incorporan el recorrido público activable por entorno. El visitante usa el código para consultar su solicitud y dejar una observación después del cierre por coordinación.
- [Propuesta SQL y estado de aplicación](docs/CAMBIOS-SCHEMA-CUIDARED.md#visitas-públicas--16112026). Validado en un PostgreSQL aislado con datos sintéticos y verificación de permisos. Incorporado posteriormente a la migración de seguimiento organizacional.

## 17/11/2026 — Integración de Backoffice con las fases 5 y 6

- La aplicación monta Backoffice, la sesión de navegador y Web Push. La recuperación de sesión también respeta el bloqueo de cuentas del Backoffice.
- Supabase recibió la corrección de compatibilidad. El mantenimiento de Backoffice usa el motor de alertas con fuente obligatoria y se ejecutó con éxito después del cambio.
- Las pruebas nuevas de Familia y Organización vuelven a durar 168 horas desde el alta. Se verificó que las fechas de las pruebas existentes coinciden con las de antes del ajuste. [Migraciones y verificación](docs/CAMBIOS-SCHEMA-CUIDARED.md#compatibilidad-del-mantenimiento-con-las-alertas-de-seguimiento).

## 17/11/2026 — Sesión al reabrir CuidaRed

- `src/modules/access/` recupera sesiones vigentes desde una cookie cifrada de acceso restringido. Cada recuperación revalida la sesión en Supabase y conserva el vencimiento máximo original de la aplicación.
- [Rutas y configuración](docs/FASE-1-PERFIL-Y-ACCESO.md#recuperación-en-el-mismo-navegador).

## 17/11/2026 — Alertas por necesidades prioritarias

- CUIDARED-011 se aplicó en Supabase como migración `20261117044316`. Agrega alertas por necesidades pendientes de prioridad alta, con cierre automático y avisos a gestores. La evaluación inicial generó una alerta de Transporte y un aviso al administrador autorizado. Los medicamentos pendientes conservan su alerta específica.
- [Registro de esquema y validación](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-011--alertas-por-necesidades-prioritarias).

## 17/11/2026 — Configuración local del emisor Web Push

- El entorno local utiliza el contacto VAPID del piloto y una pareja de claves guardada en su configuración privada. El [contrato](docs/contratos/web-push.md#prueba-en-la-misma-computadora) incluye la prueba con frontend y API en `localhost`.

## 16/11/2026 — Envío Web Push y migración CUIDARED-010

- El motor encola avisos nuevos por dispositivo y el emisor `npm run web-push:worker` cifra, entrega y reintenta. Se vuelve a comprobar el acceso antes de reservar la entrega.
- Supabase recibió la migración `20261116043610`. Pasaron la prueba transaccional remota sin envíos externos y las pruebas SQL locales de reservas, revocación e inactividad. El emisor queda apagado hasta configurar el contacto VAPID.

## 16/11/2026 — Inicio de Web Push

- Se agregó el contrato para activar o revocar avisos por navegador y la propuesta de persistencia de suscripciones. Ver [CUIDARED-010](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-010--suscripciones-web-push).
- Las pruebas HTTP comprueban sesión, validación y revocación. En PostgreSQL local se verificaron la propiedad de la suscripción, su revocación idempotente y la ausencia de acceso directo.
- La función viene desactivada. El envío en segundo plano y la aplicación de la propuesta en Supabase quedan pendientes.

## 15/11/2026 — Fases 5 y 6 aplicadas en Supabase

- Las migraciones `20261115231642` y `20261115231810` registran el esquema de Necesidades y Alertas y el trabajo diario. Ver [CUIDARED-009](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-009--necesidades-y-alertas).
- La prueba transaccional verificó sincronización, precisión, alertas por fuente, avisos, cierre y auditoría. Los datos de prueba se revirtieron. La evaluación inicial dejó una alerta y un aviso para datos existentes.
- El validador local excluye las migraciones consolidadas de CUIDARED-009 al probar los cinco bloques por separado.

## 15/11/2026 — Revisión de las fases 5 y 6

- Necesidades devuelve el estado del expediente y mantiene los permisos y el cupo al sincronizar. La cola recupera rechazos propios y un límite del plan afecta solo a la operación correspondiente. La propuesta SQL protege el avance de la versión que usa el conflicto offline.
- La propuesta de Necesidades conserva los decimales enviados por la API y admite unidades de hasta 64 caracteres, según la decisión del 15/11/2026.
- Alertas comprueba la consistencia de la fuente, excluye expedientes inactivos o retirados de las bandejas y muestra el actor de atención autorizado. El motor distingue visitas completadas del mismo día por su hora efectiva.
- La propuesta de auditoría guarda referencias sin copiar descripciones ni motivos y la programación diaria evalúa los datos existentes al activarse. Ver [CUIDARED-009](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-009--necesidades-y-alertas).
- Validación local con 1.091 pruebas del backend y pruebas SQL de los cinco bloques. La primera evaluación y programación se verificaron con Cron simulado.

## 15/11/2026 — Inicio de las fases 5 y 6

- `src/modules/necesidades/` conecta catálogo, alta de ocurrencias, prioridades, responsables, estados e historial conforme a V2 y RF-03.
- `src/modules/sync/` recibe altas y cambios de estado con reintentos idempotentes y resolución de conflictos de RF-10.
- `src/modules/alertas/` conecta alertas, casos prioritarios por adulto y avisos internos. El motor propuesto cubre las tres fuentes aprobadas. Ver [contrato](docs/contratos/alertas.md).
- Las propuestas SQL y la programación diaria se documentan en [CUIDARED-009](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-009--necesidades-y-alertas). Quedan en local para revisión.
- Validación local: 1.090 pruebas de backend, ESLint, formato de los archivos JavaScript modificados y cuatro escenarios SQL de fases 5 y 6 en PostgreSQL desechable con Auth simulado.

## 13/11/2026 — Correcciones de las fases 2 a 4

- `src/modules/cuentas/` y `src/modules/miembros/`: vencimiento en el resumen, reenvío de invitaciones pendientes, preservación del empleador global y consulta de auditoría.
- `src/modules/envejecientes/` y `src/modules/seguimiento/`: retiro con constancia, controles de alcance, cinco factores y adjuntos médicos privados.
- `src/modules/visitas/` y las propuestas de persistencia: series autorizadas, límites de captura del Voluntario e historial con responsable. El flujo público sigue cerrado.
- [Alcance y validación del esquema](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-008--correcciones-de-las-fases-2-a-4). SQL verificado localmente y aplicado con aprobación en Supabase como migración `20261114022629`. Pasaron 1,071 pruebas de backend.

## 09/11/2026 — Fases 2 a 4 aplicadas en Supabase

- Se aplicaron los nueve bloques y se archivaron en `supabase/migrations/`. Los ajustes de compatibilidad conservaron los índices equivalentes, reemplazaron las reglas anteriores de prueba y horas de visita, y permitieron reconocer la PK original de `vinculo`.
- La verificación de cuentas, expedientes, visitas, sincronización y agenda pasó en el proyecto Supabase mediante una transacción con datos sintéticos revertidos. El registro de permisos y versiones está en [CUIDARED-007](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-007--aplicación-de-fases-2-a-4-en-supabase).
- Se habilitó en Auth el autorregistro con confirmación por correo. La plantilla de alta usa el código de seis dígitos con vigencia de quince minutos.

## 08/11/2026 — Revisión de las propuestas de esquema para fases 2 a 4

- Los SQL de 2a, 2c y 3b conservan las fechas de prueba previas y los periodos de asignación y autorización. El bloque 3a valida cédulas, contactos y consentimientos antes de confirmar sus cambios.
- Los bloques 4a y 4b aíslan las visitas sin cuenta verificable y preservan la agenda y evidencias anteriores. El servicio de agenda devuelve el historial sin firmar enlaces de archivos históricos.
- El [inventario del esquema](docs/PROPUESTA-SCHEMA-CUIDARED-FASES-2-A-4.md) detalla las siete tablas nuevas y los campos, funciones y triggers propuestos. Validación con 1,068 pruebas del backend y regresiones PostgreSQL con datos sintéticos previos. [Registro CUIDARED-006](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-006--conservación-de-datos-previos-en-fases-2-a-4).

## 07/11/2026 — Integración de fases 2 a 4

- Perfil independiente de las RPC de cuentas, colecciones propias paginadas, contexto por cuenta e IDs bigint como texto en los módulos integrados.
- Autorización en Express y SQL, prueba automática de 168 horas, cupos de membresías activas, perfil global, transferencia de titularidad y catálogos aprobados. Visitas programadas y autorizadas tanto en línea como al sincronizar. Evidencias privadas de visita con alcance sobre todos los adultos.
- Se conectaron en el frontend del equipo las pantallas de cuentas, expedientes, visitas y agenda. La cola de visitas se limita a la sesión de la pestaña.
- [Contratos y validación](docs/INTEGRACION-FASES-2-A-4.md). [Registro de propuestas de esquema](docs/CAMBIOS-SCHEMA-CUIDARED.md#cuidared-005--propuesta-integrada-de-fases-2-a-4). Sin aplicación remota.

## 07/11/2026 — Borrador de integración territorial

- Se incorporaron los archivos locales del catálogo ONE 2021, sus pruebas, las dos copias auditadas del SQL histórico y la verificación de solo lectura.
- `scripts/validar-propuestas-local.js` limita la selección a los bloques de esquema 2a–4c, separando la carga territorial de los fixtures del ejecutor. Usa `fileURLToPath` para rutas de Windows con espacios. `.gitattributes` conserva LF en los dos SQL históricos para mantener la huella publicada.
- Validación local del catálogo, reproducción de su SQL, comprobación SHA-256 y pruebas Vitest de territorio. No se ejecutó el validador PostgreSQL ni se aplicó SQL.

## 2026-11-06 — Fases 2 a 4: Organización, Envejecientes, Visitas y Seguimiento

**Propósito:** el usuario pidió terminar lo que faltaba de la fase 2 y llegar hasta la fase 4 de las ocho. Confirmó dos decisiones nuevas: **prueba gratuita fija de 7 días** (a nivel de cuenta, sin plan) y **autorregistro del titular** para crear su Familia u Organización, que sustituye el «solo invitaciones» de la fase 1 (D17). Todo el SQL son **propuestas sin aplicar** en `docs/propuestas/fase-2a…4c-*.sql`, validadas en un PostgreSQL local desechable. No se escribió nada en Supabase, no se cambió la configuración Auth ni se crearon buckets. Lo que no definen V2 ni el SRS se marca como «Propuesta técnica» en cada contrato y queda para confirmación.

### Base compartida (2a)

- `src/lib/business-errors.js`: códigos de negocio `CR_*` en lista cerrada (`CR_CUENTA_SIN_ACCESO` 403, `CR_LIMITE_PLAN` 409, `CR_ROL_NO_PERMITIDO` 422, `CR_ESTADO_INVALIDO` 409, `CR_CONFLICTO` 409); cualquier otro `P0001` sigue cayendo en el error genérico.
- `src/modules/access/supabase-gateway.js`: `rpc` genérica para nombres `api_*` con el mapeo de CR-162; cliente `publico()` con la clave publicable y solo para `api_publico_*`; Storage privado con URLs firmadas usando el JWT del usuario.
- `src/lib/supabase-admin.js` y `SUPABASE_SECRET_KEY` opcional: cliente privilegiado aislado, solo para invitar identidades nuevas (CR-160). Sin la clave, la invitación de personas sin cuenta Auth responde 503; el resto funciona.
- `src/modules/cuentas/permisos.js`: matriz V2 de 5 roles × acciones con ajustes por tipo de cuenta (propuesta D04) y `scripts/generar-permisos-sql.js`, que genera la siembra `rol_permiso` del SQL para que API y base no se desalineen.
- `src/modules/cuentas/require-cuenta.js` y `src/app.js`: rutas por cuenta en `/api/v1/cuentas/:cuentaId` con `requireCuenta` (contexto desde `api_contexto_cuenta`, nunca desde el cliente), `requirePermiso` y `requireAccesoOperativo` (D07: cuenta vencida solo conserva cuenta y suscripción). El router público va antes de `requireSession`.
- `fase-2a-base.sql`: códigos de tipo de cuenta, categorías V2, roles, prioridades, planes V2 (Básico Familiar, Cuidado Integral, Operación Base, Gestión Comunitaria Avanzada) con funcionalidades (CR-157), `cuenta.plan_id` nulo durante la prueba, restricción de 7 días, membresía vigente única, `cuidador.cuenta_id`, parámetros, `rol_permiso`, esquema interno `cuidared_interno` (sesión, acceso operativo, permisos, alcance por adulto) y `api_contexto_cuenta`, `api_mis_cuentas` y `api_sesion` sin exigir invitación.

### Cuentas, configuración y suscripción (2b)

- `POST /cuentas` (autorregistro: el titular queda Coordinador en Familia o Administrador en Organización, cuenta en prueba de 7 días), `GET /me` con `cuentas` (CR-164), `GET/PATCH /cuentas/:id`, `/configuracion` (RF-19) y `/suscripcion` (RF-20, con límites, uso y planes).
- `GET /catalogos/:catalogo` con caché en memoria y lista permitida de catálogos (CR-165).
- `fase-2b-cuentas.sql`: 7 RPC y `actualizar_vencimientos()`. Las invitaciones pendientes **reservan cupo** del plan.
- Contrato: `docs/contratos/cuentas.md`.

### Miembros, roles, titularidad y Cuidador (2c)

- Invitar (correo, cédula, nombres y rol; si la identidad no existe se invita con el cliente privilegiado), aceptar o rechazar desde `/me/membresias`, cambiar rol con historial (la membresía anterior se cierra y se crea otra), desactivar/reactivar, transferir titularidad y perfil de Cuidador vinculado a la membresía (RF-12).
- En Familia el Coordinador gestiona accesos; los roles permitidos dependen del tipo de cuenta y se validan también en la base.
- `fase-2c-miembros.sql`: 13 RPC con bloqueo de fila para límites y concurrencia. Contrato: `docs/contratos/miembros.md`.

### Adultos mayores (3a)

- Expediente con cédula obligatoria y única en toda la plataforma (D09, también ante altas concurrentes y sin revelar la cuenta ajena), consentimiento obligatorio, exactamente un contacto principal de emergencia (RF-17) y cambio de estado con motivo (CR-172).
- Lectura por nivel: datos sensibles solo para quien tiene `adultos:ver-sensible`; Cuidador y Voluntario solo ven adultos asignados; Familiar solo con permiso explícito.
- `fase-3a-envejecientes.sql`: 10 RPC. Contrato: `docs/contratos/envejecientes.md`.

### Seguimiento: asignaciones, riesgo, indicaciones e historial (3b)

- Asignar Cuidador y Voluntario, autorizar o revocar Familiar responsable (RF-12, RF-13).
- Riesgo (D11): cuestionario de 100 puntos con pesos 30/40/30 y niveles 0–29/30–54/55–100; el nivel vigente es el máximo de los factores vigentes y, sin factores, «Sin evaluación vigente».
- Indicaciones médicas restringidas (RF-15) e historial consolidado paginado (CU-06).
- `fase-3b-seguimiento.sql`: 14 RPC y una tabla nueva. Contrato: `docs/contratos/seguimiento.md`.

### Visitas y solicitudes externas (4a)

- Programar (requiere programar y autorizar: Coordinador en Familia; Administrador o Coordinador en Organización, D05), iniciar, registrar realización y cancelar. Solo las visitas realizadas cuentan como contacto.
- Solicitudes de visitantes externos por `/api/v1/publico` sin sesión: solo organizaciones con acceso operativo, nunca familias. El código `VIS-XXXX-XXXX` se entrega una sola vez y a la base solo llega su huella **HMAC-SHA256** con `CODIGO_SEGUIMIENTO_SECRETO` (nuevo en `src/config/env.js`, obligatorio en producción; SHA-256 simple en desarrollo). Los datos del visitante viven solo en `solicitud_visita`, no en las notas de la visita.
- `fase-4a-visitas.sql`: 14 RPC y una tabla nueva. Contrato: `docs/contratos/visitas.md`.

### Agenda, tareas y evidencias (4b)

- Tareas con responsable, estados y cancelación; evidencias en bucket privado `evidencias` (5 MB; JPEG, PNG, WebP o PDF; ruta `cuenta/<id>/tarea/<id>/<uuid>.<ext>`) mediante URL firmada. Una tarea que exige evidencia no se completa sin una evidencia **validada** (D12).
- `fase-4b-agenda.sql`: 12 RPC y políticas de Storage. Se detiene si `tarea_agenda` o `evidencia` ya tienen filas. Contrato: `docs/contratos/agenda.md`.

### Sincronización sin conexión (4c, RF-10)

- `POST /cuentas/:cuentaId/sync` (`sync:usar`): lote de 1 a 25 operaciones de visita (`registrar` o `iniciar`), procesadas en orden y cada una en su propia RPC y transacción; responde un resultado por operación (`aplicada`, `duplicada`, `conflicto` o `rechazada`). `GET /cuentas/:cuentaId/sync/:idCliente` devuelve el resultado guardado de una operación propia.
- Idempotencia por `id_cliente` en la tabla nueva `operacion_sync` (no guarda el contenido); Last-Write-Wins con marcas UTC en milisegundos, empate a favor del servidor, marcas de más de 5 minutos en el futuro rechazadas y visitas cerradas inmodificables. Permisos revalidados en cada operación; con la cuenta vencida cada operación sale `rechazada` con `SUBSCRIPTION_INACTIVE` y se puede reintentar al renovar.
- `src/app.js`: solo `/api/v1/cuentas/:cuentaId/sync` admite cuerpos de hasta 256 kB; el resto de la API sigue en 16 kB.
- `fase-4c-sync.sql` (depende de 2a, 3b y 4a): 2 RPC y una tabla nueva. Contrato: `docs/contratos/sync.md`. Todo lo de D16 es propuesta técnica. Falta una prueba de concurrencia con dos sesiones antes de aplicar.

### Validación local

- `scripts/validar-propuestas-local.js` (`npm run validar:sql`): crea una base desechable con nombre propio, carga un esquema `auth` simulado, `DB.sql`, la migración de fase 1, las propuestas y las pruebas `docs/verificacion/local/pruebas-*.sql`, y la borra al terminar. Rechaza cualquier host que no sea local.
- **Resultado:** 16 archivos y 1072 pruebas backend aprobadas, ESLint sin errores, Prettier en los archivos nuevos y validación SQL completa (propuestas 2a–4c y 21 archivos de pruebas SQL) sin errores. No se usó ninguna base ni cuenta real.
- Frontend hermano (PR #3): autorregistro, invitaciones, resumen de cuenta y miembros en el acceso conectado, con 84 pruebas de acceso aprobadas.

### Pendiente de aprobación antes de aplicar

- Revisar y aplicar las propuestas SQL en orden (2a → 4c).
- Conceder `USAGE` sobre `cuidared_api` al rol `anon` solo para las RPC `api_publico_*`.
- Configuración Auth: habilitar registros, plantilla de código OTP de alta y MFA.
- Crear el bucket privado `evidencias` y cargar provincias/municipios en remoto.
- Confirmar `POST /visitas/realizada` (visita realizada sin programar), que choca con la «programación previa» de V2.
- Decisiones marcadas como propuesta técnica: D04, D05, D07 (flujo comercial), D09–D16.

## 2026-10-31 — CR-162: errores y convenciones de API

- `src/modules/access/supabase-gateway.js`: mapeo explícito `28000 → 401 / UNAUTHORIZED`, `42501 → 403 / FORBIDDEN`, `P0002 → 404 / NOT_FOUND` y `22023`/`23514 → 422 / INVALID_INPUT`. Se conserva `23505 → 409` y el fallback 503, sin revelar mensajes, detalles o pistas del proveedor.
- `src/lib/collection-query.js` y `src/app.js`: utilidades de paginación, orden con desempate y filtros tipados con listas permitidas; parser simple de query strings. El usuario aprobó valores predeterminados/límites, metadatos, sintaxis y validación. No se agregan endpoints de módulos futuros.
- Frontend hermano: distingue 401 y 403 de permisos, oculta perfil denegado sin cerrar innecesariamente la sesión, muestra 404 sin tratarlo como indisponibilidad y conserva formularios rechazados. Añade tipos, serialización y lectura de páginas con `apiPage`, conservando `data` y `meta`.
- `tests/supabase-gateway.test.js`, `tests/collection-query.test.js` y pruebas Playwright frontend: errores de RPC a HTTP, salida pública sin datos técnicos, consulta/respuesta paginada y comportamiento del consumidor. No usan cuentas reales ni base de datos.
- `docs/CONVENCIONES-API.md`, README, contrato de fase 1 y D08: convenciones aprobadas y alcance de integración por fase. La revisión externa del ticket no se sustituye por estas pruebas.

No se modifican esquemas, datos o funciones SQL ni se realizan commits. Las funciones SQL existentes que usen `42501` para una sesión inválida requieren revisión separada; no se remapean por el texto del error.

**Validación:** 89 pruebas backend aprobadas y 30 pruebas Playwright en móvil/escritorio aprobadas, con Auth/API interceptados; ESLint backend, formato de los archivos modificados, comprobación de tipos y compilación frontend aprobados. El lint frontend conserva 21 avisos en archivos ajenos al cambio, sin avisos en los archivos nuevos/modificados. No se escribieron datos remotos. La consulta del ticket de ClickUp no estuvo disponible por autorización del conector; se usaron los criterios aportados explícitamente por el usuario y no se cambió el estado del ticket.

## 2026-10-25 — URL de invitaciones desde configuración local

Por solicitud del usuario, `scripts/invite-test-user.js` elimina la URL fija del proyecto y carga `SUPABASE_URL` desde `.env` mediante dotenv, conservando prioridad de las variables del proceso. No hay URL de respaldo. Valida el origen HTTPS antes de usar la clave administrativa y no expone los valores ante errores. La clave secret sigue siendo temporal; no se añade al código ni al archivo de ejemplo.

`tests/invite-test-user.test.js` verifica carga real desde un `.env` sintético y rechazo de URL ausente/insegura sin red ni datos sensibles en los mensajes. La guía de invitación describe la configuración nueva. No se realizan envíos, cambios de base de datos ni commits.

**Validación:** 47 pruebas backend aprobadas (incluidas diez del script), ESLint y formato de los cuatro archivos modificados aprobados; `.env` confirmado como ignorado por Git. Las pruebas HTTP necesitaron permiso para conectarse al servidor local de pruebas. `npm run check` se detiene por un aviso de formato en `docs/PLAN.md`, ajeno a este cambio; ese archivo no se modificó.

## 2026-10-25 — Primera invitación creada y diagnóstico de eliminación

El usuario informó que la ejecución manual creó la identidad y entregó el correo, inicialmente con nueve dígitos, y que corrigió la longitud OTP a seis. La inspección remota de lectura confirmó identidad invitada y perfil existentes, correo todavía sin confirmar y ausencia de inicio de sesión.

Los logs de PostgreSQL confirmaron que el intento de borrar desde Auth falla con SQLSTATE `23503` por `fk_usuario_auth` (`cuidared.usuario.usuario_id` hacia `auth.users.id`, `ON DELETE RESTRICT`). `docs/INVITACION-PRUEBA-FASE-1.md` documenta la causa y el reenvío a la identidad no confirmada para continuar las pruebas sin borrarla. No se eliminó información, no se cambiaron restricciones ni se envió otro correo desde el agente. La política general de eliminación/anonimización permanece pendiente; no se realizó commit.

## 2026-10-25 — Diagnóstico seguro del script de invitación

Tras el error genérico reportado, una consulta remota de lectura confirmó que la identidad y el perfil de la invitación autorizada todavía no existen. No se repitió el envío.

- `scripts/invite-test-user.js`: muestra mensajes propios concretos para JSON/perfil inválido y clave administrativa ausente o mal formada; acepta espacios exteriores al pegar la clave. Los errores inesperados siguen ocultando valores y muestran únicamente códigos conocidos de conexión; los rechazos de Auth muestran código acotado y estado HTTP. No imprime claves, datos del perfil ni excepciones completas.
- `tests/invite-test-user.test.js`: comprueba rechazos antes del envío, ausencia de datos sensibles en salida y validación local sin credenciales ni red.

**Estado:** pendiente de repetir la ejecución local con el diagnóstico corregido; no se conoce aún la causa concreta del intento del usuario. Sin nuevas escrituras remotas ni commits.

**Validación:** seis pruebas del script aprobadas sin red ni credenciales reales; ESLint, formato de los archivos modificados y `git diff --check` aprobados.

## 2026-10-25 — Preparación de primera invitación autorizada

El usuario autorizó crear una identidad/perfil de prueba y enviar una invitación concreta. La consulta previa no encontró correo ni cédula duplicados. El formulario del panel inspeccionado solo admite correo y no permite aportar los metadatos requeridos por el trigger; no se envió desde ese formulario.

- `scripts/invite-test-user.js`: herramienta administrativa manual para el proyecto CuidaRed; valida los datos sin contactar servicios por defecto y exige `--send` y una clave secret temporal para ejecutar la invitación con sus metadatos. No registra datos personales, claves ni códigos y no asigna roles/cuentas.
- `docs/INVITACION-PRUEBA-FASE-1.md`: ejecución con clave oculta y variables de proceso que se retiran al terminar. No añade credenciales a archivos ni al frontend.

**Estado:** envío y creación pendientes de disponer de la credencial administrativa por un canal local; el conector disponible no incluye administración Auth. No se realizaron escrituras remotas ni commits para esta preparación.

**Validación:** sintaxis de Node, ESLint, formato de los archivos nuevos y `git diff --check` aprobados; ejecución sin `--send` con datos sintéticos aprobada, sin contactar Supabase.

## 2026-10-24 — Inicio de fase 1: Perfil y Acceso

**Propósito:** comenzar la hoja de ruta ID01–ID08 con acceso real, respetando aprobaciones de BD y commits. No se han implementado las ocho fases ni se declara cerrada la primera.

- `package.json`, lockfile y configuración: JavaScript ESM/Node.js 24, Express, Supabase SDK, Zod, ESLint/Prettier y Vitest/Supertest con versiones exactas.
- `src/`: configuración validada, errores controlados, seguridad HTTP, CORS exacto, límites de solicitudes, auditoría técnica minimizada, verificación Auth y API de sesión/perfil propio. Sin claves privilegiadas ni autorización por roles enviados por cliente.
- `tests/`: pruebas API y adaptador con datos sintéticos/transporte sustituido; ninguna escritura remota.
- `docs/FASE-1-PERFIL-Y-ACCESO.md` y `docs/propuestas/fase-1-acceso.sql`: contrato y propuesta de sesiones/RPC/RLS. **SQL sin aplicar**, no migración ejecutada. Cambios Auth también pendientes de aprobación.
- Conciliación aprobada tras inspeccionar funciones remotas: se conserva el trigger de alta de usuario; quien invita aporta los datos y el invitado confirma el perfil. Las tres RPC propuestas se aíslan en `cuidared_api`, sin conceder acceso al esquema de funciones internas existentes.
- `PLAN-DESARROLLO-BACKEND.md`, `AGENTS.md`, `README.md` y contexto: hoja de ruta y decisiones actualizadas, instalación y comandos reales.
- Frontend hermano: acceso Supabase por defecto, activación por invitación y código, recuperación, perfil y sesión; prototipo explícito solo en desarrollo. Se reutilizan contenedores y componentes visuales. API/Auth interceptados en pruebas móviles/escritorio. Se actualizan únicamente dos dependencias transitivas para corregir las alertas de instalación.

**Validación:** 37 pruebas backend y 16 de acceso frontend (ocho recorridos en móvil y escritorio) aprobadas, con dependencias interceptadas; seis escenarios históricos de acceso del prototipo aprobados en escritorio. ESLint y Prettier del backend aprobados; frontend compila y no introduce nuevos avisos de lint en los archivos del acceso. La compilación de producción excluye el prototipo; el reporte de instalación/actualización registró cero vulnerabilidades conocidas. Las verificaciones con mocks no equivalen a integración con la base real. El SQL no fue ejecutado ni probado en PostgreSQL: quedan pendientes aprobación, aplicación, configuración Auth, pruebas remotas y cierre de fase.

**Restricciones respetadas:** sin commits; sin cambios a esquema, datos, políticas, configuración Auth ni usuarios reales en Supabase. Consultas remotas únicamente de lectura para inspeccionar metadatos y permisos.

## 2026-10-25 — Verificación final y revisión pendiente

Se completaron las comprobaciones descritas arriba y se solicitó aprobación expresa de `docs/propuestas/fase-1-acceso.sql` y de la exposición de `cuidared_api` en el proyecto CuidaRed. La propuesta permanece sin aplicar hasta recibir respuesta. No se ha aprobado ni efectuado ningún commit. La fase 1 continúa abierta; las fases 2–8 siguen pendientes de sus diseños y decisiones.

## 2026-10-25 — Persistencia aplicada con aprobación expresa

**Autorización recibida:** «Apruebo aplicar esa propuesta y exponer cuidared_api». Alcance: proyecto Supabase CuidaRed (`leghywixuasnptxvrijq`), propuesta de fase 1 y exposición de ese esquema; configuración Auth y usuarios reales excluidos.

- Se aplicó la migración remota `20261025041944_fase_1_acceso`: esquema API, tres RPC, tabla privada de sesiones, RLS y privilegios previstos. Se configuró únicamente `cuidared_api` en PostgREST mediante override del rol `authenticator` y se recargó configuración/caché.
- `supabase/migrations/` conserva la copia del SQL enviado con la versión remota real. Se confirmó por consulta que el SQL almacenado coincide exactamente con el enviado. El CLI falló por binario de Windows ausente y fallo de descarga; se utilizó el conector, sin inventar una versión de migración local.
- `docs/verificacion/fase-1-acceso.sql` pasó en PostgreSQL: RLS, permisos, ruta de búsqueda, rechazos anónimos/sin identidad/con sesión inexistente y conservación del trigger de invitación. Los ajustes de prueba finalizaron con `ROLLBACK`, sin crear identidades ni datos de negocio.
- `scripts/verify-api-exposure.js` confirmó por HTTPS rechazo de los esquemas `cuidared` y `public` y denegación de RPC anónima en `cuidared_api`, usando clave publicable. Se eliminó la configuración temporal de verificación.
- `docs/VERIFICACION-FASE-1-SUPABASE.md`, guías, plan y contexto reflejan el estado aplicado, los 15 avisos previos y las dos observaciones informativas de RLS sin políticas deliberadas en tablas privadas.

**Pendiente:** configuración Auth y recorridos con usuarios reales, incluidas pruebas positivas de sesión/perfil, revocación, límites y aislamiento. La fase 1 no está cerrada. No se realizaron commits Git ni cambios a plantillas, SMTP, OTP, contraseñas o usuarios Auth.

## 14/11/2026 · Backoffice de CuidaRed

- `src/modules/backoffice/`, `src/lib/system-logger.js`, `src/lib/supabase-admin.js` y `src/app.js` conectan los módulos de administración en `/api/admin` con persistencia, autorización, trazas sanitizadas y eventos HTTP.
- `src/modules/access/`, `src/modules/cuentas/require-cuenta.js` y `src/modules/sync/sync-routes.js` propagan la revocación y los rechazos de sincronización a la PWA y al visor técnico.
- Las migraciones `20261114133700_backoffice.sql` y `20261114133759_backoffice_tareas.sql` quedaron aplicadas en Supabase CuidaRed con autorización. El script de catálogo agregó cuatro planes referenciales de V2 y tres métodos. La tarea diaria quedó activa y su ejecución manual se comprobó dentro de una transacción revertida.
- `../CuidaRed-Backoffice/iniciar.mjs` y `npm start` arrancan las tres aplicaciones. La configuración de acceso y la trazabilidad BO-01 a BO-34 están en `../CuidaRed-Backoffice/README.md`.
- Con la clave dedicada de Express se verificaron contra Supabase CuidaRed el ingreso de los tres operadores de prueba, la negación de permisos, el TOTP del superadministrador y los logs de Express y PWA por SSE. El factor temporal se retiró para que el usuario pueda inscribir su autenticador.
- Tras el 503 de `GET /api/admin/me`, el cliente administrativo de Supabase reintenta una vez la validación de sesión ante fallos transitorios. El formulario del backoffice permite retomar la verificación conservando la sesión. Verificado con pruebas de timeout y una prueba en Edge que simula un 503 y llega al QR de Supabase.

### 14/11/2026 · Disponibilidad y filtros del Backoffice

- La revisión de Supabase encontró timeouts en PostgREST durante los errores reportados. La comparación por `request_id` confirmó que se persistió el desafío de MFA y que varios eventos asociados a los 503 quedaron registrados, mientras otros identificadores no aparecieron en `log_sistema`.
- `src/lib/supabase-admin.js` limita a un reintento las lecturas ante fallos transitorios y las escrituras de log solo se reintentan ante un rechazo explícito de la ejecución. El sondeo de eventos espera progresivamente más si falla y la apertura de la conexión SSE emite un solo aviso de conexión inicial.
- `src/lib/system-logger.js` y `src/modules/access/supabase-gateway.js` conservan el servicio y los códigos sanitizados del proveedor en el diagnóstico de errores. El Backoffice reduce la concurrencia de la serie mensual y el ritmo de reconexión si se interrumpe el flujo en vivo.
- Verificación: 1080 pruebas de backend aprobadas. El flujo de Soporte con Supabase pasó en Edge, incluidos resumen, conexión en vivo, cuentas y filtros de logs. Una consulta por el identificador de la solicitud de ingreso confirmó un solo registro persistido con HTTP 200.
