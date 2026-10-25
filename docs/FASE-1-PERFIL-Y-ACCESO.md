# Fase 1 — Perfil y Acceso

## Estado y decisiones

ID01; RF-09 y RF-21. Implementación inicial en JavaScript ESM, Express, Zod, ESLint/Prettier y Vitest/Supertest. El frontend usa su SDK Supabase, y Express comprueba el token contra Auth en cada petición. El frontend existente conserva su lenguaje; la decisión JavaScript corresponde al backend.

Solo se activan invitaciones, sin autorregistro ni creación de cuentas Familia/Organización. Se validan códigos de Supabase por correo de tipo `invite` o `recovery`. Nunca se generan, muestran o almacenan códigos/contraseñas locales en el acceso conectado. Contraseñas: mínimo ocho caracteres, mayúscula, minúscula, número y símbolo. Códigos: 15 minutos. Sesiones: 12 horas máximas desde la sesión original y 30 minutos sin interacción, comprobados con reloj del servidor.

Se conserva el trigger Auth existente: quien invita debe proporcionar cédula, nombres y apellidos al crear la identidad; el invitado carga y confirma ese perfil. Si falta, la API rechaza el acceso y remite a quien invitó. No existe POST de autorregistro de perfil. El perfil usa cédula de usuario de 11 dígitos sin guiones, nombres y apellidos obligatorios, teléfono opcional de hasta 20 caracteres y correo verificado de Auth. La API no admite ID de actor, rol, estado ni cuenta desde el formulario. La cédula no se modifica mediante edición personal. La corrección de identidad/correo, avatar y eliminación requieren sus flujos y reglas específicos; no se simula su persistencia.

## API inicial

Base `/api/v1`. Todas las operaciones de esta tabla requieren `Authorization: Bearer <access_token>`. La excepción de liveness `GET /health/live` solo confirma que Express responde, no la disponibilidad de Auth/BD.

| Método y ruta            | Entrada                                         | Respuesta                                                                        |
| ------------------------ | ----------------------------------------------- | -------------------------------------------------------------------------------- |
| GET `/me`                | Ninguna                                         | 200: identidad, perfil propio preexistente de la invitación.                     |
| PATCH `/me`              | Uno o más de `nombres`, `apellidos`, `telefono` | 200: perfil actualizado.                                                         |
| POST `/session/activity` | Ninguna                                         | 204 si sesión vigente; registra interacción.                                     |
| POST `/session/logout`   | Ninguna                                         | 204 tras marcar revocación en la aplicación. Luego el SDK cierra sesión en Auth. |

Las respuestas exitosas usan `{ "data": ... }`; las de error `{ "error": { "code", "message" }, "requestId" }`. Errores públicos: 400 JSON inválido, 401 sesión inválida/vencida, 403 usuario inactivo/origen no permitido, 409 conflicto, 413 cuerpo excedido, 422 entrada inválida, 429 límite HTTP y 503 dependencia/configuración de persistencia no disponible. Los detalles del proveedor no se exponen.

Ejemplo de edición:

```http
PATCH /api/v1/me
Authorization: Bearer <access_token>
Content-Type: application/json

{"nombres":"Ana María","telefono":null}
```

El SDK realiza `signInWithPassword`, `verifyOtp`, `resetPasswordForEmail`, `updateUser` y `signOut`; Express no recibe contraseñas ni refresh tokens. Una sesión obtenida tras OTP no concede rol ni membresía.

## Persistencia aprobada y aplicada

El usuario aprobó aplicar la propuesta el **25/10/2026**. Migración registrada: [20261025041944_fase_1_acceso](../supabase/migrations/20261025041944_fase_1_acceso.sql). Se verificaron permisos en PostgreSQL y exposición por HTTPS, sin crear usuarios ni datos de negocio. Consultar [resultados y límites](VERIFICACION-FASE-1-SUPABASE.md). No se ejecuta al instalar ni iniciar el servidor.

1. Agregar `cuidared.sesion_acceso`, con referencia a la sesión Auth, última actividad y revocación de la aplicación.
2. Activar RLS en esa tabla y en `usuario`; no dar acceso directo a estas tablas a `anon`/`authenticated`.
3. Crear un esquema separado `cuidared_api` y exponer únicamente tres RPC de identidad propia: `api_sesion`, `api_mi_perfil`, `api_actualizar_mi_perfil`. `api_sesion` distingue validar/actividad/cerrar. Se expuso solo `cuidared_api` en la Data API con aprobación del 25/10/2026; no conceder acceso al esquema interno `cuidared`. La inspección encontró funciones existentes allí con ejecución concedida a `authenticated`, varias privilegiadas, que no deben exponerse automáticamente.
4. Las RPC comprueban `auth.uid()`, sesión vigente en `auth.sessions`, invitación en `auth.users`, verificación, bloqueo/borrado y estado del perfil actual. No usan `user_metadata` para autorizar. Usan funciones `SECURITY DEFINER` estrechas con `search_path` vacío porque `auth.sessions` no puede exponerse al cliente; se revoca ejecución pública y anónima.
5. Los triggers de auditoría y fecha de usuario ya existen y se conservan. No se modifica ninguna membresía ni catálogo. La minimización/retención del registro histórico de auditoría sigue pendiente de D15; el trigger actual guarda filas completas. Los logs de Express usan solo actor, acción, resultado, código, fecha e identificador de petición.

