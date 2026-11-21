-- Cierre de fases 2 a 4: asignaciones, perfil global, visitas y catálogo de riesgo.
-- Propuesta posterior a las migraciones del 09/11. Requiere aprobación antes de aplicarse.
begin;

insert into cuidared.riesgo (nombre, descripcion, codigo) values
  ('Riesgo de caída', 'Posibilidad de sufrir una caída que afecte la integridad física.', 'riesgo_caida'),
  ('Aislamiento social', 'Poca interacción o red de apoyo social.', 'aislamiento_social'),
  ('Riesgo nutricional', 'Dificultades relacionadas con la alimentación o nutrición.', 'riesgo_nutricional'),
  ('Abandono o desatención', 'Ausencia o insuficiencia de apoyo.', 'abandono_desatencion'),
  ('Dificultad de acceso a medicamentos', 'Dificultad para obtener medicamentos necesarios.', 'acceso_medicamentos')
on conflict (nombre) do update set codigo = coalesce(cuidared.riesgo.codigo, excluded.codigo);

create or replace function cuidared_interno.alcanza_envejeciente(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1
    from cuidared.envejeciente e
    join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id
      and (m.rol <> 'cuidador' or exists (
        select 1 from cuidared.cuidador c where c.usuario_id = p_usuario_id and c.fecha_fin is null
      ))
      and (m.rol in ('administrador', 'coordinador')
        or exists (
          select 1 from cuidared.vinculo v join cuidared.tipo_vinculo tv on tv.tipo_vinculo_id = v.tipo_vinculo_id
          where v.envejeciente_id = e.envejeciente_id and v.usuario_id = p_usuario_id
            and v.fecha_revocacion is null
            and (m.rol <> 'familiar' or v.autorizado_por_usuario_id is not null)
            and tv.codigo::text = case m.rol when 'cuidador' then 'cuidador_asignado'
                                             when 'voluntario' then 'voluntario_asignado'
                                             when 'familiar' then 'familiar_responsable' end)))
$$;

create or replace function cuidared_interno.seg_vincular(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid, p_tipo text, p_actor uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_rol text := case p_tipo when 'cuidador_asignado' then 'cuidador' when 'voluntario_asignado' then 'voluntario'
                            when 'familiar_responsable' then 'familiar' end;
  v_estado text;
  v_rol_actual text;
  v_tipo_id smallint;
  v_fecha timestamptz;
begin
  if v_rol is null or p_actor is null then raise invalid_parameter_value; end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  perform cuidared_interno.exigir_envejeciente(p_cuenta_id,
    case when v_rol = 'familiar' then 'familiares:autorizar' else 'adultos:asignar' end, p_envejeciente_id);
  select m.rol into v_rol_actual from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m;
  if not found or v_rol_actual <> v_rol then raise exception 'CR_ROL_NO_COMPATIBLE' using errcode = 'P0001'; end if;
  if v_rol = 'cuidador' and not exists (
    select 1 from cuidared.cuidador c where c.usuario_id = p_usuario_id and c.fecha_fin is null
  ) then
    raise exception 'CR_PERFIL_CUIDADOR_REQUERIDO' using errcode = 'P0001';
  end if;
  select e.estado::text into v_estado from cuidared.envejeciente e
   where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id
   for no key update;
  if not found then raise insufficient_privilege; end if;
  if v_estado <> 'activo' then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;
  select tv.tipo_vinculo_id into v_tipo_id from cuidared.tipo_vinculo tv where tv.codigo::text = p_tipo;
  if v_tipo_id is null then raise exception 'catalogo tipo_vinculo sin configurar' using errcode = '55000'; end if;

  v_fecha := clock_timestamp();
  update cuidared.vinculo v set fecha_revocacion = v_fecha, motivo_revocacion = 'Sustituido por nueva autorización'
   where v.envejeciente_id = p_envejeciente_id and v.usuario_id = p_usuario_id and v.fecha_revocacion is null
     and (v.tipo_vinculo_id <> v_tipo_id or v.autorizado_por_usuario_id is null);
  insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id, autorizado_por_usuario_id, fecha_autorizacion)
  values (p_envejeciente_id, p_usuario_id, v_tipo_id, p_actor, v_fecha)
  on conflict (envejeciente_id, usuario_id) where fecha_revocacion is null do nothing;
  return cuidared_interno.seg_asignacion_json(p_envejeciente_id, p_usuario_id);
end;
$$;

