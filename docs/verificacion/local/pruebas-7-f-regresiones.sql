-- Fase 7 · visitas institucionales, atenciones y retirada del seguimiento por visitas en Familia.
-- Datos sintéticos en la base local de --solo=reportes. © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_hoy date := cuidared_interno.hoy();
  v_admin uuid := pruebas.usuario('revision7-admin@example.test', '00770000001');
  v_familia_coord uuid := pruebas.usuario('revision7-familia@example.test', '00770000002');
  v_voluntario uuid := pruebas.usuario('revision7-voluntario@example.test', '00770000003');
  v_org bigint := pruebas.cuenta('organizacion', v_admin, 'activa', 'Gestión Comunitaria Avanzada');
  v_familia bigint := pruebas.cuenta('familia', v_familia_coord);
  v_adulto uuid := pruebas.envejeciente(v_org, 'Visita', 'Personal');
  v_adulto_sin_visita uuid := pruebas.envejeciente(v_org, 'Organización', 'Seguimiento');
  v_adulto_familiar uuid := pruebas.envejeciente(v_familia, 'Familia', 'Seguimiento');
  v_alerta uuid;
  v_visita uuid;
  v_solicitud uuid;
  v_institucional uuid;
  v_reporte jsonb;
  v_mes text := to_char(v_hoy, 'YYYY-MM');
  v_huella text := repeat('6', 64);
begin
  perform pruebas.miembro(v_org, v_voluntario, 'voluntario');
  update cuidared.envejeciente set fecha_creacion = now() - interval '16 days'
    where envejeciente_id in (v_adulto_sin_visita, v_adulto_familiar);

  -- Simula un aviso existente de antes del cambio. Se conserva su fila, fuente y fecha.
  insert into cuidared.alerta_envejeciente(envejeciente_id, tipo_alerta_id, prioridad_id, descripcion, origen, fuente_perfil_id)
    select v_adulto_familiar, t.tipo_alerta_id, p.prioridad_id, 'Alerta histórica de prueba', 'sistema', v_adulto_familiar
    from cuidared.tipo_alerta t cross join cuidared.prioridad p where t.codigo = 'ausencia_visitas' and p.codigo = 'media'
    returning alerta_envejeciente_id into v_alerta;
  perform pruebas.como(v_familia_coord);
  v_reporte := cuidared_api.api_resumen_casos_listar(v_familia, '{}', array['prioridad'], 20, 0)->'items'->0;
  perform pruebas.afirmar(v_reporte @> '{"seguimiento":null,"estado_atencion":"al_dia","alertas":{"abiertas":0}}',
    'Familia no conserva un estado de seguimiento operativo a partir de alertas heredadas');
  perform pruebas.afirmar(cuidared_api.api_resumen_casos_indicadores(v_familia)
    @> '{"umbral_dias_sin_visita":null,"seguimiento_vencido":0}', 'el indicador no aplica a Familia');
  perform pruebas.afirmar(not exists (select from cuidared_interno.alerta_ventana_sin_visita(v_adulto_familiar, v_familia, v_hoy)),
    'Familia deja de aportar fuentes de ausencia de visitas');

  perform cuidared_interno.alertas_reconciliar_adulto(v_adulto_familiar, v_hoy, 'ausencia_visitas');
  perform cuidared_interno.alertas_reconciliar_adulto(v_adulto_familiar, v_hoy + 1, 'ausencia_visitas');
  perform pruebas.afirmar((select count(*) = 1 and bool_and(a.alerta_envejeciente_id = v_alerta
    and a.estado = 'resuelta' and a.cierre_automatico and a.fuente_perfil_id = v_adulto_familiar)
    from cuidared.alerta_envejeciente a where a.envejeciente_id = v_adulto_familiar),
    'el motor cierra el aviso anterior sin eliminarlo y no crea otro');
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto_sin_visita, v_hoy, 'ausencia_visitas') = 1,
    'Organización conserva la generación al día 16');

  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_org, v_hoy, '09:00', 'Visita personal de prueba', 'completada', v_admin)
    returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id, estado_general)
    values (v_visita, v_adulto, 'estable');

  perform cuidared_api.api_publico_crear_solicitud(jsonb_build_object(
    'cuenta_id', v_org, 'nombres', 'Ana', 'apellidos', 'Prueba', 'cedula', '00123456789', 'telefono', '8095550100',
    'tipo_visita', 'institucional', 'entidad_visitante', 'Fundación Sintética', 'tipo_entidad', 'fundacion',
    'cantidad_visitantes', 12, 'aporte_previsto', 'Actividad comunitaria', 'fecha_propuesta', v_hoy + 1,
    'hora_propuesta', '10:00', 'motivo', 'Visita institucional', 'codigo_hash', v_huella));
  select solicitud_visita_id into strict v_solicitud from cuidared.solicitud_visita where codigo_hash = v_huella;
  perform pruebas.como(v_admin);
  v_institucional := (cuidared_api.api_autorizar_solicitud_visita(v_org, v_solicitud, jsonb_build_object(
    'participante_id', v_voluntario, 'fecha', v_hoy + 1, 'hora', '10:00', 'hora_fin_programada', '11:00'))
    ->>'visita_id')::uuid;
  update cuidared.visita set fecha = v_hoy, estado = 'en_curso' where visita_id = v_institucional;
  perform pruebas.como(v_voluntario);
  perform cuidared_api.api_registrar_visita(v_org, v_institucional,
    '{"detalles":[],"observacion_general":"Actividad comunitaria completada."}');

  perform pruebas.como(v_admin);
  v_reporte := cuidared_api.api_reporte(v_org, 'visitas', jsonb_build_object('desde', v_hoy, 'hasta', v_hoy));
  perform pruebas.afirmar(v_reporte @> '{"indicadores":{"visitas_realizadas":2,"visitas_personales":1,"visitas_institucionales":1,
    "atenciones":1,"adultos_visitados":1},"detalle_total":2}', 'el reporte concilia visitas y atenciones por separado');
  perform pruebas.afirmar(v_reporte->'detalle' @> jsonb_build_array(jsonb_build_object(
    'visita_id', v_institucional, 'tipo_visita', 'institucional', 'adultos', '[]'::jsonb))
    and v_reporte->'series'->'por_tipo_visita' @> '[{"clave":"institucional","valor":1}]',
    'el detalle y el gráfico identifican la visita institucional sin inventar un expediente');
  perform pruebas.afirmar(cuidared_api.api_reporte(v_org, 'visitas', '{"municipio_cod":"0101"}')->'indicadores'
    @> '{"visitas_realizadas":1,"visitas_institucionales":0,"atenciones":1}',
    'un filtro del expediente excluye las visitas institucionales sin expediente');
  perform pruebas.afirmar(cuidared_api.api_reporte_avanzado(v_org, '{}')->'tendencias'
    @> jsonb_build_array(jsonb_build_object('mes', v_mes, 'visitas_realizadas', 2)),
    'la tendencia general cuenta las visitas institucionales');
  perform pruebas.afirmar(cuidared_api.api_reporte_avanzado(v_org, '{}')->'comparativo_municipios'
    @> '[{"municipio":{"codigo":"0101"},"visitas_realizadas":1}]',
    'el comparativo territorial conserva solo las visitas con ubicación de expediente');
end $$;

rollback;
