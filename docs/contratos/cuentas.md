# Contrato — Cuentas, configuración, suscripción y catálogos (fase 2, bloque 2b)

## Alcance y estado

ID02; RF-11, RF-19, RF-20; CR-157, CR-162, CR-164, CR-165. Implementado en `src/modules/cuentas/` y `src/modules/catalogos/` (más el handler `GET /me`). Persistencia: **propuesta sin aplicar** en [`fase-2b-cuentas.sql`](../propuestas/fase-2b-cuentas.sql), sobre [`fase-2a-base.sql`](../propuestas/fase-2a-base.sql); no se aplica sin aprobación expresa. Validada solo contra un PostgreSQL local desechable (`node scripts/validar-propuestas-local.js --solo=2b`), que no certifica RLS ni Auth de Supabase. Stripe y los pagos llegan en la fase 8: aquí no hay cobro, contratación ni cambio de plan.

Las decisiones marcadas **Propuesta técnica (Dxx)** eligen lo más simple compatible con las Reglas de Negocio V2 y el frontend; siguen abiertas en CONTEXTO §15.2 hasta que el usuario las confirme.

Convenciones de [CONVENCIONES-API.md](../CONVENCIONES-API.md): rutas en `kebab-case`, DTO en `snake_case`, `{ "data": ... }`, errores `{ "error": { "code", "message" }, "requestId" }`. Todas las rutas exigen `Authorization: Bearer <access_token>`. Las rutas de `/cuentas/:cuentaId` pasan antes por `requireCuenta` (404 si el usuario no tiene membresía activa: no se revela si la cuenta existe).

## Endpoints

`cuenta_id` y los demás identificadores de cuenta viajan como **texto** en los DTO (`"7"`). Los importes (`precio`) son números; las fechas de calendario, `YYYY-MM-DD`; las marcas de tiempo, ISO 8601 UTC.

| Método y ruta                            | Permiso                                                   | Cuerpo                                                                                           | Respuesta                                                                          |
| ---------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| POST `/cuentas`                          | Solo sesión (sin membresía)                               | `tipo`, `nombre`, `categoria_cuenta_id`, `municipio_cod`, `direccion?`, `telefono?`, `correo?`   | 201 + cabecera `Location`: contexto de la cuenta creada (ver DTO de contexto).     |
| GET `/me`                                | Solo sesión                                               | —                                                                                                | 200: `identity`, `profile`, `cuenta_activa_id: null`, `cuentas[]` (ver CR-164).    |
| GET `/cuentas/:cuentaId`                 | Cualquier miembro activo                                  | —                                                                                                | 200: `{ cuenta, contexto, uso }`.                                                  |
| PATCH `/cuentas/:cuentaId`               | `organizacion:configurar`                                 | Uno o más de `nombre`, `categoria_cuenta_id`, `municipio_cod`, `direccion`, `telefono`, `correo` | 200: igual que GET.                                                                |
| GET `/cuentas/:cuentaId/configuracion`   | Cualquier miembro activo                                  | —                                                                                                | 200: arreglo de parámetros efectivos.                                              |
| PATCH `/cuentas/:cuentaId/configuracion` | `organizacion:configurar`                                 | `{ "valores": { "<nombre>": "<valor>" \| null } }`                                               | 200: configuración efectiva completa (igual que GET).                              |
| GET `/cuentas/:cuentaId/suscripcion`     | Cualquier miembro activo; planes con `cuenta:suscripcion` | —                                                                                                | 200: estado, prueba, plan, límites, uso, funcionalidades y (con permiso) `planes`. |
| GET `/catalogos/:catalogo`               | Solo sesión (sin cuenta)                                  | Filtros por query string (ver Catálogos)                                                         | 200: `{ data: [...] }`; `municipios` añade `meta`.                                 |

