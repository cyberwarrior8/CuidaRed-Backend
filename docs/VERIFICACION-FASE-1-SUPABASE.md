# Aplicación y verificación de persistencia — Fase 1

## Autorización y resultado

El **25 de octubre de 2026** el usuario aprobó aplicar `docs/propuestas/fase-1-acceso.sql` y exponer solo `cuidared_api` en Supabase CuidaRed (`leghywixuasnptxvrijq`). Auth y pruebas con usuarios reales quedaron expresamente fuera de esta autorización.

Migración remota registrada: **`20261025041944_fase_1_acceso`**. Copia local: [SQL aplicado](../supabase/migrations/20261025041944_fase_1_acceso.sql). La propuesta previa tenía SHA-256 `AE456013F25317D12D0726356D2D42FC6E232BDAFE5114E79BBAFABDFBE9D409`; se añadieron al envío los ajustes de exposición ya autorizados. El registro remoto contiene una entrada SQL con MD5 `5641c6238256d43dee96060237a0fd54`. Una comparación SQL confirmó que el contenido registrado coincide exactamente con el enviado.

Se aplicó:

- Esquema `cuidared_api` con tres RPC: `api_sesion`, `api_mi_perfil` y `api_actualizar_mi_perfil`.
- Tabla interna `cuidared.sesion_acceso`; RLS en esa tabla y en `cuidared.usuario`.
- Acceso directo a ambas tablas denegado a `anon` y `authenticated`. Solo `authenticated` puede usar el esquema API y ejecutar las RPC, que vuelven a comprobar identidad y sesión.
- Configuración `pgrst.db_schemas=cuidared_api` en `authenticator`, seguida de recarga de configuración y caché de PostgREST. No se expuso el esquema interno `cuidared`.

El trigger `fn_trg_auth_nuevo_usuario` conserva su definición; su MD5 anterior y posterior es `83fe36f5284de5ce0df6fc3f621ce6c3`. Las otras 37 tablas existentes conservaron su estado de RLS. La tabla nueva tiene cero filas después de las verificaciones. No se crearon usuarios ni se editaron perfiles, membresías, catálogos o datos de negocio.

## Comprobaciones realizadas

El [script SQL de verificación](verificacion/fase-1-acceso.sql) pasó en la base real. Usa ajustes de rol/claims locales a una transacción terminada con `ROLLBACK`, sin emitir tokens ni crear identidades:

1. RLS, permisos de esquema, ausencia de privilegios directos y permisos de ejecución correctos.
2. Las tres RPC tienen `search_path` vacío y el contexto privilegiado previsto.
3. `anon` no ejecuta la RPC; `authenticated` sin identidad tampoco pasa.
4. Una identidad/sesión sintética inexistente obtiene `vigente=false` para validar, actividad y cierre.
5. Las funciones de consulta y edición rechazan esa sesión inválida.
6. El trigger de invitación conserva su definición.

El [script HTTPS](../scripts/verify-api-exposure.js) pasó usando únicamente una clave publicable:

- Seleccionar `cuidared` o `public` como esquema devuelve HTTP 406 / `PGRST106`.
- Seleccionar `cuidared_api` permite resolver el esquema, pero la llamada anónima es rechazada con error de permisos `42501`.
- La raíz OpenAPI exige clave secreta; la verificación evita ese recurso y no necesita recuperar una clave privilegiada.

Para repetir la comprobación HTTPS, configurar las variables publicables del backend y ejecutar `node --env-file=.env scripts/verify-api-exposure.js`. La configuración temporal usada durante esta revisión fue eliminada; las claves no se incorporaron a archivos versionados.

## Avisos de seguridad y límites

El asesor posterior conserva **15 avisos previos** de [funciones con search_path mutable](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable). No se modificaron funciones ajenas a la propuesta aprobada. Las tres RPC nuevas tienen la ruta fijada.

También informa de dos tablas con [RLS sin políticas](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy): `usuario` y `sesion_acceso`. Es deliberado en este diseño: el cliente no tiene acceso directo y utiliza exclusivamente las funciones verificadas; no se agregaron políticas de lectura/escritura generales para silenciar el aviso.

El [ajuste de rol](https://supabase.com/docs/guides/troubleshooting/postgrest-error-pgrst002-could-not-query-the-database-for-the-schema-cache-c396e9) tiene prioridad sobre la lista de esquemas del panel. Cualquier cambio o retorno al control del panel debe revisarse y aprobarse.

Esta verificación **no certifica todavía un flujo con usuario invitado válido**: quedan pendientes configuración Auth, envío/consumo real de códigos, límites temporales con una sesión real, edición autorizada, revocación real y aislamiento entre dos identidades válidas. No se cambiaron plantillas, política de contraseña, OTP, SMTP ni límites de Auth. La fase 1 continúa abierta y no se realizaron commits.
