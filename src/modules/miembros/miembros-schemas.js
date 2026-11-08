/* Contratos de entrada y salida de miembros, titularidad y cuidadores · ID02/RF-11/RF-12. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { isBigintId, jsonBigintId } from '../../lib/bigint-id.js';
import { createCollectionQuery } from '../../lib/collection-query.js';
import { AppError, unavailable } from '../../lib/errors.js';
import { ROLES } from '../cuentas/permisos.js';

export const ESTADOS_MEMBRESIA = ['pendiente', 'activa', 'inactiva'];

const nombre = z.string().trim().min(1).max(100);

export const invitarSchema = z.strictObject({
  correo: z.string().trim().toLowerCase().pipe(z.email().max(254)),
  cedula: z.string().regex(/^\d{11}$/),
  nombres: nombre,
  apellidos: nombre,
  rol: z.enum(ROLES),
});
export const cambiarRolSchema = z.strictObject({ rol: z.enum(ROLES) });
export const titularidadSchema = z.strictObject({ membresia_id: jsonBigintId });
export const cuidadorSchema = z.strictObject({
  tipo_cuidado_id: z.int().min(1).max(32767),
  cuidador_independiente: z.boolean(),
});

// Listado: una fila por persona; orden y filtros de lista cerrada (CR-162).
export const listarMiembrosQuery = createCollectionQuery({
  sortableFields: ['nombres', 'apellidos', 'fecha_inicio', 'rol', 'estado', 'membresia_id'],
  defaultSort: 'nombres,apellidos,fecha_inicio',
  tieBreaker: 'membresia_id',
  filterSchemas: { rol: z.enum(ROLES), estado: z.enum(ESTADOS_MEMBRESIA) },
});

export const invalidInput = () =>
  new AppError(422, 'INVALID_INPUT', 'Revisa los datos del formulario.');

export function parse(schema, body) {
  const result = schema.safeParse(body);
  if (!result.success) throw invalidInput();
  return result.data;
}

/** Las acciones sin datos no aceptan cuerpo: así no se cuela cuenta_id, usuario_id, rol ni estado. */
export function requireEmptyBody(body) {
  if (body === undefined) return;
  parse(z.strictObject({}), body);
}

/** Id de ruta (membresía): texto decimal bigint. */
export function readRouteId(value) {
  if (!isBigintId(value)) {
    throw new AppError(404, 'NOT_FOUND', 'Recurso no encontrado.');
  }
  return value;
}

/* ───── DTO de salida: lista cerrada de campos (no se reenvía nada que la RPC añada de más) ───── */

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
// Como en el resto de la API (cuentas), los identificadores bigint viajan como texto: "21".
const idTexto = (value) => {
  const id = jsonBigintId.safeParse(value);
  if (!id.success) throw unavailable();
  return id.data;
};

export function readCuidador(row) {
  if (row === null || row === undefined) return null;
  if (!isObject(row) || row.cuidador_id == null || row.tipo_cuidado_id == null) throw unavailable();
  return {
    cuidador_id: idTexto(row.cuidador_id),
    tipo_cuidado_id: row.tipo_cuidado_id,
    tipo_cuidado: row.tipo_cuidado ?? null,
    cuidador_independiente: row.cuidador_independiente === true,
    usuario_empleador_id: row.usuario_empleador_id ?? null,
    fecha_inicio: row.fecha_inicio ?? null,
  };
}

export function readMiembro(row) {
  if (
    !isObject(row) ||
    row.membresia_id == null ||
    typeof row.rol !== 'string' ||
    !ESTADOS_MEMBRESIA.includes(row.estado) ||
    !isObject(row.usuario)
  ) {
    throw unavailable();
  }
  return {
    membresia_id: idTexto(row.membresia_id),
    rol: row.rol,
    estado: row.estado,
    fecha_inicio: row.fecha_inicio ?? null,
    fecha_fin: row.fecha_fin ?? null,
    es_titular: row.es_titular === true,
    usuario: {
      id: row.usuario.id,
      nombres: row.usuario.nombres,
      apellidos: row.usuario.apellidos,
      correo: row.usuario.correo,
      telefono: row.usuario.telefono ?? null,
    },
    cuidador: readCuidador(row.cuidador),
  };
}

export function readMembresiaAceptada(row) {
  if (
    !isObject(row) ||
    row.membresia_id == null ||
    row.cuenta_id == null ||
    row.estado !== 'activa'
  )
    throw unavailable();
  return {
    membresia_id: idTexto(row.membresia_id),
    cuenta_id: idTexto(row.cuenta_id),
    rol: row.rol,
    estado: row.estado,
  };
}

export function readTitularidad(row) {
  if (!isObject(row) || row.cuenta_id == null || typeof row.usuario_titular_id !== 'string')
    throw unavailable();
  return {
    cuenta_id: idTexto(row.cuenta_id),
    usuario_titular_id: row.usuario_titular_id,
    membresia_id: idTexto(row.membresia_id),
  };
}

export function readListado(row) {
  if (!isObject(row) || !Array.isArray(row.items) || !Number.isSafeInteger(Number(row.total))) {
    throw unavailable();
  }
  return { items: row.items.map(readMiembro), total: Number(row.total) };
}
