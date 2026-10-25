# Cambios actuales

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
