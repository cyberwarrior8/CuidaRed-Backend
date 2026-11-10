# Integración de CuidaRed, fases 2 a 4

La implementación local está en `Edgardo-CuidaRed-Desarrollo` en ambos repositorios. El frontend del equipo conserva el acceso real de fase 1 y abre las nuevas pantallas desde **Mi cuenta → Abrir cuenta**. La API y la base de datos vuelven a comprobar sesión, cuenta, permisos y alcance. Los cambios de persistencia están en [propuestas SQL](propuestas/) y su [registro separado](CAMBIOS-SCHEMA-CUIDARED.md).

## Flujo de ramas

`Edgardo-CuidaRed-Desarrollo` y `Katriel-Cuidared-Desarrollo` se usan para trabajar en paralelo. Los cambios de ambas ramas pasan por revisión y pruebas conjuntas en `integracion/fases-2-4` antes de incorporarse a la rama principal de cada repositorio.

## Contratos integrados

- `GET /api/v1/me` devuelve identidad y perfil y funciona con la base de fase 1. `GET /api/v1/cuentas` devuelve solo membresías activas y usa CR-162. Admite `page`, `limit`, `sort` por `nombre`, `fecha_creacion` o `cuenta_id`, y `filter[tipo_cuenta]` o `filter[suscripcion_estado]`. `GET /api/v1/me/membresias` lista invitaciones pendientes. `GET /api/v1/cuentas/:cuentaId/contexto` devuelve el contexto de la cuenta solicitada. Los IDs bigint se mantienen como texto.
- El titular crea la cuenta tras verificar su correo. Los miembros entran por invitación. La prueba inicia con el alta, dura 168 horas exactas y se usa una vez por cuenta, con un máximo de una prueba vigente a la vez por titular. Los cupos básicos cuentan familiares activos en Familia y staff activo en Organización. Sin vigencia, se conserva la lectura de datos de cuenta y suscripción. La transferencia requiere otro gestor activo y la autoriza el titular vigente.
- El perfil Cuidador es global. El Coordinador de Organización puede editarlo desde una membresía activa de esa cuenta. Los tipos aprobados son Cuidador remunerado, Familiar cuidador y Voluntario comunitario. Una baja de membresía conserva el perfil global.
- El expediente admite 60–120 años, consentimiento del adulto o representante y exactamente un contacto principal. La API calcula el riesgo en servidor y conserva la ausencia de evaluación. Se integran asignaciones, autorizaciones familiares, historial e indicaciones de Medicamento, Cuidado, Consulta y Terapia. El retiro de consentimiento, la retención y la anonimización requieren una política propia.
- Visitas realizadas solo después de programación y autorización para el actor, con acceso vigente a todos los adultos afectados. La cola offline vive en memoria en la pestaña autenticada y solo envía acciones para visitas existentes. Los resultados rechazados se conservan para reintento o descarte. La agenda permite series diarias o semanales de hasta 60 ocurrencias y exige evidencia validada antes de completar una tarea que la requiere.
- Las evidencias de visita permiten JPG, PNG, WEBP o PDF de hasta 5 MB. Storage exige una sesión vigente al subir. Participantes autorizados y gestores habilitados pueden descargar si tienen acceso a todos los adultos de la visita. Las solicitudes externas permanecen separadas y pendientes de su revisión de seguridad.

## Validación y puesta en marcha

1. Ejecutar `npm test` y `npm run lint` en el backend. En el frontend, `npm run typecheck`, `npm run build` y `npm run test:access`. Los escenarios HTTP y de navegador interceptan las dependencias.
2. Validar SQL con `npm run validar:sql` en una instalación desechable de PostgreSQL local con `psql`. La verificación de integración carga el modelo de referencia, stubs de Auth/Storage, la fase 1 y los bloques 2a–4d. Comprueba alta, expiración, cuentas propias, perfiles compartidos, titularidad, visitas autorizadas, reintentos, recurrencia y evidencias. La carga ONE histórica queda fuera del ejecutor. Los scripts SQL de verificación por bloque anteriores conservan expectativas del diseño original y requieren actualización si se quieren volver a ejecutar.
3. El proyecto compartido tiene los nueve bloques aplicados desde el 09/11/2026 y Auth permite el autorregistro con confirmación por código de seis dígitos. El [registro del esquema](CAMBIOS-SCHEMA-CUIDARED.md) enlaza las versiones aplicadas y la prueba transaccional. Se puede probar desde la aplicación con una identidad verificada existente o registrar un titular nuevo con un correo de prueba.
4. Configurar los entornos locales a partir de `.env.example` en cada copia. Ejecutar `npm run dev` en ambos repositorios. Los secretos administrativos permanecen del lado del servidor.

Pasaron 1.068 pruebas de backend, 113 de componentes y 92 de acceso y operación en navegador. También pasó la compilación del frontend. La verificación en Supabase comprobó las funciones de negocio y las políticas de acceso con identidades sintéticas. Los recorridos de correo real y de subida y descarga de archivos se prueban desde la aplicación.
