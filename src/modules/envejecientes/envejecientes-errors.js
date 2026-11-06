/* Errores de negocio de perfiles de adultos mayores y contactos · ID03/RF-01/RF-17. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

/*
 * Códigos CR_* que señalan las RPC de la fase 3a (`raise exception 'CR_…' using errcode = 'P0001'`). Solo estos textos
 * llegan al cliente; ninguno revela la cuenta ni los datos de otro adulto.
 *
 * Los códigos transversales CR_LIMITE_PLAN (409 PLAN_LIMIT_REACHED) y CR_ESTADO_INVALIDO (409 INVALID_STATE) ya los
 * registra `src/lib/business-errors.js`; esta fase los reutiliza sin redefinirlos.
 */
export const ENVEJECIENTES_ERRORES = {
  // Cédula ya registrada en cualquier cuenta de la plataforma: mensaje genérico, sin indicar cuál.
  CR_CEDULA_DUPLICADA: {
    status: 409,
    publicCode: 'CEDULA_DUPLICATE',
    message: 'Ya existe un perfil registrado con esa cédula.',
  },
  // Ley 172-13: sin consentimiento informado (o sin el nombre del representante) no se guarda el perfil.
  CR_CONSENTIMIENTO_REQUERIDO: {
    status: 422,
    publicCode: 'CONSENT_REQUIRED',
    message: 'Registra el consentimiento informado para guardar el perfil.',
  },
  // De 1 a 5 contactos y exactamente un principal; tampoco se elimina al principal sin designar otro.
  CR_CONTACTO_PRINCIPAL: {
    status: 422,
    publicCode: 'CONTACT_PRINCIPAL_INVALID',
    message:
      'Los contactos de emergencia deben ser de 1 a 5, con exactamente un contacto principal. Para eliminar al principal, designa antes a otro.',
  },
  CR_ULTIMO_CONTACTO: {
    status: 409,
    publicCode: 'LAST_CONTACT',
    message: 'El perfil debe conservar al menos un contacto de emergencia.',
  },
  CR_LIMITE_CONTACTOS: {
    status: 409,
    publicCode: 'CONTACT_LIMIT_REACHED',
    message: 'El perfil ya tiene el máximo de 5 contactos de emergencia.',
  },
};

/** Todos los CR_* que esta fase puede recibir de la base, incluidos los transversales. */
export const ENVEJECIENTES_CODIGOS = [
  ...Object.keys(ENVEJECIENTES_ERRORES),
  'CR_LIMITE_PLAN',
  'CR_ESTADO_INVALIDO',
  'CR_CUENTA_SIN_ACCESO',
];

registerBusinessErrors(ENVEJECIENTES_ERRORES);
