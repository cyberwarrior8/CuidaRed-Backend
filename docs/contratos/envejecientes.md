# Contrato — Perfiles de adultos mayores, consentimiento, contactos de emergencia y estado (fase 3, bloque 3a)

## Alcance y estado

ID03; RF-01, RF-13 (lectura por alcance), RF-17; CR-158 (consentimiento informado, Ley 172-13), CR-172 (baja), CR-162. Implementado en `src/modules/envejecientes/`. Persistencia: **propuesta sin aplicar** en [`fase-3a-envejecientes.sql`](../propuestas/fase-3a-envejecientes.sql), sobre [`fase-2a-base.sql`](../propuestas/fase-2a-base.sql) (`exigir`, `alcanza_envejeciente`, `limites`, `hoy`). No es una migración ni se aplicó a ninguna base.

Las decisiones marcadas **Propuesta técnica (Dxx)** eligen lo más simple compatible con las Reglas de Negocio V2; siguen abiertas en CONTEXTO §15.2 hasta que el usuario las confirme. La **cédula obligatoria y única en toda la plataforma** (D09) está confirmada desde el 24/10/2026.

Convenciones de [CONVENCIONES-API.md](../CONVENCIONES-API.md): rutas en `kebab-case`, DTO en `snake_case`, `{ "data": ... }`, errores `{ "error": { "code", "message" }, "requestId" }`, paginación `{ data, meta }`, solo `GET`/`POST`/`PATCH`. Todas las rutas cuelgan de `/api/v1/cuentas/:cuentaId` y pasan antes por `requireSession` y `requireCuenta`; la cuenta efectiva sale **siempre de la ruta verificada**, nunca del cuerpo ni de los filtros.

## Permisos y alcance (V2)

| Operación                                                            | Permiso                | Quién (Familia / Organización)                                                        |
| -------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------- |
| Listar, ver perfil, listar contactos                                 | `adultos:ver`          | Coordinador, Administrador, Cuidador, Familiar y Voluntario, **cada uno con alcance** |
| Alta                                                                 | `adultos:crear`        | Coordinador / Administrador y Coordinador                                             |
| Editar perfil, crear/editar/eliminar contactos, cambiar el principal | `adultos:editar`       | Coordinador / Administrador y Coordinador                                             |
| Cambiar el estado (inactivar, fallecido, reactivar)                  | `adultos:desactivar`   | Coordinador / Administrador y Coordinador                                             |
| Ver condición general y consentimiento                               | `adultos:ver-sensible` | Coordinador, Administrador y Cuidador (el Familiar y el Voluntario **no**)            |

**Alcance** (lo decide la base con `alcanza_envejeciente`, que la fase 3b reemplaza para exigir la autorización familiar vigente): Administrador y Coordinador ven todos los adultos de su cuenta; Cuidador y Voluntario solo los asignados con su tipo de vínculo; Familiar solo los autorizados. Un adulto de **otra cuenta, fuera del alcance o inexistente** responde exactamente igual: `404 NOT_FOUND` (`P0002`). Por eso las RPC usan `exigir()` + `alcanza_envejeciente()` y no `exigir_envejeciente()` (que responde `42501`).

Cada operación se comprueba dos veces: `requirePermiso` (respuesta temprana desde el contexto de la cuenta; una cuenta sin prueba o plan vigente bloquea también la lectura, D07) y la RPC, que vuelve a autorizar con el JWT del usuario.

**Propuesta técnica (D04) — niveles de visibilidad.** La RPC y, como segunda barrera, la proyección de Express (`nivelDe`) devuelven:

| Nivel      | Quién                                                | Campos                                                                                                                         |
| ---------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `minimo`   | Voluntario                                           | `envejeciente_id`, `estado`, `nombres`, `apellidos`, `direccion`, `zona`, `municipio_*`, `provincia_cod`, `contacto_principal` |
| `basico`   | Quien consulta sin `adultos:ver-sensible` (Familiar) | Lo anterior + `cedula`, `fecha_nacimiento`, `sexo`, `telefono`, fechas, `contactos`                                            |
| `completo` | Con `adultos:ver-sensible`                           | Lo anterior + `condicion_general`, `consentimiento`, `motivo_estado`, `fecha_estado`                                           |

El Voluntario **nunca** recibe cédula, fecha de nacimiento, condición, consentimiento ni la lista completa de contactos (solo el principal).

## Endpoints

