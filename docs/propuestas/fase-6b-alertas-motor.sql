-- Fase 6b · Fuentes, reconciliación idempotente y avisos internos.
-- Depende de fase 5 y 6a. Preparado para revisión, sin activación del proceso diario.
begin;

-- Estas definiciones proceden de la inspección de metadatos. En el modelo local de referencia no existen.
drop trigger if exists trg_envejeciente_riesgo_alerta on cuidared.envejeciente_riesgo;
drop trigger if exists trg_envejeciente_necesidad_alerta on cuidared.envejeciente_necesidad;
drop trigger if exists trg_detalle_visita_alerta on cuidared.detalle_visita;
drop trigger if exists trg_alerta_envejeciente_notificar on cuidared.alerta_envejeciente;
drop index if exists cuidared.ux_alerta_sistema_abierta;
do $$
declare
  v_firma text;
begin
  foreach v_firma in array array[
    'cuidared.fn_trg_alerta_por_visita()', 'cuidared.fn_trg_alerta_por_riesgo()', 'cuidared.fn_trg_alerta_por_necesidad()',
    'cuidared.fn_trg_alerta_notificar()', 'cuidared.fn_generar_alerta(uuid,text,smallint,text,text)',
    'cuidared.sp_generar_alertas_ausencia_visita()'
  ] loop
    if to_regprocedure(v_firma) is not null then
      execute format('revoke all on function %s from public, anon, authenticated', to_regprocedure(v_firma));
    end if;
  end loop;
end;
$$;

alter table cuidared.alerta_envejeciente
  add column sin_fuente_historica boolean not null default true;
-- Las migraciones no deducen la fuente de las alertas que ya existían.
alter table cuidared.alerta_envejeciente
  alter column sin_fuente_historica set default false,
  drop constraint if exists ck_alerta_env_resuelta,
  add constraint alerta_fuente_obligatoria_chk check (
    num_nonnulls(fuente_riesgo_id, fuente_necesidad_id, fuente_visita_id, fuente_perfil_id) = 1
    or (sin_fuente_historica and num_nonnulls(fuente_riesgo_id, fuente_necesidad_id, fuente_visita_id, fuente_perfil_id) = 0)
  ),
  add constraint alerta_resolucion_trazable_chk check (
    (not cierre_automatico and (estado <> 'resuelta' or usuario_atendio_id is not null)
      or cierre_automatico and estado = 'resuelta' and usuario_atendio_id is null and origen = 'sistema')
    and (estado <> 'resuelta' or (fecha_atencion is not null and nullif(btrim(accion_tomada), '') is not null))
  ) not valid;

create unique index alerta_fuente_riesgo_ux on cuidared.alerta_envejeciente (fuente_riesgo_id)
  where fuente_riesgo_id is not null;
create unique index alerta_fuente_necesidad_ux on cuidared.alerta_envejeciente (fuente_necesidad_id)
  where fuente_necesidad_id is not null;
create unique index alerta_fuente_visita_adulto_ux on cuidared.alerta_envejeciente (fuente_visita_id, envejeciente_id)
  where fuente_visita_id is not null;
create unique index alerta_fuente_perfil_ux on cuidared.alerta_envejeciente (fuente_perfil_id)
  where fuente_perfil_id is not null;

