# Visitas y seguimiento comunitario

## Flujo vigente desde el 23/11/2026

La [migración de confirmación y aportes](../supabase/migrations/20261124032710_visitas_confirmacion_observaciones_evidencias.sql) está aplicada en CuidaRed alojado. [Registro del esquema y comprobaciones](CAMBIOS-SCHEMA-VISITAS.md).

- **Programar visita:** el gestor identifica primero a la persona o al contacto de la institución/grupo, su correo y cantidad de visitantes. Después elige horario, responsable de la organización y, cuando corresponda, personas mayores. La visita queda autorizada y tiene seguimiento público, sin registrar un usuario visitante.
- **Revisar solicitudes:** se precargan tanto el inicio como el fin que propuso el visitante. Se puede aprobar ese horario, proponer otro o rechazar con motivo. **Visitas → Historial → Ver solicitudes rechazadas** conserva los rechazos.
- **Registrar en campo:** el cuidador guarda su informe, incluso mediante la cola offline existente. La realización queda pendiente de confirmación organizativa; no actualiza todavía la última visita.
- **Confirmar:** al pasar la hora de fin, Administrador y Coordinador encuentran **Confirmar si se realizó** en el detalle. Indican resultado y constancia. Si no se realizó queda cancelada con motivo; si se realizó cuenta con la fecha efectiva de la visita. En actividades grupales se identifican los adultos participantes, sin modificar otros expedientes. Las evidencias internas pendientes deben revisarse antes del cierre.
- **Visitante:** el correo es obligatorio y el formulario recoge la ventana completa. Desde la hora de inicio puede consultar su código, dejar una observación y adjuntar hasta tres fotografías autorizadas de 2 MB. Los aportes no completan la visita ni sustituyen el informe interno. Llegan a su detalle para el personal con alcance.
- **Correos:** aceptación, rechazo y demás cambios se encolan; se añade un aviso al inicio con enlace a observaciones y un aviso de realización confirmada. El correo incluye el código de solicitudes nuevas, nunca datos clínicos. El enlace requiere ingresar el código, que no se expone en la URL.

**Pendiente local:** el propietario de `cuidared.piloto@gmail.com` debe completar la [contraseña de aplicación](ACTIVAR-CORREO-PROYECTO.md). Hasta entonces la cola está pausada: guardar o aprobar una visita no implica que se haya enviado un correo. Para abrir enlaces desde otro dispositivo, configura también `PWA_ORIGIN` con el origen HTTPS accesible de la PWA.

Visitas y Solicitudes están disponibles exclusivamente en el portal operativo de Organización. Una cuenta Familia conserva su agenda de cuidado. Si el formulario público está habilitado, un pariente puede enviar una solicitud a una organización sin cuenta. Si también pertenece a la organización con rol Familiar, puede consultar el historial de las personas para las que tiene autorización.

El formulario distingue visitas personales e institucionales. Las personales identifican a la persona mayor que se desea visitar. Las institucionales identifican a la fundación, iglesia, universidad, centro educativo, empresa o grupo, con su contacto responsable, cantidad de visitantes y actividad o aporte previsto. Coordinación puede agendar una visita institucional sin asociarla a expedientes individuales. El responsable asignado registra un informe general y puede adjuntar evidencias privadas. Ambas modalidades conservan su código y el seguimiento posterior.

La [migración institucional](../supabase/migrations/20261118014628_visitas_institucionales.sql) también está aplicada en CuidaRed alojado. En otros entornos debe ejecutarse después de la migración de seguimiento organizacional. La modalidad institucional está disponible en el portal conectado a Supabase.

La [migración de reintentos](../supabase/migrations/20261118024823_solicitudes_visita_reintentos.sql) completa la activación. Si la conexión se interrumpe, vuelve a enviar con los mismos datos y con el formulario abierto. Se conserva el código del intento y se recupera la solicitud ya guardada. Al cambiar los datos se inicia un intento distinto.

## Recorrido por rol

| Rol                         | Operación                                                                                                                                                                                                                                                   |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Visitante                   | Solicitar desde la portada con correo obligatorio, guardar el código y consultar la decisión y el horario vigente. Desde el inicio de la cita, agregar observaciones y fotografías separadas del informe interno. |
| Administrador o coordinador | Programar con contacto externo, revisar solicitudes, aprobar, rechazar o cambiar el horario. Confirmar la realización después del horario y consultar rechazos. Crear tareas ligadas a una visita cuando corresponda. |
| Cuidador asignado           | Iniciar y registrar la visita autorizada, adjuntar una foto o comprobante privado en línea y consultar el historial dentro de su alcance.                                                                                                                   |
| Coordinador                 | Revisar evidencias de visita y aprobarlas o registrar el motivo de rechazo. Las evidencias pendientes impiden el cierre.                                                                                                                                    |

