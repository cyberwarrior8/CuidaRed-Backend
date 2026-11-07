/* Errores de negocio de la agenda de cuidado y las evidencias · RF-16, RS-013, D12/D13. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

/*
 * Códigos que las RPC de docs/propuestas/fase-4b-agenda.sql señalan con `raise exception 'CR_…' using errcode =
 * 'P0001'`. Lista cerrada: el texto del proveedor nunca llega al cliente. CR_ESTADO_INVALIDO y CR_CUENTA_SIN_ACCESO
 * son transversales (src/lib/business-errors.js) y también los usa este módulo.
 */
export const AGENDA_BUSINESS_ERRORS = {
  CR_CUIDADOR_NO_ASIGNADO: {
    status: 422,
    publicCode: 'CAREGIVER_NOT_ASSIGNED',
    message: 'Solo puedes asignar cuidadores vinculados a este adulto mayor en esta cuenta.',
  },
  CR_REPETICION_INVALIDA: {
    status: 422,
    publicCode: 'INVALID_REPETITION',
    message:
      'La repetición no es válida. Revisa la frecuencia, los días y la fecha de fin (máximo 60 tareas).',
  },
  CR_INDICACION_NO_CORRESPONDE: {
    status: 422,
    publicCode: 'INDICATION_MISMATCH',
    message: 'La indicación no corresponde a este adulto mayor.',
  },
  // D12 (resuelta): una tarea que requiere evidencia solo se completa con evidencia validada.
  CR_EVIDENCIA_REQUERIDA: {
    status: 409,
    publicCode: 'EVIDENCE_REQUIRED',
    message: 'Esta tarea requiere al menos una evidencia validada para poder completarse.',
  },
  // RS-013: JPG, PNG, WEBP o PDF de hasta 5 MB.
  CR_ARCHIVO_INVALIDO: {
    status: 422,
    publicCode: 'INVALID_FILE',
    message: 'El archivo no es válido. Usa una foto JPG, PNG o WEBP, o un PDF, de hasta 5 MB.',
  },
  CR_ARCHIVO_NO_SUBIDO: {
    status: 409,
    publicCode: 'FILE_NOT_UPLOADED',
    message: 'El archivo todavía no se ha subido. Súbelo e inténtalo de nuevo.',
  },
  // Propuesta técnica (D13): máximo 5 evidencias no rechazadas por tarea.
  CR_LIMITE_EVIDENCIAS: {
    status: 409,
    publicCode: 'EVIDENCE_LIMIT_REACHED',
    message: 'La tarea alcanzó el máximo de 5 evidencias.',
  },
};

registerBusinessErrors(AGENDA_BUSINESS_ERRORS);
