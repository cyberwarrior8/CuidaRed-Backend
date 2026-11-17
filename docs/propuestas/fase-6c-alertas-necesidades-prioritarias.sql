-- CUIDARED-011 · Alerta por necesidad pendiente con prioridad alta. Requiere CUIDARED-009.
begin;

insert into cuidared.tipo_alerta (codigo,nombre)
values ('necesidad_prioritaria','Necesidad prioritaria')
on conflict (codigo) do nothing;

create or replace function cuidared_interno.alerta_es_prioritaria(p_tipo text) returns boolean
language sql immutable set search_path = '' as $$
  select p_tipo in ('riesgo_alto','medicamento_pendiente','necesidad_prioritaria')
$$;

create or replace function cuidared_interno.trg_alerta_fuente_consistente() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_tipo text;
begin
  if tg_op = 'INSERT' and new.sin_fuente_historica then raise check_violation; end if;
  if tg_op = 'UPDATE'
     and (new.envejeciente_id, new.tipo_alerta_id, new.fuente_riesgo_id, new.fuente_necesidad_id,
          new.fuente_visita_id, new.fuente_perfil_id, new.sin_fuente_historica) is distinct from
         (old.envejeciente_id, old.tipo_alerta_id, old.fuente_riesgo_id, old.fuente_necesidad_id,
          old.fuente_visita_id, old.fuente_perfil_id, old.sin_fuente_historica) then
    raise check_violation;
  end if;
  if new.sin_fuente_historica then return new; end if;
  select codigo into v_tipo from cuidared.tipo_alerta where tipo_alerta_id = new.tipo_alerta_id;
  if (new.fuente_riesgo_id is not null and (v_tipo <> 'riesgo_alto' or not exists (
       select from cuidared.envejeciente_riesgo r where r.envejeciente_riesgo_id = new.fuente_riesgo_id
         and r.envejeciente_id = new.envejeciente_id)))
    or (new.fuente_necesidad_id is not null and (
      v_tipo not in ('medicamento_pendiente','necesidad_prioritaria') or not exists (
        select from cuidared.envejeciente_necesidad n
        where n.envejeciente_necesidad_id = new.fuente_necesidad_id
          and n.envejeciente_id = new.envejeciente_id)))
    or (new.fuente_visita_id is not null and (v_tipo <> 'ausencia_visitas' or not exists (
       select from cuidared.visita v join cuidared.envejeciente e on e.cuenta_id = v.cuenta_id
         where v.visita_id = new.fuente_visita_id and v.estado = 'completada'
           and e.envejeciente_id = new.envejeciente_id)))
    or (new.fuente_perfil_id is not null and v_tipo <> 'ausencia_visitas') then
    raise check_violation;
  end if;
  return new;
end;
$$;

create or replace function cuidared_interno.alertas_fuentes_vigentes(p_adulto uuid, p_cuenta bigint, p_hoy date, p_tipo text)
returns table (tipo text, prioridad text, descripcion text, riesgo_id bigint, necesidad_id uuid, visita_id uuid, perfil_id uuid)
language sql stable set search_path = '' as $$
  select 'riesgo_alto', 'alta', format('Factor de riesgo alto vigente: %s.',r.nombre),
    er.envejeciente_riesgo_id,null::uuid,null::uuid,null::uuid
  from cuidared.envejeciente_riesgo er join cuidared.nivel_riesgo nr using (nivel_riesgo_id)
  join cuidared.riesgo r using (riesgo_id)
  where (p_tipo is null or p_tipo = 'riesgo_alto') and er.envejeciente_id = p_adulto
    and er.estado = 'activo' and nr.codigo = 'alto'
  union all
  select 'medicamento_pendiente','alta',format('Necesidad de medicamentos pendiente: %s.',n.nombre),
    null, en.envejeciente_necesidad_id, null, null
  from cuidared.envejeciente_necesidad en join cuidared.necesidad n using (necesidad_id)
  join cuidared.tipo_necesidad t using (tipo_necesidad_id)
  where (p_tipo is null or p_tipo = 'medicamento_pendiente') and en.envejeciente_id = p_adulto
    and en.estado = 'pendiente' and t.codigo = 'medicamentos'
  union all
  select 'necesidad_prioritaria','alta',format('Necesidad de prioridad alta: %s.',n.nombre),
    null, en.envejeciente_necesidad_id, null, null
  from cuidared.envejeciente_necesidad en join cuidared.necesidad n using (necesidad_id)
  join cuidared.tipo_necesidad t using (tipo_necesidad_id)
  join cuidared.prioridad p using (prioridad_id)
  where (p_tipo is null or p_tipo = 'necesidad_prioritaria') and en.envejeciente_id = p_adulto
    and en.estado = 'pendiente' and t.codigo is distinct from 'medicamentos' and p.codigo = 'alta'
  union all
  select 'ausencia_visitas','media',format('Han pasado más de %s días calendario desde el último contacto efectivo.',v.umbral),
    null,null,v.visita_id,case when v.visita_id is null then p_adulto end
  from cuidared_interno.alerta_ventana_sin_visita(p_adulto,p_cuenta,p_hoy) v
  where (p_tipo is null or p_tipo = 'ausencia_visitas') and v.dias > v.umbral
