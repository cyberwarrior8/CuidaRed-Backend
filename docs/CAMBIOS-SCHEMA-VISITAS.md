# Seguimiento completo de visitas — 23/11/2026

## Alcance y autorización

El usuario autorizó previamente aplicar las migraciones necesarias del proyecto y pidió completar programación, correos, observaciones, evidencias y confirmación de visitas. Se aplicó en el proyecto CuidaRed (`leghywixuasnptxvrijq`) la migración **`20261124032710_visitas_confirmacion_observaciones_evidencias`**. El identificador usa UTC; la fecha de trabajo del proyecto es 23/11 en República Dominicana.

Fuente canónica: [migración SQL](../supabase/migrations/20261124032710_visitas_confirmacion_observaciones_evidencias.sql). Requiere las migraciones previas de visitas y correo y el backoffice base que define la función de eventos. No depende de la entrega local de soporte ni de supervisión. No ejecutar fragmentos aislados ni volver a aplicar una migración ya registrada.

## Cambios persistentes

- `solicitud_visita`: fin de horario propuesto, referencia para reconstruir el código mediante HMAC y usuario que programa desde la organización. Correo y horario completo obligatorios en solicitudes públicas nuevas. La programación administrativa no inventa cédulas, teléfonos ni identidades de Auth.
- `visita`: contacto externo personal o institucional, momento de registro en campo, usuario y fecha de confirmación y constancia de realización. La programación institucional admite cero expedientes; al confirmar se identifican las personas que realmente participaron.
- `evidencia_solicitud_visita`: metadatos y huella del archivo, cuotas e idempotencia. RLS habilitada y acceso directo revocado, incluso a `service_role`; Express usa las RPC restringidas para autorizar cada operación.
- Bucket **privado** `visitas-visitantes`, JPEG de hasta 2 MB, sin políticas públicas. Express verifica el código, decodifica y normaliza JPEG/PNG/WebP, elimina EXIF/GPS, limita dimensiones y guarda JPEG. Máximo tres fotografías por solicitud. Los enlaces de descarga del equipo son firmados y breves.
- Cola de correo: nuevos eventos `observaciones` (al inicio de la visita) y `realizada` (tras confirmación). Se conservan aceptación, rechazo con motivo, reprogramación, cancelación, acuse y recordatorio. Los códigos se reconstruyen en el servidor; no se guardan en texto claro ni en logs. Las solicitudes históricas sin referencia siguen consultándose con su código original.

## Reglas de negocio

1. Solo Organización utiliza Visitas. Cuenta Familia queda excluida también en API/RPC.
2. Registrar en campo conserva la visita `en_curso`: todavía no altera la última visita efectiva. La sincronización conserva sus controles existentes de usuario, alcance, UTC e idempotencia.
3. Administrador o Coordinador confirma después del fin programado. No se admite una confirmación anticipada ni una confirmación de Cuidador. Las evidencias internas pendientes conservan su validación por Coordinador antes del cierre.
4. Confirmar que se realizó completa la visita y actualiza la fecha efectiva de los expedientes asociados; una visita institucional sin personas identificadas no reinicia los contadores de toda la organización. Confirmar que no se realizó la cancela con motivo y no cuenta como contacto efectivo.
5. El visitante puede registrar una observación y adjuntar fotografías desde el inicio de una visita autorizada, mediante su código. No necesita cuenta. Sus aportes están separados del informe del equipo y no confirman la realización.

## Verificación y estado externo

- [Prueba SQL transaccional](verificacion/local/pruebas-visitas-confirmacion-aportes.sql) aprobada contra Supabase después de aplicar la migración: programación personal/institucional, horarios, rechazo, avisos, confirmación positiva y negativa, fechas efectivas, observación previa al cierre, evidencia privada, aislamiento y bloqueo de Familia/Cuidador. Todos los datos sintéticos se revirtieron; no se cargaron archivos reales.
- 1.341 pruebas de backend aprobadas, incluido el recorrido HTTP de una fotografía mayor de 16 KB sin ampliar los límites de consulta/descarga. Interfaz comprobada con 52 pruebas de servicios interceptados en móvil y escritorio; la entrega de correo no se acredita mediante mocks.
- Asesores de seguridad revisados antes y después: sin nuevos tipos de advertencia. Se conservan los avisos previos del proyecto sobre funciones históricas y protección de contraseñas.
- No se enviaron correos reales. El Gmail del proyecto todavía carece de contraseña de aplicación y la cola permanece pausada. [Única configuración que requiere al dueño del buzón](ACTIVAR-CORREO-PROYECTO.md).
- El ejecutor SQL local exige `psql` y PostgreSQL local. No están disponibles en este equipo; esta entrega valida el nuevo flujo con la prueba alojada y `ROLLBACK`, no afirma haber ejecutado toda la batería SQL local.
