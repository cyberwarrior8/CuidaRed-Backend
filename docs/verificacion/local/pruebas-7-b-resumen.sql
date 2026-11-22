-- Fase 7 · resumen de casos (RF-07, CU-11): prioridad, estado de atención, seguimiento 15/16 días, alertas frente a
-- adultos prioritarios, filtros, orden, paginación, vacíos y aislamiento. Base desechable de `--solo=reportes`.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_coord uuid := pruebas.usuario('r7b-coord@example.test', '00700000101');
  v_otro uuid := pruebas.usuario('r7b-otro@example.test', '00700000102');
  v_cuidador uuid := pruebas.usuario('r7b-cuidador@example.test', '00700000103');
  v_cuidador_baja uuid := pruebas.usuario('r7b-cuidador-baja@example.test', '00700000104');
  v_voluntario uuid := pruebas.usuario('r7b-voluntario@example.test', '00700000105');
  v_vacia_admin uuid := pruebas.usuario('r7b-vacia@example.test', '00700000106');
  v_cuenta bigint := pruebas.cuenta('organizacion', v_coord);
  v_otra bigint := pruebas.cuenta('organizacion', v_otro);
  v_vacia bigint := pruebas.cuenta('organizacion', v_vacia_admin);
  v_hoy date := cuidared_interno.hoy();
  a1 uuid := pruebas.envejeciente(v_cuenta, 'Uno', 'Alto');
  a2 uuid := pruebas.envejeciente(v_cuenta, 'Dos', 'Bravo');
  a3 uuid := pruebas.envejeciente(v_cuenta, 'Tres', 'Vencido');
  a4 uuid := pruebas.envejeciente(v_cuenta, 'Cuatro', 'Limite');
  a5 uuid := pruebas.envejeciente(v_cuenta, 'Cinco', 'Necesidad');
  a6 uuid := pruebas.envejeciente(v_cuenta, 'Seis', 'Visitado');
  a7 uuid := pruebas.envejeciente(v_cuenta, 'Siete', 'Inactivo', 'F', 'inactivo');
  a8 uuid := pruebas.envejeciente(v_cuenta, 'Ocho', 'Retirado');
  v_ajeno uuid := pruebas.envejeciente(v_otra, 'Nueve', 'Ajeno');
  v_alta smallint := (select prioridad_id from cuidared.prioridad where codigo = 'alta');
  v_media smallint := (select prioridad_id from cuidared.prioridad where codigo = 'media');
  v_vinculo_cuidador smallint := (select tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado');
  v_vinculo_voluntario smallint := (select tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'voluntario_asignado');
  v_visita uuid;
  v_r jsonb;
  v_i jsonb;
  v_c jsonb;
  v_orden text[] := array['prioridad'];
  v_ids uuid[];
begin
  perform pruebas.miembro(v_cuenta, v_cuidador, 'cuidador');
  perform pruebas.miembro(v_cuenta, v_cuidador_baja, 'cuidador');
  perform pruebas.miembro(v_cuenta, v_voluntario, 'voluntario');
  if not exists (select from cuidared.tipo_cuidado) then
    insert into cuidared.tipo_cuidado(nombre) values ('Cuidado en domicilio');
  end if;
  insert into cuidared.cuidador(usuario_id, tipo_cuidado_id, cuidador_independiente, fecha_inicio, fecha_fin)
    values (v_cuidador, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true, v_hoy - 30, null),
           (v_cuidador_baja, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true, v_hoy - 30, v_hoy - 1);

  -- a1: riesgo alto y medicamento pendiente → dos alertas prioritarias pendientes de un mismo adulto.
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select a1, r.riesgo_id, n.nivel_riesgo_id, 'Caída' from cuidared.riesgo r, cuidared.nivel_riesgo n
    where r.codigo = 'riesgo_caida' and n.codigo = 'alto';
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por)
    select a1, n.necesidad_id, v_media, 'Medicamento de control', v_coord
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'medicamentos' limit 1;
  -- a2: necesidad prioritaria de alimentación cuya alerta ya está en proceso.
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por)
    select a2, n.necesidad_id, v_alta, 'Sin alimentos', v_coord
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'alimentacion' limit 1;
  update cuidared.alerta_envejeciente set estado = 'en_proceso' where envejeciente_id = a2;
  -- a3: alta hace 16 días sin visitas (vence); a4: hace 15 (no vence), riesgo bajo y cuidador vigente.
  update cuidared.envejeciente set fecha_creacion = ((v_hoy - 16)::timestamp + interval '12 hours') at time zone 'America/Santo_Domingo'
    where envejeciente_id = a3;
  update cuidared.envejeciente set fecha_creacion = ((v_hoy - 15)::timestamp + interval '12 hours') at time zone 'America/Santo_Domingo'
    where envejeciente_id = a4;
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select a4, r.riesgo_id, n.nivel_riesgo_id, 'Leve' from cuidared.riesgo r, cuidared.nivel_riesgo n
    where r.codigo = 'aislamiento_social' and n.codigo = 'bajo';
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id) values
    (a4, v_cuidador, v_vinculo_cuidador), (a4, v_cuidador_baja, v_vinculo_cuidador), (a6, v_voluntario, v_vinculo_voluntario);
  -- a5: necesidad media de transporte sin alerta, en el sector Los Mina.
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por)
    select a5, n.necesidad_id, v_media, 'Traslado a consulta', v_coord
    from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'transporte' limit 1;
  update cuidared.envejeciente set zona = 'Los Mina' where envejeciente_id = a5;
  -- a6: alta hace 30 días, visita completada hace 3; una programada y una cancelada más recientes no cuentan.
  update cuidared.envejeciente set fecha_creacion = ((v_hoy - 30)::timestamp + interval '12 hours') at time zone 'America/Santo_Domingo'
    where envejeciente_id = a6;
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select a6, r.riesgo_id, n.nivel_riesgo_id, 'Moderado' from cuidared.riesgo r, cuidared.nivel_riesgo n
    where r.codigo = 'riesgo_nutricional' and n.codigo = 'medio';
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, v_hoy - 3, '09:00', 'Seguimiento', 'completada', v_coord) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, a6);
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    values (v_cuenta, v_hoy + 1, '09:00', 'Próxima', 'programada', v_coord) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, a6);
  insert into cuidared.visita(cuenta_id, fecha, hora_programada, razon, estado, creada_por, motivo_cancelacion, cancelada_por)
    values (v_cuenta, v_hoy - 1, '10:00', 'Cancelada', 'cancelada', v_coord, 'No estaba', v_coord) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id) values (v_visita, a6);
  -- a8 retiró el consentimiento: fuera del resumen. El adulto ajeno tiene una alerta prioritaria en otra cuenta.
  update cuidared.envejeciente set estado = 'inactivo', consentimiento_retirado_en = now(), consentimiento_retirado_por = v_coord
    where envejeciente_id = a8;
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select v_ajeno, r.riesgo_id, n.nivel_riesgo_id, 'Ajeno' from cuidared.riesgo r, cuidared.nivel_riesgo n
    where r.codigo = 'riesgo_caida' and n.codigo = 'alto';

  perform pruebas.afirmar((select count(*) from cuidared.alerta_envejeciente where envejeciente_id = a1 and estado = 'pendiente') = 2
    and (select count(*) from cuidared.alerta_envejeciente where envejeciente_id = a2 and estado = 'en_proceso') = 1,
    'el motor de la fase 6 generó las alertas de partida');

  perform pruebas.como(v_coord);
  v_r := cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', v_orden, 100, 0);
  perform pruebas.afirmar((v_r->>'total')::int = 6 and jsonb_array_length(v_r->'items') = 6,
    'solo adultos activos con consentimiento de la cuenta');
  select array_agg((x->>'envejeciente_id')::uuid order by n) into v_ids
    from jsonb_array_elements(v_r->'items') with ordinality as t(x, n);
  perform pruebas.afirmar(v_ids = array[a1, a2, a3, a5, a6, a4], 'orden por prioridad y desempate fijo');

  select x into v_c from jsonb_array_elements(v_r->'items') x where (x->>'envejeciente_id')::uuid = a1;
  perform pruebas.afirmar(v_c->>'prioridad' = 'alta' and v_c->>'estado_atencion' = 'alerta_pendiente'
    and v_c->>'riesgo_vigente' = 'alto' and (v_c->'alertas'->>'abiertas')::int = 2
    and (v_c->'alertas'->>'prioritarias_abiertas')::int = 2 and (v_c->>'necesidades_activas')::int = 1
    and v_c->'motivos' = '["alerta_prioritaria_abierta","riesgo_alto","necesidades_activas","sin_personal_asignado"]'::jsonb,
    'caso con dos alertas prioritarias');
  select x into v_c from jsonb_array_elements(v_r->'items') x where (x->>'envejeciente_id')::uuid = a2;
  perform pruebas.afirmar(v_c->>'prioridad' = 'alta' and v_c->>'estado_atencion' = 'alerta_en_proceso'
    and v_c->'riesgo_vigente' = 'null'::jsonb and (v_c->'alertas'->>'en_proceso')::int = 1
    and v_c->'motivos' ? 'sin_evaluacion_vigente', 'alerta en proceso y sin evaluación vigente');
  select x into v_c from jsonb_array_elements(v_r->'items') x where (x->>'envejeciente_id')::uuid = a3;
  perform pruebas.afirmar(v_c->>'prioridad' = 'media' and v_c->>'estado_atencion' = 'seguimiento_vencido'
    and (v_c->'seguimiento'->>'dias_sin_visita')::int = 16 and (v_c->'seguimiento'->>'vencido')::boolean
    and v_c->'seguimiento'->'ultima_visita_fecha' = 'null'::jsonb
    and (v_c->'seguimiento'->>'fecha_referencia')::date = v_hoy - 16
    and (v_c->'seguimiento'->>'umbral_dias')::int = 15, 'día 16 sin visitas: vencido');
  select x into v_c from jsonb_array_elements(v_r->'items') x where (x->>'envejeciente_id')::uuid = a4;
  perform pruebas.afirmar(v_c->>'prioridad' = 'baja' and v_c->>'estado_atencion' = 'al_dia'
    and (v_c->'seguimiento'->>'dias_sin_visita')::int = 15 and not (v_c->'seguimiento'->>'vencido')::boolean
    and (v_c->'asignados'->>'total')::int = 1
    and (v_c->'asignados'->'cuidadores'->0->>'usuario_id')::uuid = v_cuidador
    and jsonb_array_length(v_c->'asignados'->'voluntarios') = 0,
    'día 15: no vence; el cuidador sin perfil vigente no cuenta como personal');
  select x into v_c from jsonb_array_elements(v_r->'items') x where (x->>'envejeciente_id')::uuid = a5;
  perform pruebas.afirmar(v_c->>'prioridad' = 'media' and v_c->>'estado_atencion' = 'necesidades_activas'
    and (v_c->'alertas'->>'abiertas')::int = 0 and v_c->>'zona' = 'Los Mina', 'necesidad sin alerta');
  select x into v_c from jsonb_array_elements(v_r->'items') x where (x->>'envejeciente_id')::uuid = a6;
  perform pruebas.afirmar(v_c->>'prioridad' = 'media' and v_c->>'estado_atencion' = 'al_dia'
    and (v_c->'seguimiento'->>'ultima_visita_fecha')::date = v_hoy - 3
    and (v_c->'seguimiento'->>'dias_sin_visita')::int = 3 and v_c->>'riesgo_vigente' = 'medio'
    and (v_c->'asignados'->'voluntarios'->0->>'usuario_id')::uuid = v_voluntario
    and v_c->'municipio' = '{"codigo":"0101","nombre":"Santo Domingo de Guzmán"}'::jsonb,
    'solo la visita completada cuenta como contacto');

  /* Indicadores: alertas frente a adultos prioritarios y conciliación con las filas fuente. */
  v_i := cuidared_api.api_resumen_casos_indicadores(v_cuenta);
  perform pruebas.afirmar((v_i->>'casos_activos')::int = 6 and (v_i->>'fecha_calculo')::date = v_hoy
    and (v_i->>'umbral_dias_sin_visita')::int = 15, 'indicadores sobre los casos activos');
  perform pruebas.afirmar((v_i->>'alertas_prioritarias_abiertas')::int = 3 and (v_i->>'adultos_prioritarios')::int = 2,
    'tres alertas prioritarias y dos adultos prioritarios');
  perform pruebas.afirmar((v_i->>'adultos_prioritarios')::int
    = (cuidared_api.api_casos_prioritarios_listar(v_cuenta, '{}', array['-fecha_alerta'], 100, 0)->>'total')::int,
    'adultos prioritarios coincide con /casos-prioritarios de la fase 6');
  perform pruebas.afirmar((v_i->>'alertas_abiertas')::int = (
      select count(*) from cuidared.alerta_envejeciente ae join cuidared.envejeciente e using (envejeciente_id)
      where e.cuenta_id = v_cuenta and e.estado = 'activo' and e.consentimiento_retirado_en is null
        and ae.estado in ('pendiente', 'en_proceso'))
    and (v_i->>'alertas_abiertas')::int = (v_i->>'alertas_pendientes')::int + (v_i->>'alertas_en_proceso')::int
    and (v_i->>'alertas_pendientes')::int = 2,
    'alertas abiertas conciliadas con alerta_envejeciente');
  perform pruebas.afirmar((v_i->>'necesidades_activas')::int = (
      select count(*) from cuidared.envejeciente_necesidad en join cuidared.envejeciente e using (envejeciente_id)
      where e.cuenta_id = v_cuenta and e.estado = 'activo' and en.estado in ('pendiente', 'en_proceso'))
    and (v_i->>'necesidades_activas')::int = 3 and (v_i->>'adultos_con_necesidades_activas')::int = 3,
    'necesidades activas conciliadas');
  perform pruebas.afirmar(v_i->'por_prioridad' = '{"alta":2,"media":3,"baja":1}'::jsonb
    and v_i->'por_estado_atencion' = '{"alerta_pendiente":1,"alerta_en_proceso":1,"seguimiento_vencido":1,
      "necesidades_activas":1,"al_dia":2}'::jsonb
    and (v_i->>'seguimiento_vencido')::int = 1 and (v_i->>'sin_personal_asignado')::int = 4,
    'distribuciones que suman los casos activos');

  /* Filtros. */
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{"estado_atencion":"seguimiento_vencido"}',
    v_orden, 20, 0)->'items'->0->>'envejeciente_id')::uuid = a3, 'filtro por estado de atención');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{"prioridad":"alta"}', v_orden, 20, 0)->>'total')::int = 2,
    'filtro por prioridad');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{"riesgo":"sin_evaluacion"}', v_orden, 20, 0)->>'total')::int = 3
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, '{"riesgo":"alto"}', v_orden, 20, 0)->>'total')::int = 1,
    'filtro por riesgo vigente, incluido sin evaluación');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{"asignado":"sin"}', v_orden, 20, 0)->>'total')::int = 4
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, '{"asignado":"con"}', v_orden, 20, 0)->>'total')::int = 2
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, jsonb_build_object('asignado', v_cuidador), v_orden, 20, 0)
         ->'items'->0->>'envejeciente_id')::uuid = a4
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, jsonb_build_object('asignado', v_cuidador_baja), v_orden, 20, 0)
         ->>'total')::int = 0,
    'filtro por personal asignado');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{"zona":" Los Mina "}', v_orden, 20, 0)->>'total')::int = 1
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, '{"municipio_cod":"0101"}', v_orden, 20, 0)->>'total')::int = 6
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, '{"municipio_cod":"9999"}', v_orden, 20, 0)->'items') = '[]'::jsonb,
    'filtros de ubicación; sin coincidencias, lista vacía válida');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{"q":"VENCID"}', v_orden, 20, 0)
    ->'items'->0->>'envejeciente_id')::uuid = a3
    and (cuidared_api.api_resumen_casos_listar(v_cuenta, '{"q":"santo domingo"}', v_orden, 20, 0)->>'total')::int = 6,
    'búsqueda por nombre, apellido o municipio');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta,
    '{"prioridad":"media","estado_atencion":"al_dia"}', v_orden, 20, 0)->'items'->0->>'envejeciente_id')::uuid = a6,
    'filtros combinados');

  /* Orden y paginación. */
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['-prioridad'], 20, 0)
    ->'items'->0->>'envejeciente_id')::uuid = a4, 'prioridad invertida');
  v_r := cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['ultima_visita'], 20, 0);
  perform pruebas.afirmar((v_r->'items'->0->>'envejeciente_id')::uuid = a3 and (v_r->'items'->1->>'envejeciente_id')::uuid = a4
    and (v_r->'items'->5->>'envejeciente_id')::uuid = a6, 'sin visitas primero por alta más antigua; visitados al final');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['-ultima_visita'], 20, 0)
    ->'items'->0->>'envejeciente_id')::uuid = a6, 'última visita más reciente primero');
  v_r := cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['riesgo'], 20, 0);
  perform pruebas.afirmar((v_r->'items'->0->>'envejeciente_id')::uuid = a1 and (v_r->'items'->1->>'envejeciente_id')::uuid = a6
    and (v_r->'items'->2->>'envejeciente_id')::uuid = a4, 'riesgo alto, medio, bajo y después sin evaluación');
  v_r := cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['nombre'], 20, 0);
  perform pruebas.afirmar(v_r->'items'->0->>'apellidos' = 'Alto' and v_r->'items'->5->>'apellidos' = 'Visitado', 'orden por nombre');
  perform pruebas.afirmar((cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['estado_atencion', '-nombre'], 20, 0)
    ->'items'->4->>'envejeciente_id')::uuid = a6, 'dos campos de orden');
  v_r := cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', v_orden, 2, 4);
  perform pruebas.afirmar((v_r->>'total')::int = 6 and jsonb_array_length(v_r->'items') = 2
    and (v_r->'items'->0->>'envejeciente_id')::uuid = a6, 'página intermedia');
  v_r := cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', v_orden, 20, 40);
  perform pruebas.afirmar((v_r->>'total')::int = 6 and v_r->'items' = '[]'::jsonb, 'página fuera del conjunto conserva el total');

  /* Entradas inválidas. */
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_cuenta, '{"otro":1}', v_orden), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_cuenta, '{"estado_atencion":"en_atencion"}', v_orden), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_cuenta, '{"asignado":"alguien"}', v_orden), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_cuenta, '{"q":"a"}', v_orden), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_cuenta, '{}', array['fecha']), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 20, 0)', v_cuenta, '{}', array['riesgo', '-riesgo']), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 0, 0)', v_cuenta, '{}', v_orden), '22023');
  perform pruebas.error(format('select cuidared_api.api_resumen_casos_listar(%s, %L, %L, 101, 0)', v_cuenta, '{}', v_orden), '22023');

  /* Vacíos y aislamiento. */
  perform pruebas.como(v_vacia_admin);
  v_r := cuidared_api.api_resumen_casos_listar(v_vacia, '{}', v_orden, 20, 0);
  v_i := cuidared_api.api_resumen_casos_indicadores(v_vacia);
  perform pruebas.afirmar((v_r->>'total')::int = 0 and v_r->'items' = '[]'::jsonb and (v_i->>'casos_activos')::int = 0
    and (v_i->>'alertas_abiertas')::int = 0 and v_i->'por_prioridad' = '{"alta":0,"media":0,"baja":0}'::jsonb,
    'cuenta sin adultos: resumen e indicadores vacíos válidos');
  perform pruebas.como(v_otro);
  v_r := cuidared_api.api_resumen_casos_listar(v_otra, '{}', v_orden, 20, 0);
  perform pruebas.afirmar((v_r->>'total')::int = 1 and (v_r->'items'->0->>'envejeciente_id')::uuid = v_ajeno
    and (cuidared_api.api_resumen_casos_indicadores(v_otra)->>'adultos_prioritarios')::int = 1,
    'cada cuenta ve solo sus casos');
end $$;

rollback;
