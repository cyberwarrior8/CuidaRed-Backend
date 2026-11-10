/* Códigos de negocio CR_* de visitas y solicitudes de visita · ID04/RF-02. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

/*
 * Las RPC de fase 4a señalan estas reglas con `raise exception 'CR_<CODIGO>' using errcode = 'P0001'`.
 * Los códigos transversales (CR_ESTADO_INVALIDO, CR_CONFLICTO, CR_CUENTA_SIN_ACCESO) ya están registrados en
 * src/lib/business-errors.js y también los usan las RPC de visitas.
 */
export const VISITAS_ERRORES = {
  CR_VISITA_CERRADA: {
    status: 409,
    publicCode: 'VISIT_CLOSED',
    message: 'La visita ya está cerrada: fue completada o cancelada.',
  },
  CR_PARTICIPANTE_INVALIDO: {
    status: 422,
    publicCode: 'INVALID_PARTICIPANT',
    message: 'Uno de los participantes no es un miembro activo que pueda participar en visitas.',
  },
  CR_PARTICIPANTE_OCUPADO: {
    status: 409,
    publicCode: 'PARTICIPANT_BUSY',
    message: 'Uno de los participantes ya tiene una visita a esa hora.',
  },
  CR_NO_PARTICIPA: {
    status: 403,
    publicCode: 'NOT_PARTICIPANT',
    message: 'Solo quienes participan en la visita, o quienes la gestionan, pueden operarla.',
  },
  CR_SOLICITUD_REVISADA: {
    status: 409,
    publicCode: 'REQUEST_ALREADY_REVIEWED',
    message: 'La solicitud ya fue revisada.',
  },
  CR_SOLICITUD_NO_DISPONIBLE: {
    status: 409,
    publicCode: 'REQUEST_UNAVAILABLE',
    message: 'La solicitud no admite esa operación en este momento.',
  },
};

registerBusinessErrors(VISITAS_ERRORES);
