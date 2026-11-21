-- CU-05, CU-06, CU-14 y CU-18: agenda de visitas, seguimiento público y evidencias privadas.
-- Conserva los cierres CUIDARED-008 (expedientes retirados) y CUIDARED-009 (sync de necesidades).
begin;
set local lock_timeout = '5s';

delete from cuidared.rol_permiso rp using cuidared.tipo_cuenta t
where rp.tipo_cuenta_id = t.tipo_cuenta_id and t.codigo = 'familia'
  and rp.accion in ('visitas:ver', 'visitas:programar', 'visitas:autorizar', 'visitas:registrar');

alter table cuidared.visita
  add column hora_fin_programada time,
  add column fecha_realizacion timestamptz,
  add column pendiente_autorizacion boolean not null default false,
  add column reprogramada_por uuid references cuidared.usuario(usuario_id),
  add column reprogramada_en timestamptz,
  add constraint ck_visita_ventana check (hora_fin_programada is null or hora_fin_programada > hora_programada);
update cuidared.visita v set fecha_realizacion = x.fecha
from (select visita_id, max(fecha_registro) fecha from cuidared.detalle_visita group by visita_id) x
where v.visita_id = x.visita_id and v.estado = 'completada';

create or replace function cuidared_interno.aspectos_visita() returns text[]
language sql immutable set search_path = '' as $$
  select array['alimentacion', 'medicamentos', 'higiene', 'vivienda', 'animo', 'movilidad', 'caidas']::text[]
$$;

create function cuidared_interno.fin_ventana(p_inicio time, p_fin time) returns time
language sql immutable set search_path = '' as $$
  select coalesce(p_fin, case when p_inicio >= time '23:30' then time '23:59' else p_inicio + interval '30 minutes' end)
$$;

create function cuidared_interno.exigir_horario_visita(
  p_cuenta bigint, p_fecha date, p_inicio time, p_fin time,
  p_personas uuid[], p_adultos uuid[], p_excluir uuid default null
) returns void language plpgsql set search_path = '' as $$
begin
  if p_inicio is null or p_fin is null or p_fin <= p_inicio
     or p_fecha < cuidared_interno.hoy()
     or (p_fecha = cuidared_interno.hoy() and p_inicio < cuidared_interno.hora_local()) then
    raise invalid_parameter_value;
  end if;
  -- Serializa la reserva de ventanas de esta cuenta, incluidas dos aprobaciones simultáneas.
  perform pg_advisory_xact_lock(hashtextextended('agenda-visita:' || p_cuenta, 0));
  if exists (
    select from cuidared.visita v
    join cuidared.registro_visita r on r.visita_id = v.visita_id
    where v.cuenta_id = p_cuenta and v.fecha = p_fecha and v.estado in ('programada', 'en_curso')
      and v.visita_id is distinct from p_excluir and r.usuario_id = any(p_personas)
      and v.hora_programada < p_fin and cuidared_interno.fin_ventana(v.hora_programada, v.hora_fin_programada) > p_inicio
  ) then raise exception 'CR_PARTICIPANTE_OCUPADO' using errcode = 'P0001'; end if;
  if exists (
    select from cuidared.visita v
    join cuidared.detalle_visita d on d.visita_id = v.visita_id
    where v.cuenta_id = p_cuenta and v.fecha = p_fecha and v.estado in ('programada', 'en_curso')
      and v.visita_id is distinct from p_excluir and d.envejeciente_id = any(p_adultos)
      and v.hora_programada < p_fin and cuidared_interno.fin_ventana(v.hora_programada, v.hora_fin_programada) > p_inicio
  ) then raise exception 'CR_ADULTO_OCUPADO' using errcode = 'P0001'; end if;
end $$;

