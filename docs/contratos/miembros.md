# Contrato — Miembros, invitaciones, roles, titularidad y perfiles de Cuidador (fase 2, bloque 2c)

## Alcance y estado

ID02; RF-09, RF-11, RF-12; CR-162, CR-164. Implementado en `src/modules/miembros/`. Persistencia: **propuesta sin aplicar** en [`fase-2c-miembros.sql`](../propuestas/fase-2c-miembros.sql), sobre [`fase-2a-base.sql`](../propuestas/fase-2a-base.sql); no se aplica sin aprobación expresa. Validada solo contra un PostgreSQL local desechable (`node scripts/validar-propuestas-local.js --solo=2c`), que no certifica RLS ni Auth de Supabase. No crea tablas nuevas: usa `membresia`, `cuidador`, `vinculo`, `notificacion` y `cuenta` de `DB.sql`.

Las decisiones marcadas **Propuesta técnica (Dxx)** eligen lo más simple compatible con las Reglas de Negocio V2; siguen abiertas en CONTEXTO §15.2 hasta que el usuario las confirme.

Convenciones de [CONVENCIONES-API.md](../CONVENCIONES-API.md): rutas en `kebab-case`, DTO en `snake_case`, `{ "data": ... }`, errores `{ "error": { "code", "message" }, "requestId" }`, paginación con `{ data, meta }`. Todas las rutas exigen `Authorization: Bearer <access_token>`. Las de `/cuentas/:cuentaId` pasan antes por `requireCuenta` (404 si el usuario no tiene membresía activa en esa cuenta). Solo `GET`, `POST` y `PATCH`; las acciones son `POST …/accion`. Los identificadores bigint (`membresia_id`, `cuenta_id`, `cuidador_id`) viajan como **texto** (`"21"`), igual que en el contexto de cuenta; en el cuerpo de la petición se aceptan como número o como texto de dígitos.

## Permisos (V2)

| Operación                                                | Permiso                                      | Quién en Familia           | Quién en Organización      |
| -------------------------------------------------------- | -------------------------------------------- | -------------------------- | -------------------------- |
| Listar, ver, invitar, cambiar rol, desactivar, reactivar | `usuarios:gestionar`                         | Coordinador                | **Solo** Administrador     |
| Transferir la titularidad                                | `usuarios:gestionar` y ser el titular actual | Coordinador titular        | Administrador titular      |
| Perfil Cuidador (consultar, guardar, finalizar)          | `cuidadores:gestionar`                       | Coordinador                | Administrador              |
| Aceptar o rechazar una membresía propia                  | Solo sesión                                  | Cualquier persona invitada | Cualquier persona invitada |

El Coordinador de una Organización **no** gestiona miembros ni perfiles de Cuidador; el de una Familia sí. Cada operación se comprueba dos veces: `requirePermiso` (respuesta temprana a partir del contexto de la cuenta) y la RPC, que vuelve a autorizar con `cuidared_interno.exigir`. `usuarios:gestionar` no exige acceso operativo: con la prueba o el plan vencidos (D07) se conserva la gestión de miembros; `cuidadores:gestionar` sí lo exige.

**Propuesta técnica (D04):** la lectura del listado y del detalle también exige `usuarios:gestionar` (incluye correo y teléfono de cada persona). Las listas de candidatos para asignar cuidadores o voluntarios a un adulto son del módulo de adultos mayores (fase 3), no de este.

## Endpoints