Solo `GET`, `POST` y `PATCH`. `organizacion:configurar` y `cuenta:suscripcion` están en la matriz de [`permisos.js`](../../src/modules/cuentas/permisos.js): el Administrador en Organización y el Coordinador en Familia. Ambas, junto con la lectura de la cuenta, **no exigen acceso operativo**: con la prueba o el plan vencidos (V2, D07) el usuario conserva el acceso a su cuenta, su configuración y su suscripción, y quien tiene permiso sigue pudiendo gestionarlas. Cada RPC vuelve a autorizar en la base.

### Alta de cuenta (`POST /cuentas`)

La RPC `api_registrar_cuenta` toma la identidad de `auth.uid()`. En una transacción crea la cuenta en prueba, fija el inicio al instante de creación y el fin 168 horas después, y crea la membresía activa del titular como Coordinador en Familia o Administrador en Organización. La prueba comienza con `plan_id = null`. Enviar campos de titular, rol, estado, plan o fechas devuelve 422.

- `tipo`: `familia` | `organizacion`. `categoria_cuenta_id`: entero; debe ser una categoría activa **del mismo tipo** de cuenta.
- `nombre`: 2–120 caracteres. `municipio_cod`: `^[0-9]{4,6}$` y existente en `cuidared.municipio`. `direccion`: hasta 150. `correo`: formato de correo, hasta 254, se guarda en minúsculas.
- `telefono`: Express quita espacios y guiones y exige `^\+?[0-9]{10,15}$` (`"+1 809-555-1234"` → `"+18095551234"`). Una cadena vacía en `direccion`, `telefono` o `correo` se guarda como `null`.
- Un titular no puede tener dos cuentas con prueba **vigente** a la vez (`CR_PRUEBA_EN_CURSO`, 409). La comprobación se serializa por usuario con un lock de asesoría: dos solicitudes simultáneas no la eluden.

### DTO de contexto de cuenta (CR-164)

Mismo objeto en la respuesta de `POST /cuentas`, en `GET /cuentas/:cuentaId` (`contexto`) y en cada cuenta activa de `GET /me`:

```json
{
  "cuenta_id": "7",
  "nombre": "Familia Pérez",
  "tipo": "familia",
  "rol": "coordinador",
  "estado_membresia": "activa",
  "permisos": ["adultos:ver", "usuarios:gestionar"],
  "estado_suscripcion": "prueba",
  "funcionalidades": ["registro_visitas", "necesidades_diarias"],
  "es_titular": true,
  "acceso_operativo": true,
  "limites": { "envejecientes": 2, "usuarios": 4, "familiares": 2 }
}
```

`limites` en `null` = ilimitado. `estado_suscripcion`: `prueba`, `activa`, `vencida`, `cancelada` o `suspendida`. `funcionalidades` queda vacío cuando `acceso_operativo` es `false`.

### `GET /me` con cuentas (CR-164)

Conserva `identity` y `profile` de la fase 1 y agrega `cuentas` y `cuenta_activa_id`:

- Primero las cuentas **activas** (DTO de contexto) y luego las **pendientes** de aceptar: `{ cuenta_id, nombre, tipo, rol, estado_membresia: "pendiente", permisos: [], estado_suscripcion: null, funcionalidades: [], es_titular: false, acceso_operativo: false, limites: null, membresia_id }`.
- `cuenta_activa_id` es siempre `null`: el servidor no recuerda una cuenta activa. La cuenta viaja en la ruta `/cuentas/:cuentaId` y nunca concede acceso por sí misma. Una identidad con varias cuentas recibe cada una con su propio rol y permisos, sin mezclarlos.
- Si la base no responde o rompe el contrato, `/me` responde 503: no se disfraza de «sin cuentas».

### `GET` y `PATCH /cuentas/:cuentaId`

```json
{
  "data": {
    "cuenta": {
      "cuenta_id": "7",
      "nombre": "Familia Pérez",
      "tipo": "familia",
      "categoria": { "categoria_cuenta_id": 1, "nombre": "Monitoreo a distancia" },
      "municipio": {
        "municipio_cod": "0101",
        "nombre": "Santo Domingo de Guzmán",
        "provincia_cod": "01",
        "provincia": "Distrito Nacional"
      },
      "direccion": "Calle 1",
      "telefono": "+18095551234",
      "correo": null,
      "fecha_creacion": "2026-11-06T20:00:09.151Z"
    },
    "contexto": { "...": "DTO de contexto" },
    "uso": { "envejecientes": 1, "usuarios": 2, "familiares": 0, "voluntarios": 0 }
  }
}
```

