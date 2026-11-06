/* Persistencia de cuentas mediante RPC de cuidared_api · ID02/RF-11/RF-19/RF-20. © 2026 Equipo CuidaRed – INTEC. */

/*
 * Cada método llama una RPC con el JWT del usuario (`res.locals.access.repository.rpc`). La identidad nunca viaja en
 * los parámetros: la RPC la toma de auth.uid() y vuelve a autorizar. Las RPC están en
 * docs/propuestas/fase-2b-cuentas.sql (api_mis_cuentas, en fase-2a-base.sql).
 */
export function createCuentasRepository(rpc) {
  return {
    misCuentas: () => rpc('api_mis_cuentas'),
    registrar: (datos) => rpc('api_registrar_cuenta', { p_datos: datos }),
    obtener: (cuentaId) => rpc('api_obtener_cuenta', { p_cuenta_id: cuentaId }),
    actualizar: (cuentaId, datos) =>
      rpc('api_actualizar_cuenta', { p_cuenta_id: cuentaId, p_datos: datos }),
    configuracion: (cuentaId) => rpc('api_obtener_configuracion', { p_cuenta_id: cuentaId }),
    actualizarConfiguracion: (cuentaId, valores) =>
      rpc('api_actualizar_configuracion', { p_cuenta_id: cuentaId, p_valores: valores }),
    suscripcion: (cuentaId) => rpc('api_obtener_suscripcion', { p_cuenta_id: cuentaId }),
  };
}