| Método y ruta                                                      | Cuerpo                                                         | Respuesta                                                          |
| ------------------------------------------------------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------ |
| GET `/cuentas/:cuentaId/miembros`                                  | —                                                              | 200 paginada: `{ data: [Miembro], meta }`                          |
| GET `/cuentas/:cuentaId/miembros/:membresiaId`                     | —                                                              | 200: `{ data: Miembro }` (también membresías históricas)           |
| POST `/cuentas/:cuentaId/miembros`                                 | `correo`, `cedula` (11 dígitos), `nombres`, `apellidos`, `rol` | 201: `{ data: Miembro + usuario_existente }` (membresía pendiente) |
| PATCH `/cuentas/:cuentaId/miembros/:membresiaId`                   | `{ "rol": "…" }`                                               | 200: la membresía **nueva** (la anterior queda en el historial)    |
| POST `/cuentas/:cuentaId/miembros/:membresiaId/desactivar`         | — (sin cuerpo)                                                 | 200: la membresía ya inactiva                                      |
| POST `/cuentas/:cuentaId/miembros/:membresiaId/reactivar`          | — (sin cuerpo)                                                 | 200: la membresía **nueva**, activa                                |
| POST `/cuentas/:cuentaId/titularidad`                              | `{ "membresia_id": … }`                                        | 200: `{ data: { cuenta_id, usuario_titular_id, membresia_id } }`   |
| GET `/cuentas/:cuentaId/miembros/:membresiaId/cuidador`            | —                                                              | 200: `{ data: Cuidador }` o `{ data: null }`                       |
| POST `/cuentas/:cuentaId/miembros/:membresiaId/cuidador`           | `tipo_cuidado_id`, `cuidador_independiente`                    | 200: `{ data: Cuidador }` (crea o actualiza el perfil vigente)     |
| POST `/cuentas/:cuentaId/miembros/:membresiaId/cuidador/finalizar` | — (sin cuerpo)                                                 | 200: `{ data: Miembro }` ya sin perfil vigente                     |
| POST `/me/membresias/:membresiaId/aceptar`                         | — (sin cuerpo)                                                 | 200: `{ data: { membresia_id, cuenta_id, rol, estado } }`          |
| POST `/me/membresias/:membresiaId/rechazar`                        | — (sin cuerpo)                                                 | 204                                                                |

Los cuerpos son `strictObject`: cualquier campo desconocido (`cuenta_id`, `usuario_id`, `estado`, `usuario_empleador_id`, fechas…) es 422. Las acciones sin datos tampoco admiten cuerpo. Un id de ruta que no sea un entero positivo seguro es 404 sin consultar la base. No existen PUT ni DELETE: el historial se conserva.

### DTO `Miembro`

```json
{
  "membresia_id": "21",
  "rol": "cuidador",
  "estado": "activa",
  "fecha_inicio": "2026-11-06",
  "fecha_fin": null,
  "es_titular": false,
  "usuario": {
    "id": "b0c1d2e3-0000-4000-8000-000000000021",
    "nombres": "Diego",
    "apellidos": "Cuidador",
    "correo": "diego@example.test",
    "telefono": null
  },
  "cuidador": null
}
```

`rol`: `administrador`, `coordinador`, `cuidador`, `familiar` o `voluntario` (código de BD: el frontend local usa `admin`, que su adaptador debe traducir). `estado`: `pendiente` (invitación sin aceptar), `activa` o `inactiva` (el frontend local las llama `invitado`, `activo` e `inactivo`). La cédula **no** se expone. `cuidador` es `null` o el perfil vigente de la persona **en esa cuenta**:

```json
{
  "cuidador_id": "5",
  "tipo_cuidado_id": 1,
  "tipo_cuidado": "Cuidador remunerado",
  "cuidador_independiente": false,
  "usuario_empleador_id": "a271ce25-7f40-4c45-b5ba-dbc6a0011234",
  "fecha_inicio": "2026-11-06"
}
```

El catálogo de `tipo_cuidado_id` es `GET /catalogos/tipos-cuidado`. El DTO se reduce a esta lista cerrada de campos antes de salir; un contrato roto de la RPC responde 503.

### Listado

Una fila **por persona**: su membresía vigente (pendiente o activa) o, si no tiene, la más reciente (historial de bajas o rechazos). Los filtros y el orden se aplican a esa fila.

- `sort`: `nombres`, `apellidos`, `fecha_inicio`, `rol`, `estado`, `membresia_id` (prefijo `-` para descendente). Predeterminado: `nombres,apellidos,fecha_inicio`, desempate por `membresia_id`. Los nombres se ordenan sin distinguir mayúsculas.
- `filter[rol]`: `administrador`, `coordinador`, `cuidador`, `familiar`, `voluntario`. `filter[estado]`: `pendiente`, `activa`, `inactiva`. Igualdad.
- `page` (1) y `limit` (20, máximo 100). Parámetros desconocidos, repetidos o inválidos: 422. El orden llega a la RPC como arreglo de campos de una lista cerrada, nunca como SQL; `total` y `data` salen del mismo conjunto autorizado y filtrado.

## Flujos

### Invitar (`POST /cuentas/:cuentaId/miembros`)