`PATCH` no cambia el tipo, el titular ni la suscripción (campos extra → 422). `direccion`, `telefono` y `correo` admiten `null` para vaciarlos. La categoría nueva debe ser del mismo tipo de la cuenta. `uso` se compara con `contexto.limites`: `envejecientes` son los adultos en estado activo; `usuarios`, los miembros activos que no son voluntarios (incluye familiares); `familiares` y `voluntarios` se informan aparte.

### Configuración (`/configuracion`, RF-19)

```json
{
  "data": [
    {
      "nombre": "dias_sin_visita_alerta",
      "valor": "30",
      "tipo_dato": "entero",
      "es_propio": true,
      "valor_general": "15",
      "descripcion": "Días calendario sin visita realizada para la alerta de seguimiento (RF-05)."
    }
  ]
}
```

`valor` es el efectivo: el propio de la cuenta si `es_propio`, o el valor general del parámetro. Los valores siempre son texto. `PATCH` recibe `{ "valores": { "<nombre>": "<valor>" | null } }` (entre 1 y 50 nombres). Express normaliza números y booleanos JSON a su texto (`30` → `"30"`, `false` → `"false"`). La RPC acepta solo nombres existentes y valida el dominio por `tipo_dato`; **todo o nada**: si uno falla, no se aplica ninguno (`CR_PARAMETRO_INVALIDO`, 422). `null` borra el valor propio y la cuenta vuelve al valor general.

| `tipo_dato` | Dominio válido                                       |
| ----------- | ---------------------------------------------------- |
| `entero`    | Entero de 1 a 90 (los parámetros actuales son días). |
| `decimal`   | De 0 a 100000, hasta 4 decimales.                    |
| `booleano`  | `"true"` o `"false"`.                                |
| `texto`     | Hasta 120 caracteres, sin caracteres de control.     |

Los nombres están en minúsculas (restricción de `cuidared.parametro`): `dias_sin_visita_alerta`, `dias_escalar_necesidad`, `notificar_casos_prioritarios`, `notificar_nuevos_voluntarios`, `contacto_institucional_nombre`, `contacto_institucional_telefono`. El frontend usa las claves en mayúsculas (`DIAS_SIN_VISITA_ALERTA`…) y debe mapearlas.

Auditoría: Express registra `cuenta.config_updated` (sin los valores, solo actor, acción y resultado) y `cuenta.updated` / `cuenta.created` con el mismo criterio; los triggers de `cuidared.auditoria` de la base registran el cambio de datos (ver el aviso de la propuesta SQL: deben cubrir `cuenta` y `configuracion_cuenta`).

### Suscripción (`/suscripcion`, RF-20)

```json
{
  "data": {
    "estado": "prueba",
    "acceso_operativo": true,
    "prueba": {
      "gratuita": true,
      "vigente": true,
      "fecha_inicio": "2026-11-06",
      "fecha_fin": "2026-11-13",
      "dias_restantes": 7
    },
    "plan": null,
    "fecha_fin_vigencia": null,
    "limites": { "envejecientes": 2, "usuarios": 4, "familiares": 2 },
    "uso": { "envejecientes": 0, "usuarios": 1, "familiares": 0, "voluntarios": 0 },
    "funcionalidades": ["registro_visitas", "necesidades_diarias"],
    "planes": [
      {
        "plan_id": 1,
        "nombre": "Básico Familiar",
        "categoria": "Básico",
        "precio": 650,
        "periodicidad": "mensual",
        "duracion_dias": 30,
        "resumen": "Hasta 2 adultos mayores y 3 familiares…",
        "limites": { "envejecientes": 2, "usuarios": null, "familiares": 3 },
        "funcionalidades": ["registro_visitas", "necesidades_diarias", "visitas_recurrentes"],
        "es_actual": false
      }
    ]
  }
}
```

