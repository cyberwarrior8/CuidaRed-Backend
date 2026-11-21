-- Fase 7 · RNF de capacidad: 2.000 adultos con personal asignado, riesgo, necesidades, alertas y visitas compartidas.
-- Cada RPC del módulo debe responder en menos de 1,5 s en la base local (meta de consulta de §13: máx. 3 s) y sus
-- totales deben coincidir con las filas fuente. Base desechable de `--solo=reportes`. © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('r7e-admin@example.test', '00700000401');
  v_coord uuid := pruebas.usuario('r7e-coord@example.test', '00700000402');
  v_cuenta bigint := pruebas.cuenta('organizacion', v_admin, 'activa', 'Gestión Comunitaria Avanzada');
  v_hoy date := cuidared_interno.hoy();
  v_n integer := 2000;
  v_adultos uuid[];
  v_personal uuid[] := array[]::uuid[];
  v_media smallint := (select prioridad_id from cuidared.prioridad where codigo = 'media');
  i integer;
begin
  perform pruebas.miembro(v_cuenta, v_coord, 'coordinador');
  -- Personal: 10 cuidadores con perfil vigente y 10 voluntarios.
  if not exists (select from cuidared.tipo_cuidado) then
    insert into cuidared.tipo_cuidado(nombre) values ('Cuidado en domicilio');
  end if;
  for i in 1..20 loop
    v_personal := v_personal || pruebas.usuario('r7e-personal' || i || '@example.test', lpad((700000500 + i)::text, 11, '0'));
    perform pruebas.miembro(v_cuenta, v_personal[i], case when i <= 10 then 'cuidador' else 'voluntario' end);
  end loop;
  insert into cuidared.cuidador(usuario_id, tipo_cuidado_id, cuidador_independiente)
    select u, (select min(tipo_cuidado_id) from cuidared.tipo_cuidado), true from unnest(v_personal[1:10]) u;

  -- Adultos en 3 municipios y 12 sectores, con altas repartidas en los últimos 18 meses.
  insert into cuidared.municipio values ('0102', 'Municipio Este', '01'), ('0103', 'Municipio Norte', '01')
    on conflict do nothing;
  for i in 1..v_n loop
    perform pruebas.envejeciente(v_cuenta, 'Carga' || i, 'Prueba' || lpad(i::text, 4, '0'));
  end loop;
  select array_agg(envejeciente_id order by apellidos) into v_adultos from cuidared.envejeciente where cuenta_id = v_cuenta;
  update cuidared.envejeciente e set zona = 'Sector ' || (t.k % 12),
      municipio_cod = case t.k % 3 when 0 then '0101' when 1 then '0102' else '0103' end,
      fecha_creacion = now() - make_interval(days => (t.k % 540)::integer)
    from unnest(v_adultos) with ordinality as t(a, k) where e.envejeciente_id = t.a;
  -- Un cuidador para cada adulto y un voluntario para la mitad.
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id)
    select t.a, v_personal[1 + (t.k % 10)::integer], tv.tipo_vinculo_id
    from unnest(v_adultos) with ordinality as t(a, k), cuidared.tipo_vinculo tv where tv.codigo = 'cuidador_asignado';
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id)
    select t.a, v_personal[11 + (t.k % 10)::integer], tv.tipo_vinculo_id
    from unnest(v_adultos) with ordinality as t(a, k), cuidared.tipo_vinculo tv
    where tv.codigo = 'voluntario_asignado' and t.k % 2 = 0;
  -- Riesgo para todos (un tercio alto, con su alerta) y una necesidad por adulto (una de cada cinco, de medicamentos).
  insert into cuidared.envejeciente_riesgo(envejeciente_id, riesgo_id, nivel_riesgo_id, motivo)
    select t.a, r.riesgo_id, n.nivel_riesgo_id, 'Carga'
    from unnest(v_adultos) with ordinality as t(a, k)
    cross join cuidared.riesgo r cross join cuidared.nivel_riesgo n
    where r.codigo = 'riesgo_caida' and n.codigo = case t.k % 3 when 0 then 'alto' when 1 then 'medio' else 'bajo' end;
  insert into cuidared.envejeciente_necesidad(envejeciente_id, necesidad_id, prioridad_id, descripcion, registrado_por,
      fecha_necesidad)
    select t.a, (select min(n2.necesidad_id) from cuidared.necesidad n2 where n2.tipo_necesidad_id = 1 + (t.k % 5)::integer),
      v_media, 'Necesidad de carga', v_admin, now() - make_interval(days => (t.k % 365)::integer)
    from unnest(v_adultos) with ordinality as t(a, k);
  -- Seis visitas completadas por adulto en el último año (cada una con dos adultos): 6.000 visitas, 12.000 atenciones.
  create temporary table carga_visitas on commit drop as
    select gen_random_uuid() as visita_id, g, v_hoy - (g % 365) as fecha from generate_series(1, v_n * 3) g;
  insert into cuidared.visita(visita_id, cuenta_id, fecha, hora_programada, razon, estado, creada_por)
    select visita_id, v_cuenta, fecha, '09:00', 'Carga', 'completada', v_admin from carga_visitas;
  insert into cuidared.detalle_visita(visita_id, envejeciente_id, estado_general)
    select c.visita_id, v_adultos[1 + ((c.g * 2 + d) % v_n)::integer], 'estable'
    from carga_visitas c cross join (values (0), (1)) x(d);
  insert into cuidared.registro_visita(visita_id, usuario_id, autorizada_por_usuario_id)
    select c.visita_id, v_personal[1 + (c.g % 10)::integer], v_admin from carga_visitas c;
  -- Seguimiento para los adultos sin visita reciente (fuente de visita).
  perform cuidared_interno.alertas_reconciliar_adulto(a, v_hoy, 'ausencia_visitas') from unnest(v_adultos[1:200]) a;
  create temporary table carga_contexto on commit drop as select v_cuenta as cuenta, v_admin as admin, v_coord as coord,
    v_n as n, v_adultos[1] as adulto;
