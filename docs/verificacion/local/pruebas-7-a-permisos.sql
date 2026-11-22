-- Fase 7 · permisos por rol y tipo de cuenta, plan, cuenta vencida, aislamiento y privilegios (ID07; RF-07, RF-08).
-- Ejecutar solo en la base desechable de `--solo=reportes`, después de pruebas-00-ayudas.sql. © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('r7a-admin@example.test', '00700000001');
  v_coord uuid := pruebas.usuario('r7a-coord@example.test', '00700000002');
  v_cuidador uuid := pruebas.usuario('r7a-cuidador@example.test', '00700000003');
  v_familiar uuid := pruebas.usuario('r7a-familiar@example.test', '00700000004');
  v_voluntario uuid := pruebas.usuario('r7a-voluntario@example.test', '00700000005');
  v_fam_coord uuid := pruebas.usuario('r7a-fam-coord@example.test', '00700000006');
  v_fam_cuidador uuid := pruebas.usuario('r7a-fam-cuidador@example.test', '00700000007');
  v_integral uuid := pruebas.usuario('r7a-integral@example.test', '00700000008');
  v_base uuid := pruebas.usuario('r7a-base@example.test', '00700000009');
  v_avanzada uuid := pruebas.usuario('r7a-avanzada@example.test', '00700000010');
  v_vencida_admin uuid := pruebas.usuario('r7a-vencida@example.test', '00700000011');
  v_org bigint := pruebas.cuenta('organizacion', v_admin);
  v_fam bigint := pruebas.cuenta('familia', v_fam_coord);
  v_fam_integral bigint := pruebas.cuenta('familia', v_integral, 'activa', 'Cuidado Integral');
  v_org_base bigint := pruebas.cuenta('organizacion', v_base, 'activa', 'Operación Base');
  v_org_avanzada bigint := pruebas.cuenta('organizacion', v_avanzada, 'activa', 'Gestión Comunitaria Avanzada');
  v_vencida bigint := pruebas.cuenta('organizacion', v_vencida_admin, 'prueba', null, cuidared_interno.hoy() - 1);
  v_adulto uuid := pruebas.envejeciente(v_org, 'Ana', 'Permisos');
  v_adulto_fam uuid := pruebas.envejeciente(v_fam, 'Berta', 'Familia');
  v_adulto_vencida uuid := pruebas.envejeciente(v_vencida, 'Carla', 'Vencida');
  v_vacio jsonb := '{}'::jsonb;
  v_orden text[] := array['prioridad'];
  v_tipo text;
  v_r jsonb;
  v_adulto_tardio uuid;
  v_adulto_inactivo uuid;
