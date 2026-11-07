/* Flujo de invitación de miembros · ID02/RF-11. © 2026 Equipo CuidaRed – INTEC. */
import { AppError } from '../../lib/errors.js';

/**
 * Invita a una persona a la cuenta (D07/D14 en docs/contratos/miembros.md):
 *  1. `prepararInvitacion` (RPC con el JWT de quien invita): autoriza, valida rol del tipo de cuenta, límites del
 *     plan y, si la persona ya existe, cédula y membresía vigente. No escribe.
 *  2. Si la persona NO existe, el gateway administrativo crea su identidad Auth (el trigger crea el perfil) y le envía
 *     la invitación por correo. Es la única operación con la clave secreta: no toca tablas de negocio.
 *  3. `agregarMiembro` (RPC con el JWT de quien invita) vuelve a comprobar todo bajo el bloqueo de la cuenta y crea
 *     la membresía pendiente. Si falla tras crear la identidad (p. ej. otra invitación ocupó el último cupo), la
 *     identidad queda sin membresía y reintentar la invitación continúa desde el paso 3 sin volver a invitar.
 * El gateway administrativo nunca se usa si el paso 1 rechaza: sin cupo o sin permiso no se crea ninguna identidad.
 */
export async function invitarMiembro({ repository, adminGateway }, cuentaId, input) {
  const { correo, cedula, nombres, apellidos, rol } = input;
  const usuarioExiste = await repository.prepararInvitacion(cuentaId, { correo, cedula, rol });
  if (!usuarioExiste) {
    if (!adminGateway) {
      throw new AppError(
        503,
        'INVITATIONS_UNAVAILABLE',
        'Por ahora no se pueden invitar personas nuevas. Intenta de nuevo más tarde.',
      );
    }
    await adminGateway.inviteUser({ email: correo, cedula, nombres, apellidos });
  }
  const miembro = await repository.agregarMiembro(cuentaId, { correo, cedula, rol });
  return { miembro, usuarioExistente: usuarioExiste };
}
