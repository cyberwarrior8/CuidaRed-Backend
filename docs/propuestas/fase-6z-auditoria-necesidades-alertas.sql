-- RF-21: reutiliza la consulta por cuenta y limita los datos nuevos a referencias.
-- Propuesta 6z, posterior a los bloques de necesidades y alertas.
begin;

-- Reemplaza los disparadores históricos que grababan la fila completa.
create or replace trigger trg_envejeciente_necesidad_auditoria
  after insert or update or delete on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.trg_auditoria_referencia('envejeciente_necesidad_id','envejeciente_id');
create or replace trigger trg_alerta_envejeciente_auditoria
  after insert or update or delete on cuidared.alerta_envejeciente
  for each row execute function cuidared_interno.trg_auditoria_referencia('alerta_envejeciente_id','envejeciente_id');

create or replace function cuidared_api.api_auditoria_cuenta(
  p_cuenta_id bigint, p_limite integer, p_desplazamiento bigint, p_desc boolean
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_items jsonb;
  v_total bigint;
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'auditoria:ver');
  if p_limite is null or p_limite not between 1 and 100
     or p_desplazamiento is null or p_desplazamiento < 0 or p_desc is null then
    raise invalid_parameter_value;
  end if;

  with eventos as materialized (
    select a.auditoria_id, a.tabla, a.operacion, a.fecha, a.usuario_id,
           coalesce(a.datos_nuevos, a.datos_anteriores) as fila
    from cuidared.auditoria a
    where a.tabla in ('cuenta', 'configuracion_cuenta', 'membresia', 'envejeciente',
      'contacto_emergencia', 'vinculo', 'indicacion_medica', 'envejeciente_riesgo',
      'envejeciente_necesidad', 'alerta_envejeciente',
      'evaluacion_riesgo', 'visita', 'detalle_visita', 'registro_visita',
      'tarea_agenda', 'evidencia', 'evidencia_visita', 'evidencia_indicacion', 'solicitud_visita')
  ), propios as (
    select e.auditoria_id, e.tabla, e.operacion, e.fecha, e.usuario_id
    from eventos e
    where case
      when e.tabla in ('cuenta','configuracion_cuenta','membresia','envejeciente','visita','solicitud_visita')
        then (e.fila ->> 'cuenta_id') = p_cuenta_id::text
      when e.tabla in ('detalle_visita','registro_visita','evidencia_visita')
        then exists (select 1 from cuidared.visita v where v.visita_id::text = e.fila ->> 'visita_id'
                     and v.cuenta_id = p_cuenta_id)
      when e.tabla = 'evidencia'
        then exists (select 1 from cuidared.tarea_agenda t
                     join cuidared.envejeciente a on a.envejeciente_id = t.envejeciente_id
                     where t.tarea_agenda_id::text = e.fila ->> 'tarea_agenda_id' and a.cuenta_id = p_cuenta_id)
      when e.tabla = 'evidencia_indicacion'
        then exists (select 1 from cuidared.indicacion_medica i
                     join cuidared.envejeciente a using (envejeciente_id)
                     where i.indicacion_medica_id::text = e.fila ->> 'indicacion_medica_id' and a.cuenta_id = p_cuenta_id)
      else exists (select 1 from cuidared.envejeciente a where a.envejeciente_id::text = e.fila ->> 'envejeciente_id'
                   and a.cuenta_id = p_cuenta_id)
    end
  ), pagina as (
    select p.*, row_number() over (order by case when p_desc then fecha end desc,
      case when not p_desc then fecha end, auditoria_id desc) as posicion
    from propios p
    order by posicion limit p_limite offset p_desplazamiento
  )
  select (select count(*) from propios),
    coalesce(jsonb_agg(jsonb_build_object(
      'auditoria_id', p.auditoria_id::text,
      'actor', nullif(concat_ws(' ', u.nombres, u.apellidos), ''),
      'accion', case p.operacion when 'I' then 'alta' when 'U' then 'actualizacion' else 'baja' end,
      'entidad', p.tabla, 'fecha', p.fecha, 'resultado', 'confirmado'
    ) order by p.posicion), '[]'::jsonb)
  into v_total, v_items
  from pagina p left join cuidared.usuario u on u.usuario_id = p.usuario_id;

  return jsonb_build_object('items', v_items, 'total', v_total);
end;
$$;
revoke all on function cuidared_api.api_auditoria_cuenta(bigint,integer,bigint,boolean) from public, anon;
grant execute on function cuidared_api.api_auditoria_cuenta(bigint,integer,bigint,boolean) to authenticated;

commit;
