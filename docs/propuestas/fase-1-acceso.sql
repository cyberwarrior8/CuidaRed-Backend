-- Propuesta original APROBADA Y APLICADA el 2026-10-25; no volver a ejecutarla.
-- Registro remoto: 20261025041944_fase_1_acceso. Copia exacta en supabase/migrations/.
-- La migración agrega también la exposición de cuidared_api autorizada por el usuario.
-- Acceso propio y sesión · ID01/RF-09. © 2026 Equipo CuidaRed – INTEC.
-- Basada en metadatos de CuidaRed consultados el 2026-10-24.
begin;

create schema cuidared_api;
revoke all on schema cuidared_api from public, anon;

create table cuidared.sesion_acceso (
  sesion_id uuid primary key references auth.sessions(id) on delete cascade,
  ultima_actividad timestamptz not null,
  revocada_en timestamptz
);
alter table cuidared.sesion_acceso enable row level security;
alter table cuidared.usuario enable row level security;
-- Sin acceso directo. Las funciones siguientes restringen cada acción a auth.uid().
revoke all on cuidared.sesion_acceso, cuidared.usuario from public, anon, authenticated;
grant usage on schema cuidared_api to authenticated;

-- SECURITY DEFINER es necesario para comprobar auth.sessions sin exponerlo.
-- La identidad SIEMPRE viene del JWT validado por PostgREST, nunca de un parámetro.
create function cuidared_api.api_sesion(p_accion text default 'validar')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_sid uuid;
  v_inicio timestamptz;
  v_not_after timestamptz;
  v_ahora timestamptz := clock_timestamp();
  v_actividad timestamptz;
  v_revocada timestamptz;
begin
  if v_uid is null or p_accion is null or p_accion not in ('validar', 'actividad', 'cerrar') then
    raise insufficient_privilege;
  end if;
  begin
    v_sid := nullif(auth.jwt()->>'session_id', '')::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('vigente', false);
  end;
  if v_sid is null then return jsonb_build_object('vigente', false); end if;
  -- Excluye autorregistro, usuarios anónimos/no verificados, borrados y bloqueados.
  if not exists (select 1 from auth.users u where u.id = v_uid
    and u.invited_at is not null and u.email_confirmed_at is not null
    and u.deleted_at is null and (u.banned_until is null or u.banned_until <= v_ahora)) then
    return jsonb_build_object('vigente', false);
  end if;
  select s.created_at, s.not_after into v_inicio, v_not_after
    from auth.sessions s where s.id = v_sid and s.user_id = v_uid;
  if not found then return jsonb_build_object('vigente', false); end if;

  -- Serializa operaciones de la misma sesión; no permite revivir una sesión vencida.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_sid::text, 0));
  v_ahora := clock_timestamp();
  select ultima_actividad, revocada_en into v_actividad, v_revocada
    from cuidared.sesion_acceso where sesion_id = v_sid;
  v_actividad := coalesce(v_actividad, v_inicio);
  if v_revocada is not null or v_ahora >= v_inicio + interval '12 hours'
     or v_ahora >= v_actividad + interval '30 minutes'
     or (v_not_after is not null and v_ahora >= v_not_after) then
    return jsonb_build_object('vigente', false);
  end if;
  if exists (select 1 from cuidared.usuario u where u.usuario_id = v_uid and u.estado <> 'activo') then
    return jsonb_build_object('vigente', false, 'motivo', 'usuario_inactivo');
  end if;
  if p_accion in ('actividad', 'cerrar') then
    insert into cuidared.sesion_acceso(sesion_id, ultima_actividad, revocada_en)
      values (v_sid, v_ahora, case when p_accion = 'cerrar' then v_ahora end)
      on conflict (sesion_id) do update set
        ultima_actividad = excluded.ultima_actividad,
        revocada_en = excluded.revocada_en;
  end if;
  return jsonb_build_object('vigente', true);
end;
$$;

create function cuidared_api.api_mi_perfil()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_perfil jsonb;
begin
  if not (cuidared_api.api_sesion('validar')->>'vigente')::boolean then raise insufficient_privilege; end if;
  select jsonb_build_object('usuario_id', u.usuario_id, 'cedula', u.cedula,
    'nombres', u.nombres, 'apellidos', u.apellidos, 'correo', a.email,
    'telefono', u.telefono, 'estado', u.estado)
  into v_perfil from cuidared.usuario u join auth.users a on a.id = u.usuario_id
  where u.usuario_id = auth.uid();
  return v_perfil;
end;
$$;

create function cuidared_api.api_actualizar_mi_perfil(p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not (cuidared_api.api_sesion('validar')->>'vigente')::boolean then raise insufficient_privilege; end if;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos = '{}'::jsonb
    or p_datos - array['nombres','apellidos','telefono'] <> '{}'::jsonb
    or (p_datos ? 'nombres' and (jsonb_typeof(p_datos->'nombres') is distinct from 'string'
      or length(btrim(coalesce(p_datos->>'nombres',''))) not between 1 and 100))
    or (p_datos ? 'apellidos' and (jsonb_typeof(p_datos->'apellidos') is distinct from 'string'
      or length(btrim(coalesce(p_datos->>'apellidos',''))) not between 1 and 100))
    or (p_datos ? 'telefono' and jsonb_typeof(p_datos->'telefono') not in ('string', 'null'))
    or length(coalesce(p_datos->>'telefono','')) > 20 then
    raise invalid_parameter_value;
  end if;
  update cuidared.usuario set
    nombres = case when p_datos ? 'nombres' then btrim(p_datos->>'nombres') else nombres end,
    apellidos = case when p_datos ? 'apellidos' then btrim(p_datos->>'apellidos') else apellidos end,
    telefono = case when p_datos ? 'telefono' then nullif(btrim(p_datos->>'telefono'),'') else telefono end
    where usuario_id = auth.uid() and estado = 'activo';
  if not found then raise insufficient_privilege; end if;
  return cuidared_api.api_mi_perfil();
end;
$$;

revoke all on function cuidared_api.api_sesion(text) from public, anon;
revoke all on function cuidared_api.api_mi_perfil() from public, anon;
revoke all on function cuidared_api.api_actualizar_mi_perfil(jsonb) from public, anon;
grant execute on function cuidared_api.api_sesion(text), cuidared_api.api_mi_perfil(),
  cuidared_api.api_actualizar_mi_perfil(jsonb) to authenticated;

-- No cambia datos, catálogos, membresías ni las otras 37 tablas existentes.
-- Los triggers existentes de usuario siguen auditando las escrituras.
commit;