- Para todos los miembros se devuelve `estado`, `acceso_operativo`, `prueba` con inicio, fin y `dias_restantes`, `plan`, `fecha_fin_vigencia`, `limites`, `uso` y `funcionalidades`. Para una prueba histórica sin hora, los instantes son `null` y `acceso_operativo` es `false` mientras se revisa su vigencia.
- `planes` solo si el rol tiene `cuenta:suscripcion`: planes activos compatibles con el tipo de cuenta, ordenados por precio; `es_actual` solo es `true` con la suscripción activa. Para los demás roles la clave no existe (la API lo recorta aunque la base la entregara).
- No hay precios definitivos (D07): los de la propuesta SQL son referenciales en DOP.

### Vigencia (`cuidared_interno.actualizar_vencimientos()`)

Pasa a `vencida` las pruebas con `fecha_fin_prueba <= now()` y las suscripciones activas con `fecha_fin_vigencia < hoy()`. Es idempotente, devuelve cuántas cuentas cambió y conserva `plan_id`. `acceso_operativo()` calcula la vigencia en cada llamada. La función de actualización es interna. El bloque de programación con `pg_cron` queda como propuesta pendiente de aprobación.

## Catálogos con caché (CR-165)

`GET /catalogos/:catalogo` exige sesión, no cuenta: son datos de referencia comunes a todos los usuarios y sin datos personales. Lista cerrada (cualquier otro nombre es 404). Se publican solo los registros activos de los catálogos con estado.

| Catálogo            | Filtro (query string)             | Campos de cada elemento                                                                                                      |
| ------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `provincias`        | —                                 | `provincia_cod`, `nombre`                                                                                                    |
| `municipios`        | `provincia_cod` (2 dígitos)       | `municipio_cod`, `nombre`, `provincia_cod`; **paginado**                                                                     |
| `tipos-cuenta`      | —                                 | `tipo_cuenta_id`, `codigo`, `nombre`                                                                                         |
| `categorias-cuenta` | `tipo` (`familia`/`organizacion`) | `categoria_cuenta_id`, `nombre`, `tipo_cuenta_id`, `tipo`                                                                    |
| `roles`             | —                                 | `rol_id`, `codigo`, `nombre`, `descripcion`, `tipos` (tipos de cuenta que lo admiten, según la matriz)                       |
| `planes`            | `tipo`                            | `plan_id`, `nombre`, `categoria`, `tipo`, `precio`, `periodicidad`, `duracion_dias`, `resumen`, `limites`, `funcionalidades` |
| `tipos-cuidado`     | —                                 | `tipo_cuidado_id`, `nombre`                                                                                                  |
| `tipos-vinculo`     | —                                 | `tipo_vinculo_id`, `codigo`, `nombre`                                                                                        |
| `prioridades`       | —                                 | `prioridad_id`, `nombre`, `orden`                                                                                            |
| `niveles-riesgo`    | —                                 | `nivel_riesgo_id`, `nombre`, `orden`                                                                                         |
| `riesgos`           | —                                 | `riesgo_id`, `nombre`, `descripcion`                                                                                         |
| `tipos-necesidad`   | —                                 | `tipo_necesidad_id`, `nombre`                                                                                                |
| `necesidades`       | `tipo_necesidad_id`               | `necesidad_id`, `nombre`, `tipo_necesidad_id`, `descripcion`                                                                 |
| `tipos-alerta`      | —                                 | `tipo_alerta_id`, `codigo`, `nombre`                                                                                         |
| `tipos-indicacion`  | —                                 | `tipo_indicacion_id`, `nombre`                                                                                               |
| `metodos-pago`      | —                                 | `metodo_pago_id`, `nombre`                                                                                                   |