create function cuidared_api.api_reprogramar_visita(p_cuenta_id bigint, p_visita_id uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar')->>'usuario_id')::uuid;
  v_visita cuidared.visita;
  v_fecha date := cuidared_interno.v_fecha(p_datos->'fecha');
  v_inicio time := cuidared_interno.v_hora(p_datos->'hora');
  v_fin time := cuidared_interno.v_hora(p_datos->'hora_fin_programada');
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['fecha', 'hora', 'hora_fin_programada'] <> '{}'::jsonb then raise invalid_parameter_value; end if;
  if not cuidared_interno.visita_visible(p_cuenta_id, p_visita_id, v_uid) then raise no_data_found; end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  perform pg_advisory_xact_lock(hashtextextended(p_visita_id::text, 0));
  v_visita := cuidared_interno.bloquear_visita(p_visita_id);
  if v_visita.estado <> 'programada' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if row(v_visita.fecha, v_visita.hora_programada, v_visita.hora_fin_programada) is distinct from row(v_fecha, v_inicio, v_fin) then
    perform cuidared_interno.exigir_horario_visita(p_cuenta_id, v_fecha, v_inicio, v_fin,
      array(select r.usuario_id from cuidared.registro_visita r where r.visita_id = p_visita_id),
      array(select d.envejeciente_id from cuidared.detalle_visita d where d.visita_id = p_visita_id), p_visita_id);
    update cuidared.visita set fecha = v_fecha, hora_programada = v_inicio, hora_fin_programada = v_fin,
      reprogramada_por = v_uid, reprogramada_en = now(), fecha_actualizacion = now() where visita_id = p_visita_id;
  end if;
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $$;
revoke all on function cuidared_api.api_reprogramar_visita(bigint,uuid,jsonb) from public, anon;
grant execute on function cuidared_api.api_reprogramar_visita(bigint,uuid,jsonb) to authenticated;

alter table cuidared.evidencia_visita
  add column estado_validacion text not null default 'pendiente' check (estado_validacion in ('pendiente','validada','rechazada')),
  add column validada_por uuid references cuidared.usuario(usuario_id),
  add column revisada_en timestamptz,
  add column motivo_rechazo text;

create function cuidared_api.api_visita_revisar_evidencia(p_cuenta_id bigint, p_visita_id uuid, p_evidencia_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_contexto jsonb := cuidared_interno.exigir(p_cuenta_id, 'evidencias:validar');
  v_uid uuid := (v_contexto->>'usuario_id')::uuid;
  v_estado text := case when p_motivo is null then 'validada' else 'rechazada' end;
  v_evidencia cuidared.evidencia_visita;
begin
  if v_contexto->>'rol' is distinct from 'coordinador' then raise insufficient_privilege; end if;
  if not cuidared_interno.evidencia_visita_acceso(p_cuenta_id, p_visita_id, v_uid, false) then raise no_data_found; end if;
  if p_motivo is not null and length(btrim(p_motivo)) not between 5 and 200 then raise invalid_parameter_value; end if;
  perform 1 from cuidared.visita where visita_id = p_visita_id and cuenta_id = p_cuenta_id for update;
  select * into v_evidencia from cuidared.evidencia_visita
    where visita_id = p_visita_id and evidencia_visita_id = p_evidencia_id for update;
  if not found then raise no_data_found; end if;
  if v_evidencia.registrada_por = v_uid then raise insufficient_privilege; end if;
  if v_evidencia.estado_validacion <> 'pendiente'
     and (v_evidencia.estado_validacion <> v_estado or v_evidencia.motivo_rechazo is distinct from btrim(p_motivo)) then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if v_evidencia.estado_validacion = 'pendiente' then
    update cuidared.evidencia_visita set estado_validacion = v_estado, validada_por = v_uid,
      revisada_en = now(), motivo_rechazo = btrim(p_motivo) where evidencia_visita_id = p_evidencia_id;
  end if;
  return jsonb_build_object('evidencia_id', p_evidencia_id, 'estado_validacion', v_estado);
end $$;
revoke all on function cuidared_api.api_visita_revisar_evidencia(bigint,uuid,uuid,text) from public, anon;
grant execute on function cuidared_api.api_visita_revisar_evidencia(bigint,uuid,uuid,text) to authenticated;

create function cuidared_interno.trg_visita_cierre() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.estado = 'completada' and old.estado <> 'completada' then
    if exists (select from cuidared.evidencia_visita where visita_id = new.visita_id and estado_validacion = 'pendiente') then
      raise exception 'CR_EVIDENCIA_VISITA_PENDIENTE' using errcode = 'P0001';
    end if;
    new.fecha_realizacion := coalesce(new.fecha_realizacion, now());
  end if;
  return new;
end $$;
create trigger visita_cierre before update of estado on cuidared.visita
for each row execute function cuidared_interno.trg_visita_cierre();

create function cuidared_interno.trg_visita_fecha_offline() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.entidad = 'visita' and new.tipo = 'registrar' and (new.resultado = 'aplicada' or new.gana = 'local') then
    update cuidared.visita v set fecha_realizacion = least(new.actualizado_en_cliente, now())
    where v.visita_id = new.registro_id and v.cuenta_id = new.cuenta_id and v.estado = 'completada';
  end if;
  return new;
end $$;
create trigger visita_fecha_offline after insert or update on cuidared.operacion_sync
for each row execute function cuidared_interno.trg_visita_fecha_offline();

revoke all on function cuidared_interno.fin_ventana(time,time),
  cuidared_interno.exigir_horario_visita(bigint,date,time,time,uuid[],uuid[],uuid),
  cuidared_interno.trg_visita_cierre(), cuidared_interno.trg_visita_fecha_offline() from public, anon, authenticated;

-- Conserva los contratos existentes y amplía las ventanas, el responsable y el checklist.

create or replace function cuidared_interno.visita_json(p_visita_id uuid, p_usuario_id uuid, p_detalle boolean default true) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'visita_id', v.visita_id,
    'fecha', v.fecha,
    'hora_programada', cuidared_interno.hhmm(v.hora_programada),
    'hora_fin_programada', cuidared_interno.hhmm(v.hora_fin_programada),
    'fecha_realizacion', v.fecha_realizacion,
    'pendiente_autorizacion', v.pendiente_autorizacion,
    'reprogramada_en', v.reprogramada_en,
    'hora_inicio', cuidared_interno.hhmm(v.hora_inicio),
    'hora_fin', cuidared_interno.hhmm(v.hora_fin),
    'razon', v.razon,
    'estado', v.estado,
    'origen', v.origen,
    'notas', v.notas,
    'checklist', to_jsonb(v.checklist),
    'motivo_cancelacion', v.motivo_cancelacion,
    'creada_por', v.creada_por,
    'autorizada_por', (
      select jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos)
      from cuidared.registro_visita r join cuidared.usuario u on u.usuario_id = r.autorizada_por_usuario_id
      where r.visita_id = v.visita_id order by r.usuario_id limit 1),
    'participantes', coalesce((
      select jsonb_agg(jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos)
                       order by u.apellidos, u.nombres, u.usuario_id)
      from cuidared.registro_visita r join cuidared.usuario u on u.usuario_id = r.usuario_id
      where r.visita_id = v.visita_id), '[]'::jsonb),
    'adultos', coalesce((
      select jsonb_agg(
        case when p_detalle then jsonb_build_object(
               'envejeciente_id', e.envejeciente_id, 'nombres', e.nombres, 'apellidos', e.apellidos,
               'estado_general', d.estado_general, 'observacion', d.observacion, 'fecha_registro', d.fecha_registro)
             else jsonb_build_object('envejeciente_id', e.envejeciente_id, 'nombres', e.nombres, 'apellidos', e.apellidos) end
        order by e.apellidos, e.nombres, e.envejeciente_id)
      from cuidared.detalle_visita d
      join cuidared.envejeciente e on e.envejeciente_id = d.envejeciente_id
      where d.visita_id = v.visita_id
        and (cuidared_interno.es_gestor(v.cuenta_id, p_usuario_id)
             or cuidared_interno.alcanza_envejeciente(v.cuenta_id, d.envejeciente_id, p_usuario_id))), '[]'::jsonb),
    'visitante', (select jsonb_build_object('nombre', s.visitante_nombres || ' ' || s.visitante_apellidos)
                  from cuidared.solicitud_visita s where s.solicitud_visita_id = v.solicitud_visita_id),
    'fecha_creacion', v.fecha_creacion,
    'fecha_actualizacion', v.fecha_actualizacion)
  from cuidared.visita v where v.visita_id = p_visita_id
$$;

create or replace function cuidared_api.api_programar_visita(p_cuenta_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_hoy date := cuidared_interno.hoy();
  v_fecha date;
  v_hora time;
  v_fin time;
  v_razon text;
  v_autorizar boolean;
  v_notas text;
  v_adultos uuid[];
  v_parts uuid[];
  v_id uuid := gen_random_uuid();
  v_a uuid;
  v_p uuid;
  v_m record;
  v_estado text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  -- Programar equivale a autorizar: solo programa un usuario principal.
  if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'visitas:autorizar') then raise insufficient_privilege; end if;
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['fecha', 'hora_programada', 'hora_fin_programada', 'autorizar', 'razon', 'notas', 'envejeciente_ids', 'participante_ids'] <> '{}'::jsonb
     or (p_datos ? 'autorizar' and jsonb_typeof(p_datos->'autorizar') <> 'boolean') then
    raise invalid_parameter_value;
  end if;
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hora := cuidared_interno.v_hora(p_datos->'hora_programada');
  if v_fecha < v_hoy or (v_fecha = v_hoy and v_hora < cuidared_interno.hora_local()) then
    raise invalid_parameter_value;
  end if;
  v_fin := cuidared_interno.fin_ventana(v_hora, cuidared_interno.v_hora(p_datos->'hora_fin_programada', false));
  v_razon := cuidared_interno.v_texto(p_datos->'razon', 3, 120);
  v_autorizar := coalesce((p_datos->>'autorizar')::boolean, true);
  v_notas := cuidared_interno.v_texto(p_datos->'notas', 1, 300, false);
  v_adultos := cuidared_interno.v_uuids(p_datos->'envejeciente_ids', 1, 4);
  v_parts := cuidared_interno.v_uuids(p_datos->'participante_ids', 1, 3);
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);

  -- Adultos: de la cuenta y al alcance de quien programa. Otra cuenta e inexistente responden igual (42501).
  foreach v_a in array v_adultos loop
    perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:programar', v_a);
    select e.estado into v_estado from cuidared.envejeciente e where e.envejeciente_id = v_a;
    if v_estado <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  end loop;
  -- Participantes: miembros activos con rol permitido y sin otra visita a esa hora.
  foreach v_p in array v_parts loop
    select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_p);
    if not found or v_m.rol not in ('cuidador', 'voluntario')
       or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
      raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
    end if;
  end loop;

  perform cuidared_interno.exigir_horario_visita(p_cuenta_id, v_fecha, v_hora, v_fin, v_parts, v_adultos);
  insert into cuidared.visita (visita_id, cuenta_id, fecha, hora_programada, hora_fin_programada, razon, estado, origen, creada_por, notas, pendiente_autorizacion)
    values (v_id, p_cuenta_id, v_fecha, v_hora, v_fin, v_razon, 'programada', 'interna', v_uid, v_notas, not v_autorizar);
  foreach v_p in array v_parts loop
    insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id) values (v_id, v_p, case when v_autorizar then v_uid end);
    select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_p);
    if v_autorizar then
      foreach v_a in array v_adultos loop
        -- Si falta un vínculo vigente, 3b abre un nuevo periodo y registra a quien programa como autorizador (RF-12/RF-13).
        if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_a, v_p) then
          if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar') then
            raise insufficient_privilege;
          end if;
          perform cuidared_interno.seg_vincular(p_cuenta_id, v_a, v_p,
            case v_m.rol when 'cuidador' then 'cuidador_asignado' else 'voluntario_asignado' end, v_uid);
        end if;
      end loop;
    end if;
  end loop;
  insert into cuidared.detalle_visita (visita_id, envejeciente_id) select v_id, a from unnest(v_adultos) as a;
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $$;

