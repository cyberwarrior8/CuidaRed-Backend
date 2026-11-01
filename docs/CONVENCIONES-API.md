# Convenciones de API — CR-162

## Alcance y estado

Contrato de la API Express y su consumidor frontend conectado, con trazabilidad a CR-162. El usuario aprobó paginación, metadatos, orden y filtros el **31/10/2026**. El mapeo de errores, las utilidades de colección y su consumo frontend se verifican mediante pruebas con transporte interceptado. Esta validación técnica no sustituye una revisión externa del equipo ni declara cerrado el ticket en ClickUp.

La fase 1 solo expone perfil propio y acciones de sesión; no existen todavía endpoints de colecciones persistidas. Sus permisos, cuenta activa y campos de consulta se concretarán al desarrollar cada módulo. Las convenciones no crean acceso a datos ni sustituyen la autorización por cuenta/recurso.

## Transporte, rutas y datos

- Base de recursos: `/api/v1`; nombres de rutas en `kebab-case` y campos existentes de BD/DTO en `snake_case`. Los parámetros de consulta y metadatos propuestos conservan los nombres indicados abajo.
- JSON con `Content-Type: application/json` cuando hay cuerpo; `GET` consulta, `POST` ejecuta acciones o crea recursos y `PATCH` modifica campos permitidos. La fase 1 no implementa PUT ni DELETE.
- Rutas protegidas con `Authorization: Bearer <access_token>`; no enviar contraseñas, refresh tokens, rol, actor o permisos como parámetros de API. El SDK frontend trata las contraseñas directamente con Supabase Auth.
- Éxito de recurso individual: `{ "data": ... }`. Acciones sin representación: `204`, sin cuerpo. `GET /health/live` usa `{ "status": "ok" }` como excepción explícita.
- Campos editables en listas cerradas; la validación y la autorización se realizan en servidor. No inferir derechos desde metadatos modificables del usuario ni desde filtros.
- Marcas temporales en UTC/ISO 8601 y los identificadores conservan su tipo contractual, sin convertir UUID en números.

## Errores públicos

```json
{
  "error": {
    "code": "FORBIDDEN",
    "message": "No tienes permiso para realizar esta acción."
  },
  "requestId": "identificador-de-la-peticion"
}
```

`X-Request-Id` coincide con `requestId` en las respuestas de error. El cuerpo no expone SQLSTATE, SQL, stack, `details`, `hint`, credenciales ni datos de otra persona. Los mensajes son genéricos en español. Los logs usan únicamente los metadatos autorizados de auditoría.

| Error de RPC                                    | HTTP | Código público           | Significado                                                    |
| ----------------------------------------------- | ---- | ------------------------ | -------------------------------------------------------------- |
| `28000`                                         | 401  | `UNAUTHORIZED`           | Autorización/identidad inválida; solicitar autenticación.      |
| `42501`                                         | 403  | `FORBIDDEN`              | Permisos insuficientes; no interpretarlo como sesión caducada. |
| `P0002`                                         | 404  | `NOT_FOUND`              | Recurso no encontrado.                                         |
| `22023`, `23514`                                | 422  | `INVALID_INPUT`          | Parámetros inválidos o restricción de dominio incumplida.      |
| `23505`                                         | 409  | `PROFILE_CONFLICT`       | Conflicto de datos del perfil, sin revelar valores.            |
| Código no reconocido o RPC ausente (`PGRST202`) | 503  | `DEPENDENCY_UNAVAILABLE` | Dependencia o contrato de persistencia no disponible.          |

El adaptador aplica este mapeo por código de RPC; el estado HTTP recibido de PostgREST no lo sustituye. CR-162 define un contrato propio, que no coincide necesariamente con los valores predeterminados de PostgREST. Auth o la comprobación de sesión también pueden producir `401 / INVALID_SESSION`; usuario desactivado produce `403 / USER_INACTIVE`.

El frontend usa estado y código público, conserva los datos del formulario ante rechazos y no muestra mensajes técnicos del proveedor. Un 401 exige autenticación; un 403 de permisos oculta datos protegidos sin cerrar por ese motivo una sesión válida. `USER_INACTIVE` sí revoca la sesión local. Un 404 se muestra como recurso no encontrado.

