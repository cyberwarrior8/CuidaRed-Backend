/* Contratos de alertas y avisos internos · ID06/RF-04/RF-05/RF-18. © 2026 Equipo CuidaRed – INTEC. Todos los derechos reservados. */
import { z } from 'zod';
import { jsonBigintId } from '../../lib/bigint-id.js';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { AppError, unavailable } from '../../lib/errors.js';

const id = z.uuid();
const codigo = z
  .string()
  .max(80)
  .regex(/^[a-z][a-z0-9_]*$/);
const instante = z.iso.datetime({ offset: true });
const estadosAlerta = z.enum(['pendiente', 'en_proceso', 'resuelta']);
const estadosAviso = z.enum(['no_leida', 'leida', 'archivada']);
const asunto = { envejeciente_id: id, nombres: z.string(), apellidos: z.string() };
const origen = z.discriminatedUnion('tipo', [
  z.object({ tipo: z.literal('riesgo'), referencia_id: jsonBigintId }),
  z.object({ tipo: z.literal('necesidad'), referencia_id: id }),
  z.object({ tipo: z.literal('visita'), referencia_id: id }),
  z.object({ tipo: z.literal('perfil'), referencia_id: id }),
]);

export const alertaDto = z.object({
  alerta_envejeciente_id: id,
  ...asunto,
  tipo: z.object({ codigo, nombre: z.string() }),
  prioridad: z.object({ nombre: z.string(), orden: z.int() }),
  descripcion: z.string(),
  origen: z.enum(['sistema', 'manual']),
  estado: estadosAlerta,
  fecha_alerta: instante,
  fecha_atencion: instante.nullable(),
  atendida_por: z.string().nullable(),
  cierre_automatico: z.boolean(),
  accion_tomada: z.string().nullable(),
  fuente: origen.nullable(),
  es_prioritaria: z.boolean(),
});

export const casoDto = z.object({
  ...asunto,
  fecha_alerta: instante,
  total_alertas: z.int().positive(),
  alertas: z.array(alertaDto).min(1),
});

export const avisoDto = z.object({
  notificacion_id: id,
  alerta_envejeciente_id: id,
  mensaje: z.string(),
  estado: estadosAviso,
  fecha_notificacion: instante,
  fecha_lectura: instante.nullable(),
});

export const queryAlertas = createCollectionQuery({
  sortableFields: ['fecha_alerta', 'alerta_envejeciente_id'],
  defaultSort: '-fecha_alerta',
  tieBreaker: 'alerta_envejeciente_id',
  filterSchemas: { estado: estadosAlerta, envejeciente_id: id, tipo: codigo },
});

export const queryCasos = createCollectionQuery({
  sortableFields: ['fecha_alerta', 'envejeciente_id'],
  defaultSort: '-fecha_alerta',
  tieBreaker: 'envejeciente_id',
  filterSchemas: { envejeciente_id: id },
});

export const queryAvisos = createCollectionQuery({
  sortableFields: ['fecha_notificacion', 'notificacion_id'],
  defaultSort: '-fecha_notificacion',
  tieBreaker: 'notificacion_id',
  filterSchemas: { estado: estadosAviso },
});

export function leerId(raw) {
  if (!id.safeParse(raw).success) throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
  return raw;
}

export function leerEntrada(schema, raw) {
  const parsed = schema.safeParse(raw);
  if (!parsed.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return parsed.data;
}

export function leerSalida(schema, raw) {
  const parsed = schema.safeParse(raw);
  if (!parsed.success) throw unavailable();
  return parsed.data;
}

export const sinCuerpo = z.strictObject({});
export const resolverAlerta = z.strictObject({
  accion_tomada: z
    .string()
    .trim()
    .min(1)
    .max(500)
    .refine((texto) => !/\p{Cc}/u.test(texto.replace(/[\t\r\n]/g, ''))),
});
