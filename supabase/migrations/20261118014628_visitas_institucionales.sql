-- Visitas personales e institucionales. © 2026 Equipo CuidaRed – INTEC.
begin;
alter table cuidared.solicitud_visita
  add column tipo_visita text not null default 'personal',
  add column entidad_visitante text,
  add column tipo_entidad text,
  add column cantidad_visitantes integer not null default 1 check (cantidad_visitantes > 0),
  add column aporte_previsto text check (aporte_previsto is null or length(btrim(aporte_previsto)) between 1 and 300),
  alter column persona_a_visitar drop not null,
  drop constraint ck_solicitud_visita_revision;
alter table cuidared.solicitud_visita
  add constraint ck_solicitud_visita_tipo check (
    (tipo_visita = 'personal' and persona_a_visitar is not null and entidad_visitante is null and tipo_entidad is null and aporte_previsto is null)
    or (tipo_visita = 'institucional' and persona_a_visitar is null and length(btrim(entidad_visitante)) between 2 and 160
        and entidad_visitante is not null and tipo_entidad is not null
        and tipo_entidad in ('fundacion','iglesia','universidad','centro_educativo','empresa','grupo_comunitario','otro'))
  ),
  add constraint ck_solicitud_visita_revision check (
    case estado::text
      when 'pendiente' then revisada_por is null and visita_id is null and envejeciente_id is null and motivo_rechazo is null
      when 'rechazada' then revisada_por is not null and motivo_rechazo is not null and visita_id is null
      else revisada_por is not null and visita_id is not null
           and ((tipo_visita = 'personal' and envejeciente_id is not null) or (tipo_visita = 'institucional' and envejeciente_id is null))
    end
  );
alter table cuidared.visita add column informe_general text check (informe_general is null or length(btrim(informe_general)) between 3 and 1000);

create function cuidared_interno.es_visita_institucional(p_visita uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select from cuidared.visita v join cuidared.solicitud_visita s on s.solicitud_visita_id = v.solicitud_visita_id
    where v.visita_id = p_visita and s.cuenta_id = v.cuenta_id and s.tipo_visita = 'institucional'
  )
