/* Errores públicos de API · infraestructura. © 2026 Equipo CuidaRed – INTEC. */
export class AppError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function unavailable() {
  return new AppError(
    503,
    'DEPENDENCY_UNAVAILABLE',
    'El servicio no está disponible. Intenta de nuevo.',
  );
}
