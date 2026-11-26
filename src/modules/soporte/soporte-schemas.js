/* Entradas y errores públicos del seguimiento de soporte. © 2026 Equipo CuidaRed – INTEC. */
import { z } from 'zod';
import { registerBusinessErrors } from '../../lib/business-errors.js';
import { id, parse } from '../backoffice/backoffice-schemas.js';
export { parse };

registerBusinessErrors({
  CR_SOPORTE_LIMITE: {
    status: 409,
    publicCode: 'SUPPORT_RATE_LIMIT',
    message: 'Ya enviaste varias solicitudes. Espera unos minutos antes de crear otra.',
  },
  CR_SOPORTE_DUPLICADO: {
    status: 409,
    publicCode: 'SUPPORT_DUPLICATE',
    message:
      'Ya hay una solicitud abierta para eliminar a este usuario. Continúa en esa solicitud.',
  },
  CR_SOPORTE_VERSION: {
    status: 409,
    publicCode: 'SUPPORT_STALE',
    message: 'La solicitud recibió cambios. Actualiza el detalle antes de responder.',
  },
  CR_SOPORTE_CERRADO: {
    status: 409,
    publicCode: 'SUPPORT_CLOSED',
    message: 'Esta solicitud está cerrada. Puedes crear otra si necesitas ayuda.',
  },
  CR_BO_ELIMINACION_BLOQUEADA: {
    status: 409,
    publicCode: 'USER_DELETE_BLOCKED',
    message:
      'El usuario conserva accesos o registros que impiden su eliminación. Actualiza la revisión para ver el motivo.',
  },
  CR_BO_ELIMINACION_OCUPADA: {
    status: 409,
    publicCode: 'USER_DELETE_BUSY',
    message: 'Hay una eliminación en curso. Actualiza la lista antes de intentarlo de nuevo.',
  },
});

export const estado = z.enum([
  'abierta',
  'en_revision',
  'esperando_informacion',
  'resuelta',
  'rechazada',
]);
const texto = (min, max) =>
  z
    .string()
    .trim()
    .min(min)
    .max(max)
    .refine((v) => !/\p{Cc}/u.test(v.replaceAll('\n', '')));
export const mensaje = texto(5, 2000);
export const lista = z.strictObject({
  estado: estado.optional(),
  search: texto(0, 120).optional(),
  page: z.coerce.number().int().min(1).max(1000000).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(25),
});
export const crear = z
  .strictObject({
    tipo: z.enum(['eliminar_usuario', 'acceso', 'error', 'consulta']),
    asunto: texto(5, 120),
    descripcion: texto(10, 2000),
    usuario_objetivo_id: z.uuid().nullable().default(null),
  })
  .refine((v) => v.tipo !== 'eliminar_usuario' || v.usuario_objetivo_id !== null);
export const responder = z.strictObject({ mensaje, version: z.iso.datetime({ offset: true }) });
export const actualizar = responder.extend({ estado });
export const eliminar = z.strictObject({
  confirmacion: z.email().max(254),
  motivo: texto(5, 400),
  solicitud_id: id.nullable().default(null),
});