| Método y ruta                                            | Cuerpo / consulta                                                  | Respuesta                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------- |
| GET `/cuentas/:cuentaId/envejecientes`                   | `page`, `limit`, `sort`, `filter[estado]`, `filter[municipio_cod]` | 200 paginada: `{ data: [Item], meta }`                  |
| POST `/cuentas/:cuentaId/envejecientes`                  | Perfil + `consentimiento` + `contactos` (ver abajo)                | 201: `{ data: Perfil }` con los contactos creados       |
| GET `/cuentas/:cuentaId/envejecientes/:envejecienteId`   | —                                                                  | 200: `{ data: Perfil }` según el nivel del usuario      |
| PATCH `/cuentas/:cuentaId/envejecientes/:envejecienteId` | Uno o más campos editables                                         | 200: `{ data: Perfil }`                                 |
| POST `…/envejecientes/:envejecienteId/estado`            | `{ "estado": "activo\|inactivo\|fallecido", "motivo": "…" }`       | 200: `{ data: Estado }`                                 |
| GET `…/envejecientes/:envejecienteId/contactos`          | —                                                                  | 200: `{ data: [Contacto] }` (el principal primero)      |
| POST `…/envejecientes/:envejecienteId/contactos`         | `nombres`, `apellidos`, `parentesco`, `telefono`, `es_principal?`  | 201: `{ data: Contacto }`                               |
| PATCH `/cuentas/:cuentaId/contactos/:contactoId`         | Uno o más de `nombres`, `apellidos`, `parentesco`, `telefono`      | 200: `{ data: Contacto }`                               |
| POST `…/contactos/:contactoId/principal`                 | — (sin cuerpo)                                                     | 200: `{ data: Contacto }` ya principal (cambio atómico) |
| POST `…/contactos/:contactoId/eliminar`                  | — (sin cuerpo)                                                     | 204                                                     |

Identificadores mal formados (UUID del adulto o entero positivo del contacto) responden `404` sin llegar a la base. No existen `PUT` ni `DELETE`.

### Listado

Orden predeterminado `apellidos,nombres,fecha_creacion` con desempate por `envejeciente_id`. Campos ordenables: `apellidos`, `nombres`, `fecha_creacion`, `envejeciente_id`. Filtros: `estado` (`activo`, `inactivo`, `fallecido`; sin filtro se listan todos) y `municipio_cod` (4 a 6 dígitos). Cualquier otro parámetro, filtro o campo de orden es `422`. `total` cuenta solo los adultos autorizados que cumplen el filtro, calculado en la misma consulta que la página. Fila (`Item`): `envejeciente_id`, `estado`, `nombres`, `apellidos`, `municipio_cod`, `zona`, `fecha_creacion`; con nivel `basico` o `completo` también `fecha_nacimiento` y `sexo`; con `completo`, `autonomia`.

### Alta

```json
{
  "nombres": "Rosa María",
  "apellidos": "Peña Díaz",
  "cedula": "001-1234567-8",
  "fecha_nacimiento": "1950-03-15",
  "sexo": "F",
  "telefono": "809 555 0100",
  "municipio_cod": "0101",
  "zona": "Centro",
  "direccion": "Calle 1 #2",
  "autonomia": "parcial",
  "condiciones": ["cronica", "movilidad"],
  "nota_condicion": "Usa bastón",
  "consentimiento": { "otorgado": true, "otorgado_por": "adulto" },
  "contactos": [
    {
      "nombres": "Luis",
      "apellidos": "Peña",
      "parentesco": "Hijo/a",
      "telefono": "829-555-0101",
      "es_principal": true
    }
  ]
}
```

| Campo                  | Regla                                                                                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `nombres`, `apellidos` | 2 a 60 caracteres, solo letras, espacios, apóstrofo, punto y guion; se colapsan los espacios                                                    |
| `cedula`               | 11 dígitos; se aceptan guiones y espacios y se guarda sin ellos. **Obligatoria y única en toda la plataforma**                                  |
| `fecha_nacimiento`     | `AAAA-MM-DD` real, no futura; la RPC exige de 60 a 120 años con la fecha de negocio (America/Santo_Domingo). Propuesta técnica (D09)            |
| `sexo`                 | `F` o `M`, como en el modelo                                                                                                                    |
| `telefono`             | Opcional (`null` o ausente). Se quitan espacios y guiones; patrón del modelo `^\+?[0-9]{10,15}$`                                                |
| `municipio_cod`        | Código existente en `municipio` (4 a 6 dígitos); la provincia se deduce y se devuelve como `provincia_cod`                                      |
| `zona`                 | Sector o barrio, 1 a 60 caracteres, obligatorio                                                                                                 |
| `direccion`            | Opcional, hasta 150 caracteres                                                                                                                  |
| `autonomia`            | `independiente`, `parcial` o `dependiente`                                                                                                      |
| `condiciones`          | Opcional. Valores únicos de: `cronica`, `movilidad`, `cognitivo`, `sensorial`, `vive_solo`, `sin_ingresos`, `vivienda`, `aislamiento`           |
| `nota_condicion`       | Opcional, hasta 500 caracteres (el frontend limita a 200)                                                                                       |
| `consentimiento`       | **Obligatorio** (CR-158): `otorgado: true`, `otorgado_por` `adulto` o `representante`; con representante, su nombre en `representante`          |
| `contactos`            | De 1 a 5, con **exactamente uno** `es_principal: true`. Nombres y apellidos como arriba, `parentesco` 2 a 40 caracteres, `telefono` obligatorio |

