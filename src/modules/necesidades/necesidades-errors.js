/* Errores de negocio de necesidades · ID05/RF-03. © 2026 Equipo CuidaRed – INTEC. */
import { registerBusinessErrors } from '../../lib/business-errors.js';

registerBusinessErrors({
  CR_RESPONSABLE_NECESIDAD_INVALIDO: {
    status: 422,
    publicCode: 'INVALID_NEED_ASSIGNEE',
    message: 'La persona elegida no puede atender necesidades de este adulto.',
  },
});