create or replace function cuidared_api.api_candidatos_cuenta(
  p_cuenta_id bigint, p_uso text, p_offset bigint, p_limit integer, p_orden jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_permiso text;
  v_roles text[];
  v_item jsonb;
  v_campo text;
  v_direccion text;
  v_orden text := '';
  v_resultado jsonb;
begin
  case p_uso
    when 'visita' then v_permiso := 'visitas:programar'; v_roles := array['coordinador','cuidador','voluntario'];
    when 'asignacion' then v_permiso := 'adultos:asignar'; v_roles := array['cuidador','voluntario'];
    when 'familiar' then v_permiso := 'familiares:autorizar'; v_roles := array['familiar'];
    when 'agenda' then v_permiso := 'agenda:gestionar'; v_roles := array['cuidador'];
    when 'cuidado' then v_permiso := 'cuidadores:gestionar'; v_roles := array['cuidador'];
    when 'titularidad' then v_permiso := 'usuarios:gestionar'; v_roles := array['administrador','coordinador'];
    else raise invalid_parameter_value;
  end case;
  perform cuidared_interno.exigir(p_cuenta_id, v_permiso);
  if p_uso = 'visita' then perform cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar'); end if;
  if p_uso = 'titularidad' and not exists (
    select 1 from cuidared.cuenta where cuenta_id = p_cuenta_id and usuario_titular_id = auth.uid()
  ) then raise insufficient_privilege; end if;
  if p_offset is null or p_offset < 0 or p_limit is null or p_limit not between 1 and 100
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) > 2 then
    raise invalid_parameter_value;
  end if;
  for v_item in select value from jsonb_array_elements(p_orden) loop
    v_campo := v_item->>'field';
    v_direccion := v_item->>'direction';
    if v_campo is null or v_campo not in ('nombre','usuario_id') or
       v_direccion is null or v_direccion not in ('asc','desc') then raise invalid_parameter_value; end if;
    v_orden := v_orden || format('%I %s, ', v_campo, v_direccion);
  end loop;
  execute format($q$
    with candidatos as (
      select u.usuario_id, u.nombres || ' ' || u.apellidos as nombre, m.rol,
             m.membresia_id::text as membresia_id, c.cuidador_id::text as cuidador_id
      from cuidared.membresia x join cuidared.usuario u on u.usuario_id = x.usuario_id
      join lateral cuidared_interno.membresia_activa($1, u.usuario_id) m on m.membresia_id = x.membresia_id
      left join cuidared.cuidador c on c.usuario_id = u.usuario_id and c.fecha_fin is null
      where x.cuenta_id = $1 and m.rol = any($2) and ($3 <> 'agenda' or c.cuidador_id is not null)
        and ($3 not in ('asignacion', 'visita') or m.rol <> 'cuidador' or c.cuidador_id is not null)
        and ($3 <> 'titularidad' or (u.usuario_id <> auth.uid() and cuidared_interno.rol_gestor(m.rol_id,m.tipo_cuenta_id)))
    ), pagina as (
      select *, row_number() over (order by %1$s usuario_id) as rn
      from candidatos order by %1$s usuario_id limit $4 offset $5
    )
    select jsonb_build_object('items', coalesce((select jsonb_agg(to_jsonb(p) - 'rn' order by rn) from pagina p), '[]'::jsonb),
                              'total', (select count(*) from candidatos))
  $q$, v_orden) into v_resultado using p_cuenta_id, v_roles, p_uso, p_limit, p_offset;
  return v_resultado;
end $$;

create or replace function cuidared_api.api_guardar_cuidador_miembro(
  p_cuenta_id bigint, p_membresia_id bigint, p_tipo_cuidado_id smallint, p_cuidador_independiente boolean,
  p_conservar_empleador boolean
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m record;
begin
  perform cuidared_interno.exigir_miembros(p_cuenta_id, 'cuidadores:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 or p_tipo_cuidado_id is null or p_cuidador_independiente is null then
    raise invalid_parameter_value;
  end if;
  select m.usuario_id, m.estado::text as estado, r.codigo::text as rol, c.usuario_titular_id
    into v_m
    from cuidared.membresia m
    join cuidared.rol r on r.rol_id = m.rol_id
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if v_m.rol <> 'cuidador' then
    raise exception 'CR_NO_ES_CUIDADOR' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, v_m.usuario_id) m
                 where m.membresia_id = p_membresia_id and m.rol = 'cuidador') then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared.tipo_cuidado t where t.tipo_cuidado_id = p_tipo_cuidado_id) then
    raise invalid_parameter_value;
  end if;
  if p_conservar_empleador is null then raise invalid_parameter_value; end if;
  if p_conservar_empleador then
    update cuidared.cuidador
       set tipo_cuidado_id = p_tipo_cuidado_id
     where usuario_id = v_m.usuario_id and fecha_fin is null;
    if not found then raise no_data_found; end if;
    return cuidared_interno.cuidador_json(v_m.usuario_id, p_cuenta_id);
  end if;

  insert into cuidared.cuidador (usuario_id, tipo_cuidado_id, fecha_inicio, cuidador_independiente, usuario_empleador_id)
  values (v_m.usuario_id, p_tipo_cuidado_id, cuidared_interno.hoy(), p_cuidador_independiente,
          case when p_cuidador_independiente then null else v_m.usuario_titular_id end)
  on conflict (usuario_id) do update set
    tipo_cuidado_id = excluded.tipo_cuidado_id,
    cuidador_independiente = excluded.cuidador_independiente,
    usuario_empleador_id = excluded.usuario_empleador_id,
    fecha_fin = null;
  return cuidared_interno.cuidador_json(v_m.usuario_id, p_cuenta_id);
end;
$$;
revoke all on function cuidared_api.api_guardar_cuidador_miembro(bigint,bigint,smallint,boolean,boolean) from public, anon;
grant execute on function cuidared_api.api_guardar_cuidador_miembro(bigint,bigint,smallint,boolean,boolean) to authenticated;

create or replace function cuidared_api.api_guardar_cuidador_miembro(
  p_cuenta_id bigint, p_membresia_id bigint, p_tipo_cuidado_id smallint, p_cuidador_independiente boolean
) returns jsonb language sql security definer set search_path = '' as $$
  select cuidared_api.api_guardar_cuidador_miembro(
    p_cuenta_id, p_membresia_id, p_tipo_cuidado_id, p_cuidador_independiente, false)
$$;

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

  if v_m.rol = 'voluntario' and p_datos->>'checklist' is not null then
    raise invalid_parameter_value;
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
    if jsonb_typeof(p_datos->'checklist') <> 'array' or jsonb_array_length(p_datos->'checklist') > 6 then
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

commit;