Cualquier otro campo (`cuenta_id`, `estado`, `usuario_registrador_id`, `riesgo`…) es `422` (`strictObject`). El registrador, la fecha y el usuario del consentimiento los fija la base con el JWT, nunca el cliente. El perfil, su consentimiento y sus contactos se guardan en **una sola transacción**: un alta rechazada no deja filas parciales.

### Edición

Campos editables: `nombres`, `apellidos`, `cedula`, `fecha_nacimiento`, `sexo`, `telefono` (admite `null`), `municipio_cod`, `zona`, `direccion`, `autonomia`, `condiciones`, `nota_condicion` (admite `null` o `""`) y `consentimiento`. No se editan `estado` (usar `/estado`), `cuenta_id`, el registrador ni los contactos. La cédula puede cambiar mientras siga siendo única en la plataforma. `consentimiento` vuelve a registrarlo con la fecha y el usuario actuales; no puede retirarse (`otorgado: false` es `CONSENT_REQUIRED`): para eso se inactiva el perfil.

### Cambio de estado (CR-172)

Transiciones (**Propuesta técnica D10**): `activo → inactivo | fallecido`, `inactivo → activo | fallecido`; `fallecido` es terminal. Repetir el estado o salir de `fallecido` es `409 INVALID_STATE`. El `motivo` (hasta 200 caracteres) es obligatorio, de al menos 3, al **inactivar**; opcional al registrar el fallecimiento o reactivar. Reactivar respeta el límite del plan (`409 PLAN_LIMIT_REACHED`).

Al pasar a `inactivo` o `fallecido`, **en la misma transacción**:

- las tareas de agenda abiertas (`pendiente`, `en_progreso`) pasan a `cancelada`;
- las alertas abiertas (`pendiente`, `en_proceso`) pasan a `resuelta` con `accion_tomada` = «Cerrada automáticamente: el adulto pasó a <estado>. Motivo: …», el autor y la fecha de atención;
- las visitas `programada` cuyo **único** adulto (`detalle_visita`) es este pasan a `cancelada`; las de varios adultos se conservan.

Si las tablas de los bloques 4a y 4b tienen columnas de trazabilidad de la cancelación (`motivo_cancelacion`, `cancelada_por`, `fecha_cancelacion`, `actualizado_por`), se rellenan; la RPC detecta su existencia, así que funciona con o sin esos bloques. Los vínculos, contactos y el historial se **conservan** (D15 sin política final de retención ni anonimización). Reactivar no restaura lo cancelado ni reabre alertas. Respuesta (`Estado`): `envejeciente_id`, `estado`, `motivo_estado`, `fecha_estado`, `tareas_canceladas`, `alertas_resueltas`, `visitas_canceladas`.

### Contactos de emergencia (RF-17)

Cada adulto tiene de 1 a 5 contactos y exactamente un principal, garantizado por un índice único parcial (`uq_contacto_principal`) y por el bloqueo de la fila del adulto en cada operación. El alta con `es_principal: true` reemplaza al principal actual de forma atómica; el primer contacto de un adulto es siempre el principal. `PATCH` no cambia el principal (`es_principal` en el cuerpo es `422`): se usa `/principal`. **Propuesta técnica:** eliminar al principal con otros contactos presentes se rechaza (`CONTACT_PRINCIPAL_INVALID`); hay que designar antes otro, sin reasignación automática. Eliminar el último contacto es `409 LAST_CONTACT`. Quien alcanza al adulto consulta los contactos; el Voluntario solo ve el principal.

## DTO

`Perfil` (según nivel): `envejeciente_id`, `estado`, `nombres`, `apellidos`, `direccion`, `zona`, `municipio_cod`, `municipio_nombre`, `provincia_cod`, `contacto_principal`, y con `basico`/`completo` `cedula`, `fecha_nacimiento`, `sexo`, `telefono`, `fecha_creacion`, `fecha_actualizacion`, `contactos`; con `completo`:

```json
{
  "motivo_estado": null,
  "fecha_estado": "2026-11-06T12:00:00.000000Z",
  "condicion_general": { "autonomia": "parcial", "condiciones": ["cronica"], "nota": "Usa bastón" },
  "consentimiento": {
    "otorgado": true,
    "otorgado_por": "adulto",
    "representante": null,
    "fecha": "2026-11-06T12:00:00.000000Z",
    "registrado_por": "<usuario_id>"
  }
}
```

`Contacto`: `contacto_id` (entero), `envejeciente_id`, `nombres`, `apellidos`, `parentesco`, `telefono`, `es_principal`. Marcas temporales en UTC ISO 8601 con `Z`.

## Errores

Además del mapeo de CR-162 (`28000` 401, `42501` 403, `P0002` 404, `22023`/`23514` 422), los `CR_*` de esta fase se registran en [`envejecientes-errors.js`](../../src/modules/envejecientes/envejecientes-errors.js):

| Código de la base                    | HTTP | Código público              | Cuándo                                                                                    |
| ------------------------------------ | ---- | --------------------------- | ----------------------------------------------------------------------------------------- |
| `CR_CEDULA_DUPLICADA`                | 409  | `CEDULA_DUPLICATE`          | La cédula ya existe en **cualquier** cuenta; el mensaje no revela cuál ni de quién        |
| `CR_CONSENTIMIENTO_REQUERIDO`        | 422  | `CONSENT_REQUIRED`          | Sin consentimiento, no otorgado, o representante sin nombre                               |
| `CR_CONTACTO_PRINCIPAL`              | 422  | `CONTACT_PRINCIPAL_INVALID` | Menos de 1 o más de 5 contactos, o no hay exactamente un principal; eliminar al principal |
| `CR_ULTIMO_CONTACTO`                 | 409  | `LAST_CONTACT`              | Eliminar el único contacto                                                                |
| `CR_LIMITE_CONTACTOS`                | 409  | `CONTACT_LIMIT_REACHED`     | Un sexto contacto                                                                         |
| `CR_LIMITE_PLAN` (transversal)       | 409  | `PLAN_LIMIT_REACHED`        | Alta o reactivación por encima del máximo de adultos activos del plan o de la prueba      |
| `CR_ESTADO_INVALIDO` (transversal)   | 409  | `INVALID_STATE`             | Mismo estado o salir de `fallecido`                                                       |
| `CR_CUENTA_SIN_ACCESO` (transversal) | 403  | `SUBSCRIPTION_INACTIVE`     | Cuenta sin prueba o plan vigente                                                          |

Express comprueba antes de llamar a la base el consentimiento y los contactos del alta y devuelve el mismo código público; la RPC los vuelve a exigir.

## RPC y esquema

Todas en `cuidared_api`, `security definer set search_path = ''`, con `revoke` de `public` y `anon` y `grant` a `authenticated`; autorizan con `cuidared_interno.exigir` y `alcanza_envejeciente` antes de leer o escribir y validan las entradas (`22023`).

| RPC                                                                                                                    | Uso                                                   |
| ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `api_crear_envejeciente(p_cuenta_id, p_datos jsonb)`                                                                   | Alta transaccional con límite del plan y cédula única |
| `api_listar_envejecientes(p_cuenta_id, p_estado, p_municipio_cod, p_orden jsonb, p_limite, p_desplazamiento)`          | Devuelve `{ total, items }` con el alcance del rol    |
| `api_ver_envejeciente(p_cuenta_id, p_envejeciente_id)`                                                                 | Perfil por nivel                                      |
| `api_editar_envejeciente(p_cuenta_id, p_envejeciente_id, p_datos jsonb)`                                               | Edición parcial                                       |
| `api_estado_envejeciente(p_cuenta_id, p_envejeciente_id, p_estado, p_motivo)`                                          | Estado con cascada                                    |
| `api_listar_contactos`, `api_crear_contacto`, `api_editar_contacto`, `api_principal_contacto`, `api_eliminar_contacto` | Contactos                                             |

Cambios de esquema en `envejeciente`: `cedula` `NOT NULL` + índice único global `uq_envejeciente_cedula`; `zona`; `autonomia`, `condiciones text[]` (CHECK contra la lista cerrada, **Propuesta técnica D14**: un CHECK sincronizado con `CONDICIONES` del frontend y no una tabla) y `nota_condicion`; `consentimiento_otorgado`, `_otorgado_por`, `_representante`, `_fecha`, `_registrado_por` con `ck_envejeciente_consentimiento` (sin consentimiento no se guarda un perfil); `motivo_estado`, `fecha_estado`. En `contacto_emergencia`: índice único parcial `uq_contacto_principal`. `envejeciente` y `contacto_emergencia` quedan con RLS activado y sin acceso directo (como `usuario` en la fase 1). La propuesta incluye las consultas previas (comentadas) para detectar cédulas nulas o repetidas, perfiles sin consentimiento y principales duplicados antes de aplicar.