1. `api_preparar_invitacion` (RPC con el JWT de quien invita; no escribe): autoriza `usuarios:gestionar`, valida que el **rol exista en el tipo de cuenta** (`CR_ROL_NO_PERMITIDO`) y que haya **cupo en el plan** (`CR_LIMITE_PLAN`), y responde `{ usuario_existe }`. Si la persona ya existe (se busca por correo, sin distinguir mayúsculas) exige que la **cédula coincida** y que esté activa (`CR_IDENTIDAD_NO_COINCIDE`, 409 con mensaje genérico, que también cubre una cédula ya registrada con otro correo) y que no tenga una membresía vigente en la cuenta (`CR_YA_ES_MIEMBRO`).
2. Si la persona **no existe**: sin `deps.adminGateway` → 503 `INVITATIONS_UNAVAILABLE`. Con él, `adminGateway.inviteUser({ email, cedula, nombres, apellidos })` crea la identidad Auth (el trigger crea el perfil y se envía el correo con el código). Es la única operación con la clave secreta y no toca tablas de negocio.
3. `api_agregar_miembro` (RPC con el JWT de quien invita) vuelve a comprobar **todo** bajo el bloqueo de la cuenta (permiso, rol, identidad por correo y cédula —nunca por un id del cliente—, membresía vigente y cupo) y crea la membresía **pendiente** (`fecha_inicio` = hoy de negocio) y una **notificación personal** para la persona.

Si el paso 3 falla tras crear la identidad (p. ej. otra invitación ocupó el último cupo), la identidad queda sin membresía; reintentar la invitación encuentra a la persona ya registrada y continúa desde el paso 3 sin enviar otro correo. Una invitación pendiente **no concede acceso**: `membresia_activa` solo devuelve membresías `activa`. Las invitaciones se limitan a 30 por persona que invita cada 15 minutos (429), porque pueden enviar correo y confirman si un correo ya tiene perfil.

### Aceptar o rechazar (`/me/membresias/:id/…`)

Solo la persona invitada y solo sobre su membresía **pendiente** (la de otra persona o inexistente es 404; si ya no está pendiente, `CR_ESTADO_INVALIDO`). Aceptar vuelve a comprobar el cupo del plan (puede haber cambiado desde la invitación; los Voluntarios no consumen cupo), pasa a `activa` y fija `fecha_inicio` = hoy. Rechazar pasa a `inactiva` con `fecha_fin` = hoy; se puede volver a invitar. Así funciona también la invitación de una persona nueva cuando activa su cuenta (fase 1): al entrar, sus membresías pendientes aparecen en `GET /me` (`cuentas[]`, con `membresia_id`) y se aceptan aquí.

### Cambiar rol (V2: historial)

`PATCH` cierra la membresía actual (`inactiva`, `fecha_fin` = hoy) y crea otra `activa` con el nuevo rol; devuelve la nueva. En la misma transacción se **revocan los vínculos de acceso del rol anterior** (`cuidador_asignado`, `voluntario_asignado`, `familiar_responsable` que no correspondan al nuevo rol) sobre los adultos **de esa cuenta**; el vínculo `referente` y los de otras cuentas no se tocan. Si el rol anterior era `cuidador`, se finaliza su perfil Cuidador de esa cuenta. Solo se pueden cambiar membresías `activa`. Protecciones: no sobre la membresía propia (`CR_MEMBRESIA_PROPIA`); el titular conserva un rol gestor (`CR_TITULAR_PROTEGIDO`); siempre queda al menos un gestor activo (`CR_ULTIMO_GESTOR`). Se exige cupo solo si el cambio **aumenta** el uso (p. ej. Voluntario → Cuidador); pasar de un rol que ya cuenta a otro no lo exige.

### Desactivar y reactivar

`desactivar` pasa la membresía a `inactiva` con `fecha_fin` = hoy (también cancela una invitación pendiente) con las mismas protecciones. La baja **revoca el acceso** de inmediato porque `membresia_activa` deja de devolverla; se conservan los vínculos y el perfil Cuidador. `reactivar` crea una membresía **activa nueva** con el mismo rol, respetando el cupo; la membresía indicada debe ser la más reciente de la persona en la cuenta y estar inactiva (`CR_ESTADO_INVALIDO` si no).

### Titularidad

Solo la persona titular actual (403 si no lo es). El destino debe ser **otra** persona con membresía **activa** y rol **gestor** del tipo de cuenta (Administrador en Organización, Coordinador en Familia): `CR_DESTINO_NO_GESTOR` (422) o `CR_ESTADO_INVALIDO` (409). Actualiza `cuenta.usuario_titular_id` y queda auditado (`cuenta.titularidad_transferida`). Con otro titular, quien cedió deja de estar protegido y ya puede cambiar de rol o desactivarse; esto resuelve el pendiente del frontend. La titularidad de pago (fase 8) sigue a `usuario_titular_id`.

### Perfil Cuidador (RF-12)

