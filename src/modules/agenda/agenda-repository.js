/* Persistencia de la agenda de cuidado: RPC de cuidared_api con el JWT del usuario · RF-16. © 2026 Equipo CuidaRed – INTEC. */

/*
 * Un repositorio por petición sobre `res.locals.access.repository`. Cada RPC autoriza de nuevo en la base con
 * cuidared_interno.exigir (cuenta, rol, permiso, alcance sobre el adulto, acceso operativo): esta capa solo traduce
 * parámetros (DTO snake_case → p_*) y no decide permisos. Contrato SQL: docs/propuestas/fase-4b-agenda.sql.
 */
export function createAgendaRepository(access) {
  const rpc = (name, params) => access.rpc(name, params);
  return {
    listTareas: (cuentaId, { filters, sort, limit, offset }) =>
      rpc('api_tareas_listar', {
        p_cuenta_id: cuentaId,
        p_filtros: { ...filters },
        p_orden: sort.map(({ field, direction }) => ({ campo: field, direccion: direction })),
        p_limit: limit,
        p_offset: offset,
      }),
    getTarea: (cuentaId, tareaId) =>
      rpc('api_tarea_obtener', { p_cuenta_id: cuentaId, p_tarea_id: tareaId }),
    createTareas: (cuentaId, datos) =>
      rpc('api_tarea_crear', { p_cuenta_id: cuentaId, p_datos: datos }),
    updateTarea: (cuentaId, tareaId, datos) =>
      rpc('api_tarea_actualizar', { p_cuenta_id: cuentaId, p_tarea_id: tareaId, p_datos: datos }),
    cancelTarea: (cuentaId, tareaId, { motivo, alcance }) =>
      rpc('api_tarea_cancelar', {
        p_cuenta_id: cuentaId,
        p_tarea_id: tareaId,
        p_motivo: motivo,
        p_alcance: alcance,
      }),
    startTarea: (cuentaId, tareaId) =>
      rpc('api_tarea_iniciar', { p_cuenta_id: cuentaId, p_tarea_id: tareaId }),
    completeTarea: (cuentaId, tareaId) =>
      rpc('api_tarea_completar', { p_cuenta_id: cuentaId, p_tarea_id: tareaId }),
    prepareUpload: (cuentaId, tareaId, datos) =>
      rpc('api_evidencia_preparar_subida', {
        p_cuenta_id: cuentaId,
        p_tarea_id: tareaId,
        p_datos: datos,
      }),
    registerEvidence: (cuentaId, tareaId, datos) =>
      rpc('api_evidencia_registrar', {
        p_cuenta_id: cuentaId,
        p_tarea_id: tareaId,
        p_datos: datos,
      }),
    listEvidences: (cuentaId, tareaId) =>
      rpc('api_evidencias_listar', { p_cuenta_id: cuentaId, p_tarea_id: tareaId }),
    validateEvidence: (cuentaId, evidenciaId) =>
      rpc('api_evidencia_validar', { p_cuenta_id: cuentaId, p_evidencia_id: evidenciaId }),
    rejectEvidence: (cuentaId, evidenciaId, motivo) =>
      rpc('api_evidencia_rechazar', {
        p_cuenta_id: cuentaId,
        p_evidencia_id: evidenciaId,
        p_motivo: motivo,
      }),
  };
}
