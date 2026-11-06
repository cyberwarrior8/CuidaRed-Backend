/* Códigos de negocio de miembros, titularidad y cuidadores · ID02/RF-11/RF-12. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

/*
 * Las RPC de docs/propuestas/fase-2c-miembros.sql señalan estas reglas con `raise exception 'CR_<CODIGO>' using
 * errcode = 'P0001'`. Los mensajes son genéricos: no revelan datos de otra persona ni de otra cuenta.
 * CR_LIMITE_PLAN, CR_ROL_NO_PERMITIDO, CR_ESTADO_INVALIDO y CR_CONFLICTO ya los registra lib/business-errors.js.
 */
registerBusinessErrors({
  CR_IDENTIDAD_NO_COINCIDE: {
    status: 409,
    publicCode: 'IDENTITY_MISMATCH',
    message: 'No se pudo invitar a esa persona con esos datos.',
  },
  CR_YA_ES_MIEMBRO: {
    status: 409,
    publicCode: 'ALREADY_MEMBER',
    message: 'Esa persona ya tiene una membresía vigente en la cuenta.',
  },
  CR_MEMBRESIA_PROPIA: {
    status: 409,
    publicCode: 'OWN_MEMBERSHIP',
    message: 'No puedes cambiar ni desactivar tu propia membresía.',
  },
  CR_TITULAR_PROTEGIDO: {
    status: 409,
    publicCode: 'OWNER_PROTECTED',
    message:
      'La persona titular de la cuenta conserva un rol gestor y no puede desactivarse. Transfiere antes la titularidad.',
  },
  CR_ULTIMO_GESTOR: {
    status: 409,
    publicCode: 'LAST_MANAGER',
    message: 'La cuenta debe conservar al menos una persona gestora activa.',
  },
  CR_NO_ES_CUIDADOR: {
    status: 409,
    publicCode: 'NOT_A_CAREGIVER',
    message: 'Solo los miembros con rol Cuidador tienen perfil de cuidador.',
  },
  CR_DESTINO_NO_GESTOR: {
    status: 422,
    publicCode: 'NEW_OWNER_NOT_MANAGER',
    message: 'La nueva persona titular debe ser un miembro activo con rol gestor de la cuenta.',
  },
});

// 23505 (índice único de membresía vigente) cuando dos operaciones coinciden pese al bloqueo por cuenta.
export const ALREADY_MEMBER_CONFLICT = {
  code: 'ALREADY_MEMBER',
  message: 'Esa persona ya tiene una membresía vigente en la cuenta.',
};