$$;
revoke all on function cuidared_interno.es_visita_institucional(uuid) from public, anon, authenticated;
CREATE OR REPLACE FUNCTION cuidared_api.api_publico_crear_solicitud(p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cuenta bigint;
  v_nombres text;
  v_apellidos text;
  v_cedula text;
  v_telefono text;
  v_correo text;
  v_persona text;
  v_fecha date;
  v_hora time;
  v_motivo text;
  v_hash text;
  v_org text;
  v_id uuid;
  v_tipo text;
  v_entidad text;
  v_tipo_entidad text;
  v_cantidad integer;
  v_aporte text;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['cuenta_id', 'nombres', 'apellidos', 'cedula', 'telefono', 'correo', 'persona_a_visitar',
                        'fecha_propuesta', 'hora_propuesta', 'motivo', 'codigo_hash', 'tipo_visita', 'entidad_visitante', 'tipo_entidad', 'cantidad_visitantes', 'aporte_previsto'] <> '{}'::jsonb
     or jsonb_typeof(p_datos->'cuenta_id') is distinct from 'number'
     or (p_datos->>'cuenta_id') !~ '^[1-9][0-9]{0,17}$' then
    raise invalid_parameter_value;
  end if;
  v_cuenta := (p_datos->>'cuenta_id')::bigint;
  v_nombres := cuidared_interno.v_texto(p_datos->'nombres', 2, 60);
  v_apellidos := cuidared_interno.v_texto(p_datos->'apellidos', 2, 60);
  v_cedula := cuidared_interno.v_texto(p_datos->'cedula', 11, 11);
  v_telefono := cuidared_interno.v_texto(p_datos->'telefono', 10, 16);
  v_correo := cuidared_interno.v_texto(p_datos->'correo', 5, 254, false);
  v_tipo := coalesce(cuidared_interno.v_texto(p_datos->'tipo_visita', 1, 20, false), 'personal');
  if v_tipo not in ('personal','institucional') then raise invalid_parameter_value; end if;
  v_persona := cuidared_interno.v_texto(p_datos->'persona_a_visitar', 3, 120, v_tipo = 'personal');
  v_entidad := cuidared_interno.v_texto(p_datos->'entidad_visitante', 2, 160, v_tipo = 'institucional');
  v_tipo_entidad := cuidared_interno.v_texto(p_datos->'tipo_entidad', 1, 30, v_tipo = 'institucional');
  v_aporte := cuidared_interno.v_texto(p_datos->'aporte_previsto', 1, 300, false);
  if p_datos ? 'cantidad_visitantes' and (
    jsonb_typeof(p_datos->'cantidad_visitantes') <> 'number' or p_datos->>'cantidad_visitantes' !~ '^[1-9][0-9]{0,9}$'
  ) then raise invalid_parameter_value; end if;
  v_cantidad := coalesce((p_datos->>'cantidad_visitantes')::integer, 1);
  if v_cantidad < 1
     or (v_tipo = 'institucional' and (v_persona is not null or v_tipo_entidad not in ('fundacion','iglesia','universidad','centro_educativo','empresa','grupo_comunitario','otro')))
     or (v_tipo = 'personal' and (v_entidad is not null or v_tipo_entidad is not null or v_aporte is not null)) then
    raise invalid_parameter_value;
  end if;
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha_propuesta');
  v_hora := cuidared_interno.v_hora(p_datos->'hora_propuesta');
  v_motivo := cuidared_interno.v_texto(p_datos->'motivo', 3, 300);
  v_hash := cuidared_interno.v_texto(p_datos->'codigo_hash', 64, 64);
  if v_cedula !~ '^[0-9]{11}$' or v_telefono !~ '^\+?[0-9]{10,15}$' or v_hash !~ '^[0-9a-f]{64}$'
     or (v_correo is not null and v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
     or v_fecha < cuidared_interno.hoy() then
    raise invalid_parameter_value;
  end if;
  select c.nombre into v_org
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id and t.codigo::text = 'organizacion'
  where c.cuenta_id = v_cuenta and cuidared_interno.acceso_operativo(c.cuenta_id);
  if not found then raise invalid_parameter_value; end if;
  -- Frenos contra inundación: pendientes por visitante, pendientes por cuenta y creaciones por hora.
  if (select count(*) from cuidared.solicitud_visita s
      where s.cuenta_id = v_cuenta and s.visitante_cedula = v_cedula and s.estado::text = 'pendiente') >= 3 then
    raise exception 'CR_CONFLICTO' using errcode = 'P0001';
  end if;
  -- Las RPC públicas pueden llamarse directo (sin pasar por el límite de Express): estos topes acotan el daño por cuenta.
  if (select count(*) from cuidared.solicitud_visita s where s.cuenta_id = v_cuenta and s.estado::text = 'pendiente') >= 500
     or (select count(*) from cuidared.solicitud_visita s
         where s.cuenta_id = v_cuenta and s.fecha_creacion > now() - interval '1 hour') >= 60 then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  insert into cuidared.solicitud_visita (cuenta_id, visitante_nombres, visitante_apellidos, visitante_cedula, visitante_telefono,
                                        visitante_correo, persona_a_visitar, fecha_propuesta, hora_propuesta, motivo, codigo_hash, tipo_visita, entidad_visitante, tipo_entidad, cantidad_visitantes, aporte_previsto)
    values (v_cuenta, v_nombres, v_apellidos, v_cedula, v_telefono, lower(v_correo), v_persona, v_fecha, v_hora, v_motivo, v_hash, v_tipo, v_entidad, v_tipo_entidad, v_cantidad, v_aporte)
    returning solicitud_visita_id into v_id;
  -- Aviso a los usuarios principales de la cuenta (sin datos del adulto: aún no está confirmado ni identificado).
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
    select g, v_cuenta, format('Nueva solicitud de visita de %s %s para el %s.', v_nombres, v_apellidos, to_char(v_fecha, 'DD/MM/YYYY'))
    from cuidared_interno.gestores_cuenta(v_cuenta) g;
  return jsonb_build_object('organizacion', v_org, 'estado', 'pendiente', 'fecha_propuesta', v_fecha,
                            'hora_propuesta', cuidared_interno.hhmm(v_hora));
end $function$;
CREATE OR REPLACE FUNCTION cuidared_api.api_autorizar_solicitud_visita(p_cuenta_id bigint, p_solicitud_id uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_env := cuidared_interno.v_uuid(p_datos->'envejeciente_id', v_s.tipo_visita = 'personal');
  if v_s.tipo_visita = 'institucional' and v_env is not null then raise invalid_parameter_value; end if;
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hora := cuidared_interno.v_hora(p_datos->'hora');
  if v_fecha < v_hoy or (v_fecha = v_hoy and v_hora < cuidared_interno.hora_local()) then
    raise invalid_parameter_value;
  end if;
  -- El adulto lo confirma quien autoriza: de la cuenta (otra cuenta e inexistente responden igual, 42501) y activo.
  if v_env is not null then
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:autorizar', v_env);
  select e.estado into v_estado from cuidared.envejeciente e where e.envejeciente_id = v_env;
  if v_estado <> 'activo' then raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; end if;
  end if;

  v_fin := cuidared_interno.fin_ventana(v_hora, cuidared_interno.v_hora(p_datos->'hora_fin_programada', false));
  v_responsable := coalesce(cuidared_interno.v_uuid(p_datos->'participante_id', false), v_uid);
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_responsable);
  if not found or (v_m.rol not in ('voluntario', 'cuidador') and
     not (v_m.rol = 'coordinador' and v_responsable = v_uid and not (p_datos ? 'participante_id')))
     or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
  end if;
  perform cuidared_interno.exigir_horario_visita(p_cuenta_id, v_fecha, v_hora, v_fin, array[v_responsable], case when v_env is null then '{}'::uuid[] else array[v_env] end);
  if v_env is not null and v_m.rol in ('cuidador', 'voluntario') and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_env, v_responsable) then
    if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar') then raise insufficient_privilege; end if;
    perform cuidared_interno.seg_vincular(p_cuenta_id, v_env, v_responsable,
      case v_m.rol when 'cuidador' then 'cuidador_asignado' else 'voluntario_asignado' end, v_uid);
  end if;

  insert into cuidared.visita (visita_id, cuenta_id, fecha, hora_programada, hora_fin_programada, razon, estado, origen, creada_por, solicitud_visita_id)
    values (v_id, p_cuenta_id, v_fecha, v_hora, v_fin, btrim(left(v_s.motivo, 120)), 'programada', 'solicitud', v_uid, p_solicitud_id);
  insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id) values (v_id, v_responsable, v_uid);
  if v_env is not null then
    insert into cuidared.detalle_visita (visita_id, envejeciente_id) values (v_id, v_env);
  end if;
  update cuidared.solicitud_visita
    set estado = 'autorizada', envejeciente_id = v_env, revisada_por = v_uid, revisada_en = now(), visita_id = v_id
    where solicitud_visita_id = p_solicitud_id;
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $function$;