create or replace function cuidared_api.api_autorizar_solicitud_visita(p_cuenta_id bigint, p_solicitud_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_s record;
  v_env uuid;
  v_fecha date;
  v_hora time;
  v_fin time;
  v_responsable uuid;
  v_m record;
  v_hoy date := cuidared_interno.hoy();
  v_estado text;
  v_id uuid := gen_random_uuid();
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_solicitud_id is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  perform cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  select * into v_s from cuidared.solicitud_visita where solicitud_visita_id = p_solicitud_id and cuenta_id = p_cuenta_id for update;
  if not found then raise no_data_found; end if;
  if v_s.estado::text <> 'pendiente' then raise exception 'CR_SOLICITUD_REVISADA' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['envejeciente_id', 'fecha', 'hora', 'hora_fin_programada', 'participante_id'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  v_env := cuidared_interno.v_uuid(p_datos->'envejeciente_id');
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hora := cuidared_interno.v_hora(p_datos->'hora');
  if v_fecha < v_hoy or (v_fecha = v_hoy and v_hora < cuidared_interno.hora_local()) then
    raise invalid_parameter_value;
  end if;
  -- El adulto lo confirma quien autoriza: de la cuenta (otra cuenta e inexistente responden igual, 42501) y activo.
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:autorizar', v_env);
  select e.estado into v_estado from cuidared.envejeciente e where e.envejeciente_id = v_env;
  if v_estado <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;

  v_fin := cuidared_interno.fin_ventana(v_hora, cuidared_interno.v_hora(p_datos->'hora_fin_programada', false));
  v_responsable := coalesce(cuidared_interno.v_uuid(p_datos->'participante_id', false), v_uid);
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_responsable);
  if not found or (v_m.rol not in ('voluntario', 'cuidador') and
     not (v_m.rol = 'coordinador' and v_responsable = v_uid and not (p_datos ? 'participante_id')))
     or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
  end if;
  perform cuidared_interno.exigir_horario_visita(p_cuenta_id, v_fecha, v_hora, v_fin, array[v_responsable], array[v_env]);
  if v_m.rol in ('cuidador', 'voluntario') and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_responsable) then
    if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar') then raise insufficient_privilege; end if;
    perform cuidared_interno.seg_vincular(p_cuenta_id, v_env, v_responsable,
      case v_m.rol when 'cuidador' then 'cuidador_asignado' else 'voluntario_asignado' end, v_uid);
  end if;

  insert into cuidared.visita (visita_id, cuenta_id, fecha, hora_programada, hora_fin_programada, razon, estado, origen, creada_por, solicitud_visita_id)
    values (v_id, p_cuenta_id, v_fecha, v_hora, v_fin, btrim(left(v_s.motivo, 120)), 'programada', 'solicitud', v_uid, p_solicitud_id);
  insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id) values (v_id, v_responsable, v_uid);
  insert into cuidared.detalle_visita (visita_id, envejeciente_id) values (v_id, v_env);
  update cuidared.solicitud_visita
    set estado = 'autorizada', envejeciente_id = v_env, revisada_por = v_uid, revisada_en = now(), visita_id = v_id
    where solicitud_visita_id = p_solicitud_id;
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $$;