create function cuidared_interno.trg_alerta_fuente_consistente() returns trigger
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
    or (new.fuente_necesidad_id is not null and (v_tipo <> 'medicamento_pendiente' or not exists (
       select from cuidared.envejeciente_necesidad n where n.envejeciente_necesidad_id = new.fuente_necesidad_id
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

create trigger alerta_fuente_consistente before insert or update of envejeciente_id,tipo_alerta_id,fuente_riesgo_id,
  fuente_necesidad_id,fuente_visita_id,fuente_perfil_id,sin_fuente_historica on cuidared.alerta_envejeciente
  for each row execute function cuidared_interno.trg_alerta_fuente_consistente();

insert into cuidared.tipo_alerta(codigo,nombre) values
  ('riesgo_alto','Riesgo alto'),
  ('medicamento_pendiente','Medicamento pendiente'),
  ('ausencia_visitas','Seguimiento familiar sin visita')
on conflict(codigo) do nothing;

create function cuidared_interno.alerta_parametro(p_cuenta bigint, p_parametro text) returns text
language sql stable set search_path = '' as $$
  select coalesce(c.valor,p.valor)
  from cuidared.parametro p
  left join cuidared.configuracion_cuenta c on c.parametro_id = p.parametro_id and c.cuenta_id = p_cuenta
  where p.nombre = p_parametro
$$;

-- Último contacto efectivo verificable de la cuenta. Una visita de varios adultos aporta
-- una referencia distinta por adulto. Programadas y canceladas se excluyen.
create function cuidared_interno.alerta_ventana_sin_visita(p_adulto uuid, p_cuenta bigint, p_hoy date)
returns table (visita_id uuid, referencia date, dias integer, umbral integer)
language sql stable set search_path = '' as $$
  with ultima_visita as (
    select v.visita_id, v.fecha
    from cuidared.detalle_visita d join cuidared.visita v using (visita_id)
    where d.envejeciente_id = p_adulto and v.cuenta_id = p_cuenta and v.estado = 'completada'
      and v.fecha <= p_hoy
    order by v.fecha desc, coalesce(v.hora_fin, v.hora_inicio) desc nulls last,
      v.fecha_creacion desc, v.visita_id
    limit 1
  ), configuracion as (
    select cuidared_interno.alerta_parametro(p_cuenta,'dias_sin_visita_alerta') as valor
  )
  select u.visita_id, coalesce(u.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date),
    p_hoy - coalesce(u.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date),
    case when cuidared_interno.valor_parametro_valido('entero',c.valor) then c.valor::integer else 15 end
  from cuidared.envejeciente e cross join configuracion c left join ultima_visita u on true
  where e.envejeciente_id = p_adulto and e.cuenta_id = p_cuenta
$$;

create function cuidared_interno.alertas_fuentes_vigentes(p_adulto uuid, p_cuenta bigint, p_hoy date, p_tipo text)
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
  select 'ausencia_visitas','media',format('Han pasado más de %s días calendario desde el último contacto efectivo.',v.umbral),
    null,null,v.visita_id,case when v.visita_id is null then p_adulto end
  from cuidared_interno.alerta_ventana_sin_visita(p_adulto,p_cuenta,p_hoy) v
  where (p_tipo is null or p_tipo = 'ausencia_visitas') and v.dias > v.umbral
$$;

-- El índice único por fuente protege entre sesiones. El bloqueo por expediente también serializa
-- el cierre de alertas y evita generarlas concurrentemente con un retiro de consentimiento.
create function cuidared_interno.alertas_reconciliar_adulto(p_adulto uuid, p_hoy date, p_tipo text default null) returns integer
language plpgsql set search_path = '' as $$
declare
  v_cuenta bigint;
  v_cantidad integer;
begin
  if p_hoy is null or (p_tipo is not null and p_tipo not in ('riesgo_alto','medicamento_pendiente','ausencia_visitas')) then
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
      and t.codigo in ('riesgo_alto','medicamento_pendiente','ausencia_visitas')
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
  join cuidared.prioridad p on lower(p.nombre) = f.prioridad
  on conflict do nothing;
  get diagnostics v_cantidad = row_count;
  return v_cantidad;
end;
$$;

-- Los cambios del riesgo o de la necesidad alertan dentro de su propia transacción.
create function cuidared_interno.trg_alerta_reconciliar_fuente() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform cuidared_interno.alertas_reconciliar_adulto(new.envejeciente_id,cuidared_interno.hoy(),tg_argv[0]);
  return null;
end;
$$;

create trigger alertas_riesgo_vigente
  after insert or update of estado,nivel_riesgo_id on cuidared.envejeciente_riesgo
  for each row execute function cuidared_interno.trg_alerta_reconciliar_fuente('riesgo_alto');
create trigger alertas_medicamento_pendiente
  after insert or update of estado,necesidad_id on cuidared.envejeciente_necesidad
  for each row execute function cuidared_interno.trg_alerta_reconciliar_fuente('medicamento_pendiente');

create function cuidared_interno.trg_alerta_avisar() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_cuenta bigint;
  v_tipo text;
begin
  if new.origen <> 'sistema' or new.sin_fuente_historica then return null; end if;
  select e.cuenta_id into v_cuenta from cuidared.envejeciente e
    where e.envejeciente_id = new.envejeciente_id and e.estado = 'activo'
      and e.consentimiento_retirado_en is null;
  if not found then return null; end if;
  select codigo into v_tipo from cuidared.tipo_alerta where tipo_alerta_id = new.tipo_alerta_id;
  if not cuidared_interno.acceso_operativo(v_cuenta)
    or (cuidared_interno.alerta_es_prioritaria(v_tipo) and cuidared_interno.alerta_parametro(v_cuenta,'notificar_casos_prioritarios') = 'false') then
    return null;
  end if;
  insert into cuidared.notificacion (usuario_id,cuenta_id,alerta_envejeciente_id,mensaje)
  select distinct m.usuario_id,v_cuenta,new.alerta_envejeciente_id,
    case when v_tipo = 'ausencia_visitas' then 'Hay una alerta de seguimiento por revisar.'
         else 'Hay una alerta de caso prioritario por revisar.' end
  from cuidared.membresia m
  join cuidared_interno.membresia_activa(v_cuenta,m.usuario_id) vigente on vigente.membresia_id = m.membresia_id
  where m.cuenta_id = v_cuenta
    and (vigente.rol = 'coordinador' or (vigente.tipo = 'organizacion' and vigente.rol = 'administrador'))
    and cuidared_interno.tiene_permiso(v_cuenta,m.usuario_id,'alertas:ver')
    and cuidared_interno.alcanza_envejeciente(v_cuenta,new.envejeciente_id,m.usuario_id);
  return null;
end;
$$;

create trigger alertas_avisos_personales after insert on cuidared.alerta_envejeciente
  for each row execute function cuidared_interno.trg_alerta_avisar();

-- Invocación de operador o del dueño del trabajo diario. Nunca expuesta por la Data API.
create function cuidared_interno.alertas_evaluar_diario() returns integer
language plpgsql set search_path = '' as $$
declare
  v_adulto uuid;
  v_cantidad integer := 0;
  v_hoy date := cuidared_interno.hoy();
begin
  for v_adulto in select e.envejeciente_id from cuidared.envejeciente e
    where e.estado = 'activo' and e.consentimiento_retirado_en is null
      and cuidared_interno.acceso_operativo(e.cuenta_id)
    order by e.envejeciente_id
  loop
    v_cantidad := v_cantidad + cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_hoy);
  end loop;
  return v_cantidad;
end;
$$;

revoke all on function cuidared_interno.alerta_parametro(bigint,text),
  cuidared_interno.alerta_ventana_sin_visita(uuid,bigint,date),
  cuidared_interno.alertas_fuentes_vigentes(uuid,bigint,date,text),
  cuidared_interno.alertas_reconciliar_adulto(uuid,date,text),
  cuidared_interno.trg_alerta_fuente_consistente(),
  cuidared_interno.trg_alerta_reconciliar_fuente(),
  cuidared_interno.trg_alerta_avisar(),
  cuidared_interno.alertas_evaluar_diario() from public, anon, authenticated;

commit;
