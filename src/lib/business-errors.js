/* Errores de negocio de las RPC y su traducción pública · CR-162. © 2026 Equipo CuidaRed – INTEC. */
import { AppError } from './errors.js';

/*
 * Las RPC señalan reglas de negocio incumplidas con `raise exception 'CR_<CODIGO>' using errcode = 'P0001'`.
 * Solo se traducen los códigos registrados aquí (lista cerrada): el texto del proveedor nunca llega al cliente.
 * Cada módulo registra los suyos al importarse con `registerBusinessErrors`.
 */
const registry = new Map();
const codePattern = /^CR_[A-Z][A-Z0-9_]{1,62}$/;

export function registerBusinessErrors(map) {
  for (const [code, definition] of Object.entries(map)) {
    if (!codePattern.test(code)) throw new Error(`Código de negocio inválido: ${code}`);
    const { status, publicCode, message } = definition;
    if (![403, 404, 409, 422].includes(status) || !/^[A-Z][A-Z0-9_]{0,63}$/.test(publicCode)) {
      throw new Error(`Definición inválida para ${code}`);
    }
    registry.set(code, { status, publicCode, message });
  }
}

/** Traduce el mensaje de una RPC (P0001) a un AppError, o undefined si no es un código registrado. */
export function businessError(rawMessage) {
  if (typeof rawMessage !== 'string') return undefined;
  const code = rawMessage.trim();
  const definition = codePattern.test(code) ? registry.get(code) : undefined;
  return definition
    ? new AppError(definition.status, definition.publicCode, definition.message)
    : undefined;
}

// Códigos transversales de cuenta y plan (fase 2). Los módulos agregan los propios.
registerBusinessErrors({
  CR_CUENTA_SIN_ACCESO: {
    status: 403,
    publicCode: 'SUBSCRIPTION_INACTIVE',
    message:
      'La cuenta no tiene una prueba o un plan vigente. Solo puedes gestionar la cuenta y su suscripción.',
  },
  CR_LIMITE_PLAN: {
    status: 409,
    publicCode: 'PLAN_LIMIT_REACHED',
    message: 'Se alcanzó el límite del plan de la cuenta.',
  },
  CR_ROL_NO_PERMITIDO: {
    status: 422,
    publicCode: 'ROLE_NOT_ALLOWED',
    message: 'Ese rol no está disponible para este tipo de cuenta.',
  },
  CR_ESTADO_INVALIDO: {
    status: 409,
    publicCode: 'INVALID_STATE',
    message: 'La operación no es posible en el estado actual del registro.',
  },
  CR_CONFLICTO: {
    status: 409,
    publicCode: 'CONFLICT',
    message: 'No se pudo guardar porque entra en conflicto con otro registro.',
  },
});
