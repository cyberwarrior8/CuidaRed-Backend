/* Errores de negocio del seguimiento del adulto mayor · ID03/RF-12/RF-13/RF-14/RF-15. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

/*
 * Códigos que señalan las RPC de docs/propuestas/fase-3b-seguimiento.sql con
 * `raise exception 'CR_…' using errcode = 'P0001'`. Además de estos, el módulo reutiliza los transversales de fase 2:
 * CR_ESTADO_INVALIDO (409), CR_ROL_NO_PERMITIDO (422, voluntario en Familia) y CR_CUENTA_SIN_ACCESO (403).
 */
export const ERRORES_SEGUIMIENTO = {
  CR_ROL_NO_COMPATIBLE: {
    status: 422,
    publicCode: 'ROLE_NOT_COMPATIBLE',
    message: 'La persona no tiene en esta cuenta el rol necesario para esta operación.',
  },
  CR_EVALUACION_INCOMPLETA: {
    status: 422,
    publicCode: 'EVALUATION_INCOMPLETE',
    message: 'Responde todas las preguntas de la evaluación de riesgo.',
  },
  CR_ADULTO_INACTIVO: {
    status: 409,
    publicCode: 'ADULT_INACTIVE',
    message: 'El adulto mayor no está activo: no se pueden registrar cambios nuevos.',
  },
};

registerBusinessErrors(ERRORES_SEGUIMIENTO);
