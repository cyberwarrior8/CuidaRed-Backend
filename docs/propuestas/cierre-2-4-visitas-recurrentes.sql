-- Series atómicas de visitas. Aplicar tras cierre-2-4-consentimiento.sql.
begin;

alter table cuidared.visita add column serie_id uuid;
create index visita_serie_idx on cuidared.visita (cuenta_id, serie_id) where serie_id is not null;

create function cuidared_api.api_programar_visitas_recurrentes(p_cuenta_id bigint, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  v_rep jsonb := p_datos -> 'repeticion';
  v_desde date;
  v_hasta date;
  v_frecuencia text;
  v_dias integer[];
  v_fechas date[];
  v_fecha date;
  v_serie uuid := gen_random_uuid();
  v_visita jsonb;
  v_visitas jsonb := '[]'::jsonb;
begin
  if not cuidared_interno.tiene_permiso(p_cuenta_id, (v_ctx->>'usuario_id')::uuid, 'visitas:autorizar')
     or not cuidared_interno.cuenta_tiene_funcionalidad(p_cuenta_id, 'visitas_recurrentes') then
    raise insufficient_privilege;
  end if;
  if jsonb_typeof(v_rep) is distinct from 'object'
     or v_rep - array['frecuencia','hasta','dias_semana'] <> '{}'::jsonb then raise invalid_parameter_value; end if;
  v_desde := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hasta := cuidared_interno.v_fecha(v_rep->'hasta');
  v_frecuencia := v_rep->>'frecuencia';
  if v_desde < cuidared_interno.hoy() or v_hasta < v_desde or v_hasta - v_desde > 730 then
    raise invalid_parameter_value;
  end if;
  if v_frecuencia = 'semanal' then
    if jsonb_typeof(v_rep->'dias_semana') is distinct from 'array' then raise invalid_parameter_value; end if;
    if jsonb_array_length(v_rep->'dias_semana') not between 1 and 7
       or exists (select from jsonb_array_elements(v_rep->'dias_semana') d
                  where jsonb_typeof(d) <> 'number' or (d #>> '{}') !~ '^[1-7]$') then
      raise invalid_parameter_value;
    end if;
    select array_agg(distinct (d #>> '{}')::integer) into v_dias from jsonb_array_elements(v_rep->'dias_semana') d;
    if cardinality(v_dias) <> jsonb_array_length(v_rep->'dias_semana') then raise invalid_parameter_value; end if;
  elsif v_frecuencia is distinct from 'diaria' or v_rep ? 'dias_semana' then
    raise invalid_parameter_value;
  end if;
  select array_agg(d::date order by d) into v_fechas
    from generate_series(v_desde::timestamp, v_hasta::timestamp, interval '1 day') d
    where v_frecuencia = 'diaria' or extract(isodow from d)::integer = any(v_dias);
  if v_fechas is null or cardinality(v_fechas) > 60 then
    raise exception 'CR_SERIE_VISITA_INVALIDA' using errcode = 'P0001';
  end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  foreach v_fecha in array v_fechas loop
    v_visita := cuidared_api.api_programar_visita(p_cuenta_id, (p_datos - 'repeticion') || jsonb_build_object('fecha',v_fecha));
    update cuidared.visita set serie_id = v_serie where visita_id = (v_visita->>'visita_id')::uuid;
    v_visitas := v_visitas || jsonb_build_array(v_visita);
  end loop;
  return jsonb_build_object('serie_id', v_serie, 'visitas', v_visitas);
end;
$$;
revoke all on function cuidared_api.api_programar_visitas_recurrentes(bigint,jsonb) from public, anon;
grant execute on function cuidared_api.api_programar_visitas_recurrentes(bigint,jsonb) to authenticated;
commit;
