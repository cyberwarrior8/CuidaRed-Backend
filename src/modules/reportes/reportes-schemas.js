/* Contratos de resumen de casos, reportes, exportaciones e informe médico · ID07/RF-07/RF-08. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { AppError, unavailable } from '../../lib/errors.js';

/*
 * Entradas: se validan en Express con listas cerradas antes de llegar a la base, que vuelve a validarlas.
 * Salidas: cada respuesta de RPC se proyecta con un esquema (z.object descarta claves no previstas) para no publicar
 * nada fuera de docs/contratos/reportes.md; un contrato roto es indisponibilidad (503), nunca datos a medias.
 */

const invalido = () => new AppError(422, 'INVALID_INPUT', 'Revisa los parámetros de consulta.');
const noEncontrado = () => new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');

/* ───────────── Tipos de reporte ───────────── */

/** Tipo de la ruta (kebab-case) → código del contrato y de la RPC. */
export const TIPOS_RUTA = {
  adultos: 'adultos',
  visitas: 'visitas',
  necesidades: 'necesidades',
  'casos-prioritarios': 'casos_prioritarios',
};
const TIPOS = Object.values(TIPOS_RUTA);

/** Tipo de la ruta o 404 sin consultar la base. */
export function leerTipo(raw) {
  if (!Object.hasOwn(TIPOS_RUTA, raw)) throw noEncontrado();
  return TIPOS_RUTA[raw];
}

const uuid = z.uuid();

/** Identificador de adulto de la ruta: si no es UUID, el recurso no existe. */
export function leerEnvejecienteId(raw) {
  if (!uuid.safeParse(raw).success) throw noEncontrado();
  return raw;
}

/* ───────────── Entradas ───────────── */

const sinControl = (texto) => !/\p{Cc}/u.test(texto);
const textoFiltro = (min, max) => z.string().trim().min(min).max(max).refine(sinControl);
const esFecha = (texto) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(texto)) return false;
  const fecha = new Date(`${texto}T00:00:00Z`);
  return !Number.isNaN(fecha.getTime()) && fecha.toISOString().slice(0, 10) === texto;
};
const fechaEntrada = z.string().refine(esFecha);
const municipioEntrada = z.string().regex(/^[0-9]{4,6}$/);
const riesgoEntrada = z.enum(['alto', 'medio', 'bajo', 'sin_evaluacion']);
const ESTADOS_ATENCION = [
  'alerta_pendiente',
  'alerta_en_proceso',
  'seguimiento_vencido',
  'necesidades_activas',
  'al_dia',
];
const PRIORIDADES = ['alta', 'media', 'baja'];

const CAMPOS_ORDEN = ['prioridad', 'estado_atencion', 'ultima_visita', 'riesgo', 'nombre'];
const coleccionResumen = createCollectionQuery({
  // `envejeciente_id` solo es el desempate interno: la RPC aplica el desempate fijo del contrato.
  sortableFields: [...CAMPOS_ORDEN, 'envejeciente_id'],
  defaultSort: 'prioridad',
  tieBreaker: 'envejeciente_id',
  filterSchemas: {
    estado_atencion: z.enum(ESTADOS_ATENCION),
    prioridad: z.enum(PRIORIDADES),
    riesgo: riesgoEntrada,
    municipio_cod: municipioEntrada,
    zona: textoFiltro(1, 60),
    asignado: z.union([z.enum(['sin', 'con']), uuid]),
    q: textoFiltro(2, 60),
  },
});

/** Consulta CR-162 del resumen: uno o dos campos de orden del contrato (sin el desempate interno). */
export function queryResumen(raw) {
  if (
    typeof raw?.sort === 'string' &&
    raw.sort.split(',').some((t) => /^-?envejeciente_id$/.test(t))
  )
    throw invalido();
  const query = coleccionResumen(raw);
  const sort = query.sort.filter((s) => s.field !== 'envejeciente_id');
  if (sort.length < 1 || sort.length > 2) throw invalido();
  return { ...query, sort };
}

/** Rutas sin parámetros de consulta: cualquier parámetro es 422. */
export function sinParametros(query) {
  if (query && Object.keys(query).length) throw invalido();
}

