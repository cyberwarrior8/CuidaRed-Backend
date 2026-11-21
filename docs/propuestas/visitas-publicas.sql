-- Propuesta de activación de visitas públicas. Aplicar en un entorno autorizado.
begin;

create or replace function cuidared_api.api_publico_consultar_solicitud(p_codigo_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  resultado jsonb;
begin
  if p_codigo_hash is null or p_codigo_hash !~ '^[0-9a-f]{64}$' then raise no_data_found; end if;
  select jsonb_build_object(
    'organizacion', c.nombre,
    'estado', s.estado,
    'fecha', coalesce(v.fecha, s.fecha_propuesta),
    'hora', cuidared_interno.hhmm(coalesce(v.hora_programada, s.hora_propuesta)),
    'motivo_rechazo', s.motivo_rechazo,
    'puede_registrar_observacion', coalesce(
      s.estado::text = 'realizada' and v.estado::text = 'completada'
      and s.observacion_visitante is null and cuidared_interno.acceso_operativo(s.cuenta_id), false),
    'observacion', s.observacion_visitante)
  into resultado
  from cuidared.solicitud_visita s
  join cuidared.cuenta c on c.cuenta_id = s.cuenta_id
  left join cuidared.visita v on v.visita_id = s.visita_id and v.cuenta_id = s.cuenta_id
  where s.codigo_hash = p_codigo_hash;
  if not found then raise no_data_found; end if;
  return resultado;
end $$;

create or replace function cuidared_api.api_publico_registrar_observacion_posterior(p_codigo_hash text, p_observacion text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_s record;
  v_obs text;
begin
  if p_codigo_hash is null or p_codigo_hash !~ '^[0-9a-f]{64}$' then raise no_data_found; end if;
  select s.solicitud_visita_id, s.estado, s.visita_id, s.cuenta_id, s.observacion_visitante
  into v_s
  from cuidared.solicitud_visita s
  where s.codigo_hash = p_codigo_hash
  for update;
  if not found then raise no_data_found; end if;
  v_obs := cuidared_interno.v_texto(to_jsonb(p_observacion), 3, 600);

  -- Un reintento de la misma observación devuelve el resultado guardado.
  if v_s.estado::text = 'realizada' and v_s.observacion_visitante = v_obs then
    return cuidared_api.api_publico_consultar_solicitud(p_codigo_hash);
  end if;
  if v_s.estado::text <> 'realizada' or v_s.observacion_visitante is not null
     or cuidared_interno.acceso_operativo(v_s.cuenta_id) is not true
     or not exists (
       select from cuidared.visita
       where visita_id = v_s.visita_id and cuenta_id = v_s.cuenta_id and estado::text = 'completada'
     ) then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  -- La observación es del visitante. Se conserva aparte del informe que registró el equipo.
  update cuidared.solicitud_visita
    set observacion_visitante = v_obs, observacion_en = now()
    where solicitud_visita_id = v_s.solicitud_visita_id;
  return cuidared_api.api_publico_consultar_solicitud(p_codigo_hash);
end $$;

revoke all on function
  cuidared_api.api_publico_listar_organizaciones(),
  cuidared_api.api_publico_crear_solicitud(jsonb),
  cuidared_api.api_publico_consultar_solicitud(text),
  cuidared_api.api_publico_registrar_observacion_posterior(text, text)
from public, anon, authenticated;

revoke all on function cuidared_api.api_publico_registrar_observacion(text, text)
from public, anon, authenticated, service_role;

grant execute on function
  cuidared_api.api_publico_listar_organizaciones(),
  cuidared_api.api_publico_crear_solicitud(jsonb),
  cuidared_api.api_publico_consultar_solicitud(text),
  cuidared_api.api_publico_registrar_observacion_posterior(text, text)
to service_role;

commit;