Las funciones SQL existentes no se modifican con este cambio. Debe revisarse por separado cualquier función que lance `42501` ante una sesión inválida: el adaptador responderá 403 conforme a CR-162, sin adivinar la causa a partir del texto. Cambiar esos SQLSTATE requiere la revisión/aprobación de BD correspondiente.

## Paginación acordada

Parámetros `page` (entero desde 1, predeterminado 1) y `limit` (entero desde 1, predeterminado 20, máximo 100). Respuesta:

```json
{
  "data": [],
  "meta": { "page": 1, "limit": 20, "total": 0, "totalPages": 0 }
}
```

`total` cuenta solo registros autorizados que cumplen los filtros, antes de paginar. `totalPages = ceil(total / limit)`. Una página fuera del conjunto devuelve 200 con `data: []`; un parámetro inválido se rechaza con 422. No devolver totales globales de otras cuentas. No paginar `/me` ni acciones de sesión.

## Orden y filtros acordados

Ejemplo: `?page=1&limit=20&sort=-fecha_creacion,nombres&filter[estado]=activo`. `URLSearchParams` puede codificar los corchetes como `%5B` y `%5D`.

- `sort`: campos separados por coma; prefijo `-` para descendente. Cada endpoint declara campos autorizados y orden predeterminado, con desempate único para estabilidad.
- `filter[campo]=valor`: cada endpoint declara campos, tipos, valores permitidos y semántica. El contrato inicial contempla igualdad; búsquedas, rangos y operadores adicionales deben definirse antes de usarse.
- Parámetros desconocidos, campos no permitidos, duplicados o valores inválidos: 422. No interpretar nombres de columna, SQL u operadores del cliente como consultas ejecutables.
- Aplicar autorización, filtros y orden sobre el conjunto completo antes de paginar. Las consultas de datos y conteo deben usar el mismo alcance y filtros.

## Uso de las utilidades

`src/lib/collection-query.js` ofrece `createCollectionQuery` y `paginatedResponse`. El parser recibe `req.query` con el parser simple de Express. Cada endpoint debe configurar campos ordenables, orden predeterminado, campo único de desempate y esquemas Zod de filtros. Devuelve `{page, limit, offset, sort, filters}`; cada orden es `{field, direction}` y los filtros están tipados por su esquema. Rechaza desbordamiento de offset y parámetros repetidos. Los valores se vinculan como parámetros de BD, sin concatenarlos en SQL.

Ejemplo de configuración para un futuro listado de usuarios; no crea una ruta pública de usuarios en la fase 1:

```js
const readQuery = createCollectionQuery({
  sortableFields: ['fecha_creacion', 'nombres', 'usuario_id'],
  defaultSort: '-fecha_creacion',
  tieBreaker: 'usuario_id',
  filterSchemas: { estado: z.enum(['activo', 'inactivo']) },
});
const query = readQuery(req.query);
// El servicio aplica autorización y filtros; calcula total antes de limit/offset.
const { rows, total } = await service.listAuthorized(actor, query);
res.json(paginatedResponse(rows, { ...query, total }));
```

Frontend: `src/lib/api-contract.ts` contiene `CollectionQuery`, `PageMeta`, `PaginatedResponse`, `collectionSearch` y `readPaginatedResponse`. El adaptador conectado exporta `apiPage<T>(path, token, query)`, que codifica los parámetros y conserva ambos campos `data` y `meta`; `api<T>` continúa devolviendo solo `data` para recursos individuales. La ruta de `apiPage` debe ir sin query/fragmento: todos los filtros se pasan mediante `query`. El servidor es la autoridad sobre las listas permitidas y la autorización. El lector frontend rechaza metadatos inconsistentes en lugar de simular resultados vacíos.

## Validación entre backend y frontend

Pruebas del adaptador y HTTP en `tests/supabase-gateway.test.js`; parser y respuesta paginada en `tests/collection-query.test.js`; consumo de códigos y mensajes en `../CuidaRed-Frontend/tests/access/access.spec.ts` y consulta/respuesta en `tests/access/api-contract.spec.ts`, en móvil y escritorio. Estas pruebas no crean identidades ni ejecutan funciones SQL reales. La integración de cada listado persistido se verificará al implementar su módulo, con el mismo contrato. No hay un endpoint ficticio de colección en producción.

Referencias: [errores PostgREST](https://supabase.com/docs/guides/api/rest/postgrest-error-codes), `FASE-1-PERFIL-Y-ACCESO.md` y D08 de `CONTEXTO-BACKEND.md`.