create or replace function cuidared_interno.registrar_visita_realizada(p_cuenta_id bigint, p_usuario_id uuid, p_visita_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_m record;
  v_v cuidared.visita;
  v_id uuid;
  v_hoy date := cuidared_interno.hoy();
  v_ahora time := cuidared_interno.hora_local();
  v_fecha date;
  v_ini time;
  v_fin time;
  v_ini_p time;
  v_fin_p time;
  v_checklist text[] := '{}'::text[];
  v_item jsonb;
  v_det jsonb;
  v_detalles jsonb := '[]'::jsonb;
  v_ids uuid[] := '{}';
  v_env uuid;
  v_eg text;
  v_obs text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_usuario_id is null or p_visita_id is null
     or jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['hora_inicio', 'hora_fin', 'checklist', 'detalles'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id);
  if not found or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise insufficient_privilege;
  end if;
  if not cuidared_interno.acceso_operativo(p_cuenta_id) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;

  -- Entrada (se valida completa antes de tocar datos).
  if jsonb_typeof(p_datos->'detalles') is distinct from 'array'
     or jsonb_array_length(p_datos->'detalles') not between 1 and 4 then
    raise invalid_parameter_value;
  end if;
  for v_det in select e.value from jsonb_array_elements(p_datos->'detalles') as e loop
    if jsonb_typeof(v_det) is distinct from 'object'
       or v_det - array['envejeciente_id', 'estado_general', 'observacion'] <> '{}'::jsonb then
      raise invalid_parameter_value;
    end if;
    v_env := cuidared_interno.v_uuid(v_det->'envejeciente_id');
    if v_env = any (v_ids) then raise invalid_parameter_value; end if;
    v_ids := array_append(v_ids, v_env);
    v_eg := cuidared_interno.v_texto(v_det->'estado_general', 1, 30, false);
    if v_m.rol = 'voluntario' and v_eg is not null then raise invalid_parameter_value; end if;
    if v_eg is null then
      -- Registro mínimo: solo el Voluntario puede omitir el estado general.
      if v_m.rol <> 'voluntario' then raise invalid_parameter_value; end if;
    elsif v_eg not in ('estable', 'requiere_atencion', 'situacion_critica') then
      raise invalid_parameter_value;
    end if;
    v_obs := cuidared_interno.v_texto(v_det->'observacion', 3, 1000);
    v_detalles := v_detalles || jsonb_build_array(
      jsonb_build_object('envejeciente_id', v_env, 'estado_general', v_eg, 'observacion', v_obs));
  end loop;
  if p_datos ? 'checklist' and jsonb_typeof(p_datos->'checklist') <> 'null' then
    if jsonb_typeof(p_datos->'checklist') <> 'array' or jsonb_array_length(p_datos->'checklist') > cardinality(cuidared_interno.aspectos_visita()) then
      raise invalid_parameter_value;
    end if;
    for v_item in select e.value from jsonb_array_elements(p_datos->'checklist') as e loop
      if jsonb_typeof(v_item) <> 'string' or not ((v_item #>> '{}') = any (cuidared_interno.aspectos_visita()))
         or (v_item #>> '{}') = any (v_checklist) then
        raise invalid_parameter_value;
      end if;
      v_checklist := array_append(v_checklist, v_item #>> '{}');
    end loop;
  end if;
  v_ini_p := cuidared_interno.v_hora(p_datos->'hora_inicio', false);
  v_fin_p := cuidared_interno.v_hora(p_datos->'hora_fin', false);

  v_id := p_visita_id;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id::text, 0));
  v_v := cuidared_interno.bloquear_visita(v_id);
  if v_v.visita_id is null or v_v.cuenta_id is distinct from p_cuenta_id then
    raise no_data_found;
  end if;

  perform cuidared_interno.exigir_operar_visita(p_cuenta_id, v_id, p_usuario_id);
    if v_v.estado::text = 'completada' then
      return jsonb_build_object('visita_id', v_id, 'creada', false, 'ya_registrada', true, 'estado', 'completada');
    end if;
    if v_v.estado::text = 'cancelada' then
      raise exception 'CR_VISITA_CERRADA' using errcode = 'P0001';
    end if;
    if v_v.fecha > v_hoy then
      raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
    end if;
    -- Los detalles cubren exactamente los adultos de la visita y el usuario alcanza a cada uno.
    if (select array_agg(d.envejeciente_id order by d.envejeciente_id) from cuidared.detalle_visita d where d.visita_id = v_id)
       is distinct from (select array_agg(x order by x) from unnest(v_ids) as x) then
      raise invalid_parameter_value;
    end if;
  v_fecha := v_v.fecha;

  -- Horas: las indicadas; si faltan, el inicio registrado (o programado) y, si la visita es de hoy, la hora actual.
  v_fin := coalesce(v_fin_p, case when v_fecha = v_hoy then v_ahora end);
  v_ini := coalesce(v_ini_p, v_v.hora_inicio);
  if v_ini is null and v_v.hora_programada is not null
     and (v_fin is null or v_v.hora_programada <= v_fin) then
    v_ini := v_v.hora_programada;
  end if;
  v_ini := coalesce(v_ini, v_fin);
  if v_ini is not null and v_fin is not null and v_fin < v_ini then
    raise invalid_parameter_value;
  end if;

    update cuidared.visita
      set estado = 'completada', hora_inicio = v_ini, hora_fin = v_fin, checklist = v_checklist, fecha_actualizacion = now()
      where visita_id = v_id;
    update cuidared.detalle_visita d
      set estado_general = x.estado_general, observacion = x.observacion, registrado_por = p_usuario_id, fecha_registro = now()
      from jsonb_to_recordset(v_detalles) as x(envejeciente_id uuid, estado_general text, observacion text)
      where d.visita_id = v_id and d.envejeciente_id = x.envejeciente_id;

  if exists (select 1 from jsonb_to_recordset(v_detalles) as x(envejeciente_id uuid, estado_general text, observacion text)
             where x.estado_general = 'situacion_critica') then
    perform cuidared_interno.notificar_situacion_critica(p_cuenta_id, v_id, p_usuario_id);
  end if;
  return jsonb_build_object('visita_id', v_id, 'ya_registrada', false, 'estado', 'completada');
end $$;

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
    'hora_fin_programada', cuidared_interno.hhmm(v.hora_fin_programada),
    'reprogramada', coalesce(v.reprogramada_en is not null
      or v.fecha <> s.fecha_propuesta or v.hora_programada <> s.hora_propuesta, false),
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


create or replace function cuidared_interno.evidencia_visita_acceso(p_cuenta bigint, p_visita uuid, p_uid uuid, p_subir boolean)
returns boolean language sql stable set search_path = '' as $$
  select cuidared_interno.acceso_operativo(p_cuenta)
    and exists (select 1 from cuidared.visita v where v.visita_id = p_visita and v.cuenta_id = p_cuenta
                and v.hora_programada is not null and v.estado in ('en_curso','completada') and (not p_subir or v.estado = 'en_curso'))
    and exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita)
    and not exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita
                    and not cuidared_interno.alcanza_envejeciente(p_cuenta, d.envejeciente_id, p_uid))
    and (
      (cuidared_interno.tiene_permiso(p_cuenta, p_uid, 'visitas:registrar')
       and (not p_subir or exists (select from cuidared_interno.membresia_activa(p_cuenta, p_uid) m where m.rol = 'cuidador'))
       and exists (select 1 from cuidared.registro_visita r where r.visita_id = p_visita
                   and r.usuario_id = p_uid and r.autorizada_por_usuario_id is not null))
      or (not p_subir and cuidared_interno.tiene_permiso(p_cuenta, p_uid, 'visitas:autorizar'))
    )
$$;

create or replace function cuidared_api.api_visita_listar_evidencias(p_cuenta_id bigint, p_visita_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := cuidared_interno.exigir_sesion();
begin
  if not cuidared_interno.evidencia_visita_acceso(p_cuenta_id, p_visita_id, v_uid, false) then raise insufficient_privilege; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'evidencia_id', evidencia_visita_id, 'nombre_archivo', nombre_archivo, 'ruta', ruta,
    'estado_validacion', estado_validacion, 'motivo_rechazo', motivo_rechazo
  ) order by fecha_registro, evidencia_visita_id) from cuidared.evidencia_visita where visita_id = p_visita_id), '[]'::jsonb);
end $$;

-- Cola transaccional. El correo se toma de la solicitud al reclamarlo y nunca llega al cliente público.
create table cuidared.aviso_visita (
  aviso_id uuid primary key default gen_random_uuid(),
  solicitud_id uuid not null references cuidared.solicitud_visita(solicitud_visita_id),
  evento text not null check (evento in ('autorizada','rechazada','reprogramada','cancelada','recordatorio')),
  cita timestamptz,
  fin time,
  disponible_en timestamptz not null default now(),
  intentos integer not null default 0,
  reclamo uuid,
  cierre text check (cierre in ('enviado','fallido','omitido'))
);
alter table cuidared.aviso_visita enable row level security;
revoke all on cuidared.aviso_visita from public, anon, authenticated;
create index ix_aviso_visita_pendiente on cuidared.aviso_visita(disponible_en, aviso_id) where cierre is null;
create index ix_aviso_visita_solicitud on cuidared.aviso_visita(solicitud_id) where cierre is null;

create function cuidared_interno.encolar_aviso_visita(p_solicitud uuid, p_evento text, p_cita timestamptz, p_fin time)
returns void language plpgsql set search_path = '' as $$
begin
  if not exists (select from cuidared.solicitud_visita where solicitud_visita_id = p_solicitud and visitante_correo is not null) then return; end if;
  update cuidared.aviso_visita set cierre = 'omitido', reclamo = null
    where solicitud_id = p_solicitud and evento = 'recordatorio' and cierre is null;
  if p_evento = 'realizada' then return; end if;
  insert into cuidared.aviso_visita(solicitud_id, evento, cita, fin) values(p_solicitud, p_evento, p_cita, p_fin);
  if p_evento in ('autorizada','reprogramada') and p_cita > now() + interval '10 minutes' then
    insert into cuidared.aviso_visita(solicitud_id, evento, cita, fin, disponible_en)
    values(p_solicitud, 'recordatorio', p_cita, p_fin, greatest(now() + interval '10 minutes', p_cita - interval '24 hours'));
  end if;