const FILTROS_REPORTE = ['desde', 'hasta', 'municipio_cod', 'zona', 'riesgo'];
const esquemasFiltro = {
  desde: fechaEntrada,
  hasta: fechaEntrada,
  municipio_cod: municipioEntrada,
  zona: textoFiltro(1, 60),
  riesgo: riesgoEntrada,
  tipo_necesidad_id: z
    .string()
    .regex(/^[1-9]\d{0,4}$/)
    .transform(Number)
    .refine((n) => n <= 32767),
};

/**
 * `filter[...]` de un reporte (igualdad, sin paginación). `tipo_necesidad_id` solo en `necesidades`; `formato`
 * solo en la exportación. Un parámetro desconocido, repetido o inválido es 422.
 */
export function leerFiltrosReporte(query, { tipo, conFormato = false } = {}) {
  if (!query || typeof query !== 'object' || Array.isArray(query)) throw invalido();
  const permitidos =
    tipo === 'necesidades' ? [...FILTROS_REPORTE, 'tipo_necesidad_id'] : FILTROS_REPORTE;
  const filtros = {};
  let formato;
  for (const [clave, valor] of Object.entries(query)) {
    if (typeof valor !== 'string') throw invalido();
    if (conFormato && clave === 'formato') {
      if (valor !== 'csv') throw invalido();
      formato = valor;
      continue;
    }
    const campo = /^filter\[([a-z_]+)\]$/.exec(clave)?.[1];
    if (!campo || !permitidos.includes(campo)) throw invalido();
    const resultado = esquemasFiltro[campo].safeParse(valor);
    if (!resultado.success) throw invalido();
    filtros[campo] = resultado.data;
  }
  if (conFormato && formato === undefined) throw invalido();
  if (filtros.desde && filtros.hasta && filtros.desde > filtros.hasta) throw invalido();
  return filtros;
}

// Una clave con valor null equivale a omitirla (igual que la base): los filtros normalizados de una respuesta,
// que traen todas las claves, se pueden reenviar tal cual.
const sinNulos = (valor) =>
  valor && typeof valor === 'object' && !Array.isArray(valor)
    ? Object.fromEntries(Object.entries(valor).filter(([, v]) => v !== null))
    : valor;
const filtrosCuerpo = z
  .preprocess(
    sinNulos,
    z.strictObject({
      desde: fechaEntrada.nullable().optional(),
      hasta: fechaEntrada.nullable().optional(),
      municipio_cod: municipioEntrada.nullable().optional(),
      zona: textoFiltro(1, 60).nullable().optional(),
      riesgo: riesgoEntrada.nullable().optional(),
      tipo_necesidad_id: z.int().min(1).max(32767).nullable().optional(),
    }),
  )
  .nullable()
  .optional();

const exportacionCuerpo = z.strictObject({
  tipo: z.enum([...TIPOS, 'analisis_avanzado']),
  formato: z.enum(['pdf', 'xlsx']),
  filtros: filtrosCuerpo,
});

/** Cuerpo de POST /reportes/exportaciones (registro previo del PDF o el Excel). */
export function leerExportacion(body) {
  const resultado = exportacionCuerpo.safeParse(body ?? {});
  if (!resultado.success)
    throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  const datos = resultado.data;
  const filtros = datos.filtros ?? {};
  if (
    (filtros.tipo_necesidad_id != null && datos.tipo !== 'necesidades') ||
    (filtros.desde && filtros.hasta && filtros.desde > filtros.hasta)
  ) {
    throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  }
  return datos;
}

/* ───────────── Salidas ───────────── */

