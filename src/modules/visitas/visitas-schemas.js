/* Contratos de entrada y consulta de visitas y solicitudes de visita · ID04/RF-02. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { AppError } from '../../lib/errors.js';

export const ESTADOS_VISITA = ['programada', 'en_curso', 'completada', 'cancelada'];
export const ESTADOS_GENERALES = ['estable', 'requiere_atencion', 'situacion_critica'];
// Catálogo de aspectos del checklist: el del frontend (ASPECTOS_VISITA). Propuesta técnica (D14), sin catálogo oficial.
export const ASPECTOS_VISITA = [
  'alimentacion',
  'medicamentos',
  'higiene',
  'vivienda',
  'animo',
  'movilidad',
];
export const ESTADOS_SOLICITUD = ['pendiente', 'autorizada', 'rechazada', 'realizada', 'cancelada'];

const uuid = z.uuid();
const fecha = z.iso.date();
const hora = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);
const texto = (min, max) => z.string().trim().min(min).max(max);
const sinRepetidos = (items) => new Set(items).size === items.length;

/** Valida el cuerpo y responde 422 genérico: nunca devuelve el detalle de Zod. */
export function parseBody(schema, body) {
  const result = schema.safeParse(body ?? {});
  if (!result.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return result.data;
}

/** Los identificadores de la ruta son UUID; cualquier otra cosa es "no existe" (sin tocar la base). */
export function uuidParam(value) {
  if (!uuid.safeParse(value).success) {
    throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
  }
  return value;
}

/** Quita los nulos de primer y segundo nivel: para las RPC "ausente" y null significan lo mismo. */
export function sinNulos(value) {
  if (Array.isArray(value)) return value.map(sinNulos);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, v]) => v !== null && v !== undefined)
        .map(([k, v]) => [k, sinNulos(v)]),
    );
  }
  return value;
}

// Acciones sin parámetros (p. ej. iniciar): el cuerpo, si existe, debe ser vacío.
export const sinCuerpoSchema = z.strictObject({});

export const programarVisitaSchema = z.strictObject({
  fecha,
  hora_programada: hora,
  razon: texto(3, 120),
  notas: texto(1, 300).nullish(),
  envejeciente_ids: z.array(uuid).min(1).max(4).refine(sinRepetidos),
  participante_ids: z.array(uuid).min(1).max(3).refine(sinRepetidos),
});

const detalleSchema = z.strictObject({
  envejeciente_id: uuid,
  // Obligatorio salvo para el Voluntario (registro mínimo); lo decide el servidor según el rol real de quien registra.
  estado_general: z.enum(ESTADOS_GENERALES).nullish(),
  observacion: texto(3, 1000),
});
const camposRegistro = {
  detalles: z
    .array(detalleSchema)
    .min(1)
    .max(4)
    .refine((items) => sinRepetidos(items.map((d) => d.envejeciente_id))),
  checklist: z.array(z.enum(ASPECTOS_VISITA)).max(6).refine(sinRepetidos).nullish(),
  hora_inicio: hora.nullish(),
  hora_fin: hora.nullish(),
};

export const registrarVisitaSchema = z.strictObject(camposRegistro);

export const visitaRealizadaSchema = z.strictObject({
  // Id generado por el cliente: un reintento con el mismo id no duplica la visita (idempotencia).
  visita_id: uuid.nullish(),
  fecha: fecha.nullish(),
  razon: texto(3, 120).nullish(),
  ...camposRegistro,
});

export const cancelarVisitaSchema = z.strictObject({ motivo: texto(3, 300) });

export const autorizarSolicitudSchema = z.strictObject({
  envejeciente_id: uuid,
  fecha,
  hora,
});
export const rechazarSolicitudSchema = z.strictObject({ motivo: texto(3, 300) });

// Listados (CR-162): orden y filtros con lista cerrada; los filtros usan la sintaxis filter[campo]=valor.
export const readVisitasQuery = createCollectionQuery({
  sortableFields: ['fecha', 'hora_programada', 'estado', 'fecha_creacion', 'visita_id'],
  defaultSort: '-fecha,-hora_programada',
  tieBreaker: 'visita_id',
  filterSchemas: {
    estado: z.enum(ESTADOS_VISITA),
    envejeciente_id: uuid,
    desde: fecha,
    hasta: fecha,
  },
});

export const readSolicitudesQuery = createCollectionQuery({
  sortableFields: ['fecha_creacion', 'fecha_propuesta', 'solicitud_visita_id'],
  defaultSort: '-fecha_creacion',
  tieBreaker: 'solicitud_visita_id',
  filterSchemas: { estado: z.enum(ESTADOS_SOLICITUD) },
});