**Concurrencia.** La unicidad de la cédula la garantiza el índice único (un alta concurrente en otra cuenta falla con `CR_CEDULA_DUPLICADA`); el límite del plan, un `pg_advisory_xact_lock` por cuenta tomado antes de contar (alta y reactivación); contactos y cambio de principal, el bloqueo `for no key update` de la fila del adulto. Verificado con dos sesiones simultáneas contra el PostgreSQL local.

## Equivalencia con el frontend (`src/domain/api/adultos.ts`)

| Frontend                                          | API                                                                                           |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `nombre`, `apellido`                              | `nombres`, `apellidos`                                                                        |
| `cedula` `000-0000000-0`                          | `cedula` (se normaliza; la respuesta la devuelve sin guiones)                                 |
| `sexo` `Femenino`/`Masculino`                     | `sexo` `F`/`M`                                                                                |
| `fechaNacimiento`, `municipioCod`, `zona`         | `fecha_nacimiento`, `municipio_cod`, `zona` (`provinciaCod` no se envía; se deduce)           |
| `condicionGeneral.{autonomia, condiciones, nota}` | `autonomia`, `condiciones`, `nota_condicion` (500 en el servidor, 200 en el formulario)       |
| `consentimiento`, `consentimientoPor`             | `consentimiento.{otorgado, otorgado_por, representante}`; **nuevo:** nombre del representante |
| `contacto*` (un contacto) / `ContactoEmergencia`  | `contactos[]` con `es_principal`; `contacto_id` numérico                                      |
| `estado` `activo`/`inactivo`                      | `estado` y `POST …/estado` con `fallecido` y `motivo`                                         |
| `riesgo`, `motivoRiesgo`, `evaluacion`            | Fuera de 3a: evaluaciones y riesgo son del bloque 3b                                          |
| `foto`, `anonimizado`, `anonimizarAdulto`         | Fuera de alcance (D15: sin política de anonimización)                                         |

Pendiente de integración frontend: reemplazar los servicios locales de `adultos.ts` por llamadas a estas rutas con `apiPage`/`api`, mostrar el nombre del representante y el estado `fallecido`, y aceptar que el Voluntario y el Familiar reciben menos campos.

## Pendientes y decisiones abiertas

- **D15:** las cédulas de perfiles anonimizados (el frontend usa `000-0000000-0`) chocarían con el índice único; la anonimización no forma parte de 3a. Plazos de retención, anonimización y fallecimiento siguen sin política.
- **D09:** la edad de 60 a 120 años, el formato de cédula sin guiones y la dirección opcional son propuestas del bloque.
- **D04:** los tres niveles de visibilidad, y que el Familiar vea la identificación completa, son propuestas.
- **D14:** `parentesco` es texto libre de 2 a 40 caracteres; el frontend ofrece una lista, pero no hay catálogo aprobado.
- **Sondeo de cédulas:** como la cédula es única en toda la plataforma, un miembro con permiso de alta podría comprobar si una cédula ya está registrada en alguna cuenta (es inherente a la regla confirmada; el mensaje no revela cuenta ni datos). Mitigación actual: el límite de peticiones de la API; si se quiere más, un contador de intentos fallidos por usuario.
- **Fixtures:** con esta propuesta, todo `INSERT` directo en `cuidared.envejeciente` (datos de prueba, cargas) debe aportar la cédula y las columnas `consentimiento_*`; sin ellas lo rechaza `ck_envejeciente_consentimiento`.

## Validación

- `npm test`: `tests/envejecientes.test.js` con gateway simulado (permisos por rol, validación estricta, cuenta tomada de la ruta, proyección por nivel, errores públicos, auditoría sin datos personales).
- `node scripts/validar-propuestas-local.js --solo=3a` en un PostgreSQL local desechable: `pruebas-3a-esquema.sql`, `pruebas-3a-adultos.sql` (alta, límite, cédula duplicada entre cuentas, alcance por rol, aislamiento), `pruebas-3a-estado.sql` (cascada y transiciones) y `pruebas-3a-contactos.sql`. No certifica RLS ni Auth de Supabase.
- Las asignaciones de las pruebas SQL se insertan en `cuidared.vinculo` como superusuario: las construye el bloque 3b.