CREATE OR REPLACE FUNCTION cuidared_interno.visita_visible(p_cuenta_id bigint, p_visita_id uuid, p_usuario_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select exists (
    select from cuidared.visita v join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where v.cuenta_id = p_cuenta_id and v.visita_id = p_visita_id
      and not cuidared_interno.visita_con_expediente_retirado(v.visita_id)
      and (m.rol in ('administrador','coordinador') or (not v.pendiente_autorizacion and exists (
        select from cuidared.detalle_visita d where d.visita_id = v.visita_id
          and cuidared_interno.alcanza_envejeciente(p_cuenta_id, d.envejeciente_id, p_usuario_id))
        or (not v.pendiente_autorizacion and cuidared_interno.es_visita_institucional(v.visita_id) and exists (
          select from cuidared.registro_visita r where r.visita_id = v.visita_id and r.usuario_id = p_usuario_id
            and r.autorizada_por_usuario_id is not null))))
  )
$function$;

CREATE OR REPLACE FUNCTION cuidared_interno.exigir_operar_visita(p_cuenta_id bigint, p_visita_id uuid, p_usuario_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_m record;
begin
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id);
  if not found or not ('visitas:registrar' = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise insufficient_privilege;
  end if;
  if not cuidared_interno.acceso_operativo(p_cuenta_id) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;
  if not cuidared_interno.visita_visible(p_cuenta_id, p_visita_id, p_usuario_id) then
    raise no_data_found;
  end if;
  if not exists (select 1 from cuidared.registro_visita r join cuidared.visita v using (visita_id)
                  where r.visita_id = p_visita_id and r.usuario_id = p_usuario_id
                    and r.autorizada_por_usuario_id is not null and v.hora_programada is not null) then
    raise exception 'CR_NO_PARTICIPA' using errcode = 'P0001';
  end if;
  if (not cuidared_interno.es_visita_institucional(p_visita_id) and not exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita_id))
     or exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita_id
                and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, d.envejeciente_id, p_usuario_id)) then
    raise insufficient_privilege;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION cuidared_interno.evidencia_visita_acceso(p_cuenta bigint, p_visita uuid, p_uid uuid, p_subir boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select cuidared_interno.acceso_operativo(p_cuenta)
    and exists (select 1 from cuidared.visita v where v.visita_id = p_visita and v.cuenta_id = p_cuenta
                and v.hora_programada is not null and v.estado in ('en_curso','completada') and (not p_subir or v.estado = 'en_curso'))
    and (cuidared_interno.es_visita_institucional(p_visita) or exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita))
    and not exists (select 1 from cuidared.detalle_visita d where d.visita_id = p_visita
                    and not cuidared_interno.alcanza_envejeciente(p_cuenta, d.envejeciente_id, p_uid))
    and (
      (cuidared_interno.tiene_permiso(p_cuenta, p_uid, 'visitas:registrar')
       and (not p_subir or exists (select from cuidared_interno.membresia_activa(p_cuenta, p_uid) m where m.rol = 'cuidador'))
       and exists (select 1 from cuidared.registro_visita r where r.visita_id = p_visita
                   and r.usuario_id = p_uid and r.autorizada_por_usuario_id is not null))
      or (not p_subir and cuidared_interno.tiene_permiso(p_cuenta, p_uid, 'visitas:autorizar'))
    )
