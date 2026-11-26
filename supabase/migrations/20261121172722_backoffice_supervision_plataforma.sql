-- Supervisión agregada de la plataforma, sin expedientes ni datos de visitantes.
-- © 2026 Equipo CuidaRed – INTEC. Requiere las migraciones de visitas, necesidades y Web Push.
begin;

create function cuidared_interno.bo_supervision(p_meses integer default 6)
returns jsonb language sql stable set search_path = '' as $$
  with limites as (
    select cuidared_interno.hoy() hoy,
      date_trunc('month',now() at time zone 'America/Santo_Domingo')::date mes,
      now() - interval '24 hours' ayer
  ), meses as (
    select to_char(d,'YYYY-MM') mes, d::date inicio,
      (d + interval '1 month')::date fin
    from limites, generate_series(mes - make_interval(months => p_meses - 1), mes, interval '1 month') d
  ), serie as (
    select m.mes,count(c.cuenta_id) total
    from meses m left join cuidared.cuenta c
      on c.fecha_creacion >= m.inicio::timestamp at time zone 'America/Santo_Domingo'
      and c.fecha_creacion < m.fin::timestamp at time zone 'America/Santo_Domingo'
    group by m.mes
  ), planes as (
    select case
      when c.suscripcion_estado = 'prueba' and c.fecha_fin_prueba > now() then 'Prueba gratuita'
      when c.suscripcion_estado = 'prueba' then 'Prueba vencida'
      else coalesce(p.nombre,'Sin plan asignado') end nombre, count(*) total
    from cuidared.cuenta c left join cuidared.plan p using (plan_id)
    group by 1
  ), solicitudes as (
    select count(*) filter(where estado='pendiente') pendientes,
      count(*) filter(where estado='pendiente' and fecha_propuesta < (select hoy from limites)) fecha_superada,
      count(*) filter(where estado='autorizada') autorizadas,
      count(*) filter(where estado='realizada') realizadas
    from cuidared.solicitud_visita
  ), visitas as (
    select count(*) filter(where estado='programada' and pendiente_autorizacion) sin_autorizar,
      count(*) filter(where estado in ('programada','en_curso') and fecha < (select hoy from limites)) fecha_superada,
      count(*) filter(where estado='programada' and fecha >= (select hoy from limites)) programadas
    from cuidared.visita
  ), tareas as (
    select count(*) filter(where estado in ('pendiente','en_progreso')) pendientes,
      count(*) filter(where estado in ('pendiente','en_progreso') and fecha_programada < (select hoy from limites)) vencidas
    from cuidared.tarea_agenda where not es_historica
  ), evidencias as (
    select (select count(*) from cuidared.evidencia e join cuidared.tarea_agenda t using(tarea_agenda_id)
      where not e.es_historica and e.estado_validacion='pendiente' and t.estado in ('pendiente','en_progreso')) tareas,
      (select count(*) from cuidared.evidencia_visita e join cuidared.visita v using(visita_id)
      where e.estado_validacion='pendiente' and v.estado in ('programada','en_curso')) visitas
  ), sincronizacion as (
    select count(*) filter(where resultado='aplicada') aplicadas,
      count(*) filter(where resultado='duplicada') duplicadas,
      count(*) filter(where resultado='conflicto') conflictos,
      count(*) filter(where resultado='rechazada') rechazadas
    from cuidared.operacion_sync where procesada_en >= (select ayer from limites)
  ), correos as (
    select case when destinatario_usuario_id is null then 'visitante' else 'organizacion' end destino,
      count(*) filter(where cierre is null) pendientes,
      count(*) filter(where cierre is null and intentos > 0) reintentos,
      count(*) filter(where cierre='enviado') enviados,
      count(*) filter(where cierre='fallido') fallidos,
      count(*) filter(where cierre='omitido') omitidos
    from cuidared.aviso_visita group by 1
  ), notificaciones as (
    select count(*) filter(where estado='pendiente') pendientes,
      count(*) filter(where estado='fallida') fallidas,
      count(*) filter(where estado='enviada') enviadas
    from cuidared.push_entrega
  )
  select jsonb_build_object(
    'actualizado_en',now(),
    'cuentas_por_mes',(select coalesce(jsonb_agg(to_jsonb(s) order by mes),'[]') from serie s),
    'cuentas_por_plan',(select coalesce(jsonb_agg(to_jsonb(p) order by total desc,nombre),'[]') from planes p),
    'solicitudes',(select to_jsonb(s) from solicitudes s),
    'visitas',(select to_jsonb(v) from visitas v),
    'tareas',(select to_jsonb(t) from tareas t),
    'evidencias',(select to_jsonb(e) from evidencias e),
    'necesidades_abiertas',(select count(*) from cuidared.envejeciente_necesidad where estado in ('pendiente','en_proceso')),
    'alertas_activas',(select count(*) from cuidared.alerta_envejeciente where estado in ('pendiente','en_proceso')),
    'sincronizacion',(select to_jsonb(s) from sincronizacion s),
    'correos',(select coalesce(jsonb_agg(to_jsonb(c) order by destino),'[]') from correos c),
    'notificaciones',(select to_jsonb(n) from notificaciones n)
  )
$$;

-- Única entrada desde Express: valida de nuevo la sesión dedicada y MFA del operador.
create function cuidared_api.api_bo_supervision(p_actor uuid,p_sesion uuid,p_aal text,p_meses integer default 6)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rol text := cuidared_interno.bo_rol(p_actor,p_sesion);
begin
  if v_rol is null or (v_rol='super_admin' and p_aal is distinct from 'aal2') then
    raise insufficient_privilege;
  end if;
  if p_meses is null or p_meses not in (6,12) then raise invalid_parameter_value; end if;
  return cuidared_interno.bo_supervision(p_meses);
end $$;

revoke all on function cuidared_interno.bo_supervision(integer) from public,anon,authenticated,service_role;
revoke all on function cuidared_api.api_bo_supervision(uuid,uuid,text,integer) from public,anon,authenticated,service_role;
grant execute on function cuidared_api.api_bo_supervision(uuid,uuid,text,integer) to service_role;

-- Solo señales de invalidación: nunca se publican las filas ni su contenido en SSE.
do $$
declare tabla text;
begin
  foreach tabla in array array['solicitud_visita','aviso_visita','operacion_sync','tarea_agenda',
    'evidencia','evidencia_visita','alerta_envejeciente','push_entrega'] loop
    execute format('create trigger bo_supervision_evento after insert or update or delete on cuidared.%I '
      'for each statement execute function cuidared_interno.bo_eventos(%L)',tabla,'operacion');
  end loop;
end $$;

notify pgrst,'reload schema';
commit;