const instante = z.iso.datetime({ offset: true });
const fecha = z.string().refine(esFecha);
const hora = z.string().regex(/^\d{2}:\d{2}$/);
const entero = z.int().min(0);
const texto = z.string();
const riesgoVigente = z.enum(['alto', 'medio', 'bajo']).nullable();
const municipio = z.object({ codigo: texto, nombre: texto.nullable() });
const persona = z.object({ usuario_id: uuid, nombres: texto, apellidos: texto });
export const opcionesReporteDto = z.object({
  municipios: z.array(municipio),
  sectores: z.array(texto),
  asignados: z.array(persona.extend({ rol: z.enum(['cuidador', 'voluntario']) })),
});
const nombrePersona = z.object({ nombres: texto, apellidos: texto });
const generadoPor = z.object({
  nombres: texto,
  apellidos: texto,
  rol: z.enum(['administrador', 'coordinador', 'cuidador', 'familiar', 'voluntario']),
});
const cuenta = z.object({ nombre: texto });
const estadoGeneral = z.enum(['estable', 'requiere_atencion', 'situacion_critica']).nullable();
const filtrosDto = z.object({
  desde: fecha.nullable(),
  hasta: fecha.nullable(),
  municipio_cod: texto.nullable(),
  zona: texto.nullable(),
  riesgo: riesgoEntrada.nullable(),
  tipo_necesidad_id: z.int().nullable(),
});
const serie = z.array(
  z.object({ clave: texto, etiqueta: texto, valor: entero, porcentaje: entero }),
);
const series = (claves) => z.object(Object.fromEntries(claves.map((c) => [c, serie])));

const casoResumen = z.object({
  envejeciente_id: uuid,
  nombres: texto,
  apellidos: texto,
  municipio,
  zona: texto.nullable(),
  fecha_alta: instante,
  riesgo_vigente: riesgoVigente,
  prioridad: z.enum(PRIORIDADES),
  estado_atencion: z.enum(ESTADOS_ATENCION),
  motivos: z.array(
    z.enum([
      'alerta_prioritaria_abierta',
      'riesgo_alto',
      'alerta_seguimiento_abierta',
      'alerta_abierta',
      'seguimiento_vencido',
      'necesidades_activas',
      'riesgo_medio',
      'sin_evaluacion_vigente',
      'sin_personal_asignado',
    ]),
  ),
  alertas: z.object({
    abiertas: entero,
    pendientes: entero,
    en_proceso: entero,
    prioritarias_abiertas: entero,
  }),
  necesidades_activas: entero,
  seguimiento: z
    .object({
      ultima_visita_id: uuid.nullable(),
      ultima_visita_fecha: fecha.nullable(),
      fecha_referencia: fecha,
      dias_sin_visita: z.int(),
      umbral_dias: entero,
      vencido: z.boolean(),
    })
    .nullable(),
  asignados: z.object({
    total: entero,
    cuidadores: z.array(persona),
    voluntarios: z.array(persona),
  }),
});
export const resumenPagina = z.object({ items: z.array(casoResumen), total: entero });

export const indicadoresDto = z.object({
  fecha_calculo: fecha,
  umbral_dias_sin_visita: entero.nullable(),
  casos_activos: entero,
  por_prioridad: z.object({ alta: entero, media: entero, baja: entero }),
  por_estado_atencion: z.object(Object.fromEntries(ESTADOS_ATENCION.map((e) => [e, entero]))),
  adultos_prioritarios: entero,
  alertas_prioritarias_abiertas: entero,
  alertas_abiertas: entero,
  alertas_pendientes: entero,
  alertas_en_proceso: entero,
  seguimiento_vencido: entero,
  necesidades_activas: entero,
  adultos_con_necesidades_activas: entero,
  sin_personal_asignado: entero,
});

const enteros = (claves) => z.object(Object.fromEntries(claves.map((c) => [c, entero])));

