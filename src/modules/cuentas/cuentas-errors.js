/* Errores de negocio de alta, configuración y suscripción de cuentas · ID02/RF-11/RF-19/RF-20. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

/*
 * Códigos que las RPC de docs/propuestas/fase-2b-cuentas.sql señalan con `raise exception 'CR_<CODIGO>'`.
 * Los de uso transversal (CR_CUENTA_SIN_ACCESO, CR_LIMITE_PLAN, CR_ROL_NO_PERMITIDO, CR_ESTADO_INVALIDO y
 * CR_CONFLICTO) ya están registrados en src/lib/business-errors.js.
 */
registerBusinessErrors({
  CR_CATEGORIA_INVALIDA: {
    status: 422,
    publicCode: 'INVALID_CATEGORY',
    message: 'La categoría elegida no corresponde al tipo de cuenta.',
  },
  CR_PRUEBA_EN_CURSO: {
    status: 409,
    publicCode: 'TRIAL_IN_PROGRESS',
    message: 'Ya tienes una cuenta con prueba gratuita vigente. Podrás abrir otra cuando termine.',
  },
  CR_PARAMETRO_INVALIDO: {
    status: 422,
    publicCode: 'INVALID_PARAMETER',
    message: 'El parámetro no existe o su valor no es válido.',
  },
});
