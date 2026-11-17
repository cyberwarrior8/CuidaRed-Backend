/* Entradas de Backoffice · BO-RNF-01. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { bigintId } from '../../lib/bigint-id.js';
import { AppError } from '../../lib/errors.js';

export function parse(schema, value) {
  const result = schema.safeParse(value);
  if (!result.success) throw new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');
  return result.data;
}
export const id = bigintId;
export const usuario = z.uuid();
export const planId = z.int().min(1).max(32767);
export const motivo = z
  .string()
  .trim()
  .min(5)
  .max(400)
  .refine((s) => !/\p{Cc}/u.test(s.replaceAll('\n', '')));
export const variante = z.enum(['completo_claro', 'completo_oscuro', 'isotipo']);
export const credenciales = z.strictObject({
  email: z.email().max(254),
  password: z.string().min(1).max(256),
});
const fecha = z.iso.date();
const diaRD = (value) => new Date(value + 'T00:00:00-04:00').getTime();
const positive = (max) => z.string().regex(/^\d+$/).transform(Number).pipe(z.int().min(1).max(max));
const filtro = z.enum(['activa', 'por_vencer', 'vencida', 'extendida']);
const origen = z.enum(['api', 'auth', 'sync', 'job', 'frontend', 'backoffice']);
const clave = z.string().regex(/^[a-z][a-z0-9_.]{0,63}$/);
const fields = {
  page: positive(1000000).optional(),
  limit: positive(50).pipe(z.int().min(25)).optional(),
  search: z
    .string()
    .trim()
    .max(120)
    .transform((s) => s || undefined)
    .optional(),
  tipo: z.enum(['organizacion', 'familia']).optional(),
  estado: z.enum(['activa', 'deshabilitada']).optional(),
  plan: positive(32767).optional(),
  filtro: filtro.optional(),
  cuenta: id.optional(),
  usuario: usuario.optional(),
  nivel: z.enum(['info', 'warn', 'error', 'critical']).optional(),
  origen: origen.optional(),
  http: positive(599).pipe(z.int().min(100)).optional(),
  vista: z.literal('sync').optional(),
  entidad: clave.optional(),
  entidad_id: z
    .string()
    .regex(/^[a-zA-Z0-9_-]{1,80}$/)
    .optional(),
  accion: clave.optional(),
  desde: fecha.optional(),
  hasta: fecha.optional(),
  corte: z.iso.datetime().optional(),
};
export const query = z
  .strictObject(fields)
  .refine((f) => !f.desde || !f.hasta || f.desde <= f.hasta)
  .transform((f) => ({
    ...f,
    desde: f.desde ? new Date(diaRD(f.desde)).toISOString() : undefined,
    hasta: f.hasta ? new Date(diaRD(f.hasta) + 86400000).toISOString() : undefined,
  }));
export const edit = (fields) => z.strictObject({ ...fields, motivo });
export const frontendEvent = z.strictObject({
  evento: z.enum(['javascript.error', 'javascript.rejection', 'api.error', 'api.network']),
  requestId: z.uuid().optional(),
});
