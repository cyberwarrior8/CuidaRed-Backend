# Cambio de esquema: supervisión de plataforma

## 22/11/2026 — Soporte y eliminación controlada

Estado: **aplicado y verificado**. Fuente: [20261122192350_backoffice_soporte_eliminacion_usuarios.sql](../supabase/migrations/20261122192350_backoffice_soporte_eliminacion_usuarios.sql). El usuario solicitó explícitamente el formulario de soporte, su seguimiento en el backoffice y la eliminación del usuario en la base; se mantiene la autorización previa de aplicar las migraciones necesarias. La ejecución real de una eliminación requiere la confirmación del operador en la interfaz.

- Se crean `cuidared.solicitud_soporte` y `cuidared.mensaje_soporte`, con RLS y sin acceso directo de clientes o del rol de servicio. Las RPC públicas exigen Administrador de Organización de la cuenta concreta; las administrativas revalidan el operador dedicado y MFA. Se indexan cuenta, estado y mensajes, y se impiden solicitudes de eliminación abiertas duplicadas para el mismo usuario y cuenta.
- Se crea `cuidared_interno.bo_eliminacion_usuario`, sin acceso de clientes ni del servicio por tabla. Contiene una autorización de cinco minutos, asociada al operador, su sesión y el objetivo. Las RPC de revisión, preparación y confirmación de estado se conceden exclusivamente a `service_role`; la lógica exige Superadministrador con AAL2.
- La FK del perfil a `auth.users` pasa de RESTRICT a CASCADE con una guarda BEFORE DELETE en el perfil. La guarda exige una autorización vigente, revalida elegibilidad y elimina solo las membresías inactivas y el perfil de cuidador sin dependencias. Se conservan los registros operativos y la auditoría. La aplicación usa `auth.admin.deleteUser(id, false)`; no ejecuta borrados directos de Auth como flujo de producción.
- Se bloquea la eliminación de perfiles activos, titulares, operadores de backoffice, personas con membresías activas/pendientes, relaciones con otras cuentas, archivos o referencias operativas. Las FK se inspeccionan para incorporar las dependencias actuales al control. Una membresía reactivada después de preparar la operación bloquea la cascada.
- `bo_detalle` utiliza una nueva consulta de la membresía más reciente por persona, incluidas las inactivas. Distingue estado global y estado de membresía.
- Los eventos solo publican el tema `soporte`. El seguimiento usa versiones para evitar escrituras concurrentes perdidas y no permite leer solicitudes de otra organización.

Verificación: `pruebas-soporte-eliminacion.sql` pasó alojada con usuarios sintéticos y ROLLBACK. Comprueba duplicados, aislamiento, versión, MFA, rechazo sin autorización, rechazo tras reactivar una membresía, eliminación conjunta de Auth/perfil/membresías, resolución del ticket, idempotencia y reutilización de correo/cédula. No se enviaron correos ni se eliminó al miembro real. Se comprobaron por separado la aparición de su membresía inactiva y su elegibilidad mediante consultas de lectura.

Las advertencias anteriores del proyecto sobre funciones antiguas y protección de contraseñas permanecen fuera de este cambio. Las nuevas tablas con RLS y sin políticas son de acceso por RPC, con permisos de tabla revocados; no se abren lecturas públicas.

La operación conserva instantáneas y conversaciones de auditoría; no implementa una solicitud de supresión de todos los datos personales históricos. [Guía de operación](../../CuidaRed-Backoffice/docs/SOPORTE-Y-USUARIOS.md).

Fecha: 21/11/2026. Estado: **aplicado y verificado** en Supabase CuidaRed (`leghywixuasnptxvrijq`).

## Alcance y autorización

La petición actual requiere conservar las funciones del backoffice y determinar el seguimiento necesario para los módulos de la PWA. El usuario autorizó previamente aplicar las migraciones necesarias para completar el backoffice; esa autorización sigue vigente en esta sesión. Se informó de la nueva consulta de supervisión antes de aplicarla.

Fuente SQL: [20261121172722_backoffice_supervision_plataforma.sql](../supabase/migrations/20261121172722_backoffice_supervision_plataforma.sql). Nombre registrado: `backoffice_supervision_plataforma`. No modifica filas de negocio ni crea cuentas o credenciales.

