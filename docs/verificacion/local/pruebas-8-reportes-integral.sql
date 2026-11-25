-- Fases 7 y 8 · Reportes avanzados y Excel en Cuidado Integral (RF-07, RF-08, RF-20).
-- © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_coord uuid := pruebas.usuario('integral-reportes-coord@example.test', '00885200001');
  v_familiar uuid := pruebas.usuario('integral-reportes-familiar@example.test', '00885200002');
  v_basico uuid := pruebas.usuario('basico-reportes-coord@example.test', '00885200003');
  v_prueba uuid := pruebas.usuario('prueba-reportes-coord@example.test', '00885200004');
  v_integral_id bigint := pruebas.cuenta('familia', v_coord, 'activa', 'Cuidado Integral');
  v_basico_id bigint := pruebas.cuenta('familia', v_basico, 'activa', 'Básico Familiar');
  v_prueba_id bigint := pruebas.cuenta('familia', v_prueba);
  v_datos jsonb;
begin
  perform pruebas.envejeciente(v_integral_id);
  perform pruebas.miembro(v_integral_id, v_familiar, 'familiar');
  perform pruebas.como(v_coord);
  v_datos := cuidared_api.api_contexto_cuenta(v_integral_id);
  perform pruebas.afirmar(
    (v_datos->'funcionalidades') @> '["dashboard_metricas","reportes_avanzados"]'
    and not ((v_datos->'permisos') ? 'visitas:ver'),
    'Cuidado Integral incluye los reportes avanzados y conserva los permisos de Familia');
  perform pruebas.afirmar(cuidared_api.api_stripe_catalogo_cuenta(v_integral_id)
    @> '[{"codigo":"cuidado_integral","funcionalidades":["reportes_avanzados"]}]',
    'el catálogo comercial refleja el beneficio');
  perform pruebas.afirmar(exists (select from cuidared_interno.stripe_catalogo_modelo()
    where codigo = 'cuidado_integral' and 'reportes_avanzados' = any (funcionalidades)),
    'el modelo para instalaciones nuevas incluye el beneficio');

  v_datos := cuidared_api.api_reporte_avanzado(v_integral_id, '{}');
  perform pruebas.afirmar(v_datos->>'tipo' = 'analisis_avanzado'
    and jsonb_array_length(v_datos->'tendencias') > 0
    and (v_datos->'tendencias'->0->'visitas_realizadas') = 'null'::jsonb,
    'Familia obtiene comparativos y tendencias sin métricas de Visitas');
  perform pruebas.afirmar((cuidared_api.api_registrar_exportacion_reporte(v_integral_id,
    '{"tipo":"adultos","formato":"xlsx"}')->>'formato') = 'xlsx', 'Excel de adultos disponible');
  perform pruebas.afirmar((cuidared_api.api_registrar_exportacion_reporte(v_integral_id,
    '{"tipo":"analisis_avanzado","formato":"xlsx"}')->>'formato') = 'xlsx', 'Excel del análisis disponible');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_integral_id, 'visitas', '{}'), '42501');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_integral_id,
    '{"tipo":"visitas","formato":"xlsx"}'), '42501');

  perform pruebas.como(v_familiar);
  perform pruebas.error(format('select cuidared_api.api_reporte_avanzado(%s, %L)', v_integral_id, '{}'), '42501');
  perform pruebas.como(v_basico);
  perform pruebas.error(format('select cuidared_api.api_reporte_avanzado(%s, %L)', v_basico_id, '{}'), '42501');
  perform pruebas.como(v_prueba);
  perform pruebas.error(format('select cuidared_api.api_reporte_avanzado(%s, %L)', v_prueba_id, '{}'), '42501');
end $$;

rollback;