Las ventanas usan la hora de República Dominicana. La API comprueba cruces para el responsable y la persona mayor antes de guardar. El historial ordena los resultados por la fecha efectiva de realización o cancelación. Las capturas de visitas autorizadas se escriben en IndexedDB por usuario, con identificador estable y hora UTC. El mismo usuario puede recuperarlas en el mismo navegador después de cerrar la pestaña. Tras recuperar conexión, se revalidan los permisos y se aplica Last-Write-Wins en el servidor. Abre el detalle y valida tu sesión antes de salir a campo. Los adjuntos de evidencias necesitan conexión.

Para asignar un cuidador, verifica que haya aceptado su invitación y tenga un perfil activo en Cuenta → Perfiles globales de cuidadores. Se conserva la compatibilidad de registros históricos; el formulario no crea un usuario visitante ni ofrece registrar voluntarios externos.

## Activar en un entorno de Supabase

1. En CuidaRed alojado la [migración de seguimiento organizacional](../supabase/migrations/20261117035328_visitas_seguimiento_organizacional.sql) ya está aplicada. Para preparar otro entorno, confirma el proyecto destino y aplica primero las migraciones previas, incluidos el cierre de fases 2 a 4 (`CUIDARED-008`) y las fases 5 y 6 (`CUIDARED-009`). La migración de Visitas conserva el bucket privado `evidencias` existente.
2. En el backend configura `VISITAS_PUBLICAS_HABILITADAS=1`, `CODIGO_SEGUIMIENTO_SECRETO` (aleatorio y estable, al menos 32 caracteres) y `SUPABASE_SECRET_KEY`. Usa `PWA_ORIGIN` con el origen que abrirán los visitantes. Conserva el secreto de seguimiento en reinicios y despliegues para que sigan funcionando los códigos emitidos.
3. Inicia el backend y el frontend con `npm run dev` en terminales separadas. `VITE_API_URL` del frontend apunta a Express (por defecto `http://localhost:3000` en desarrollo). Una respuesta `200` de `GET /api/v1/publico/organizaciones` con `{"data":[]}` indica que el módulo está disponible y el proyecto todavía no tiene organizaciones operativas. Para reactivar una prueba de una organización autorizada, usa Backoffice → Pruebas gratuitas → Vencidas → Reactivar, elige el plazo e indica el motivo. En la portada usa «Volver a cargar organizaciones».
4. Para probar los correos **sin dominio propio**, configura el [envío con un Gmail existente](CORREO-VISITAS-SIN-DOMINIO.md). Para el dueño del buzón ya elegido están los [pasos mínimos de activación](ACTIVAR-CORREO-PROYECTO.md). También puedes usar Resend si dispones de un dominio propio verificado, con `VISITAS_CORREO_PROVEEDOR=resend`, `VISITAS_RESEND_API_KEY` y `VISITAS_CORREO_REMITENTE` exclusivamente en el `.env` del backend. La cola se procesa cada 30 segundos con el servidor activo. El visitante recibe el acuse inicial, cambios de estado, recordatorios y acceso a observaciones; la organización recibe las solicitudes nuevas en su correo de contacto y, si no tiene uno, en los correos confirmados de sus gestores activos. Los correos del visitante enlazan a `PWA_ORIGIN` e incluyen el código de solicitudes nuevas; excluyen datos clínicos.
5. Prueba primero con una organización de prueba y cuentas sintéticas de administrador, coordinador, cuidador y familiar. Emite una solicitud con un buzón de prueba, autorízala, cámbiala de horario, registra el cierre y verifica la consulta con su código. Antes de aceptar datos de visitantes reales, completa la revisión D15 de retención y aviso de privacidad.

La oferta de planes de la portada es informativa. `VITE_CONTACTO_EMAIL` es opcional y habilita el enlace de soporte general. Los cambios de visita los gestiona la organización que recibió la solicitud.

## Elegir el proveedor de correo

