/* Validación de entradas de la agenda de cuidado y las evidencias · RF-16, RS-013, CR-162. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { bigintId, jsonBigintId } from '../../lib/bigint-id.js';
import { businessError } from '../../lib/business-errors.js';
import { AppError } from '../../lib/errors.js';
import { createCollectionQuery } from '../../lib/collection-query.js';
import './agenda-errors.js';

export const ESTADOS_TAREA = ['pendiente', 'en_progreso', 'completada', 'cancelada'];
// RS-013: jpg, png, webp o pdf de hasta 5 MB (los valida también la base y el bucket).
export const EVIDENCIA_TIPOS = ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];
export const EVIDENCIA_MAX_BYTES = 5 * 1024 * 1024;

const fecha = z.iso.date();
const hora = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);
const uuid = z.uuid();
const idEntero = jsonBigintId;
const titulo = z.string().trim().min(3).max(80);
const alcance = z.enum(['esta', 'siguientes']);

/* Cuerpos (z.strictObject: sin campos desconocidos; el actor, la cuenta y el estado nunca vienen del cliente). */

// Propuesta técnica (D12): diaria o semanal con fecha de fin; dias_semana ISO 8601 (1 = lunes … 7 = domingo).
// Las reglas de fondo (días obligatorios, fin posterior al inicio, máximo 60 tareas) las aplica la base.
const repeticion = z.strictObject({
  frecuencia: z.enum(['diaria', 'semanal']),
  dias_semana: z.array(z.int().min(1).max(7)).max(7).optional(),
  hasta: fecha,
});

export const crearTareaSchema = z.strictObject({
  envejeciente_id: uuid,
  cuidador_id: idEntero,
  titulo,
  indicacion_medica_id: uuid.nullish(),
  prioridad_id: z.int().min(1).max(32767),
  fecha_programada: fecha,
  hora_programada: hora.nullish(),
  requiere_evidencia: z.boolean(),
  repeticion: repeticion.optional(),
});

export const actualizarTareaSchema = z
  .strictObject({
    titulo: titulo.optional(),
    cuidador_id: idEntero.optional(),
    indicacion_medica_id: uuid.nullable().optional(),
    prioridad_id: z.int().min(1).max(32767).optional(),
    fecha_programada: fecha.optional(),
    hora_programada: hora.nullable().optional(),
    requiere_evidencia: z.boolean().optional(),
    alcance: alcance.optional(),
  })
  .refine((datos) => Object.keys(datos).some((campo) => campo !== 'alcance'), {
    message: 'Indica al menos un campo para actualizar.',
  });

export const cancelarTareaSchema = z.strictObject({
  motivo: z.string().trim().min(3).max(300),
  alcance: alcance.default('esta'),
});

const archivo = {
  nombre_archivo: z
    .string()
    .trim()
    .min(1)
    .max(150)
    .refine((nombre) => !/[/\\]/.test(nombre) && !/\p{Cc}/u.test(nombre)),
  tipo_mime: z.enum(EVIDENCIA_TIPOS),
  tamano_bytes: z.int().min(1).max(EVIDENCIA_MAX_BYTES),
};

export const subidaEvidenciaSchema = z.strictObject(archivo);

export const registrarEvidenciaSchema = z.strictObject({
  ruta: z.string().min(1).max(300),
  observacion: z.string().trim().min(1).max(300).optional(),
  ...archivo,
});

export const rechazarEvidenciaSchema = z.strictObject({
  motivo: z.string().trim().min(5).max(200),
});

// Acciones sin datos (iniciar, completar, validar): cuerpo ausente o vacío.
export const sinCuerpoSchema = z.strictObject({});

/**
 * Valida un cuerpo. Los errores de repetición y de archivo usan sus códigos de negocio (CR_REPETICION_INVALIDA,
 * CR_ARCHIVO_INVALIDO), igual que cuando los detecta la base; el resto es INVALID_INPUT genérico (CR-162).
 */
export function parseBody(schema, body) {
  const result = schema.safeParse(body ?? {});
  if (result.success) return result.data;
  const campos = new Set(result.error.issues.map((issue) => issue.path[0]));
  if (campos.has('repeticion')) throw businessError('CR_REPETICION_INVALIDA');
  if (['nombre_archivo', 'tipo_mime', 'tamano_bytes'].some((campo) => campos.has(campo))) {
    throw businessError('CR_ARCHIVO_INVALIDO');
  }
  throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
}

/* Listado paginado de tareas (CR-162): filter[desde|hasta|estado|envejeciente_id|cuidador_id]. */
const readTareasQuery = createCollectionQuery({
  sortableFields: [
    'fecha_programada',
    'hora_programada',
    'estado',
    'prioridad',
    'fecha_creacion',
    'tarea_id',
  ],
  defaultSort: 'fecha_programada,hora_programada',
  tieBreaker: 'tarea_id',
  filterSchemas: {
    desde: fecha,
    hasta: fecha,
    estado: z.enum(ESTADOS_TAREA),
    envejeciente_id: uuid,
    cuidador_id: bigintId,
  },
});

export function parseTareasQuery(query) {
  const parsed = readTareasQuery(query);
  const { desde, hasta } = parsed.filters;
  if (desde && hasta && desde > hasta) {
    throw new AppError(422, 'INVALID_INPUT', 'Revisa los parámetros de consulta.');
  }
  return parsed;
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Identificador de ruta: uno mal formado "no existe" (404) sin consultar la base. */
export function readUuidParam(value) {
  if (typeof value !== 'string' || !uuidPattern.test(value)) {
    throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
  }
  return value.toLowerCase();
}