const REPORTES = {
  adultos: {
    campo_fecha: 'fecha_alta',
    indicadores: enteros([
      'registrados',
      'activos',
      'inactivos',
      'fallecidos',
      'riesgo_alto',
      'riesgo_medio',
      'riesgo_bajo',
      'sin_evaluacion',
    ]).extend({ edad_promedio: z.number().nullable(), sin_personal_asignado: entero }),
    series: series(['por_riesgo', 'por_municipio', 'por_zona', 'por_estado', 'por_mes']),
    detalle: z.object({
      envejeciente_id: uuid,
      nombres: texto,
      apellidos: texto,
      municipio,
      zona: texto.nullable(),
      edad: entero,
      sexo: z.enum(['F', 'M']),
      riesgo_vigente: riesgoVigente,
      estado: z.enum(['activo', 'inactivo', 'fallecido']),
      fecha_alta: instante,
      personal_asignado: entero,
    }),
  },
  visitas: {
    campo_fecha: 'fecha_visita',
    indicadores: z.object({
      visitas_realizadas: entero,
      visitas_personales: entero,
      visitas_institucionales: entero,
      atenciones: entero,
      adultos_visitados: entero,
      adultos_activos: entero,
      promedio_por_adulto: z.number().nullable(),
      requirieron_atencion: entero,
      situaciones_criticas: entero,
      visitas_compartidas: entero,
    }),
    series: series(['por_mes', 'por_tipo_visita', 'por_estado_general']),
    detalle: z.object({
      visita_id: uuid,
      fecha,
      hora_inicio: hora.nullable(),
      hora_fin: hora.nullable(),
      razon: texto.nullable(),
      origen: z.enum(['interna', 'solicitud']),
      tipo_visita: z.enum(['personal', 'institucional']),
      responsables: z.array(persona),
      adultos: z.array(
        z.object({
          envejeciente_id: uuid,
          nombres: texto,
          apellidos: texto,
          estado_general: estadoGeneral,
        }),
      ),
    }),
  },
  necesidades: {
    campo_fecha: 'fecha_registro',
    indicadores: enteros([
      'registradas',
      'activas',
      'pendientes',
      'en_proceso',
      'resueltas',
      'canceladas',
      'porcentaje_resueltas',
      'prioridad_alta_activas',
      'recurrentes',
      'adultos_con_necesidades',
    ]).extend({
      mas_frecuente: z
        .object({ tipo_necesidad_id: z.int(), nombre: texto, total: entero })
        .nullable(),
    }),
    series: series(['por_tipo', 'por_estado', 'por_prioridad', 'recurrencia', 'por_mes']),
    detalle: z
      .object({ tipo_necesidad_id: z.int(), nombre: texto })
      .extend(
        enteros([
          'total',
          'porcentaje',
          'pendientes',
          'en_proceso',
          'resueltas',
          'canceladas',
          'prioridad_alta',
          'recurrentes',
        ]).shape,
      ),
  },
  casos_prioritarios: {
    campo_fecha: 'fecha_alerta',
    indicadores: enteros([
      'alertas_prioritarias',
      'adultos_prioritarios',
      'casos_abiertos',
      'alertas_pendientes',
      'alertas_en_proceso',
      'alertas_resueltas',
      'resueltas_automaticamente',
      'porcentaje_resueltas',
    ]),
    series: series(['por_estado', 'por_tipo', 'por_mes']),
    detalle: z.object({
      envejeciente_id: uuid,
      nombres: texto,
      apellidos: texto,
      municipio,
      zona: texto.nullable(),
      riesgo_vigente: riesgoVigente,
      alertas: entero,
      alertas_abiertas: entero,
      tipos: z.array(z.enum(['riesgo_alto', 'medicamento_pendiente', 'necesidad_prioritaria'])),
      estado_actual: z.enum(['pendiente', 'en_proceso', 'resuelta']),
      ultima_alerta: instante,
    }),
  },
};

/** Esquema de la respuesta de un tipo de reporte, con las claves en el orden del contrato. */
export const reporteDto = Object.fromEntries(
  Object.entries(REPORTES).map(([tipo, d]) => [
    tipo,
    z.object({
      tipo: z.literal(tipo),
      campo_fecha: z.literal(d.campo_fecha),
      zona_horaria: z.literal('America/Santo_Domingo'),
      generado_en: instante,
      filtros: filtrosDto,
      vacio: z.boolean(),
      indicadores: d.indicadores,
      series: d.series,
      detalle: z.array(d.detalle),
      detalle_total: entero,
      detalle_truncado: z.boolean(),
    }),
  ]),
);