Un perfil vigente (`fecha_fin` nula) por persona y cuenta (`uq_cuidador_vigente`): una misma persona puede ser Cuidador de varias cuentas, con un perfil en cada una. `POST` hace upsert del perfil vigente; solo para miembros con rol `cuidador` y membresía `pendiente` o `activa` (`CR_NO_ES_CUIDADOR`, `CR_ESTADO_INVALIDO`); `tipo_cuidado_id` debe existir (422). **Propuesta técnica (D14):** si `cuidador_independiente` es `false`, `usuario_empleador_id` es el **titular** de la cuenta (siempre es gestor: Coordinador en Familia, Administrador en Organización) aunque el perfil lo registre otro gestor; si es `true`, queda `null`. `finalizar` pone `fecha_fin` = hoy (`CR_ESTADO_INVALIDO` si no hay perfil vigente); registrar uno nuevo después conserva el historial.

## Errores

| Origen                               | HTTP | Código público            | Cuándo                                                                 |
| ------------------------------------ | ---- | ------------------------- | ---------------------------------------------------------------------- |
| `requireSession`                     | 401  | `INVALID_SESSION`         | Sin sesión válida.                                                     |
| `requireCuenta`                      | 404  | `NOT_FOUND`               | Sin membresía activa en la cuenta o id de cuenta/membresía inválido.   |
| `requirePermiso` / `42501`           | 403  | `FORBIDDEN`               | Rol sin permiso, o transferir la titularidad sin ser el titular.       |
| `requirePermiso`                     | 403  | `SUBSCRIPTION_INACTIVE`   | Perfiles Cuidador con la cuenta sin prueba ni plan vigente.            |
| Zod / `22023`                        | 422  | `INVALID_INPUT`           | Cuerpo, consulta o parámetros inválidos.                               |
| `P0002`                              | 404  | `NOT_FOUND`               | La membresía no existe **en esa cuenta** (o no es de quien llama).     |
| `CR_ROL_NO_PERMITIDO`                | 422  | `ROLE_NOT_ALLOWED`        | Rol que no existe en el tipo de cuenta.                                |
| `CR_DESTINO_NO_GESTOR`               | 422  | `NEW_OWNER_NOT_MANAGER`   | Destino de titularidad sin rol gestor.                                 |
| `CR_LIMITE_PLAN`                     | 409  | `PLAN_LIMIT_REACHED`      | Sin cupo en el plan (usuarios o familiares).                           |
| `CR_IDENTIDAD_NO_COINCIDE`           | 409  | `IDENTITY_MISMATCH`       | Cédula distinta, persona inactiva o cédula ya registrada (genérico).   |
| `CR_YA_ES_MIEMBRO` / `23505`         | 409  | `ALREADY_MEMBER`          | Ya tiene una membresía vigente en la cuenta.                           |
| `CR_MEMBRESIA_PROPIA`                | 409  | `OWN_MEMBERSHIP`          | Cambiar o desactivar la propia membresía.                              |
| `CR_TITULAR_PROTEGIDO`               | 409  | `OWNER_PROTECTED`         | Quitar el rol gestor o desactivar al titular.                          |
| `CR_ULTIMO_GESTOR`                   | 409  | `LAST_MANAGER`            | Dejaría la cuenta sin gestor activo.                                   |
| `CR_NO_ES_CUIDADOR`                  | 409  | `NOT_A_CAREGIVER`         | Perfil Cuidador para un miembro con otro rol.                          |
| `CR_ESTADO_INVALIDO`                 | 409  | `INVALID_STATE`           | Estado incompatible (no pendiente, no activa, ya activa, sin perfil…). |
| `adminGateway.inviteUser`            | 409  | `INVITATION_CONFLICT`     | El proveedor rechazó crear la identidad.                               |
| Falta de `adminGateway`              | 503  | `INVITATIONS_UNAVAILABLE` | Persona nueva sin clave administrativa configurada.                    |
| Más de 30 invitaciones en 15 minutos | 429  | `RATE_LIMITED`            | Límite por persona que invita.                                         |

Los códigos `CR_*` propios se registran en [`miembros-errors.js`](../../src/modules/miembros/miembros-errors.js), que importan ambos routers; `CR_LIMITE_PLAN`, `CR_ROL_NO_PERMITIDO` y `CR_ESTADO_INVALIDO` vienen de `lib/business-errors.js`. Los mensajes son genéricos y no revelan datos de otra persona ni de otra cuenta.

## Límites del plan