end $$;

create function cuidared_interno.trg_aviso_solicitud() returns trigger language plpgsql set search_path = '' as $$
declare v_visita cuidared.visita;
begin
  if new.estado = old.estado then return new; end if;
  select * into v_visita from cuidared.visita where visita_id = new.visita_id and cuenta_id = new.cuenta_id;
  perform cuidared_interno.encolar_aviso_visita(new.solicitud_visita_id,
    case when new.estado = 'autorizada' and (new.fecha_propuesta <> v_visita.fecha or new.hora_propuesta <> v_visita.hora_programada)
      then 'reprogramada' else new.estado end,
    (v_visita.fecha + v_visita.hora_programada) at time zone 'America/Santo_Domingo', v_visita.hora_fin_programada);
  return new;
end $$;
create trigger solicitud_aviso after update of estado on cuidared.solicitud_visita
for each row execute function cuidared_interno.trg_aviso_solicitud();

create function cuidared_interno.trg_aviso_reprogramacion() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.solicitud_visita_id is not null and old.reprogramada_en is distinct from new.reprogramada_en then
    perform cuidared_interno.encolar_aviso_visita(new.solicitud_visita_id, 'reprogramada',
      (new.fecha + new.hora_programada) at time zone 'America/Santo_Domingo', new.hora_fin_programada);
  end if;
  return new;
end $$;
create trigger visita_aviso_reprogramacion after update of reprogramada_en on cuidared.visita
for each row execute function cuidared_interno.trg_aviso_reprogramacion();

create function cuidared_api.api_visita_reclamar_avisos() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_reclamo uuid := gen_random_uuid(); v_avisos jsonb;
begin
  update cuidared.aviso_visita set cierre = 'omitido', reclamo = null
    where cierre is null and evento = 'recordatorio' and cita <= now() and disponible_en <= now();
  with elegidos as (
      select a.aviso_id, a.disponible_en from cuidared.aviso_visita a
      where a.cierre is null and a.disponible_en <= now()
      order by a.disponible_en, a.aviso_id limit 10 for update skip locked
    ), tomados as (
      update cuidared.aviso_visita a set intentos = a.intentos + 1,
        reclamo = v_reclamo, disponible_en = now() + interval '5 minutes'
      from elegidos e where e.aviso_id = a.aviso_id returning a.*
    )
    select coalesce(jsonb_agg(jsonb_build_object('id', a.aviso_id, 'reclamo', a.reclamo,
      'evento', a.evento, 'correo', s.visitante_correo, 'organizacion', c.nombre, 'cita', a.cita,
      'fin', cuidared_interno.hhmm(a.fin)) order by e.disponible_en, a.aviso_id), '[]'::jsonb) into v_avisos
    from tomados a join cuidared.solicitud_visita s on s.solicitud_visita_id = a.solicitud_id
    join elegidos e on e.aviso_id = a.aviso_id
    join cuidared.cuenta c on c.cuenta_id = s.cuenta_id;
  return v_avisos;
end $$;