Se crea este registro separado para la entrega actual; el archivo histórico `docs/CAMBIOS-SCHEMA-CUIDARED.md` ya estaba eliminado en el árbol de trabajo y no se restaura ni se sustituye su contenido anterior.

## Objetos y permisos

- `cuidared_interno.bo_supervision(integer)`: consulta agregada de cuentas, visitas, solicitudes, tareas, evidencias, necesidades, alertas, correo, sincronización y notificaciones. Serie mensual de seis o doce meses, zona `America/Santo_Domingo`. No entrega datos personales, direcciones de correo ni expedientes.
- `cuidared_api.api_bo_supervision(uuid,uuid,text,integer)`: entrada exclusiva para el servidor. Revalida la sesión dedicada mediante `bo_rol`, la vigencia del operador y el segundo factor para Superadministrador. Solo acepta periodos de seis o doce meses.
- Ambas funciones fijan `search_path = ''` y califican sus objetos. La entrada pública de API es `SECURITY DEFINER`; su ejecución queda revocada a `PUBLIC`, `anon` y `authenticated`, y concedida únicamente a `service_role`. La función interna no se concede a clientes ni al servicio directamente.
- Ocho triggers de sentencia `bo_supervision_evento` reutilizan `cuidared_interno.bo_eventos` en `solicitud_visita`, `aviso_visita`, `operacion_sync`, `tarea_agenda`, `evidencia`, `evidencia_visita`, `alerta_envejeciente` y `push_entrega`. Emiten únicamente el tema de invalidación `operacion`; no contienen las filas modificadas.
- Se notifica la recarga del esquema de PostgREST. No se cambian buckets, políticas RLS, roles ni claves del proyecto.

## Aplicación y verificación

Se inspeccionaron las tablas y dependencias existentes antes de escribir la migración. La consulta agregada se ejecutó en modo de lectura; después se aplicó la migración mediante la conexión Supabase y se alineó el nombre del archivo con la versión registrada en su historial. El validador SQL local clasifica el nuevo archivo como migración posterior, evitando cargarlo antes de sus dependencias.

Comprobaciones alojadas, sin insertar datos:

| Comprobación                                                       | Resultado |
| ------------------------------------------------------------------ | --------- |
| Puntos de serie para seis / doce meses                             | 6 / 12    |
| Suma de cuentas por plan igual al total de cuentas                 | Sí        |
| `anon` / `authenticated` pueden ejecutar la entrada administrativa | No / No   |
| `service_role` puede ejecutar la entrada administrativa            | Sí        |
| Triggers nuevos presentes                                          | 8         |
| Funciones con `search_path` fijo                                   | Ambas     |

La suite completa del backend pasó: 1.174 pruebas. Las nuevas rutas incluyen validación de periodo, rechazo de filtros arbitrarios, comprobación de roles y ausencia de secretos en el estado de servicios. Los navegadores utilizan servicios simulados; los permisos de PostgreSQL se comprobaron por separado en el proyecto alojado.

Los asesores de seguridad conservaron los mismos resultados anteriores a la migración: 38 avisos informativos por RLS sin políticas en el modelo de acceso por funciones, 15 funciones antiguas con `search_path` mutable y la protección de contraseñas filtradas deshabilitada. Ninguno corresponde a los objetos nuevos. Se mantienen como asuntos previos para revisión del equipo, sin alterar permisos de otros módulos:

- [RLS sin políticas](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).
- [Fijar search_path en funciones existentes](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable).
- [Protección de contraseñas filtradas](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

## Operación

`GET /api/admin/supervision?meses=6` requiere sesión de backoffice. Express añade solo indicadores booleanos de configuración y el nombre del proveedor de correo; no devuelve sus secretos. El gráfico y el seguimiento usan esta consulta y las señales SSE existentes. La previa de archivos `POST /api/admin/logos/:variante/validar` reutiliza la validación de publicación sin escribir en la base ni en Storage.

En otro entorno se deben aplicar primero las migraciones de backoffice, fases 5/6, visitas y Web Push. No ejecutar de nuevo el archivo en el proyecto donde ya figura aplicado. El cierre del correo real sigue dependiendo de la credencial del propietario, según [Activar correo del proyecto](ACTIVAR-CORREO-PROYECTO.md).