**Propuesta técnica (D07):** `cuidared_interno.limites(cuenta)` da `usuarios` y `familiares` (`null` = ilimitado; del plan activo o de la prueba). Cuentan las membresías **vigentes** (`pendiente` y `activa`, una por persona): una invitación pendiente reserva su cupo. El **Voluntario no cuenta** para `usuarios` (registra visitas sin plan propio). El **Familiar** cuenta para `usuarios` y para `familiares`. Si el plan se reduce y la cuenta queda por encima del límite, no se pueden invitar, aceptar ni reactivar usuarios hasta liberar cupo, pero sí cambiar roles que no aumenten el uso.

## Concurrencia

Toda operación que cambia membresías de una cuenta (invitar, aceptar, rechazar, cambiar rol, desactivar, reactivar, titularidad, perfil Cuidador) toma un **bloqueo de asesoría por cuenta** (`pg_advisory_xact_lock`) y, tras esperarlo, **vuelve a autorizar** a quien llama: dos invitaciones simultáneas no superan el límite y dos bajas simultáneas no dejan la cuenta sin gestor. Verificado a mano con dos sesiones en el PostgreSQL local (la segunda espera y recibe `CR_LIMITE_PLAN`). Además `uq_membresia_vigente` y `uq_cuidador_vigente` impiden duplicados aunque el bloqueo fallara (23505).

## Persistencia (RPC en `cuidared_api`)

Todas son `security definer`, con `search_path` vacío, `revoke` a `public` y `anon`, `grant` a `authenticated`, y autorizan con `cuidared_interno.exigir` (o `exigir_sesion` en las de membresía propia). La identidad sale solo de `auth.uid()`.

| RPC                                                                                                | Permiso                             |
| -------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `api_listar_miembros(cuenta, rol, estado, orden, limite, desplazamiento)`                          | `usuarios:gestionar`                |
| `api_detalle_miembro(cuenta, membresia)`                                                           | `usuarios:gestionar`                |
| `api_preparar_invitacion(cuenta, correo, cedula, rol)`                                             | `usuarios:gestionar`                |
| `api_agregar_miembro(cuenta, correo, cedula, rol)`                                                 | `usuarios:gestionar`                |
| `api_cambiar_rol_miembro(cuenta, membresia, rol)`                                                  | `usuarios:gestionar`                |
| `api_desactivar_miembro(cuenta, membresia)` / `api_reactivar_miembro(…)`                           | `usuarios:gestionar`                |
| `api_transferir_titularidad(cuenta, membresia)`                                                    | `usuarios:gestionar` + titular      |
| `api_obtener_cuidador_miembro` / `api_guardar_cuidador_miembro` / `api_finalizar_cuidador_miembro` | `cuidadores:gestionar`              |
| `api_aceptar_membresia(membresia)` / `api_rechazar_membresia(membresia)`                           | Sesión (membresía propia pendiente) |

También se activa RLS y se revoca el acceso directo de `authenticated` a `membresia` y `cuidador` (defensa en profundidad, idempotente) y se añade el índice `ix_membresia_cuenta`. Códigos SQL: `28000` sin sesión, `42501` sin permiso, `P0002` no existe, `22023` entrada inválida, `P0001` + `CR_*` regla de negocio.

## Decisiones propuestas

- **D07** límites: voluntarios fuera de `usuarios`; familiares dentro de `usuarios` y `familiares`; las invitaciones pendientes reservan cupo; aceptar vuelve a comprobarlo.
- **D09** una membresía vigente por persona y cuenta y un perfil Cuidador vigente por persona y cuenta; serialización por cuenta.
- **D04** al cambiar de rol se revocan los vínculos de acceso del rol anterior y se finaliza el perfil Cuidador; al desactivar se conservan (el acceso se corta por la membresía); listado y detalle exigen `usuarios:gestionar`.
- **D14** aviso personal a la persona invitada (con nombre de cuenta y rol, sin datos de adultos); empleador del Cuidador no independiente = titular.
- **D15** desactivar y cambiar de rol conservan el historial; nada se borra salvo los vínculos de acceso del rol anterior.
- Reactivar no distingue una invitación rechazada de una baja: la membresía más reciente inactiva se reactiva con su rol.

## Verificación

- `tests/miembros.test.js`: 172 pruebas HTTP con gateway simulado (éxito, 401, 403, 404, 422, 409, aislamiento entre cuentas, permisos por rol y tipo de cuenta, flujo de invitación con y sin `adminGateway`, límites, titularidad, perfil Cuidador y membresías propias).
- `docs/verificacion/local/pruebas-2c-*.sql`: RPC contra PostgreSQL local, dentro de `begin … rollback`, con las ayudas de `pruebas-00-ayudas.sql`.
- No se probó contra Supabase real: RLS y Auth requieren aprobación y revisión aparte.