create function cuidared_api.api_visita_cerrar_aviso(p_id uuid, p_reclamo uuid, p_resultado text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_resultado is null or p_resultado not in ('enviado','fallido','reintentar') then raise invalid_parameter_value; end if;
  update cuidared.aviso_visita
    set cierre = case when p_resultado <> 'reintentar' then p_resultado when intentos >= 7 then 'fallido' end,
      reclamo = null, disponible_en = now() + make_interval(mins => least(60, 2 ^ least(intentos, 6))::integer)
    where aviso_id = p_id and reclamo = p_reclamo and cierre is null;
end $$;
revoke all on function cuidared_interno.encolar_aviso_visita(uuid,text,timestamptz,time),
  cuidared_interno.trg_aviso_solicitud(), cuidared_interno.trg_aviso_reprogramacion() from public, anon, authenticated;
revoke all on function cuidared_api.api_visita_reclamar_avisos(), cuidared_api.api_visita_cerrar_aviso(uuid,uuid,text)
  from public, anon, authenticated;
grant usage on schema cuidared_api to service_role;
grant execute on function cuidared_api.api_visita_reclamar_avisos(), cuidared_api.api_visita_cerrar_aviso(uuid,uuid,text) to service_role;

alter table cuidared.tarea_agenda add column visita_id uuid references cuidared.visita(visita_id);
create index ix_tarea_agenda_visita on cuidared.tarea_agenda(visita_id) where visita_id is not null;

create or replace function cuidared_interno.tarea_json(p_tarea_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'visita_id', t.visita_id, 'tarea_id', t.tarea_agenda_id,
    'envejeciente_id', t.envejeciente_id,
    'envejeciente_nombre', btrim(e.nombres::text || ' ' || e.apellidos::text),
    'cuidador_id', t.cuidador_id::text,
    'cuidador_nombre', btrim(u.nombres::text || ' ' || u.apellidos::text),
    'indicacion_medica_id', t.indicacion_medica_id,
    'indicacion_titulo', i.titulo,
    'prioridad_id', t.prioridad_id,
    'prioridad', p.nombre,
    'titulo', t.titulo,
    'fecha_programada', t.fecha_programada,
    'hora_programada', to_char(t.hora_programada, 'HH24:MI'),
    'estado', t.estado,
    'es_historica', t.es_historica,
    'requiere_evidencia', t.requiere_evidencia,
    'es_repetitiva', t.es_repetitiva,
    'serie_id', t.serie_id,
    'motivo_cancelacion', t.motivo_cancelacion,
    'completada_por', t.completada_por,
    'fecha_completada', t.fecha_completada,
    'evidencias', jsonb_build_object(
      'pendientes', (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'pendiente'),
      'validadas', (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'validada'),
      'rechazadas', (select count(*) from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'rechazada')),
    -- Motivo visible para el cuidador: la tarea volvió a pendiente y espera una evidencia nueva.
    'ultimo_motivo_rechazo', case when t.estado::text = 'pendiente'
        and not exists (select 1 from cuidared.evidencia v where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text in ('pendiente', 'validada'))
      then (select v.motivo_rechazo from cuidared.evidencia v
            where v.tarea_agenda_id = t.tarea_agenda_id and v.estado_validacion::text = 'rechazada'
            order by v.fecha_validacion desc, v.evidencia_id limit 1) end,
    'usuario_creador_id', t.usuario_creador_id,
    'fecha_creacion', t.fecha_creacion,
    'fecha_actualizacion', t.fecha_actualizacion)
  from cuidared.tarea_agenda t
  join cuidared.envejeciente e on e.envejeciente_id = t.envejeciente_id
  join cuidared.cuidador c on c.cuidador_id = t.cuidador_id
  join cuidared.usuario u on u.usuario_id = c.usuario_id
  join cuidared.prioridad p on p.prioridad_id = t.prioridad_id
  left join cuidared.indicacion_medica i on i.indicacion_medica_id = t.indicacion_medica_id
    and i.envejeciente_id = t.envejeciente_id
  where t.tarea_agenda_id = p_tarea_id
$$;

create or replace function cuidared_api.api_tarea_crear(p_cuenta_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_visita uuid;
  v_env uuid; v_cuidador bigint; v_titulo text; v_indicacion uuid; v_prioridad smallint;
  v_fecha date; v_hora time; v_evidencia boolean;
  v_rep jsonb; v_frec text; v_hasta date; v_dias integer[]; v_fechas date[];
  v_e record;
  v_usuario_cuidador uuid;
  v_serie uuid; v_id uuid; v_ids uuid[] := array[]::uuid[]; v_f date;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_uid := (cuidared_interno.exigir(p_cuenta_id, 'agenda:gestionar')->>'usuario_id')::uuid;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos - array['envejeciente_id', 'visita_id', 'cuidador_id', 'titulo',
       'indicacion_medica_id', 'prioridad_id', 'fecha_programada', 'hora_programada', 'requiere_evidencia', 'repeticion'] <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  begin
    v_env := cuidared_interno.agenda_dato(p_datos, 'envejeciente_id', 'string')::uuid;
    v_visita := cuidared_interno.v_uuid(p_datos->'visita_id', false);
    v_cuidador := cuidared_interno.agenda_dato(p_datos, 'cuidador_id', 'string')::bigint;
    v_titulo := cuidared_interno.agenda_texto(p_datos, 'titulo', 3, 80);
    v_indicacion := cuidared_interno.agenda_dato(p_datos, 'indicacion_medica_id', 'string', false)::uuid;
    v_prioridad := cuidared_interno.agenda_dato(p_datos, 'prioridad_id', 'number')::smallint;
    v_fecha := cuidared_interno.agenda_fecha(p_datos, 'fecha_programada');
    v_hora := cuidared_interno.agenda_hora(p_datos, 'hora_programada');
    v_evidencia := cuidared_interno.agenda_dato(p_datos, 'requiere_evidencia', 'boolean')::boolean;
  exception when data_exception then raise invalid_parameter_value;
  end;
  if v_fecha < cuidared_interno.hoy() then raise invalid_parameter_value; end if;

  -- Repetición (propuesta técnica D12): diaria o semanal con fecha de fin; máximo 60 ocurrencias.
  v_rep := p_datos -> 'repeticion';
  if v_rep is null or jsonb_typeof(v_rep) = 'null' then
    v_fechas := array[v_fecha];
  else
    begin
      if jsonb_typeof(v_rep) <> 'object' or v_rep - array['frecuencia', 'dias_semana', 'hasta'] <> '{}'::jsonb then
        raise invalid_parameter_value;
      end if;
      v_frec := cuidared_interno.agenda_dato(v_rep, 'frecuencia', 'string');
      v_hasta := cuidared_interno.agenda_fecha(v_rep, 'hasta');
      if v_frec = 'semanal' then
        if jsonb_typeof(v_rep -> 'dias_semana') is distinct from 'array'
           or exists (select 1 from jsonb_array_elements(v_rep -> 'dias_semana') d
                      where jsonb_typeof(d) <> 'number' or (d #>> '{}') !~ '^[1-7]$') then
          raise invalid_parameter_value;
        end if;
        select array_agg(distinct (d #>> '{}')::integer) into v_dias from jsonb_array_elements(v_rep -> 'dias_semana') d;
      elsif v_frec = 'diaria' then
        if v_rep ? 'dias_semana' and jsonb_typeof(v_rep -> 'dias_semana') <> 'null'
           and v_rep -> 'dias_semana' <> '[]'::jsonb then
          raise invalid_parameter_value;
        end if;
      else
        raise invalid_parameter_value;
      end if;
      if v_hasta < v_fecha or v_hasta - v_fecha > 730 then raise invalid_parameter_value; end if;
    exception when data_exception then
      raise exception 'CR_REPETICION_INVALIDA' using errcode = 'P0001';
    end;
    select array_agg(d::date order by d) into v_fechas
    from generate_series(v_fecha::timestamp, v_hasta::timestamp, interval '1 day') d
    where v_frec = 'diaria' or extract(isodow from d)::integer = any (v_dias);
    if v_fechas is null or cardinality(v_fechas) > 60 then
      raise exception 'CR_REPETICION_INVALIDA' using errcode = 'P0001';
    end if;
    v_serie := gen_random_uuid();
  end if;

  -- El adulto debe ser de la cuenta (si no, "no existe"), estar a mi alcance y activo.
  select e.nombres, e.apellidos, e.estado into v_e
  from cuidared.envejeciente e where e.envejeciente_id = v_env and e.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_uid) then raise insufficient_privilege; end if;
  if v_e.estado::text <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if not exists (select 1 from cuidared.prioridad where prioridad_id = v_prioridad) then
    raise invalid_parameter_value;
  end if;
  if v_indicacion is not null and not exists (
    select 1 from cuidared.indicacion_medica i where i.indicacion_medica_id = v_indicacion and i.envejeciente_id = v_env) then
    raise exception 'CR_INDICACION_NO_CORRESPONDE' using errcode = 'P0001';
  end if;
  v_usuario_cuidador := cuidared_interno.tarea_exigir_cuidador(p_cuenta_id, v_cuidador, v_env);

  if v_visita is not null then
    perform cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
    if not exists (select from cuidared.visita v join cuidared.detalle_visita d on d.visita_id = v.visita_id
      where v.visita_id = v_visita and v.cuenta_id = p_cuenta_id and d.envejeciente_id = v_env
      and v.estado <> 'cancelada') then raise no_data_found; end if;
  end if;

  foreach v_f in array v_fechas loop
    insert into cuidared.tarea_agenda (cuidador_id, envejeciente_id, indicacion_medica_id, prioridad_id, usuario_creador_id,
                                       titulo, fecha_programada, hora_programada, requiere_evidencia, es_repetitiva, serie_id,
                                       actualizado_por, visita_id)
    values (v_cuidador, v_env, v_indicacion, v_prioridad, v_uid, v_titulo, v_f, v_hora, v_evidencia, v_serie is not null,
            v_serie, v_uid, v_visita)
    returning tarea_agenda_id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  if v_usuario_cuidador <> v_uid then
    perform cuidared_interno.agenda_notificar(v_usuario_cuidador, p_cuenta_id,
      case when cardinality(v_fechas) > 1
        then format('Se te asignaron %s tareas «%s» para %s, del %s al %s.', cardinality(v_fechas), v_titulo,
                    btrim(v_e.nombres::text || ' ' || v_e.apellidos::text), to_char(v_fechas[1], 'DD/MM/YYYY'),
                    to_char(v_fechas[cardinality(v_fechas)], 'DD/MM/YYYY'))
        else format('Se te asignó la tarea «%s» para %s: %s%s.', v_titulo, btrim(v_e.nombres::text || ' ' || v_e.apellidos::text),
                    to_char(v_fechas[1], 'DD/MM/YYYY'), coalesce(' ' || to_char(v_hora, 'HH24:MI'), '')) end);
  end if;

  return jsonb_build_object('serie_id', v_serie, 'tareas',
    (select jsonb_agg(cuidared_interno.tarea_json(u.id) order by u.ord) from unnest(v_ids) with ordinality as u(id, ord)));
end;
$$;

create or replace function cuidared_api.api_listar_visitas(
  p_cuenta_id bigint,
  p_filtros jsonb default '{}'::jsonb,
  p_orden jsonb default '[]'::jsonb,
  p_limite integer default 20,
  p_desplazamiento integer default 0
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_uid uuid;
  v_gestor boolean;
  v_estado text;
  v_env uuid;
  v_desde date;
  v_hasta date;
  v_orden text := '';
  v_usados text[] := '{}';
  v_elem jsonb;
  v_campo text;
  v_dir text;
  v_res jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:ver');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  v_gestor := (v_ctx->>'rol') in ('administrador', 'coordinador');
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or jsonb_typeof(p_filtros) is distinct from 'object'
     or p_filtros - array['estado', 'envejeciente_id', 'desde', 'hasta'] <> '{}'::jsonb
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) > 5 then
    raise invalid_parameter_value;
  end if;
  v_estado := cuidared_interno.v_texto(p_filtros->'estado', 1, 20, false);
  if v_estado is not null and v_estado not in ('programada', 'en_curso', 'completada', 'cancelada') then
    raise invalid_parameter_value;
  end if;
  v_env := cuidared_interno.v_uuid(p_filtros->'envejeciente_id', false);
  v_desde := cuidared_interno.v_fecha(p_filtros->'desde', false);
  v_hasta := cuidared_interno.v_fecha(p_filtros->'hasta', false);
  if v_desde is not null and v_hasta is not null and v_desde > v_hasta then raise invalid_parameter_value; end if;
  -- Filtrar por un adulto fuera del alcance (otra cuenta o inexistente) = adulto inexistente.
  if v_env is not null and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_uid) then
    raise no_data_found;
  end if;
  for v_elem in select e.value from jsonb_array_elements(p_orden) as e loop
    if jsonb_typeof(v_elem) is distinct from 'object' or v_elem - array['campo', 'direccion'] <> '{}'::jsonb
       or jsonb_typeof(v_elem->'campo') is distinct from 'string' or jsonb_typeof(v_elem->'direccion') is distinct from 'string' then
      raise invalid_parameter_value;
    end if;
    v_campo := v_elem->>'campo';
    v_dir := v_elem->>'direccion';
    if not (v_campo = any (array['fecha', 'hora_programada', 'estado', 'fecha_creacion', 'fecha_evento', 'visita_id']))
       or v_dir not in ('asc', 'desc') or v_campo = any (v_usados) then
      raise invalid_parameter_value;
    end if;
    v_usados := array_append(v_usados, v_campo);
    -- Solo identificadores de la lista cerrada y direcciones asc/desc llegan al SQL dinámico.
    v_orden := v_orden || format('f.%I %s nulls last, ', v_campo, v_dir);
  end loop;
  if v_orden = '' then v_orden := 'f.fecha desc nulls last, f.hora_programada desc nulls last, '; end if;
  if not ('visita_id' = any (v_usados)) then v_orden := v_orden || 'f.visita_id asc'; else v_orden := left(v_orden, length(v_orden) - 2); end if;

  execute format($q$
    with f as (
      select v.visita_id, v.fecha, v.hora_programada, v.estado, v.fecha_creacion,
        coalesce(v.fecha_realizacion, v.fecha_cancelacion,
                 (v.fecha + coalesce(v.hora_programada, time '00:00')) at time zone 'America/Santo_Domingo') as fecha_evento
      from cuidared.visita v
      where v.cuenta_id = $1 and not cuidared_interno.visita_con_expediente_retirado(v.visita_id)
        and ($4::text is null or v.estado::text = $4)
        and ($5::uuid is null or exists (
              select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id and d.envejeciente_id = $5))
        and ($6::date is null or v.fecha >= $6)
        and ($7::date is null or v.fecha <= $7)
        and ($3 or (not v.pendiente_autorizacion and (
             exists (select 1 from cuidared.registro_visita r where r.visita_id = v.visita_id and r.usuario_id = $2)
             or exists (select 1 from cuidared.detalle_visita d where d.visita_id = v.visita_id
                        and cuidared_interno.alcanza_envejeciente($1, d.envejeciente_id, $2)))))
    ), p as (
      select f.visita_id, row_number() over (order by %s) as rn from f
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'items', coalesce((select jsonb_agg(cuidared_interno.visita_json(p.visita_id, $2, false) order by p.rn)
                         from p where p.rn > $8 and p.rn <= $8 + $9), '[]'::jsonb))
  $q$, v_orden)
  into v_res
  using p_cuenta_id, v_uid, v_gestor, v_estado, v_env, v_desde, v_hasta, p_desplazamiento, p_limite;
  return v_res;
end $$;

create or replace function cuidared_interno.visita_visible(p_cuenta_id bigint, p_visita_id uuid, p_usuario_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select from cuidared.visita v join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where v.cuenta_id = p_cuenta_id and v.visita_id = p_visita_id
      and not cuidared_interno.visita_con_expediente_retirado(v.visita_id)
      and (m.rol in ('administrador','coordinador') or (not v.pendiente_autorizacion and exists (
        select from cuidared.detalle_visita d where d.visita_id = v.visita_id
          and cuidared_interno.alcanza_envejeciente(p_cuenta_id, d.envejeciente_id, p_usuario_id))))
  )
$$;

create function cuidared_api.api_autorizar_visita(p_cuenta_id bigint, p_visita_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar')->>'usuario_id')::uuid;
  v_visita cuidared.visita;
  v_persona record;
  v_adulto uuid;
begin
  if not cuidared_interno.visita_visible(p_cuenta_id, p_visita_id, v_uid) then raise no_data_found; end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  perform pg_advisory_xact_lock(hashtextextended(p_visita_id::text, 0));
  v_visita := cuidared_interno.bloquear_visita(p_visita_id);
  if v_visita.estado <> 'programada' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  if not v_visita.pendiente_autorizacion then return cuidared_interno.visita_json(p_visita_id, v_uid, true); end if;
  if v_visita.fecha < cuidared_interno.hoy()
     or (v_visita.fecha = cuidared_interno.hoy() and v_visita.hora_fin_programada <= cuidared_interno.hora_local()) then
    raise exception 'CR_VISITA_HORARIO_PASADO' using errcode = 'P0001';
  end if;
  for v_persona in
    select r.usuario_id, m.rol from cuidared.registro_visita r
    left join lateral cuidared_interno.membresia_activa(p_cuenta_id, r.usuario_id) m on true
    where r.visita_id = p_visita_id order by r.usuario_id
  loop
    if v_persona.rol is null or v_persona.rol not in ('cuidador','voluntario') then
      raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
    end if;
    for v_adulto in select envejeciente_id from cuidared.detalle_visita where visita_id = p_visita_id loop
      perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:autorizar', v_adulto);
      if not exists (select from cuidared.envejeciente where envejeciente_id = v_adulto and estado = 'activo') then
        raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
      end if;
      if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_adulto, v_persona.usuario_id) then
        if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar') then raise insufficient_privilege; end if;
        perform cuidared_interno.seg_vincular(p_cuenta_id, v_adulto, v_persona.usuario_id,
          case v_persona.rol when 'cuidador' then 'cuidador_asignado' else 'voluntario_asignado' end, v_uid);
      end if;
    end loop;
  end loop;
  update cuidared.registro_visita set autorizada_por_usuario_id = v_uid where visita_id = p_visita_id;
  update cuidared.visita set pendiente_autorizacion = false, fecha_actualizacion = now() where visita_id = p_visita_id;
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $$;
revoke all on function cuidared_api.api_autorizar_visita(bigint,uuid) from public, anon;
grant execute on function cuidared_api.api_autorizar_visita(bigint,uuid) to authenticated;

create or replace function cuidared_api.api_sync_aplicar_operacion(p_cuenta_id bigint, p_operacion jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_id uuid;
  v_registro uuid;
  v_entidad text;
  v_tipo text;
  v_datos jsonb;
  v_cliente timestamp with time zone;
  v_base timestamp with time zone;
  v_ahora timestamp with time zone := pg_catalog.now();
  v_previa cuidared.operacion_sync;
  v_hay_previa boolean;
  v_res record;
  v_resultado text;
  v_motivo text;
  v_gana text;
  v_servidor timestamp with time zone;
  v_original text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or jsonb_typeof(p_operacion) is distinct from 'object'
     or length(p_operacion::text) > 65536
     or p_operacion - array['id_cliente', 'entidad', 'tipo', 'registro_id', 'datos', 'actualizado_en', 'base_actualizado_en']
        <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  -- Sin membresía activa o sin sync:usar no hay nada que registrar: 403 y no se guarda nada.
  if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'sync:usar') then
    raise insufficient_privilege;
  end if;

  v_id := cuidared_interno.v_uuid(p_operacion->'id_cliente');
  v_registro := cuidared_interno.v_uuid(p_operacion->'registro_id');
  v_entidad := cuidared_interno.v_texto(p_operacion->'entidad', 1, 30);
  v_tipo := cuidared_interno.v_texto(p_operacion->'tipo', 1, 30);
  if v_entidad !~ '^[a-z][a-z_]{0,29}$' or v_tipo !~ '^[a-z][a-z_]{0,29}$'
     or jsonb_typeof(p_operacion->'datos') is distinct from 'object' then
    raise invalid_parameter_value;
  end if;
  v_datos := p_operacion->'datos';
  v_cliente := cuidared_interno.v_marca(p_operacion->'actualizado_en');
  v_base := cuidared_interno.v_marca(p_operacion->'base_actualizado_en', false);

  -- Serializa los reintentos con la misma clave: el segundo espera y ve la fila ya escrita.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id::text, 1));
  select * into v_previa from cuidared.operacion_sync o where o.id_cliente = v_id;
  v_hay_previa := found;

  -- La clave es de una sola operación de una sola persona en una sola cuenta: cualquier otro uso se rechaza sin revelar nada
  -- de la fila existente ni modificarla.
  if v_hay_previa and (v_previa.usuario_id <> v_uid or v_previa.cuenta_id <> p_cuenta_id or v_previa.entidad::text <> v_entidad
                       or v_previa.tipo::text <> v_tipo or v_previa.registro_id <> v_registro) then
    return cuidared_interno.sync_item(v_id, v_registro, 'rechazada', 'ID_CLIENTE_EN_USO', null, null, null);
  end if;

  begin
    if not cuidared_interno.acceso_operativo(p_cuenta_id) then
      -- D07: sin escrituras operativas. Es transitorio: al renovar la cuenta el mismo reintento se resuelve.
      v_resultado := 'rechazada'; v_motivo := 'SUBSCRIPTION_INACTIVE';
    elsif v_hay_previa and v_previa.resultado::text <> 'rechazada' then
      -- Reintento de una operación ya resuelta: se devuelve lo resuelto, sin aplicar nada.
      if v_entidad = 'necesidad' then
        perform cuidared_interno.necesidad_exigir(p_cuenta_id, v_registro,
          case v_tipo when 'registrar' then 'necesidades:registrar' else 'necesidades:actualizar' end);
      else
        perform cuidared_interno.exigir_operar_visita(p_cuenta_id, v_registro, v_uid);
      end if;
      v_resultado := 'duplicada'; v_original := v_previa.resultado::text; v_motivo := v_previa.motivo::text;
      v_gana := v_previa.gana::text; v_servidor := v_previa.actualizado_en_servidor;
    elsif v_entidad not in ('visita', 'necesidad') then
      v_resultado := 'rechazada'; v_motivo := 'ENTIDAD_NO_SOPORTADA';
    elsif (v_entidad = 'visita' and v_tipo not in ('registrar', 'iniciar'))
       or (v_entidad = 'necesidad' and v_tipo not in ('registrar', 'cambiar_estado')) then
      v_resultado := 'rechazada'; v_motivo := 'TIPO_NO_SOPORTADO';
    elsif v_cliente > v_ahora + interval '5 minutes' or v_base > v_ahora + interval '5 minutes' then
      v_resultado := 'rechazada'; v_motivo := 'RELOJ_INVALIDO';
    else
      if v_entidad = 'necesidad' then
        select * into v_res from cuidared_interno.sync_necesidad(
          p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      else
        select * into v_res from cuidared_interno.sync_visita(
          p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      end if;
      v_resultado := v_res.o_resultado; v_motivo := v_res.o_motivo; v_gana := v_res.o_gana; v_servidor := v_res.o_servidor;
    end if;
  exception
    -- Las reglas incumplidas son el resultado de ESTA operación; la subtransacción deshace lo que haya escrito.
    when insufficient_privilege then
      v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN'; v_gana := null; v_servidor := null;
    when no_data_found then
      v_resultado := 'rechazada'; v_motivo := 'NOT_FOUND'; v_gana := null; v_servidor := null;
    when data_exception or check_violation then
      v_resultado := 'rechazada'; v_motivo := 'INVALID_INPUT'; v_gana := null; v_servidor := null;
    when raise_exception then
      v_gana := null; v_servidor := null;
      case sqlerrm
        when 'CR_CUENTA_SIN_ACCESO' then v_resultado := 'rechazada'; v_motivo := 'SUBSCRIPTION_INACTIVE';
        when 'CR_LIMITE_PLAN' then v_resultado := 'rechazada'; v_motivo := 'PLAN_LIMIT_REACHED';
        when 'CR_EVIDENCIA_VISITA_PENDIENTE' then v_resultado := 'rechazada'; v_motivo := 'VISIT_EVIDENCE_PENDING';
        when 'CR_VISITA_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'VISIT_CLOSED';
        when 'CR_ESTADO_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_ADULTO_INACTIVO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_NECESIDAD_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'NEED_CLOSED';
        when 'CR_RESPONSABLE_NECESIDAD_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_NEED_ASSIGNEE';
        when 'CR_NO_PARTICIPA' then v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN';
        when 'CR_CONFLICTO' then v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN';
        else raise;
      end case;
  end;

  -- Un reintento de una operación ya resuelta no escribe nada (la fila original se conserva).
  if v_original is null then
    perform cuidared_interno.sync_registrar(v_id, v_uid, p_cuenta_id, v_entidad, v_tipo, v_registro, v_resultado, v_motivo,
                                            v_gana, v_cliente, v_base, v_servidor);
  end if;
  return cuidared_interno.sync_item(v_id, v_registro, v_resultado, v_motivo, v_gana, v_original, v_servidor);
end $$;

commit;
