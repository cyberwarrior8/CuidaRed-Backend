# Migraciones aplicadas

`migrations/20261025041944_fase_1_acceso.sql` es una copia del SQL remitido al conector y registrado en el proyecto **CuidaRed** (`leghywixuasnptxvrijq`) el 25 de octubre de 2026, con aprobación expresa del usuario. Conserva los comentarios originales de preparación; su estado aplicado se documenta en el [informe de verificación](../docs/VERIFICACION-FASE-1-SUPABASE.md).

El CLI 2.122.0 no pudo ejecutarse: faltó el binario de Windows y la recuperación se interrumpió por red. Se utilizó `apply_migration` del conector y se exportó la migración existente usando la versión devuelta por `list_migrations`; no se inventó un identificador local.

La base `cuidared` ya existía y todavía no tiene una migración inicial reproducible en este repositorio. Esta migración depende de sus tablas y de `auth.sessions`; no representa por sí sola la creación completa del proyecto. `Docs/Base de Datos/DB.sql` es contexto, no un script ejecutable de restauración.

La migración configura `pgrst.db_schemas=cuidared_api` en el rol `authenticator`. Mientras exista ese override, el panel de Supabase no administra esa lista. Cambiarla o restablecerla también requiere aprobación previa.

No hay commits autorizados. Las futuras modificaciones de esquema, datos, funciones o permisos necesitan su propia aprobación conforme a `AGENTS.md`.
