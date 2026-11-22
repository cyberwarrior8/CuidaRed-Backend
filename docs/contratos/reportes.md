# Contrato de resumen de casos, reportes, exportaciones e informe médico — fase 7

## Estado y alcance

ID07 de Prototipos · RF-07 (resumen de seguimiento, CU-11) y RF-08 (reportes estadísticos, CU-12) del SRS · Reglas de Negocio V2. También cubre la exportación auditada y el informe médico V2 por adulto (`informe:exportar`).

Las rutas Express y el frontend conectado utilizan este contrato. CUIDARED-012 se aplicó en Supabase CuidaRed el 21/11/2026 como versión `20261121064256`. La validación local usa `node scripts/validar-propuestas-local.js --solo=reportes`. [Registro de aplicación](../CAMBIOS-SCHEMA-CUIDARED.md#cuidared-012--reportes-fase-7).

Aplican [CR-162](../CONVENCIONES-API.md) (errores, paginación, `sort`, `filter[...]`) y el contexto de cuenta de la fase 2: todas las rutas cuelgan de `/api/v1/cuentas/:cuentaId`, exigen `Authorization: Bearer <access_token>` y pasan por `requireCuenta`. La cuenta, el actor, el rol y el plan **nunca** se aceptan del cliente: los decide la base con la membresía y la suscripción reales. Campos en `snake_case`; marcas de tiempo ISO 8601 con zona (`2026-11-20T14:05:00+00:00`); fechas de calendario `YYYY-MM-DD` en el calendario de República Dominicana (`America/Santo_Domingo`), el mismo que usa el motor de alertas de la fase 6.

Los estados son los del backend, no los del simulador del frontend:

| Entidad   | Estados del backend                                 | Equivalencia en el simulador                          |
| --------- | --------------------------------------------------- | ----------------------------------------------------- |
| Visita    | `programada`, `en_curso`, `completada`, `cancelada` | `pendiente` → `programada`/`en_curso`                 |
| Necesidad | `pendiente`, `en_proceso`, `resuelta`, `cancelada`  | `satisfecha` → `resuelta`; `inactiva` → `cancelada`   |
| Alerta    | `pendiente`, `en_proceso`, `resuelta`               | `en_atencion` → `en_proceso`; `atendida` → `resuelta` |
| Riesgo    | nivel `alto`, `medio`, `bajo` o `null`              | `null` = «Sin evaluación vigente» (D11), nunca «bajo» |
| Adulto    | `activo`, `inactivo`, `fallecido`                   | —                                                     |

## Decisiones

| Tema                                                       | Decisión                                                                                                                                                                                                                                                                                            | Origen                      |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| Permisos                                                   | Matriz vigente: `resumen:ver` (Administrador de Organización y Coordinador de ambos tipos), `reportes:ver` (los mismos), `informe:exportar` (Coordinador y Cuidador; **no** Administrador).                                                                                                         | Confirmada 20/11/2026       |
| Plan                                                       | El resumen de casos no tiene requisito de plan. Los reportes estadísticos exigen la funcionalidad `dashboard_metricas`. El análisis avanzado y la exportación a Excel exigen además `reportes_avanzados`. En la prueba, Organización tiene `dashboard_metricas` y Familia no.                       | Confirmada 20/11/2026       |
| Formatos                                                   | El backend entrega JSON agregado y sirve un CSV auditado (UTF-8 con BOM). El PDF y el Excel se generan en el frontend a partir del JSON, después de registrar la exportación en el servidor.                                                                                                        | Confirmada 20/11/2026       |
| Informe médico                                             | Identificación mínima, indicaciones vigentes, riesgo vigente e historial (máx. 15), últimas 10 visitas realizadas con observaciones, aviso de que no es diagnóstico, quién y cuándo lo generó. Sin evidencias. Secciones omitidas según `indicaciones:ver` y `adultos:ver-sensible`. JSON auditado. | Confirmada 20/11/2026       |
| Acceso vencido                                             | Sin prueba ni plan vigente se bloquea todo este módulo (403 `SUBSCRIPTION_INACTIVE`).                                                                                                                                                                                                               | D07, confirmada             |
| Alertas frente a adultos                                   | Las cantidades de alertas y de adultos prioritarios se publican siempre por separado: dos alertas de un adulto cuentan como dos alertas y un adulto prioritario.                                                                                                                                    | D06/§7.6, confirmada        |
| Prioridad, estado de atención y orden del resumen          | Reglas de la sección [Resumen de casos](#resumen-de-casos-rf-07).                                                                                                                                                                                                                                   | **Propuesta técnica (D20)** |
| Fecha que filtra cada reporte, población y tope de detalle | Reglas de la sección [Reportes estadísticos](#reportes-estadísticos-rf-08).                                                                                                                                                                                                                         | **Propuesta técnica (D20)** |
| Registro y contenido de las exportaciones                  | Auditoría en `cuidared.auditoria` (entidad `exportacion_reporte`), columnas del CSV, neutralización de fórmulas y reportes sin cédula.                                                                                                                                                              | **Propuesta técnica (D21)** |
| Detalles del informe médico                                | Vigencia de una indicación, visitas solo con `visitas:ver`, sin nombre del visitante externo, adultos inactivos o fallecidos consultables, auditoría `informe_medico`.                                                                                                                              | **Propuesta técnica (D22)** |
| Código de error del plan                                   | Una funcionalidad ausente responde 403 `FORBIDDEN`, el mismo mecanismo que las series de visitas (`visitas_recurrentes`). El frontend distingue el motivo con `funcionalidades` del contexto de cuenta.                                                                                             | Mecanismo existente         |

## Permisos y plan

| Rol (tipo de cuenta)                 | Resumen de casos | Reportes (con `dashboard_metricas`) | Análisis avanzado / Excel (con `reportes_avanzados`) | Informe médico                     |
| ------------------------------------ | ---------------- | ----------------------------------- | ---------------------------------------------------- | ---------------------------------- |
| Administrador (Organización)         | Sí               | Sí                                  | Sí                                                   | No (403)                           |
| Coordinador (Familia u Organización) | Sí               | Sí                                  | Sí                                                   | Sí, todos los adultos de la cuenta |
| Cuidador (Familia u Organización)    | No (403)         | No (403)                            | No (403)                                             | Solo adultos asignados (ver abajo) |
| Familiar, Voluntario                 | No (403)         | No (403)                            | No (403)                                             | No (403)                           |

- La Familia en prueba no tiene `dashboard_metricas`: sus reportes responden 403 aunque el Coordinador tenga `reportes:ver`. La Organización en prueba sí lo tiene. Ningún plan de prueba incluye `reportes_avanzados`.
- El reporte de **visitas** exige además `visitas:ver`. Desde el 19/11/2026 Visitas es exclusivo de Organización, por lo que en Familia ese reporte responde 403 (D05). **Propuesta técnica (D20).**
- **Alcance del Cuidador en el informe:** vínculo `cuidador_asignado` no revocado y perfil de cuidador vigente (`cuidador.fecha_fin is null`), las mismas reglas de `cuidared_interno.alcanza_envejeciente` que usan los demás módulos. Un adulto de otra cuenta, inexistente, fuera de alcance o con consentimiento retirado responde igual: 404 `NOT_FOUND`.
- Administrador y Coordinador alcanzan todos los adultos de su cuenta; los reportes y el resumen nunca incluyen datos de otra cuenta. Los adultos con consentimiento retirado quedan fuera de todos los cálculos.
- Express responde antes con `requirePermiso` y con `funcionalidades` del contexto; cada RPC vuelve a comprobar sesión, membresía, permiso, acceso operativo, plan y alcance.

## API

Prefijo `/api/v1/cuentas/:cuentaId`. `:tipo` admite `adultos`, `visitas`, `necesidades` y `casos-prioritarios`; otro valor es 404 sin consultar la base.

| Método y ruta                                       | Permiso                                       | Plan                                                                            | Entrada                                | Respuesta               |
| --------------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------- | ----------------------- |
| GET `/resumen-casos`                                | `resumen:ver`                                 | —                                                                               | `page`, `limit`, `sort`, `filter[...]` | 200 `{data, meta}`      |
| GET `/resumen-casos/indicadores`                    | `resumen:ver`                                 | —                                                                               | —                                      | 200 `{data}`            |
| GET `/resumen-casos/opciones`                       | `resumen:ver`                                 | —                                                                               | —                                      | 200 `{data}`            |
| GET `/reportes/opciones`                           | `reportes:ver`                                | `dashboard_metricas`                                                             | —                                      | 200 `{data}`            |
| GET `/reportes/:tipo`                               | `reportes:ver` (+ `visitas:ver` en `visitas`) | `dashboard_metricas`                                                            | `filter[...]`                          | 200 `{data}`            |
| GET `/reportes/analisis-avanzado`                   | `reportes:ver`                                | `dashboard_metricas` + `reportes_avanzados`                                     | `filter[...]`                          | 200 `{data}`            |
| GET `/reportes/:tipo/exportacion`                   | `reportes:ver` (+ `visitas:ver` en `visitas`) | `dashboard_metricas`                                                            | `formato=csv`, `filter[...]`           | 200 `text/csv` auditado |
| POST `/reportes/exportaciones`                      | `reportes:ver` (+ `visitas:ver` en `visitas`) | `dashboard_metricas`; `xlsx` y `analisis_avanzado` también `reportes_avanzados` | `{ tipo, formato, filtros }`           | 201 `{data}`            |
| GET `/envejecientes/:envejecienteId/informe-medico` | `informe:exportar` + alcance                  | —                                                                               | —                                      | 200 `{data}` auditado   |

Express registra `/reportes/opciones` y `/reportes/analisis-avanzado` antes de `/reportes/:tipo`. Un parámetro desconocido, repetido o inválido es 422 `INVALID_INPUT`. `:envejecienteId` mal formado es 404. Todas las respuestas de este módulo, incluidos el CSV y el informe médico, llevan `Cache-Control: no-store`. Si `hasta < desde`, el frontend suspende la consulta y la exportación hasta corregir el período.

Las rutas de opciones devuelven `municipios: [{codigo, nombre}]`, `sectores: string[]` y `asignados: [{usuario_id, nombres, apellidos, rol}]` con valores distintos de todo el alcance autorizado. Resumen toma solo expedientes activos y personal con asignación vigente. Reportes incluye expedientes históricos con consentimiento vigente y devuelve `asignados: []`.

## Resumen de casos (RF-07)

**Casos activos:** adultos de la cuenta con estado `activo`, consentimiento vigente y al alcance del actor. Se calcula con la fecha de negocio de hoy (`America/Santo_Domingo`).

### Campos de cada caso

- **`riesgo_vigente`**: máximo nivel de los factores de riesgo con estado `activo` (D11). `null` significa «Sin evaluación vigente».
- **`alertas`**: alertas abiertas del adulto (`pendiente` o `en_proceso`) de cualquier tipo. `prioritarias_abiertas` cuenta las de tipo `riesgo_alto`, `medicamento_pendiente` y `necesidad_prioritaria` con una sola fuente (la misma regla que `/casos-prioritarios` de la fase 6).
- **`necesidades_activas`**: ocurrencias `pendiente` o `en_proceso`.
- **`seguimiento`**: solo Organización (RF-05). `ultima_visita_fecha` es la última visita completada del adulto en la cuenta, con fecha no futura. Si todavía no tiene visitas completadas, la referencia es la fecha local del alta. `vencido = dias_sin_visita > umbral_dias`, con 15 días por defecto. Para Familia el objeto y el umbral de indicadores son `null`. Las alertas históricas de ausencia de visitas de Familia se conservan y quedan fuera de los indicadores operativos del resumen.
- **`asignados`**: cuidadores (vínculo `cuidador_asignado` no revocado, membresía activa como cuidador y perfil vigente) y voluntarios (vínculo `voluntario_asignado` no revocado y membresía activa como voluntario), ordenados por apellidos, nombres e id. Sin familiares. **Propuesta técnica (D20).**

### Prioridad — Propuesta técnica (D20)

| Prioridad | Condición (se evalúa en este orden)                                                                                               |
| --------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `alta`    | Al menos una alerta prioritaria abierta, o `riesgo_vigente = 'alto'`.                                                             |
| `media`   | Cualquier otra alerta abierta (p. ej. `ausencia_visitas`), seguimiento vencido, necesidades activas o `riesgo_vigente = 'medio'`. |
| `baja`    | Ninguna de las anteriores.                                                                                                        |

`motivos` enumera, en este orden y sin repetir, los códigos que se cumplen: `alerta_prioritaria_abierta`, `riesgo_alto`, `alerta_seguimiento_abierta` (tipo `ausencia_visitas`), `alerta_abierta` (otro tipo no prioritario), `seguimiento_vencido`, `necesidades_activas`, `riesgo_medio`, `sin_evaluacion_vigente`, `sin_personal_asignado`. El frontend traduce los códigos a texto.

### Estado de atención — Propuesta técnica (D20)

Del más al menos urgente; cada caso tiene exactamente uno:

| Código                | Condición                                            |
| --------------------- | ---------------------------------------------------- |
| `alerta_pendiente`    | Al menos una alerta abierta en `pendiente`.          |
| `alerta_en_proceso`   | Tiene alertas abiertas y todas están `en_proceso`.   |
| `seguimiento_vencido` | Sin alertas abiertas y `seguimiento.vencido = true`. |
| `necesidades_activas` | Sin lo anterior y con necesidades activas.           |
| `al_dia`              | Ninguna de las anteriores.                           |

### Consulta (`GET /resumen-casos`)

Paginación CR-162 (`page` desde 1, `limit` de 1 a 100, predeterminado 20).

Filtros por igualdad (todos opcionales, combinables con «y»):

| Filtro                    | Valores                                                                                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `filter[estado_atencion]` | `alerta_pendiente`, `alerta_en_proceso`, `seguimiento_vencido`, `necesidades_activas`, `al_dia`                                                     |
| `filter[prioridad]`       | `alta`, `media`, `baja`                                                                                                                             |
| `filter[riesgo]`          | `alto`, `medio`, `bajo`, `sin_evaluacion` (riesgo vigente `null`)                                                                                   |
| `filter[municipio_cod]`   | Código de municipio de 4 a 6 dígitos                                                                                                                |
| `filter[zona]`            | Sector exacto del adulto (1 a 60 caracteres; se ignoran los espacios de los extremos)                                                               |
| `filter[asignado]`        | `sin` (sin personal), `con` (con al menos una persona) o el `usuario_id` (UUID) de un cuidador o voluntario asignado                                |
| `filter[q]`               | Búsqueda de 2 a 60 caracteres, sin distinguir mayúsculas, dentro de nombres, apellidos, sector o nombre del municipio. **Propuesta técnica (D20).** |

Orden (`sort`, uno o dos campos distintos; `-` invierte):

| Campo                            | Ascendente (sin `-`)                                                                                     |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `prioridad` (**predeterminado**) | `alta` → `media` → `baja`                                                                                |
| `estado_atencion`                | del más urgente (`alerta_pendiente`) al menos urgente (`al_dia`)                                         |
| `ultima_visita`                  | sin visitas primero (por fecha de alta más antigua) y después de la visita más antigua a la más reciente |
| `riesgo`                         | `alto` → `medio` → `bajo` → sin evaluación vigente                                                       |
| `nombre`                         | apellidos y nombres, de la A a la Z                                                                      |

Después de los campos pedidos se aplica siempre el desempate fijo: prioridad, estado de atención, alertas abiertas (más primero), riesgo, días sin visita (más primero), apellidos, nombres y `envejeciente_id`.

```json
{
  "data": [
    {
      "envejeciente_id": "0b6e1f0e-5c8f-4a51-9f8e-2d9d7a1c4b10",
      "nombres": "Juana",
      "apellidos": "Pérez Díaz",
      "municipio": { "codigo": "0101", "nombre": "Santo Domingo de Guzmán" },
      "zona": "Villa Juana",
      "fecha_alta": "2026-08-02T14:10:00+00:00",
      "riesgo_vigente": "alto",
      "prioridad": "alta",
      "estado_atencion": "alerta_pendiente",
      "motivos": ["alerta_prioritaria_abierta", "riesgo_alto", "seguimiento_vencido"],
      "alertas": { "abiertas": 2, "pendientes": 1, "en_proceso": 1, "prioritarias_abiertas": 2 },
      "necesidades_activas": 1,
      "seguimiento": {
        "ultima_visita_id": "6c0f3b9a-0b1e-4a65-8d0e-3c6a4e0f9a21",
        "ultima_visita_fecha": "2026-11-01",
        "fecha_referencia": "2026-11-01",
        "dias_sin_visita": 19,
        "umbral_dias": 15,
        "vencido": true
      },
      "asignados": {
        "total": 1,
        "cuidadores": [
          {
            "usuario_id": "5d7c8a8e-1a4b-4f0e-9a3e-7e0d1b2c3f40",
            "nombres": "Ana",
            "apellidos": "Gómez"
          }
        ],
        "voluntarios": []
      }
    }
  ],
  "meta": { "page": 1, "limit": 20, "total": 1, "totalPages": 1 }
}
```

Sin casos que cumplan los filtros: `200` con `data: []` y `total: 0`.

### Indicadores (`GET /resumen-casos/indicadores`)

Se calculan sobre **todos** los casos activos del alcance, sin filtros, igual que la cabecera del prototipo:

```json
{
  "data": {
    "fecha_calculo": "2026-11-20",
    "umbral_dias_sin_visita": 15,
    "casos_activos": 42,
    "por_prioridad": { "alta": 7, "media": 20, "baja": 15 },
    "por_estado_atencion": {
      "alerta_pendiente": 5,
      "alerta_en_proceso": 2,
      "seguimiento_vencido": 6,
      "necesidades_activas": 9,
      "al_dia": 20
    },
    "adultos_prioritarios": 6,
    "alertas_prioritarias_abiertas": 9,
    "alertas_abiertas": 14,
    "alertas_pendientes": 10,
    "alertas_en_proceso": 4,
    "seguimiento_vencido": 8,
    "necesidades_activas": 17,
    "adultos_con_necesidades_activas": 11,
    "sin_personal_asignado": 3
  }
}
```

- `adultos_prioritarios` cuenta **adultos** con al menos una alerta prioritaria abierta y coincide con `total` de `/casos-prioritarios` (fase 6). `alertas_prioritarias_abiertas` cuenta **alertas**.
- `seguimiento_vencido` cuenta todos los casos vencidos, tengan o no alertas abiertas; `por_estado_atencion.seguimiento_vencido` solo los que no tienen alertas abiertas.
- `por_prioridad` y `por_estado_atencion` suman `casos_activos`. `alertas_abiertas = alertas_pendientes + alertas_en_proceso`.

## Reportes estadísticos (RF-08)

### Filtros comunes

| Filtro                           | Valores                                                                                                          | Aplica a                                       |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `filter[desde]`, `filter[hasta]` | `YYYY-MM-DD`, inclusivos, calendario de Santo Domingo. Cada uno es opcional; `desde` posterior a `hasta` es 422. | La fecha propia de cada tipo (tabla siguiente) |
| `filter[municipio_cod]`          | Código de 4 a 6 dígitos                                                                                          | Municipio **actual** del adulto                |
| `filter[zona]`                   | Sector exacto (1 a 60)                                                                                           | Sector **actual** del adulto                   |
| `filter[riesgo]`                 | `alto`, `medio`, `bajo`, `sin_evaluacion`                                                                        | Riesgo vigente **actual** del adulto           |
| `filter[tipo_necesidad_id]`      | Entero del catálogo `/catalogos/tipos-necesidad`                                                                 | Solo `necesidades`; en otro tipo es 422        |

Sin `desde` ni `hasta` el reporte abarca todo el historial.

### Fecha que filtra cada tipo y población — Propuesta técnica (D20)

| Tipo                 | `campo_fecha`    | Fecha usada para el rango                               | Población                                                                                                                            |
| -------------------- | ---------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `adultos`            | `fecha_alta`     | Fecha local de `envejeciente.fecha_creacion`            | Adultos dados de alta en el periodo, en cualquier estado                                                                             |
| `visitas`            | `fecha_visita`   | `visita.fecha`, que ya es una fecha local               | Visitas `completada` con al menos un adulto de la población filtrada                                                                 |
| `necesidades`        | `fecha_registro` | Fecha local de `envejeciente_necesidad.fecha_necesidad` | Ocurrencias registradas en el periodo, con su estado actual                                                                          |
| `casos_prioritarios` | `fecha_alerta`   | Fecha local de `alerta_envejeciente.fecha_alerta`       | Alertas prioritarias (`riesgo_alto`, `medicamento_pendiente`, `necesidad_prioritaria`) generadas en el periodo, con su estado actual |

Municipio, sector y riesgo filtran a los adultos por sus datos actuales. Los adultos inactivos o fallecidos conservan sus hechos históricos. Las visitas institucionales completadas sin expediente entran en el total y en la tendencia mensual general al consultar solo por período. Se distinguen en los indicadores `visitas_personales` y `visitas_institucionales`, en la serie `por_tipo_visita` y en cada fila con `tipo_visita`. Las atenciones solo cuentan expedientes y los comparativos por municipio o sector usan su ubicación.

### Estructura común

```json
{
  "data": {
    "tipo": "visitas",
    "campo_fecha": "fecha_visita",
    "zona_horaria": "America/Santo_Domingo",
    "generado_en": "2026-11-20T14:05:00.481+00:00",
    "filtros": {
      "desde": "2026-06-01",
      "hasta": "2026-11-20",
      "municipio_cod": null,
      "zona": null,
      "riesgo": null,
      "tipo_necesidad_id": null
    },
    "vacio": false,
    "indicadores": {},
    "series": {},
    "detalle": [],
    "detalle_total": 0,
    "detalle_truncado": false
  }
}
```

- `vacio` es `true` cuando la población del periodo no tiene registros. Una respuesta vacía es válida: indicadores en 0 (o `null` en promedios y en `mas_frecuente`), las series conservan todas sus claves fijas con `valor: 0` y `detalle: []`.
- Cada serie es una lista de `{ clave, etiqueta, valor, porcentaje }`. `porcentaje` es el entero redondeado respecto de la suma de la serie (0 si la suma es 0). `etiqueta` es el texto en español para gráficos y CSV.
- `por_mes` usa `clave` `YYYY-MM` e incluye todos los meses del periodo, también los vacíos. Sin `desde`, parte del mes del primer registro de la población (o del mes de `hasta` si no hay registros). Sin `hasta`, termina en el mes actual. Como máximo se publican los **24 últimos meses** del periodo; los indicadores sí cubren el periodo completo.
- `detalle` se publica completo hasta **5.000 filas**. `detalle_total` indica cuántas había; `detalle_truncado` es `true` si se recortó. **Propuesta técnica (D20).**
- Los reportes estadísticos no publican cédula, teléfono, dirección ni observaciones. **Propuesta técnica (D21).**

### `adultos`

| Grupo         | Contenido                                                                                                                                                                                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `indicadores` | `registrados`, `activos`, `inactivos`, `fallecidos`, `riesgo_alto`, `riesgo_medio`, `riesgo_bajo`, `sin_evaluacion` (estos cuatro sobre activos), `edad_promedio` (años con un decimal, sobre registrados; `null` sin registros) y `sin_personal_asignado` (activos sin cuidador ni voluntario). |
| `series`      | `por_riesgo` (activos; claves `alto`, `medio`, `bajo`, `sin_evaluacion`), `por_municipio` (activos; clave = código), `por_zona` (activos; clave = sector o `sin_zona`), `por_estado` (registrados; `activo`, `inactivo`, `fallecido`) y `por_mes` (altas).                                       |
| `detalle`     | Por adulto, ordenado por apellidos y nombres: `envejeciente_id`, `nombres`, `apellidos`, `municipio {codigo, nombre}`, `zona`, `edad`, `sexo`, `riesgo_vigente`, `estado`, `fecha_alta`, `personal_asignado` (número).                                                                           |

`por_municipio` y `por_zona` se ordenan de mayor a menor valor y luego por etiqueta.

### `visitas`

| Grupo         | Contenido                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `indicadores` | `visitas_realizadas` (total de visitas distintas), `visitas_personales`, `visitas_institucionales` y `atenciones` (un adulto atendido en una visita con expediente cuenta una vez), `adultos_visitados` (distintos), `adultos_activos` (activos de la población filtrada), `promedio_por_adulto` (`atenciones / adultos_visitados` con dos decimales; `null` sin visitas), `requirieron_atencion` (atenciones `requiere_atencion` o `situacion_critica`), `situaciones_criticas` y `visitas_compartidas` (visitas con más de un adulto registrado, aunque alguno quede fuera del filtro). |
| `series`      | `por_mes` (visitas), `por_tipo_visita` y `por_estado_general` (atenciones; `estable`, `requiere_atencion`, `situacion_critica`, `sin_registro`).                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `detalle`     | Por visita, de la más reciente a la más antigua: `visita_id`, `fecha`, `hora_inicio`, `hora_fin`, `razon`, `origen` (`interna` o `solicitud`), `responsables` (`[{usuario_id, nombres, apellidos}]` de los participantes) y `adultos` (`[{envejeciente_id, nombres, apellidos, estado_general}]`, solo los de la población filtrada).                                                                                                                                                                                                            |

### `necesidades`

| Grupo         | Contenido                                                                                                                                                                                                                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `indicadores` | `registradas`, `activas` (`pendiente` + `en_proceso`), `pendientes`, `en_proceso`, `resueltas`, `canceladas`, `porcentaje_resueltas`, `prioridad_alta_activas`, `recurrentes`, `adultos_con_necesidades` y `mas_frecuente` (`{tipo_necesidad_id, nombre, total}` o `null`).                                              |
| `series`      | `por_tipo` (todas las categorías del catálogo, o solo la filtrada; clave = `tipo_necesidad_id` como texto; de mayor a menor), `por_estado` (`pendiente`, `en_proceso`, `resuelta`, `cancelada`), `por_prioridad` (códigos del catálogo, de mayor a menor urgencia), `recurrencia` (`recurrente`, `puntual`) y `por_mes`. |
| `detalle`     | Por categoría con registros, de la más a la menos frecuente: `tipo_necesidad_id`, `nombre`, `total`, `porcentaje`, `pendientes`, `en_proceso`, `resueltas`, `canceladas`, `prioridad_alta`, `recurrentes`.                                                                                                               |

### `casos_prioritarios`

| Grupo         | Contenido                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `indicadores` | `alertas_prioritarias` (**alertas**), `adultos_prioritarios` (**adultos** distintos con alguna alerta del periodo), `casos_abiertos` (adultos con alguna de esas alertas todavía abierta), `alertas_pendientes`, `alertas_en_proceso`, `alertas_resueltas`, `resueltas_automaticamente` y `porcentaje_resueltas`.                                                                            |
| `series`      | `por_estado` (alertas; `pendiente`, `en_proceso`, `resuelta`), `por_tipo` (alertas; `riesgo_alto`, `medicamento_pendiente`, `necesidad_prioritaria`) y `por_mes` (alertas).                                                                                                                                                                                                                  |
| `detalle`     | Por adulto, primero los abiertos y luego por apellidos: `envejeciente_id`, `nombres`, `apellidos`, `municipio {codigo, nombre}`, `zona`, `riesgo_vigente`, `alertas`, `alertas_abiertas`, `tipos` (códigos sin repetir, en orden alfabético), `estado_actual` (`pendiente` si alguna lo está; si no, `en_proceso` si alguna lo está; si no, `resuelta`) y `ultima_alerta` (marca de tiempo). |

Ejemplo de `GET /reportes/casos-prioritarios?filter[desde]=2026-11-01`:

```json
{
  "data": {
    "tipo": "casos_prioritarios",
    "campo_fecha": "fecha_alerta",
    "zona_horaria": "America/Santo_Domingo",
    "generado_en": "2026-11-20T14:05:00.481+00:00",
    "filtros": {
      "desde": "2026-11-01",
      "hasta": null,
      "municipio_cod": null,
      "zona": null,
      "riesgo": null,
      "tipo_necesidad_id": null
    },
    "vacio": false,
    "indicadores": {
      "alertas_prioritarias": 3,
      "adultos_prioritarios": 2,
      "casos_abiertos": 1,
      "alertas_pendientes": 1,
      "alertas_en_proceso": 1,
      "alertas_resueltas": 1,
      "resueltas_automaticamente": 0,
      "porcentaje_resueltas": 33
    },
    "series": {
      "por_estado": [
        { "clave": "pendiente", "etiqueta": "Pendiente", "valor": 1, "porcentaje": 33 },
        { "clave": "en_proceso", "etiqueta": "En proceso", "valor": 1, "porcentaje": 33 },
        { "clave": "resuelta", "etiqueta": "Resuelta", "valor": 1, "porcentaje": 33 }
      ],
      "por_tipo": [
        { "clave": "riesgo_alto", "etiqueta": "Riesgo alto", "valor": 1, "porcentaje": 33 },
        {
          "clave": "medicamento_pendiente",
          "etiqueta": "Medicamentos pendientes",
          "valor": 2,
          "porcentaje": 67
        },
        {
          "clave": "necesidad_prioritaria",
          "etiqueta": "Necesidad prioritaria",
          "valor": 0,
          "porcentaje": 0
        }
      ],
      "por_mes": [{ "clave": "2026-11", "etiqueta": "2026-11", "valor": 3, "porcentaje": 100 }]
    },
    "detalle": [
      {
        "envejeciente_id": "0b6e1f0e-5c8f-4a51-9f8e-2d9d7a1c4b10",
        "nombres": "Juana",
        "apellidos": "Pérez Díaz",
        "municipio": { "codigo": "0101", "nombre": "Santo Domingo de Guzmán" },
        "zona": "Villa Juana",
        "riesgo_vigente": "alto",
        "alertas": 2,
        "alertas_abiertas": 2,
        "tipos": ["medicamento_pendiente", "riesgo_alto"],
        "estado_actual": "pendiente",
        "ultima_alerta": "2026-11-18T13:00:00+00:00"
      }
    ],
    "detalle_total": 2,
    "detalle_truncado": false
  }
}
```

El ejemplo muestra una sola fila del detalle por brevedad.

## Análisis avanzado (`reportes_avanzados`)

`GET /reportes/analisis-avanzado` acepta `desde`, `hasta`, `municipio_cod`, `zona` y `riesgo` (`tipo_necesidad_id` es 422). Población: adultos de la cuenta que cumplen los filtros de ubicación y riesgo.

```json
{
  "data": {
    "tipo": "analisis_avanzado",
    "zona_horaria": "America/Santo_Domingo",
    "generado_en": "2026-11-20T14:05:00.481+00:00",
    "filtros": {
      "desde": null,
      "hasta": null,
      "municipio_cod": null,
      "zona": null,
      "riesgo": null,
      "tipo_necesidad_id": null
    },
    "vacio": false,
    "comparativo_zonas": [
      {
        "municipio": { "codigo": "0101", "nombre": "Santo Domingo de Guzmán" },
        "zona": "Villa Juana",
        "adultos_activos": 8,
        "riesgo_alto": 2,
        "visitas_realizadas": 11,
        "visitas_por_adulto": 1.38,
        "necesidades_activas": 3,
        "alertas_abiertas": 4,
        "dias_sin_visita_promedio": 9.5,
        "sin_personal_asignado": 1
      }
    ],
    "comparativo_municipios": [
      {
        "municipio": { "codigo": "0101", "nombre": "Santo Domingo de Guzmán" },
        "adultos_activos": 30,
        "riesgo_alto": 5,
        "visitas_realizadas": 40,
        "visitas_por_adulto": 1.33,
        "necesidades_activas": 9,
        "alertas_abiertas": 12,
        "dias_sin_visita_promedio": 11.2,
        "sin_personal_asignado": 2
      }
    ],
    "tendencias": [
      {
        "mes": "2026-11",
        "visitas_realizadas": 6,
        "variacion_visitas": 20,
        "necesidades_registradas": 4,
        "alertas_prioritarias": 3,
        "perfiles_nuevos": 1
      }
    ]
  }
}
```

- **Comparativos** (por sector dentro de su municipio y por municipio). Los grupos salen de los adultos activos de la población. `adultos_activos`, `riesgo_alto`, `alertas_abiertas` (alertas abiertas hoy, de cualquier tipo), `dias_sin_visita_promedio` (un decimal) y `sin_personal_asignado` reflejan el estado actual. `visitas_realizadas` (visitas completadas distintas del periodo con algún adulto activo del grupo) y `necesidades_activas` (registradas en el periodo y todavía activas) usan el periodo. `visitas_por_adulto = visitas_realizadas / adultos_activos` con dos decimales. Sector vacío: `zona: null`. Orden: más adultos activos primero y luego municipio y sector.
- **Tendencias** por mes, sobre toda la población (cualquier estado). Periodo: de `desde` a `hasta` (sin `hasta`, hasta hoy); el primer mes empieza en `desde` y el último termina en `hasta`, de modo que cada conteo respeta el periodo pedido. Sin `desde`, los 12 meses que terminan en `hasta`; si el periodo abarca menos de 3 meses, los 6 que terminan en `hasta`. Los meses añadidos por esa ampliación se cuentan completos y el último se recorta a `hasta`. Máximo 24 meses. `variacion_visitas` es el porcentaje entero frente al mes anterior; `null` en el primer mes o si el anterior fue 0.
- **Métricas de visitas sin `visitas:ver`.** Si el actor no tiene ese permiso (Familia, D05), `visitas_realizadas` y `visitas_por_adulto` de los comparativos y `visitas_realizadas` y `variacion_visitas` de las tendencias valen `null`. En Familia, `dias_sin_visita_promedio` vale `null`. **Propuesta técnica (D20).**
- `vacio` es `true` si la población no tiene adultos.

## Exportaciones

Toda exportación se registra en la auditoría de la cuenta (`cuidared.auditoria`) **antes** de entregar el archivo o de autorizar su generación. El registro deja constancia del **intento autorizado por el servidor**, no de una entrega confirmada: si después fallan la validación de la salida (503), la red o la generación del archivo en el navegador, el registro se conserva, con la entidad `exportacion_reporte`, el actor, la fecha y solo `{cuenta_id, tipo, formato, filtros}`: nunca filas del reporte. `GET /auditoria` la muestra como `accion: "exportacion"`, `entidad: "exportacion_reporte"`; el informe médico, como `accion: "exportacion"`, `entidad: "informe_medico"`. Las demás entidades conservan `alta`, `actualizacion` y `baja`. **Propuesta técnica (D21).**

### CSV (`GET /reportes/:tipo/exportacion?formato=csv`)

Mismos filtros, permisos y plan que `GET /reportes/:tipo`. `formato` es obligatorio y solo admite `csv`. Respuesta `200`:

- `Content-Type: text/csv; charset=utf-8`, `Content-Disposition: attachment; filename="reporte-<tipo>-<YYYY-MM-DD>.csv"` (tipo de la ruta y fecha de negocio de hoy) y `Cache-Control: no-store`.
- Cuerpo UTF-8 que empieza con BOM (`EF BB BF`), separador coma y fin de línea CRLF. Una celda con coma, punto y coma, comillas o salto de línea va entre comillas dobles, duplicando las internas. Una celda de texto se antepone con `'` cuando empieza por tabulador o retorno de carro, o cuando su primer carácter visible (tras espacios iniciales) es `=`, `+`, `-`, `@` o su forma de ancho completo (`＝`, `＋`, `－`, `＠`) para que la hoja de cálculo no la evalúe como fórmula. **Propuesta técnica (D21).**
- Un reporte vacío también se descarga y se audita: conserva la cabecera, los indicadores en 0 y la línea `Sin datos para los filtros seleccionados.` en lugar del detalle.

Estructura, en este orden:

1. `Reporte CuidaRed,<título>`; `Cuenta,<nombre>`; `Generado,<generado_en>`; `Generado por,<nombres apellidos>`; `Fecha filtrada,<campo_fecha>`; `Desde,<desde o vacío>`; `Hasta,<hasta o vacío>`; `Municipio,<código o Todos>`; `Sector,<sector o Todos>`; `Riesgo,<nivel o Todos>`; en `necesidades`, `Categoría,<id o Todas>`.
2. Línea vacía, `Indicadores` y `Indicador,Valor`, una fila por clave de `indicadores` (`mas_frecuente` se escribe como su nombre).
3. Por cada serie: línea vacía, su nombre, `Clave,Etiqueta,Valor,Porcentaje` y sus filas.
4. Línea vacía, `Detalle` y las columnas del tipo:

| Tipo                 | Columnas del detalle                                                                                                                                             |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `adultos`            | `Apellidos`, `Nombres`, `Municipio`, `Sector`, `Edad`, `Sexo`, `Riesgo vigente`, `Estado`, `Fecha de alta`, `Personal asignado`                                  |
| `visitas`            | `Fecha`, `Hora inicio`, `Hora fin`, `Razón`, `Origen`, `Tipo de visita`, `Responsables`, `Adultos atendidos`, `Estados observados`                                                 |
| `necesidades`        | `Categoría`, `Total`, `% del total`, `Pendientes`, `En proceso`, `Resueltas`, `Canceladas`, `Prioridad alta`, `Recurrentes`                                      |
| `casos-prioritarios` | `Apellidos`, `Nombres`, `Municipio`, `Sector`, `Riesgo vigente`, `Alertas prioritarias`, `Alertas abiertas`, `Tipos de alerta`, `Estado actual`, `Última alerta` |

Los títulos son «Adultos mayores registrados», «Visitas realizadas», «Necesidades frecuentes y atendidas» y «Casos prioritarios». En las columnas de lista (`Responsables`, `Adultos atendidos`, `Estados observados`, `Tipos de alerta`) los elementos se separan con `|` rodeado de espacios. `Riesgo vigente` sin nivel se escribe «Sin evaluación vigente». Fechas `YYYY-MM-DD`; marcas de tiempo ISO 8601. Si `detalle_truncado` es `true`, se añade al final `Detalle recortado,<filas publicadas> de <detalle_total>`.

### Registro previo de PDF y Excel (`POST /reportes/exportaciones`)

El frontend lo llama justo antes de generar el archivo con los datos del último `GET`:

```json
{
  "tipo": "casos_prioritarios",
  "formato": "pdf",
  "filtros": { "desde": "2026-11-01", "hasta": null }
}
```

- `tipo`: `adultos`, `visitas`, `necesidades`, `casos_prioritarios` o `analisis_avanzado`. `formato`: `pdf` o `xlsx` (`csv` es 422: el CSV se pide con `GET`). `filtros`: objeto opcional con las mismas claves y reglas que `filter[...]` del tipo (`null` equivale a omitir la clave, también en la base); una clave desconocida con valor es 422. Los `filtros` normalizados de una respuesta de `GET /reportes/:tipo`, que traen las seis claves (por ejemplo `tipo_necesidad_id: null` en `adultos`), se pueden reenviar tal cual.
- Permisos: los de ese tipo. Plan: `dashboard_metricas`; `xlsx` o `analisis_avanzado` exigen además `reportes_avanzados`. Sin plan: 403 `FORBIDDEN` y no se registra nada.
- Respuesta `201`:

```json
{
  "data": {
    "exportacion_id": "3f9b2a40-8c1d-4e7a-9b55-0d4f6e2a1c90",
    "tipo": "casos_prioritarios",
    "formato": "pdf",
    "filtros": {
      "desde": "2026-11-01",
      "hasta": null,
      "municipio_cod": null,
      "zona": null,
      "riesgo": null,
      "tipo_necesidad_id": null
    },
    "fecha": "2026-11-20T14:06:12.004+00:00",
    "generado_por": { "nombres": "Laura", "apellidos": "Mejía", "rol": "coordinador" },
    "cuenta": { "nombre": "Fundación Esperanza" }
  }
}
```

El PDF o el Excel pueden mostrar `generado_por`, `fecha` y `exportacion_id` como constancia. Cada llamada crea un registro nuevo.

## Informe médico (`GET /envejecientes/:envejecienteId/informe-medico`)

Coordinador o Cuidador con alcance sobre el adulto, en cualquier estado del expediente (`activo`, `inactivo` o `fallecido`) mientras conserve el consentimiento (**Propuesta técnica D22**). Cada consulta genera un registro de auditoría `informe_medico` con `{cuenta_id, envejeciente_id, secciones_omitidas}` y nunca con su contenido; su `informe_id` se devuelve como constancia. La respuesta lleva `Cache-Control: no-store`.

```json
{
  "data": {
    "informe_id": "9a3c5e10-2b4f-4c6d-8e1a-7f0b9c2d3e41",
    "generado_en": "2026-11-20T14:07:30.112+00:00",
    "generado_por": { "nombres": "Laura", "apellidos": "Mejía", "rol": "coordinador" },
    "cuenta": { "nombre": "Fundación Esperanza" },
    "aviso": "CuidaRed no diagnostica ni sustituye al médico tratante.",
    "secciones_omitidas": [],
    "identificacion": {
      "envejeciente_id": "0b6e1f0e-5c8f-4a51-9f8e-2d9d7a1c4b10",
      "nombres": "Juana",
      "apellidos": "Pérez Díaz",
      "cedula": "00112345678",
      "fecha_nacimiento": "1944-03-12",
      "edad": 82,
      "sexo": "F",
      "municipio": { "codigo": "0101", "nombre": "Santo Domingo de Guzmán" },
      "provincia": { "codigo": "01", "nombre": "Distrito Nacional" },
      "estado": "activo"
    },
    "riesgo": {
      "nivel_vigente": "alto",
      "vigentes": [
        {
          "envejeciente_riesgo_id": "41",
          "factor": { "codigo": "riesgo_caida", "nombre": "Riesgo de caída" },
          "nivel": { "codigo": "alto", "nombre": "Alto" },
          "motivo": "Caída reciente en el baño",
          "observacion": null,
          "fecha": "2026-11-10T15:00:00+00:00"
        }
      ],
      "historial": [
        {
          "envejeciente_riesgo_id": "41",
          "factor": { "codigo": "riesgo_caida", "nombre": "Riesgo de caída" },
          "nivel": { "codigo": "alto", "nombre": "Alto" },
          "estado": "activo",
          "motivo": "Caída reciente en el baño",
          "fecha": "2026-11-10T15:00:00+00:00",
          "fecha_resolucion": null
        }
      ],
      "historial_total": 1
    },
    "indicaciones": {
      "vigentes": [
        {
          "indicacion_medica_id": "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f",
          "tipo": { "tipo_indicacion_id": 1, "nombre": "Medicamento" },
          "titulo": "Losartán 50 mg",
          "descripcion": "Una tableta en la mañana.",
          "frecuencia_horario": "Diaria, 8:00",
          "fecha_inicio": "2026-10-01",
          "fecha_fin": null,
          "registrada_por": { "nombres": "Ana", "apellidos": "Gómez" }
        }
      ],
      "no_vigentes": 2
    },
    "visitas": {
      "realizadas_total": 7,
      "ultima_fecha": "2026-11-01",
      "recientes": [
        {
          "visita_id": "6c0f3b9a-0b1e-4a65-8d0e-3c6a4e0f9a21",
          "fecha": "2026-11-01",
          "hora_inicio": "09:00",
          "hora_fin": "09:40",
          "origen": "interna",
          "responsables": [{ "nombres": "Ana", "apellidos": "Gómez" }],
          "estado_general": "requiere_atencion",
          "observacion": "Refiere mareos por la mañana."
        }
      ]
    }
  }
}
```

- **Identificación mínima**: nombre, cédula, fecha de nacimiento y edad, sexo, municipio y provincia, y estado del expediente. Sin dirección, teléfono, contactos ni evidencias.
- **`riesgo`** (requiere `adultos:ver-sensible`): `factor.codigo` y `nivel.codigo` pueden ser `null` en catálogos heredados sin código (fase 3b); `nombre` siempre está presente. `nivel_vigente` (`null` = «Sin evaluación vigente»), los factores `activo` (más grave y más reciente primero) y el historial de todos los estados (`activo`, `resuelto`, `reemplazado`), del más reciente al más antiguo, con un máximo de 15 filas. `historial_total` indica el total. Sin el permiso: `riesgo: null` y `"riesgo"` en `secciones_omitidas`.
- **`indicaciones`** (requiere `indicaciones:ver`): vigente = estado `activa`, inicio igual o anterior a hoy y fin nulo o igual o posterior a hoy. `no_vigentes` cuenta las demás, incluidas las futuras. El orden es de la más reciente a la más antigua por `fecha_inicio`. `registrada_por` solo se publica si esa persona es o fue miembro de la cuenta. Sin el permiso: `indicaciones: null` y `"indicaciones"` en `secciones_omitidas`.
- **`visitas`** (requiere `visitas:ver`, solo Organización): las 10 visitas `completada` más recientes del adulto en la cuenta, con la fecha no futura y el mismo orden que el seguimiento de la fase 6. `realizadas_total` cuenta todas. `responsables` son los participantes; no se publica el nombre de un visitante externo. `estado_general` y `observacion` son los de **este** adulto y requieren `adultos:ver-sensible`; sin él valen `null`. Sin `visitas:ver` (Familia): `visitas: null` y `"visitas"` en `secciones_omitidas`. **Propuesta técnica (D22).**
- `secciones_omitidas` se ordena `indicaciones`, `riesgo`, `visitas`.

## Errores

Además de CR-162 (`28000` 401, `42501` 403, `P0002` 404, `22023` 422):

| Situación                                                                                                                              | HTTP | Código público          |
| -------------------------------------------------------------------------------------------------------------------------------------- | ---- | ----------------------- |
| Sin el permiso de la matriz, o el plan no incluye la funcionalidad                                                                     | 403  | `FORBIDDEN`             |
| Cuenta sin prueba ni plan vigente (`CR_CUENTA_SIN_ACCESO`)                                                                             | 403  | `SUBSCRIPTION_INACTIVE` |
| `:tipo` desconocido, `:envejecienteId` mal formado; adulto inexistente, de otra cuenta, fuera de alcance o con consentimiento retirado | 404  | `NOT_FOUND`             |
| Filtro, orden, paginación o cuerpo inválidos; `desde > hasta`; `formato` distinto de `csv` en `GET` o de `pdf`/`xlsx` en `POST`        | 422  | `INVALID_INPUT`         |

No hay códigos `CR_*` nuevos.

## Persistencia propuesta

La [migración de la fase 7](../../supabase/migrations/20261121064256_fase_7_reportes_cuidared_012.sql) agrega funciones. Las RPC en `cuidared_api` usan `security definer`, `search_path` vacío y `execute` para `authenticated`.

| RPC                                                                                                                                           | Ruta                                                         |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `api_resumen_casos_listar(p_cuenta_id bigint, p_filtros jsonb, p_orden text[], p_limite integer, p_desplazamiento bigint)` → `{items, total}` | GET `/resumen-casos`                                         |
| `api_resumen_casos_indicadores(p_cuenta_id bigint)`                                                                                           | GET `/resumen-casos/indicadores`                             |
| `api_reporte_opciones(p_cuenta_id bigint, p_ambito text)`                                                                                      | GET `/resumen-casos/opciones` y `/reportes/opciones`            |
| `api_reporte(p_cuenta_id bigint, p_tipo text, p_filtros jsonb)`                                                                               | GET `/reportes/:tipo`                                        |
| `api_reporte_avanzado(p_cuenta_id bigint, p_filtros jsonb)`                                                                                   | GET `/reportes/analisis-avanzado`                            |
| `api_exportar_reporte_csv(p_cuenta_id bigint, p_tipo text, p_filtros jsonb)` → `{exportacion, reporte}`                                       | GET `/reportes/:tipo/exportacion` (Express serializa el CSV) |
| `api_registrar_exportacion_reporte(p_cuenta_id bigint, p_datos jsonb)`                                                                        | POST `/reportes/exportaciones`                               |
| `api_informe_medico(p_cuenta_id bigint, p_envejeciente_id uuid)`                                                                              | GET `/envejecientes/:envejecienteId/informe-medico`          |

- `p_tipo` usa los códigos `adultos`, `visitas`, `necesidades` y `casos_prioritarios`; Express traduce `casos-prioritarios` de la ruta. `p_filtros` lleva las claves sin `filter[...]` y con tipos JSON (`tipo_necesidad_id` numérico; fechas y códigos como cadena). `p_orden` recibe los tokens de `sort` (`'prioridad'`, `'-riesgo'`). `exportacion` de `api_exportar_reporte_csv` tiene la forma de la respuesta de `POST /reportes/exportaciones`.
- Funciones internas en `cuidared_interno`, sin `execute` para los roles de la API. Reutilizan `exigir`, `tiene_permiso`, `cuenta_tiene_funcionalidad`, `alcanza_envejeciente`, `membresia_activa`, `alerta_parametro`, `alerta_es_prioritaria`, `nivel_riesgo_vigente` y `hoy`.
- `api_auditoria_cuenta` se reemplaza con la misma firma y salida para incluir las entidades `exportacion_reporte` e `informe_medico` de la cuenta.
- **Sin índices nuevos.** Las agregaciones parten de `envejeciente (cuenta_id, estado)` y llegan a cada hecho por los índices existentes por adulto: `ix_detalle_visita_envejeciente`, `ix_necesidades_expediente_fecha`, `alerta_adulto_fecha_idx`, `ix_env_riesgo_envejeciente`, `uq_vinculo_vigente` e `ix_indicacion_medica_envejeciente`. Con 100 adultos cada consulta recorre unos cientos o miles de filas. El rango de fechas se aplica después de llegar por adulto, por lo que un índice por fecha no reduciría el trabajo con este volumen.

## Verificación

`node scripts/validar-propuestas-local.js --solo=reportes` crea una base local desechable con **todas** las migraciones de `supabase/migrations/` (salvo las dos que solo programan Supabase Cron), carga la propuesta y ejecuta `docs/verificacion/local/pruebas-7-*.sql` en transacciones con `ROLLBACK`: permisos por rol y tipo de cuenta, plan (Familia en prueba denegada, Organización en prueba permitida, avanzado solo con `reportes_avanzados`), aislamiento entre cuentas, alcance del Cuidador en el informe, omisión de secciones, conciliación de totales con las filas fuente, alertas frente a adultos prioritarios, resultados vacíos, semántica de fechas (medianoche de Santo Domingo y límites inclusivos), umbral 15/16 días, auditoría de exportaciones e informe, cuenta vencida y carga de 2.000 adultos con 6.000 visitas, personal asignado, riesgo, necesidades y alertas. En la validación local del 20/11/2026, con estadísticas del planificador como las que mantiene autovacuum, la RPC más lenta tardó 147 ms (límite de la prueba: 1,5 s). Las agregaciones se calculan una vez por cuenta, sin subconsultas por adulto. Trazabilidad: ID07, RF-07, RF-08, CU-11, CU-12.

## Notas para el frontend conectado

- Sustituir `casosResumen`, `indicadoresResumen`, `generarReporte` y `analisisAvanzado` por estas consultas; mantener los gráficos con `series` y las tablas con `detalle`.
- Estados del prototipo: `en_atencion` → `alerta_en_proceso`; `visita_vencida` → `seguimiento_vencido`; `necesidades` → `necesidades_activas`. Necesidades `satisfecha`/`inactiva` → `resuelta`/`cancelada`. Alertas `atendida` → `resuelta`.
- El riesgo `null` se muestra como «Sin evaluación vigente».
- El CSV se descarga del servidor. Antes de generar el PDF o el Excel se llama a `POST /reportes/exportaciones` y, si responde 403, no se genera el archivo.
- Para el informe médico, el PDF se construye con jsPDF a partir de `data`; se omiten las secciones de `secciones_omitidas` con el aviso correspondiente.
- Mostrar la sección avanzada bloqueada cuando `funcionalidades` del contexto no incluya `reportes_avanzados`, y los reportes bloqueados cuando no incluya `dashboard_metricas`.