- **Filtros simples, no `filter[...]`:** un catálogo es referencia, no una colección de negocio. Un parámetro desconocido, repetido o inválido es 422 (también `page`/`limit`/`sort` en los catálogos no paginados).
- **`municipios` sigue CR-162:** `page` (desde 1), `limit` (predeterminado 20, máximo 100), `sort` (`nombre` por omisión, o `municipio_cod`; con desempate por `municipio_cod`) y respuesta `{ data, meta: { page, limit, total, totalPages } }`. Para cargar los municipios de una provincia en un selector conviene `?provincia_cod=02&limit=100`.
- **Caché:** en memoria de la API, 5 minutos por clave (catálogo + filtros + página), acotada a 500 claves, con una sola carga para peticiones simultáneas y sin guardar errores. Las respuestas 200 llevan `Cache-Control: private, max-age=300` (la API usa `no-store` por defecto y solo lo cambia aquí). Un cambio en un catálogo se ve en hasta 5 minutos en la API más hasta 5 en el navegador; no hay invalidación manual. Con varias instancias, cada una mantiene su propia caché. Criterio CR-165 (< 500 ms): una respuesta en caché no consulta la base.
- **Territorio (D14 pendiente):** esta propuesta **no siembra** provincias ni municipios. La base remota debe tenerlos cargados antes de aplicar el alta de cuentas: `municipio_cod` es obligatorio y se valida contra `cuidared.municipio`. Sin territorio cargado, todo `POST /cuentas` responde 422.

## Errores

Además de los códigos transversales de [CONVENCIONES-API.md](../CONVENCIONES-API.md) (401, 403 `FORBIDDEN`, 404, 422 `INVALID_INPUT`, 503) y de los ya registrados en `src/lib/business-errors.js`:

| Código SQL (P0001)      | HTTP | Código público      | Cuándo                                                                              |
| ----------------------- | ---- | ------------------- | ----------------------------------------------------------------------------------- |
| `CR_CATEGORIA_INVALIDA` | 422  | `INVALID_CATEGORY`  | La categoría no existe, está inactiva o no es del tipo de cuenta (alta y PATCH).    |
| `CR_PRUEBA_EN_CURSO`    | 409  | `TRIAL_IN_PROGRESS` | El titular ya tiene otra cuenta con prueba gratuita vigente.                        |
| `CR_PARAMETRO_INVALIDO` | 422  | `INVALID_PARAMETER` | Parámetro inexistente o valor fuera del dominio de su `tipo_dato` (nada se aplica). |

Registrados en [`cuentas-errors.js`](../../src/modules/cuentas/cuentas-errors.js). Un `22023` de la base (municipio inexistente, teléfono mal formado que llegara a la RPC) es `422 INVALID_INPUT`. Los mensajes públicos son fijos: nunca incluyen texto del proveedor.

## RPC y esquema (propuesta sin aplicar)

Todas en `cuidared_api`, `security definer`, `set search_path = ''`, `revoke ... from public, anon` y `grant execute ... to authenticated`; la identidad sale solo de `auth.uid()` y ninguna recibe usuario, rol ni permisos por parámetro. La propuesta **no crea tablas ni columnas**: usa las de la base y de 2a.

| RPC                                                    | Autorización                                      | Resultado                                                    |
| ------------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------ |
| `api_registrar_cuenta(p_datos jsonb)`                  | Sesión vigente y usuario activo                   | Contexto de la cuenta creada.                                |
| `api_obtener_cuenta(p_cuenta_id bigint)`               | `exigir_miembro` (membresía activa)               | `{ cuenta, contexto, uso }`.                                 |
| `api_actualizar_cuenta(p_cuenta_id, p_datos)`          | `exigir(…, 'organizacion:configurar')`            | Igual que `api_obtener_cuenta`.                              |
| `api_obtener_configuracion(p_cuenta_id)`               | `exigir_miembro`                                  | Arreglo de parámetros efectivos.                             |
| `api_actualizar_configuracion(p_cuenta_id, p_valores)` | `exigir(…, 'organizacion:configurar')`            | Configuración efectiva completa.                             |
| `api_obtener_suscripcion(p_cuenta_id)`                 | `exigir_miembro`; planes con `cuenta:suscripcion` | Estado, prueba, plan, límites, uso, funcionalidades, planes. |
| `api_catalogo(p_nombre text, p_filtro jsonb)`          | Sesión vigente                                    | `{ items, total }`.                                          |