$$;

create or replace function cuidared_interno.alertas_reconciliar_adulto(p_adulto uuid, p_hoy date, p_tipo text default null) returns integer
language plpgsql set search_path = '' as $$
declare
  v_cuenta bigint;
  v_cantidad integer;
begin
  if p_hoy is null
     or (p_tipo is not null and p_tipo not in ('riesgo_alto','medicamento_pendiente','necesidad_prioritaria','ausencia_visitas')) then
    raise invalid_parameter_value;
  end if;
  select e.cuenta_id into v_cuenta
    from cuidared.envejeciente e where e.envejeciente_id = p_adulto and e.estado = 'activo'
      and e.consentimiento_retirado_en is null
    for share;
  if not found or not cuidared_interno.acceso_operativo(v_cuenta) then return 0; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_adulto::text, 608144));
  with fuentes as materialized (
    select * from cuidared_interno.alertas_fuentes_vigentes(p_adulto,v_cuenta,p_hoy,p_tipo)
  ), cerrar as (
    update cuidared.alerta_envejeciente a set estado = 'resuelta',
      accion_tomada = 'Cierre automático: la condición dejó de estar vigente.',
      cierre_automatico = true, fecha_atencion = now(), usuario_atendio_id = null, fecha_actualizacion = now()
    from cuidared.tipo_alerta t
    where a.envejeciente_id = p_adulto and a.tipo_alerta_id = t.tipo_alerta_id and a.origen = 'sistema'
      and not a.sin_fuente_historica and a.estado in ('pendiente','en_proceso')
      and t.codigo in ('riesgo_alto','medicamento_pendiente','necesidad_prioritaria','ausencia_visitas')
      and (p_tipo is null or t.codigo = p_tipo)
      and not exists (select from fuentes f where f.tipo = t.codigo
        and f.riesgo_id is not distinct from a.fuente_riesgo_id
        and f.necesidad_id is not distinct from a.fuente_necesidad_id
        and f.visita_id is not distinct from a.fuente_visita_id
        and f.perfil_id is not distinct from a.fuente_perfil_id)
  )
  insert into cuidared.alerta_envejeciente (envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,origen,
    fuente_riesgo_id,fuente_necesidad_id,fuente_visita_id,fuente_perfil_id)
  select p_adulto,t.tipo_alerta_id,p.prioridad_id,f.descripcion,'sistema',f.riesgo_id,f.necesidad_id,f.visita_id,f.perfil_id
  from fuentes f join cuidared.tipo_alerta t on t.codigo = f.tipo
  join cuidared.prioridad p on p.codigo = f.prioridad
  on conflict do nothing;
  get diagnostics v_cantidad = row_count;
  return v_cantidad;
end;
$$;

create trigger alertas_necesidad_prioritaria
  after insert or update of estado,necesidad_id,prioridad_id on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.trg_alerta_reconciliar_fuente('necesidad_prioritaria');

-- Evaluar las ocurrencias elegibles ya registradas. El flujo normal decide a quién avisar.
do $$
declare
  v_adulto uuid;
  v_hoy date := cuidared_interno.hoy();
begin
  for v_adulto in
    select distinct e.envejeciente_id
    from cuidared.envejeciente e
    join cuidared.envejeciente_necesidad en using (envejeciente_id)
    join cuidared.necesidad n using (necesidad_id)
    join cuidared.tipo_necesidad t using (tipo_necesidad_id)
    join cuidared.prioridad p using (prioridad_id)
    where e.estado = 'activo' and e.consentimiento_retirado_en is null
      and cuidared_interno.acceso_operativo(e.cuenta_id)
      and en.estado = 'pendiente' and p.codigo = 'alta' and t.codigo is distinct from 'medicamentos'
      and not exists (select from cuidared.alerta_envejeciente a
        where a.fuente_necesidad_id = en.envejeciente_necesidad_id)
    order by e.envejeciente_id
  loop
    perform cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_hoy,'necesidad_prioritaria');
  end loop;
end;
$$;

commit;
