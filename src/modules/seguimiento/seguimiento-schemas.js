/* Validación de entradas del seguimiento del adulto mayor · ID03/RF-12/RF-13/RF-14/RF-15. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { AppError } from '../../lib/errors.js';

/* ───────────── Identificadores de ruta ───────────── */

const notFound = () => new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Un id malformado en la ruta es un recurso inexistente (mismo criterio que requireCuenta); no llega a la base.
export function uuidParam(value) {
  if (typeof value !== 'string' || !uuidPattern.test(value)) throw notFound();
  return value.toLowerCase();
}
// Identidades bigint de la base; el límite de 15 dígitos las mantiene representables como Number.
export function bigintParam(value) {
  if (typeof value !== 'string' || !/^[1-9]\d{0,14}$/.test(value)) throw notFound();
  return Number(value);
}

export function parseBody(schema, body) {
  const result = schema.safeParse(body ?? {});
  if (!result.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return result.data;
}

/* ───────────── Campos reutilizables ───────────── */

const idUsuario = z.guid();
const vacioANull = (value) => (value === '' ? null : value);
const textoOpcional = (max) =>
  z.string().trim().max(max).nullable().transform(vacioANull).optional();

function esFechaReal(value) {
  const [anio, mes, dia] = value.split('-').map(Number);
  if (anio < 1900 || anio > 2100) return false;
  const fecha = new Date(Date.UTC(anio, mes - 1, dia));
  return (
    fecha.getUTCFullYear() === anio && fecha.getUTCMonth() === mes - 1 && fecha.getUTCDate() === dia
  );
}
const fecha = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/)
  .refine(esFechaReal);

/* ───────────── Asignaciones y permiso familiar (RF-12, RF-13) ───────────── */

export const TIPOS_ASIGNACION = ['cuidador_asignado', 'voluntario_asignado'];

export const asignarSchema = z.strictObject({
  tipo: z.enum(TIPOS_ASIGNACION),
  usuario_id: idUsuario,
});
export const autorizarFamiliarSchema = z.strictObject({ usuario_id: idUsuario });
// El actor y la cuenta nunca viajan en el cuerpo: salen de la sesión y de la ruta.
export const revocarSchema = z.strictObject({ motivo: textoOpcional(300) });

/* ───────────── Riesgo (RF-14, D11) ───────────── */

export const NIVELES_RIESGO = ['bajo', 'medio', 'alto'];

/*
 * Claves del cuestionario v1 en snake_case (el frontend usa camelCase: ingresosFijos → ingresos_fijos, viveSolo →
 * vive_solo). Solo se declaran claves y valores admitidos; los puntos y umbrales viven únicamente en la base, que
 * calcula puntaje, desglose y nivel (el cliente nunca los aporta).
 */
export const RESPUESTAS_SI_NO = [
  'ingresos_fijos',
  'vive_solo',
  'cronica',
  'medicamentos',
  'familiares',
  'cuidador',
];
export const RESPUESTAS_OPCION = {
  vivienda: ['propia', 'alquilada', 'cedida', 'precaria'],
  movilidad: ['independiente', 'apoyo', 'reducida', 'encamado'],
  frecuencia: ['diaria', 'semanal', 'mensual', 'ocasional', 'nunca'],
};
export const PREGUNTAS = [...RESPUESTAS_SI_NO, ...Object.keys(RESPUESTAS_OPCION)];

const respuestasShape = {
  ...Object.fromEntries(
    RESPUESTAS_SI_NO.map((clave) => [clave, z.boolean().nullable().optional()]),
  ),
  ...Object.fromEntries(
    Object.entries(RESPUESTAS_OPCION).map(([clave, valores]) => [
      clave,
      z
        .enum([...valores, ''])
        .nullable()
        .optional(),
    ]),
  ),
};
// Las ausentes se informan con un error propio (422 EVALUATION_INCOMPLETE) y no como entrada inválida.
export const evaluarSchema = z.strictObject({ respuestas: z.strictObject(respuestasShape) });

export function respuestasFaltantes(respuestas) {
  return PREGUNTAS.filter((clave) => [undefined, null, ''].includes(respuestas[clave]));
}

export const registrarRiesgoSchema = z.strictObject({
  riesgo_id: z.number().int().min(1).max(32767),
  nivel: z.enum(NIVELES_RIESGO),
  motivo: z.string().trim().min(5).max(200),
  observacion: textoOpcional(300),
});
export const resolverRiesgoSchema = z.strictObject({ observacion: textoOpcional(300) });

/* ───────────── Indicaciones médicas (RF-15) ───────────── */

export const ESTADOS_INDICACION = ['activa', 'suspendida', 'finalizada'];

const tipoIndicacion = z.number().int().min(1).max(32767);
const titulo = z.string().trim().min(3).max(80);
const finNoAnterior = (d) => !d.fecha_inicio || !d.fecha_fin || d.fecha_fin >= d.fecha_inicio;

export const crearIndicacionSchema = z
  .strictObject({
    tipo_indicacion_id: tipoIndicacion,
    titulo,
    descripcion: textoOpcional(300),
    frecuencia_horario: textoOpcional(60),
    fecha_inicio: fecha,
    fecha_fin: fecha.nullable().optional(),
  })
  .refine(finNoAnterior);

// El estado se cambia solo con su propia acción. Un null limpia el campo; omitirlo lo conserva.
export const editarIndicacionSchema = z
  .strictObject({
    tipo_indicacion_id: tipoIndicacion.optional(),
    titulo: titulo.optional(),
    descripcion: textoOpcional(300),
    frecuencia_horario: textoOpcional(60),
    fecha_inicio: fecha.optional(),
    fecha_fin: fecha.nullable().optional(),
  })
  .refine((d) => Object.keys(d).length > 0)
  .refine(finNoAnterior);

export const estadoIndicacionSchema = z.strictObject({ estado: z.enum(ESTADOS_INDICACION) });

/* ───────────── Colecciones (CR-162) ───────────── */

export const TIPOS_EVENTO = ['riesgo', 'evaluacion', 'indicacion', 'visita', 'necesidad', 'alerta'];

export const indicacionesQuery = createCollectionQuery({
  sortableFields: ['fecha_inicio', 'fecha_creacion', 'indicacion_medica_id'],
  defaultSort: '-fecha_inicio',
  tieBreaker: 'indicacion_medica_id',
  filterSchemas: { estado: z.enum(ESTADOS_INDICACION) },
});

export const historialQuery = createCollectionQuery({
  sortableFields: ['fecha'],
  defaultSort: '-fecha',
  tieBreaker: 'fecha',
  filterSchemas: { tipo: z.enum(TIPOS_EVENTO) },
});

/*
 * La base ordena por UN campo y desempata siempre por su identificador ascendente. Un orden con más campos, o un
 * desempate descendente, no se puede cumplir con exactitud y se rechaza en lugar de ignorarse.
 */
export function ordenUnico({ sort }, desempate) {
  const [principal, ...resto] = sort;
  if (resto.some((s) => s.field !== desempate || s.direction !== 'asc')) {
    throw new AppError(422, 'INVALID_INPUT', 'Revisa los parámetros de consulta.');
  }
  return { campo: principal.field, descendente: principal.direction === 'desc' };
}
