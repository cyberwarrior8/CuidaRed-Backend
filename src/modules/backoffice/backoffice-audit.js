/* Eventos de sesión PWA que complementan la bitácora SQL de Supabase Auth. */
export function auditAccess(adminGateway, audit) {
  return async ({ actorId, action, req }) => {
    if (typeof adminGateway?.backofficeRpc !== 'function') return;
    try {
      await adminGateway.backofficeRpc('auditar', {
        p_actor: actorId,
        p_rol: 'pwa',
        p_accion: action,
        p_ip: req.ip || null,
        p_agente: req.get('user-agent') || null,
        p_motivo: null,
      });
    } catch {
      audit({
        actorId,
        action: 'audit.persistence',
        result: 'error',
        code: 'AUDIT_STORAGE_UNAVAILABLE',
      });
    }
  };
}