Ayudas internas nuevas en `cuidared_interno` (sin acceso de la API): `exigir_miembro`, `uso_de_cuenta`, `cuenta_detalle`, `configuracion_efectiva`, `valor_parametro_valido` y `actualizar_vencimientos`. `exigir_miembro` es la variante de `exigir` para leer la propia cuenta (cualquier miembro activo, sin acción concreta y sin exigir acceso operativo); `exigir` seguiría siendo el punto único para toda acción con permiso.

## Propuestas técnicas (decisiones abiertas)

- **Prueba única (D07):** 7 días fijos, sin plan, en la cuenta. Anti-abuso mínimo: un titular no tiene dos pruebas vigentes a la vez. Queda abierto si la regla de V2 «una sola vez» debe limitarse por persona (hoy un titular puede abrir otra cuenta con otra prueba cuando la anterior venció) o por cuenta.
- **Vigencia (D07):** el acceso se calcula por fecha en cada llamada; el trabajo diario solo actualiza el estado. Cuenta vencida: lectura de cuenta, configuración y suscripción para todos los miembros; gestión de cuenta y configuración para quien tiene `organizacion:configurar`; planes para quien tiene `cuenta:suscripcion`. Solo el titular paga (fase 8).
- **Configuración (D14):** `configuracion_cuenta.valor` > `parametro.valor` (valor general); `parametro.valor_defecto` queda como referencia de fábrica. Dominios por tipo de dato como en la tabla anterior; los enteros se limitan a 1–90 porque hoy todos son plazos en días (un parámetro entero de otra naturaleza necesitará su propio rango).
- **Uso frente a límites (D04/D07):** `usuarios` incluye familiares y excluye voluntarios, igual que el frontend; las invitaciones pendientes **reservan cupo** (mismo criterio que el bloque 2c al invitar y al aceptar).
- **Formatos (D09):** teléfono `^\+?[0-9]{10,15}$` con normalización en Express; nombre de cuenta 2–120; dirección hasta 150.
- **Cuenta activa (D08):** por ruta (`/cuentas/:cuentaId`), no por cabecera; `/me` no la elige.

## Integración con el frontend

El prototipo (`CuidaRed-Frontend`) difiere en estos puntos, que su integración debe adaptar:

- Rol del administrador: `administrador` (backend) frente a `admin` (prototipo local). El tipo `CuentaMe` del cliente conectado admite `estado_membresia` `activa`/`inactiva`; ahora también llega `pendiente`.
- Prueba gratuita de **7 días** (decisión del usuario, 2026-11-06), no 14.
- `cuenta_id` es texto en el DTO; los identificadores de catálogo (`categoria_cuenta_id`, `plan_id`…) son números.
- Claves de parámetros en minúsculas; valores siempre en texto.

## Validación

- `tests/cuentas-alta.test.js`, `tests/cuentas-me.test.js`, `tests/cuentas-cuenta.test.js` y `tests/catalogos.test.js` (Vitest + Supertest, RPC simulada por nombre): éxito, 401, 403, 404, 409, 422 y 503; aislamiento entre cuentas; permisos por rol y tipo de cuenta; cuenta vencida; normalización de entradas; contrato de salida; caché (aciertos, vencimiento, claves, carga compartida, errores sin guardar).
- `docs/verificacion/local/pruebas-2b-cuentas.sql` (dentro de `begin … rollback`): alta Familia/Organización con prueba de 7 días, rol de titular, anti-abuso, categorías de otro tipo, validaciones 22023, edición, configuración todo-o-nada, suscripción, cuenta vencida, `actualizar_vencimientos`, catálogos y filtros, permisos de ejecución y endurecimiento de las funciones. No prueba concurrencia real, RLS ni triggers de auditoría.