end $$;

-- Estadísticas del planificador, como las que Supabase mantiene con autovacuum (dentro de la misma transacción).
analyze cuidared.envejeciente;
analyze cuidared.vinculo;
analyze cuidared.envejeciente_riesgo;
analyze cuidared.envejeciente_necesidad;
analyze cuidared.alerta_envejeciente;
analyze cuidared.visita;
analyze cuidared.detalle_visita;
analyze cuidared.registro_visita;
analyze cuidared.membresia;

do $$
declare
  v_cuenta bigint := (select cuenta from carga_contexto);
  v_admin uuid := (select admin from carga_contexto);
  v_coord uuid := (select coord from carga_contexto);
  v_n integer := (select n from carga_contexto);
  v_inicio timestamptz;
  v_ms numeric;
  v_max numeric := 0;
  v_r jsonb;
  v_rpc text;
begin
  perform pruebas.como(v_admin);
  foreach v_rpc in array array['resumen', 'resumen_filtrado', 'indicadores', 'adultos', 'visitas', 'necesidades',
      'casos_prioritarios', 'avanzado'] loop
    v_inicio := clock_timestamp();
    v_r := case v_rpc
      when 'resumen' then cuidared_api.api_resumen_casos_listar(v_cuenta, '{}', array['prioridad'], 20, 0)
      when 'resumen_filtrado' then cuidared_api.api_resumen_casos_listar(v_cuenta, '{"riesgo":"alto","asignado":"con"}',
        array['-ultima_visita'], 100, 200)
      when 'indicadores' then cuidared_api.api_resumen_casos_indicadores(v_cuenta)
      when 'avanzado' then cuidared_api.api_reporte_avanzado(v_cuenta, '{}')
      else cuidared_api.api_reporte(v_cuenta, v_rpc, '{}') end;
    v_ms := extract(epoch from clock_timestamp() - v_inicio) * 1000;
    raise notice 'Fase 7 · carga % adultos · % · % ms', v_n, v_rpc, round(v_ms);
    v_max := greatest(v_max, v_ms);
    if v_rpc = 'resumen' then
      perform pruebas.afirmar((v_r->>'total')::int = v_n and jsonb_array_length(v_r->'items') = 20, 'resumen paginado');
    elsif v_rpc = 'indicadores' then
      perform pruebas.afirmar((v_r->>'casos_activos')::int = v_n
        and (v_r->>'adultos_prioritarios')::int = (
          select count(distinct ae.envejeciente_id) from cuidared.alerta_envejeciente ae
          join cuidared.tipo_alerta t using (tipo_alerta_id) join cuidared.envejeciente e using (envejeciente_id)
          where e.cuenta_id = v_cuenta and ae.estado in ('pendiente', 'en_proceso') and cuidared_interno.alerta_es_prioritaria(t.codigo))
        and (v_r->>'alertas_abiertas')::int = (
          select count(*) from cuidared.alerta_envejeciente ae join cuidared.envejeciente e using (envejeciente_id)
          where e.cuenta_id = v_cuenta and ae.estado in ('pendiente', 'en_proceso'))
        and (v_r->>'sin_personal_asignado')::int = 0,
        'indicadores conciliados');
    elsif v_rpc = 'visitas' then
      perform pruebas.afirmar((v_r->'indicadores'->>'visitas_realizadas')::int = v_n * 3
        and (v_r->'indicadores'->>'atenciones')::int = v_n * 6 and (v_r->>'detalle_total')::int = v_n * 3
        and jsonb_array_length(v_r->'detalle') = 5000 and (v_r->>'detalle_truncado')::boolean,
        'visitas conciliadas y detalle recortado a 5.000');
    elsif v_rpc = 'avanzado' then
      perform pruebas.afirmar(jsonb_array_length(v_r->'comparativo_zonas') = 12
        and (select sum((z->>'adultos_activos')::int) from jsonb_array_elements(v_r->'comparativo_zonas') z) = v_n,
        'comparativo de doce sectores');
    end if;
  end loop;
  perform pruebas.como(v_coord);
  v_inicio := clock_timestamp();
  v_r := cuidared_api.api_informe_medico(v_cuenta, (select adulto from carga_contexto));
  v_ms := extract(epoch from clock_timestamp() - v_inicio) * 1000;
  raise notice 'Fase 7 · carga % adultos · informe · % ms', v_n, round(v_ms);
  v_max := greatest(v_max, v_ms);
  perform pruebas.afirmar((v_r->'visitas'->>'realizadas_total')::int = 6 and jsonb_array_length(v_r->'visitas'->'recientes') = 6,
    'informe con sus seis visitas');
  raise notice 'Fase 7 · carga % adultos: consulta más lenta % ms', v_n, round(v_max);
  perform pruebas.afirmar(v_max < 1500, format('cada RPC responde en menos de 1,5 s (máx. %s ms)', round(v_max)));
end $$;

rollback;