// Las métricas de visitas son null cuando el actor no tiene `visitas:ver` (Familia).
const comparativo = {
  municipio,
  adultos_activos: entero,
  riesgo_alto: entero,
  visitas_realizadas: entero.nullable(),
  visitas_por_adulto: z.number().nullable(),
  necesidades_activas: entero,
  alertas_abiertas: entero,
  dias_sin_visita_promedio: z.number().nullable(),
  sin_personal_asignado: entero,
};
export const avanzadoDto = z.object({
  tipo: z.literal('analisis_avanzado'),
  zona_horaria: z.literal('America/Santo_Domingo'),
  generado_en: instante,
  filtros: filtrosDto,
  vacio: z.boolean(),
  comparativo_zonas: z.array(z.object({ municipio, zona: texto.nullable(), ...comparativo })),
  comparativo_municipios: z.array(z.object(comparativo)),
  tendencias: z.array(
    z.object({
      mes: z.string().regex(/^\d{4}-\d{2}$/),
      visitas_realizadas: entero.nullable(),
      variacion_visitas: z.int().nullable(),
      necesidades_registradas: entero,
      alertas_prioritarias: entero,
      perfiles_nuevos: entero,
    }),
  ),
});

export const exportacionDto = z.object({
  exportacion_id: uuid,
  tipo: z.enum([...TIPOS, 'analisis_avanzado']),
  formato: z.enum(['csv', 'pdf', 'xlsx']),
  filtros: filtrosDto,
  fecha: instante,
  generado_por: generadoPor,
  cuenta,
});

// Los catálogos heredados pueden tener `codigo` null (riesgo y nivel_riesgo de la fase 3b).
const nivel = z.object({ codigo: texto.nullable(), nombre: texto });
export const informeDto = z.object({
  informe_id: uuid,
  generado_en: instante,
  generado_por: generadoPor,
  cuenta,
  aviso: texto,
  secciones_omitidas: z.array(z.enum(['indicaciones', 'riesgo', 'visitas'])),
  identificacion: z.object({
    envejeciente_id: uuid,
    nombres: texto,
    apellidos: texto,
    cedula: texto,
    fecha_nacimiento: fecha,
    edad: entero,
    sexo: z.enum(['F', 'M']),
    municipio,
    provincia: z.object({ codigo: texto, nombre: texto }).nullable(),
    estado: z.enum(['activo', 'inactivo', 'fallecido']),
  }),
  riesgo: z
    .object({
      nivel_vigente: riesgoVigente,
      vigentes: z.array(
        z.object({
          envejeciente_riesgo_id: z.string().regex(/^\d+$/),
          factor: nivel,
          nivel,
          motivo: texto.nullable(),
          observacion: texto.nullable(),
          fecha: instante,
        }),
      ),
      historial: z.array(
        z.object({
          envejeciente_riesgo_id: z.string().regex(/^\d+$/),
          factor: nivel,
          nivel,
          estado: z.enum(['activo', 'resuelto', 'reemplazado']),
          motivo: texto.nullable(),
          fecha: instante,
          fecha_resolucion: instante.nullable(),
        }),
      ),
      historial_total: entero,
    })
    .nullable(),
  indicaciones: z
    .object({
      vigentes: z.array(
        z.object({
          indicacion_medica_id: uuid,
          tipo: z.object({ tipo_indicacion_id: z.int(), nombre: texto }),
          titulo: texto,
          descripcion: texto.nullable(),
          frecuencia_horario: texto.nullable(),
          fecha_inicio: fecha,
          fecha_fin: fecha.nullable(),
          registrada_por: nombrePersona.nullable(),
        }),
      ),
      no_vigentes: entero,
    })
    .nullable(),
  visitas: z
    .object({
      realizadas_total: entero,
      ultima_fecha: fecha.nullable(),
      recientes: z.array(
        z.object({
          visita_id: uuid,
          fecha,
          hora_inicio: hora.nullable(),
          hora_fin: hora.nullable(),
          origen: z.enum(['interna', 'solicitud']),
          responsables: z.array(nombrePersona),
          estado_general: estadoGeneral,
          observacion: texto.nullable(),
        }),
      ),
    })
    .nullable(),
});

/** Proyecta la salida de una RPC con su esquema; un contrato roto es indisponibilidad. */
export function leerSalida(schema, raw) {
  const resultado = schema.safeParse(raw);
  if (!resultado.success) throw unavailable();
  return resultado.data;
}