Para el proyecto sin dominio propio utiliza `VISITAS_CORREO_PROVEEDOR=smtp` y sigue la [guía de Gmail](CORREO-VISITAS-SIN-DOMINIO.md). El remitente debe coincidir con la cuenta autenticada. SMTP requiere TLS en el puerto 465 o STARTTLS obligatorio en el 587. `npm run visitas:correo` comprueba la configuración sin enviar ni consumir la cola; `--enviar-a=TU_BUZON_REAL` envía una prueba al buzón indicado.

### Alternativa: Resend con dominio propio

El remitente identifica quién envía el correo; no es el destinatario de todas las visitas. Verificar un dominio permite enviar desde sus direcciones. Un buzón para recibir respuestas requiere un proveedor de correo o configurar la recepción en Resend. **Suppressions es una lista de destinatarios bloqueados: agregar una dirección allí no crea un buzón.**

Mientras publicas los registros que muestra Domains, configura `VISITAS_CORREO_HABILITADO=0` en el `.env` del backend. Mantiene los avisos pendientes en Supabase y permite usar el módulo sin intentar envíos desde un dominio sin verificar. La clave y el remitente deben estar configurados con valores válidos. No necesitas ampliar una clave de solo envío para usar el módulo.

Ejecuta `npm run visitas:correo` para comprobar la configuración local sin enviar correos ni consumir la cola. Una vez verificado el dominio, ejecuta `npm run visitas:correo -- --enviar-a=TU_BUZON_REAL`. Envía un único mensaje identificado como prueba, sin crear solicitudes ni cambiar visitas. Informa el identificador de Resend y el enlace a su detalle; no imprime la clave ni la dirección del destinatario.

Una respuesta aceptada por la API no demuestra la entrega. En Resend → Emails → Sending abre ese identificador y comprueba **Delivered**. Revisa también el buzón y spam: Delivered acredita aceptación por el servidor de correo del destinatario, no lectura ni llegada a la bandeja principal. Si falla, comprueba dominio, permiso de la clave, cuota y lista de supresiones. El remitente de prueba `onboarding@resend.dev` tiene limitaciones y no sustituye un dominio propio para enviar a otras personas.

Después de una prueba correcta, cambia `VISITAS_CORREO_HABILITADO=1` y reinicia el backend. La cola se procesa cada 30 segundos mientras el servidor está ejecutándose. El significado interno de `cierre='enviado'` es **aceptado por Resend**, no confirmación de entrega al buzón. La aplicación todavía no recibe los webhooks de entrega/rebote de Resend.

## Destinatarios del flujo actual

| Momento                                              | Visitante con correo en la solicitud                    | Administrador/coordinador                                                                                       |
| ---------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Nueva solicitud                                      | Código y confirmación en pantalla, más acuse por correo | Notificación, bandeja y correo al contacto de la organización; sin contacto, a sus gestores activos confirmados |
| Aprobación, rechazo, cambio de horario o cancelación | Correo mediante la cola                                 | Estado actualizado en CuidaRed                                                                                  |
| Recordatorio previo                                  | Correo si la aprobación permite programarlo             | Calendario de CuidaRed                                                                                          |
| Inicio de la visita                                  | Enlace a observaciones y fotografías, con su código      | Aportes externos en el detalle                                                                                  |
| Realización confirmada                               | Correo y consulta con su código                          | Historial y última visita efectiva actualizados                                                                |

La [migración de recepción](../supabase/migrations/20261120024229_visitas_avisos_recepcion.sql) y la [configuración del buzón por organización](../supabase/migrations/20261120031507_visitas_correo_organizacion.sql) están aplicadas en CuidaRed alojado. Se aplican a solicitudes nuevas; no envían correos retroactivos. Cada organización puede definir su buzón en Cuenta → Correo, sin crear un usuario de acceso para esa dirección. Si no lo define, se notifican sus gestores activos confirmados y se revalidan sus membresías antes de cada envío. Un contacto retirado antes del reclamo no recibe el aviso. El visitante siempre usa el correo del formulario. El correo inicial indica un horario solicitado y no constituye una aprobación.

En desarrollo `PWA_ORIGIN=http://localhost:5173` enlaza al equipo donde se abre el correo. Para probar desde otros dispositivos o con visitantes externos, usa la dirección HTTPS pública de la PWA y autorízala también en `FRONTEND_ORIGINS`.

Para repetir las pruebas SQL con `psql` y un PostgreSQL local, ejecuta `npm run validar:sql -- --solo=visitas` en el backend. El script crea una base desechable con roles simulados y datos sintéticos.