$function$;

CREATE OR REPLACE FUNCTION cuidared_interno.registrar_visita_realizada(p_cuenta_id bigint, p_usuario_id uuid, p_visita_id uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
  v_informe text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_usuario_id is null or p_visita_id is null
     or jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['hora_inicio', 'hora_fin', 'checklist', 'detalles', 'observacion_general'] <> '{}'::jsonb then
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
  v_informe := cuidared_interno.v_texto(p_datos->'observacion_general', 3, 1000, cuidared_interno.es_visita_institucional(p_visita_id));
  if not cuidared_interno.es_visita_institucional(p_visita_id) and v_informe is not null then raise invalid_parameter_value; end if;
  if jsonb_typeof(p_datos->'detalles') is distinct from 'array'
     or jsonb_array_length(p_datos->'detalles') not between (case when cuidared_interno.es_visita_institucional(p_visita_id) then 0 else 1 end) and 4 then
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
      set estado = 'completada', informe_general = v_informe, hora_inicio = v_ini, hora_fin = v_fin, checklist = v_checklist, fecha_actualizacion = now()
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
end $function$;

CREATE OR REPLACE FUNCTION cuidared_interno.solicitud_json(p_solicitud_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'solicitud_visita_id', s.solicitud_visita_id,
    'estado', s.estado,
    'visitante', jsonb_build_object('nombres', s.visitante_nombres, 'apellidos', s.visitante_apellidos,
                                    'cedula', s.visitante_cedula, 'telefono', s.visitante_telefono,
                                    'correo', s.visitante_correo),
    'persona_a_visitar', s.persona_a_visitar,
    'tipo_visita', s.tipo_visita, 'entidad_visitante', s.entidad_visitante, 'tipo_entidad', s.tipo_entidad,
    'cantidad_visitantes', s.cantidad_visitantes, 'aporte_previsto', s.aporte_previsto,
    'fecha_propuesta', s.fecha_propuesta,
    'hora_propuesta', cuidared_interno.hhmm(s.hora_propuesta),
    'motivo', s.motivo,
    'fecha_creacion', s.fecha_creacion,
    'revisada_por', (select jsonb_build_object('usuario_id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos)
                     from cuidared.usuario u where u.usuario_id = s.revisada_por),
    'revisada_en', s.revisada_en,
    'motivo_rechazo', s.motivo_rechazo,
    'envejeciente', (select jsonb_build_object('envejeciente_id', e.envejeciente_id, 'nombres', e.nombres, 'apellidos', e.apellidos)
                     from cuidared.envejeciente e where e.envejeciente_id = s.envejeciente_id),
    'visita_id', s.visita_id,
    'observacion_visitante', s.observacion_visitante,
    'observacion_en', s.observacion_en)
  from cuidared.solicitud_visita s where s.solicitud_visita_id = p_solicitud_id
$function$;

CREATE OR REPLACE FUNCTION cuidared_interno.visita_json(p_visita_id uuid, p_usuario_id uuid, p_detalle boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
    'informe_general', v.informe_general,
    'tipo_visita', case when cuidared_interno.es_visita_institucional(v.visita_id) then 'institucional' else 'personal' end,
    'entidad_visitante', (select entidad_visitante from cuidared.solicitud_visita where solicitud_visita_id = v.solicitud_visita_id),
    'cantidad_visitantes', (select cantidad_visitantes from cuidared.solicitud_visita where solicitud_visita_id = v.solicitud_visita_id),
    'aporte_previsto', (select aporte_previsto from cuidared.solicitud_visita where solicitud_visita_id = v.solicitud_visita_id),
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
$function$;

commit;
