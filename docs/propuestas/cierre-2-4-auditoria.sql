-- RF-21. Consulta de los cambios confirmados con cuenta verificable.
-- Propuesta para revisión. No se publican los datos previos o nuevos de una fila.
begin;

-- Las tablas nuevas que quedaron fuera de los triggers históricos registran solo el identificador
-- de la fila y de su contenedor. Los datos de la indicación, del visitante o del archivo no se copian.
create function cuidared_interno.trg_auditoria_referencia() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_fila jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_referencia jsonb := jsonb_build_object(tg_argv[1], v_fila->tg_argv[1]);
begin
  if tg_op = 'UPDATE' and old is not distinct from new then return new; end if;
  insert into cuidared.auditoria(tabla,operacion,registro_id,usuario_id,datos_anteriores,datos_nuevos)
  values(tg_table_name,left(tg_op,1),v_fila->>tg_argv[0],auth.uid(),
    case when tg_op = 'DELETE' then v_referencia end, case when tg_op <> 'DELETE' then v_referencia end);
  return coalesce(new, old);
end;
$$;
revoke all on function cuidared_interno.trg_auditoria_referencia() from public, anon, authenticated;

create trigger auditoria_evaluacion_riesgo after insert or update or delete on cuidared.evaluacion_riesgo
  for each row execute function cuidared_interno.trg_auditoria_referencia('evaluacion_riesgo_id','envejeciente_id');
create trigger auditoria_solicitud_visita after insert or update or delete on cuidared.solicitud_visita
  for each row execute function cuidared_interno.trg_auditoria_referencia('solicitud_visita_id','cuenta_id');
create trigger auditoria_evidencia_visita after insert or update or delete on cuidared.evidencia_visita
  for each row execute function cuidared_interno.trg_auditoria_referencia('evidencia_visita_id','visita_id');
create trigger auditoria_evidencia_indicacion after insert or update or delete on cuidared.evidencia_indicacion
  for each row execute function cuidared_interno.trg_auditoria_referencia('evidencia_indicacion_id','indicacion_medica_id');

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