begin
  perform pruebas.miembro(v_org, v_coord, 'coordinador');
  perform pruebas.miembro(v_org, v_cuidador, 'cuidador');
  perform pruebas.miembro(v_org, v_familiar, 'familiar');
  perform pruebas.miembro(v_org, v_voluntario, 'voluntario');
  perform pruebas.miembro(v_fam, v_fam_cuidador, 'cuidador');
  if not exists (select from cuidared.tipo_cuidado) then
    insert into cuidared.tipo_cuidado(nombre) values ('Cuidado en domicilio');
  end if;
  insert into cuidared.cuidador(usuario_id, tipo_cuidado_id, cuidador_independiente)
    values (v_cuidador, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true),
           (v_fam_cuidador, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true);
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id)
    select v_adulto, v_cuidador, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado';
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id)
    select v_adulto_fam, v_fam_cuidador, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado';

  -- Plan de partida: la prueba de Organización tiene dashboard_metricas; la de Familia no; ninguna, reportes_avanzados.
  perform pruebas.como(v_admin);
  perform pruebas.afirmar((cuidared_api.api_contexto_cuenta(v_org)->'funcionalidades') ? 'dashboard_metricas'
    and not ((cuidared_api.api_contexto_cuenta(v_org)->'funcionalidades') ? 'reportes_avanzados'),
    'Organización en prueba: dashboard sí, avanzados no');
  perform pruebas.como(v_fam_coord);
  perform pruebas.afirmar(not ((cuidared_api.api_contexto_cuenta(v_fam)->'funcionalidades') ? 'dashboard_metricas'),
    'Familia en prueba sin dashboard_metricas');
  perform pruebas.como(v_avanzada);
  perform pruebas.afirmar((cuidared_api.api_contexto_cuenta(v_org_avanzada)->>'acceso_operativo')::boolean
    and (cuidared_api.api_contexto_cuenta(v_org_avanzada)->'funcionalidades') ? 'reportes_avanzados',
    'plan avanzado vigente con reportes_avanzados');

  /* Administrador de Organización (prueba): resumen y reportes sí; avanzado, Excel e informe no. */
  perform pruebas.como(v_admin);
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_org, v_vacio, v_orden, 20, 0)->>'total')::int = 1,
    'administrador consulta el resumen');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_indicadores(v_org)->>'casos_activos')::int = 1,
    'administrador consulta los indicadores');
  foreach v_tipo in array array['adultos', 'visitas', 'necesidades', 'casos_prioritarios'] loop
    v_r := cuidared_api.api_reporte(v_org, v_tipo, v_vacio);
    perform pruebas.afirmar(v_r->>'tipo' = v_tipo and v_r ? 'indicadores' and v_r ? 'series' and v_r ? 'detalle',
      'reporte ' || v_tipo || ' con dashboard_metricas');
  end loop;
  perform pruebas.error(format('select cuidared_api.api_reporte_avanzado(%s, %L)', v_org, v_vacio), '42501');
  perform pruebas.afirmar((cuidared_api.api_exportar_reporte_csv(v_org, 'adultos', v_vacio)->'exportacion'->>'formato') = 'csv',
    'CSV permitido con dashboard_metricas');
  perform pruebas.afirmar((cuidared_api.api_registrar_exportacion_reporte(v_org,
    '{"tipo":"visitas","formato":"pdf"}')->>'formato') = 'pdf', 'PDF permitido con dashboard_metricas');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
    '{"tipo":"adultos","formato":"xlsx"}'), '42501');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
    '{"tipo":"analisis_avanzado","formato":"pdf"}'), '42501');
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_org, v_adulto), '42501');

  /* Coordinador de Organización: resumen, reportes e informe. */
  perform pruebas.como(v_coord);
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_org, v_vacio, v_orden, 20, 0)->>'total')::int = 1,
    'coordinador consulta el resumen');
  perform pruebas.afirmar((cuidared_api.api_reporte(v_org, 'adultos', v_vacio)->'indicadores'->>'registrados')::int = 1,
    'coordinador consulta reportes');
  perform pruebas.afirmar((cuidared_api.api_informe_medico(v_org, v_adulto)->'identificacion'->>'envejeciente_id')::uuid = v_adulto,
    'coordinador genera el informe médico');

  /* Cuidador: solo el informe de sus adultos; ni resumen ni reportes. */
  perform pruebas.como(v_cuidador);
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_org, v_vacio, v_orden), '42501');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_indicadores(%s)', v_org), '42501');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', v_vacio), '42501');
  perform pruebas.error(format('select cuidared_api.api_exportar_reporte_csv(%s, %L, %L)', v_org, 'adultos', v_vacio), '42501');
  perform pruebas.afirmar(cuidared_api.api_informe_medico(v_org, v_adulto) ? 'aviso', 'cuidador asignado genera el informe');

  /* Familiar y Voluntario: nada del módulo. */
  foreach v_tipo in array array['familiar', 'voluntario'] loop
    perform pruebas.como(case v_tipo when 'familiar' then v_familiar else v_voluntario end);
    perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_org, v_vacio, v_orden), '42501');
    perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'necesidades', v_vacio), '42501');
    perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
      '{"tipo":"adultos","formato":"pdf"}'), '42501');
    perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_org, v_adulto), '42501');
  end loop;

  /* Familia en prueba: resumen e informe sin requisito de plan; reportes y exportaciones denegados por el plan. */
  perform pruebas.como(v_fam_coord);
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_fam, v_vacio, v_orden, 20, 0)->>'total')::int = 1,
    'Familia en prueba consulta el resumen');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_fam, 'adultos', v_vacio), '42501');
  perform pruebas.error(format('select cuidared_api.api_exportar_reporte_csv(%s, %L, %L)', v_fam, 'adultos', v_vacio), '42501');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_fam,
    '{"tipo":"adultos","formato":"pdf"}'), '42501');
  perform pruebas.afirmar(not exists (select from cuidared.auditoria a where a.tabla = 'exportacion_reporte'
    and a.datos_nuevos->>'cuenta_id' = v_fam::text), 'una exportación denegada no se registra');
  v_r := cuidared_api.api_informe_medico(v_fam, v_adulto_fam);
  perform pruebas.afirmar(v_r->'visitas' = 'null'::jsonb and v_r->'secciones_omitidas' = '["visitas"]'::jsonb,
    'Familia: informe sin visitas (módulo exclusivo de Organización)');
  perform pruebas.como(v_fam_cuidador);
  perform pruebas.afirmar(cuidared_api.api_informe_medico(v_fam, v_adulto_fam) ? 'identificacion',
    'cuidador de Familia asignado genera el informe');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_fam, v_vacio, v_orden), '42501');

  /* Familia con plan que incluye métricas: reportes sí, salvo visitas (requiere visitas:ver). */
  perform pruebas.como(v_integral);
  perform pruebas.afirmar((cuidared_api.api_reporte(v_fam_integral, 'adultos', v_vacio)->>'vacio')::boolean,
    'Familia con dashboard_metricas consulta reportes (vacío válido)');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_fam_integral, 'visitas', v_vacio), '42501');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_fam_integral,
    '{"tipo":"visitas","formato":"pdf"}'), '42501');

  /* Organización con plan base: reportes sí; avanzado y Excel no. Plan avanzado: ambos. */
  perform pruebas.como(v_base);
  perform pruebas.afirmar(cuidared_api.api_reporte(v_org_base, 'casos_prioritarios', v_vacio) ? 'indicadores',
    'plan base con reportes');
  perform pruebas.error(format('select cuidared_api.api_reporte_avanzado(%s, %L)', v_org_base, v_vacio), '42501');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org_base,
    '{"tipo":"necesidades","formato":"xlsx"}'), '42501');
  perform pruebas.como(v_avanzada);
  v_r := cuidared_api.api_reporte_avanzado(v_org_avanzada, v_vacio);
  perform pruebas.afirmar(v_r->>'tipo' = 'analisis_avanzado' and (v_r->>'vacio')::boolean
    and jsonb_array_length(v_r->'comparativo_zonas') = 0 and jsonb_array_length(v_r->'tendencias') = 12,
    'plan avanzado: análisis vacío válido con 12 meses de tendencia');
  perform pruebas.afirmar((cuidared_api.api_registrar_exportacion_reporte(v_org_avanzada,
    '{"tipo":"analisis_avanzado","formato":"xlsx"}')->>'formato') = 'xlsx', 'Excel con reportes_avanzados');

  /* Cuenta vencida: todo el módulo bloqueado, incluido el informe (D07). */
  perform pruebas.como(v_vencida_admin);
  perform pruebas.afirmar(not (cuidared_api.api_contexto_cuenta(v_vencida)->>'acceso_operativo')::boolean, 'cuenta vencida');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_vencida, v_vacio, v_orden),
    'P0001', 'CR_CUENTA_SIN_ACCESO');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_indicadores(%s)', v_vencida), 'P0001', 'CR_CUENTA_SIN_ACCESO');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_vencida, 'adultos', v_vacio),
    'P0001', 'CR_CUENTA_SIN_ACCESO');
  perform pruebas.error(format('select cuidared_api.api_exportar_reporte_csv(%s, %L, %L)', v_vencida, 'adultos', v_vacio),
    'P0001', 'CR_CUENTA_SIN_ACCESO');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_vencida,
    '{"tipo":"adultos","formato":"pdf"}'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
  perform pruebas.miembro(v_vencida, v_coord, 'coordinador');
  perform pruebas.como(v_coord);
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_vencida, v_adulto_vencida),
    'P0001', 'CR_CUENTA_SIN_ACCESO');

  /* Aislamiento: sin membresía en la cuenta no hay acceso, ni siquiera a sus indicadores. */
  perform pruebas.como(v_admin);
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_indicadores(%s)', v_fam), '42501');
  perform pruebas.error(format('select cuidared_api.api_reporte_opciones(%s, %L)', v_fam, 'resumen'), '42501');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org_avanzada, 'adultos', v_vacio), '42501');
  perform pruebas.como(v_coord);
  perform pruebas.error(format('select cuidared_api.api_informe_medico(%s, %L)', v_org, v_adulto_fam), 'P0002');

  /* Entradas inválidas (422). */
  perform pruebas.como(v_admin);
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'desconocido', v_vacio), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', '{"tipo_necesidad_id":1}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', '{"desde":"2026-05-02","hasta":"2026-05-01"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', '{"desde":"2026-02-30"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', '{"municipio_cod":"01"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', '{"riesgo":"critico"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'necesidades', '{"tipo_necesidad_id":"1"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_reporte(%s, %L, %L)', v_org, 'adultos', '{"otro":1}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
    '{"tipo":"adultos","formato":"csv"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
    '{"tipo":"adultos","formato":"pdf","extra":true}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
    '{"formato":"pdf"}'), '22023');
  perform pruebas.error(format('select cuidared_api.api_registrar_exportacion_reporte(%s, %L)', v_org,
    '{"tipo":"adultos","formato":"pdf","filtros":{"tipo_necesidad_id":1}}'), '22023');

  /* Opciones completas, distintas y de alcance limitado. */
  perform pruebas.envejeciente(v_org, 'Adulto', 'Caso ' || g) from generate_series(1, 100) g;
  v_adulto_tardio := pruebas.envejeciente(v_org, 'Zoraida', 'Caso 101');
  v_adulto_inactivo := pruebas.envejeciente(v_org, 'Teresa', 'Inactiva', 'F', 'inactivo');
  update cuidared.envejeciente set zona = 'Sector 101' where envejeciente_id in (v_adulto_tardio, v_adulto);
  update cuidared.envejeciente set zona = 'Sector histórico' where envejeciente_id = v_adulto_inactivo;
  update cuidared.envejeciente set zona = 'Sector ajeno' where envejeciente_id = v_adulto_fam;
  v_r := cuidared_api.api_reporte_opciones(v_org, 'resumen');
  perform pruebas.afirmar((select count(*) from jsonb_array_elements_text(v_r->'sectores') s where s = 'Sector 101') = 1
    and not (v_r->'sectores' ?| array['Sector histórico', 'Sector ajeno'])
    and v_r->'asignados' @> jsonb_build_array(jsonb_build_object('usuario_id', v_cuidador, 'rol', 'cuidador')),
    'opciones del resumen incluyen todo el alcance activo sin repetir');
  v_r := cuidared_api.api_reporte_opciones(v_org, 'reportes');
  perform pruebas.afirmar(v_r->'sectores' ?& array['Sector 101', 'Sector histórico']
    and not (v_r->'sectores' ? 'Sector ajeno') and v_r->'asignados' = '[]'::jsonb,
    'opciones de reportes incluyen históricos de la cuenta y omiten personal');
  perform pruebas.como(v_fam_coord);
  perform pruebas.afirmar(cuidared_api.api_reporte_opciones(v_fam, 'resumen')->'sectores' ? 'Sector ajeno',
    'el resumen conserva opciones de Familia sin plan de métricas');
  perform pruebas.error(format('select cuidared_api.api_reporte_opciones(%s, %L)', v_fam, 'reportes'), '42501');

  /* Privilegios: RPC solo para authenticated; funciones internas sin ejecución para los roles de la API. */
  perform pruebas.afirmar(
    has_function_privilege('authenticated', 'cuidared_api.api_reporte(bigint,text,jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'cuidared_api.api_informe_medico(bigint,uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'cuidared_api.api_resumen_casos_listar(bigint,jsonb,text[],integer,bigint)', 'EXECUTE')
    and has_function_privilege('authenticated', 'cuidared_api.api_reporte_opciones(bigint,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'cuidared_api.api_reporte(bigint,text,jsonb)', 'EXECUTE')
    and not has_function_privilege('anon', 'cuidared_api.api_registrar_exportacion_reporte(bigint,jsonb)', 'EXECUTE')
    and not has_function_privilege('anon', 'cuidared_api.api_exportar_reporte_csv(bigint,text,jsonb)', 'EXECUTE')
    and not has_function_privilege('anon', 'cuidared_api.api_informe_medico(bigint,uuid)', 'EXECUTE')
    and not has_function_privilege('anon', 'cuidared_api.api_reporte_opciones(bigint,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'cuidared_api.api_auditoria_cuenta(bigint,integer,bigint,boolean)', 'EXECUTE'),
    'RPC de reportes solo para authenticated');
  perform pruebas.afirmar(not exists (
      select from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'cuidared_interno' and p.proname like 'reporte\_%'
        and (has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE')))
    and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'cuidared_interno' and p.proname like 'reporte\_%') >= 20,
    'funciones internas de reportes sin ejecución para la API');
  perform pruebas.afirmar(not exists (
      select from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'cuidared_api' and p.proname in ('api_resumen_casos_listar', 'api_resumen_casos_indicadores',
        'api_reporte', 'api_reporte_avanzado', 'api_exportar_reporte_csv', 'api_registrar_exportacion_reporte',
        'api_informe_medico')
        and (not p.prosecdef or p.proconfig is distinct from array['search_path=""'])),
    'RPC security definer con search_path vacío');
end $$;

rollback;