**Lectura realizada el 24/10/2026:** las 38 tablas existentes de `cuidared` tienen RLS desactivado. Los permisos inspeccionados (`anon`: uso de esquema/SELECT/INSERT; `authenticated`: SELECT/UPDATE) resultaron falsos en las 38. Esto no demuestra exposición pública ni constituye revisión de todos los privilegios. La versión viva tiene longitudes y triggers no incluidos en el exportado `DB.sql`; se conserva este como base conceptual aprobada, conciliando esos metadatos antes de cambios.

La ejecución y las pruebas negativas de permisos/sesiones en PostgreSQL ya se completaron. El CLI no pudo ejecutarse y la migración se aplicó con el conector; la copia local usa la versión registrada remotamente. Quedan pendientes pruebas con identidades válidas, revocación real, límites exactos de tiempo y concurrencia, sujetas a revisión aparte. No se habilitaron las otras 37 tablas.

## Configuración Auth pendiente de aprobación

- Desactivar autorregistro, permitir proveedor correo/contraseña y confirmar correo.
- Plantillas **Invite user** y **Reset password** con `{{ .Token }}` en lugar de enlaces. No generar una invitación real ni enviar correo durante pruebas automatizadas.
- Caducidad OTP: 900 segundos; aplicar también la política de contraseña en Supabase, ya que validar solo en frontend se puede eludir.
- Revisar límites de envío, verificación e intentos de login. El limitador de Express no protege peticiones que van directamente a Auth. El simulador bloqueaba cinco intentos durante cinco minutos; no se afirma que ese bloqueo exista en Supabase.
- Verificar SMTP/capacidad de envío del proyecto y URLs autorizadas antes de probar con correo real. La emisión/reenvío de invitaciones de miembros se implementará con la administración de la fase 2; no se expone una ruta pública de invitación.

## Integración y límites

Acceso real por defecto; solo durante desarrollo se puede activar el prototipo con `VITE_AUTH_MODE=demo`. La compilación de producción excluye el prototipo. La identidad real no se transforma en usuario local ni se enlaza con cuentas demo. Las rutas operativas quedan fuera del modo conectado hasta incorporar autorización y persistencia en las fases correspondientes.

Se reutilizan el contenedor visual y componentes de formularios existentes. Activación conserva tres pasos. La sesión del SDK se guarda en `sessionStorage`, sin contraseñas ni códigos; activación/recuperación usan clientes efímeros. La recuperación cambia la contraseña y solicita cierre global antes de volver al login. El heartbeat responde a interacción visible, no a consultas periódicas. Si falla la revocación durante logout, se borra la sesión local y se informa que el cierre de servidor no pudo confirmarse.

## Validación y cierre pendiente

`npm test` ejecuta pruebas API con dependencias sustituidas; no usa Supabase real. `tests/supabase-gateway.test.js` verifica el adaptador SDK con transporte interceptado. Las pruebas frontend de `tests/access/` interceptan Auth/API y se ejecutan en móvil/escritorio mediante `playwright.access.config.ts`. La regresión del prototipo conserva su configuración separada.

La persistencia está aprobada y aplicada, pero la fase sigue abierta: faltan aprobación/configuración Auth, pruebas con usuarios reales autorizados y decisiones residuales. Persistencia duradera/retención de logs y mediciones de carga/recuperación se completarán según D15/D19 y las fases integradas; no se declaran verificadas.

## Referencias técnicas consultadas

- [Supabase getUser](https://supabase.com/docs/reference/javascript/auth-getuser), [verifyOtp](https://supabase.com/docs/reference/javascript/auth-verifyotp), [recuperación](https://supabase.com/docs/reference/javascript/auth-resetpasswordforemail), [plantillas](https://supabase.com/docs/guides/auth/auth-email-templates), [changelog](https://supabase.com/changelog).
- [Express: errores](https://expressjs.com/en/guide/error-handling/), [Vitest](https://vitest.dev/guide/).
- Fuentes funcionales y su jerarquía en [CONTEXTO-BACKEND.md](../CONTEXTO-BACKEND.md).
