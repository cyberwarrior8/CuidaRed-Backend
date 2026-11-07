# Cambios actuales

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
