-- Soporte de organizaciones y eliminación controlada de identidades sin historial operativo.
-- © 2026 Equipo CuidaRed – INTEC. Autorizado por la solicitud del 22/11/2026.
begin;

create table cuidared.solicitud_soporte (
  solicitud_id bigint generated always as identity primary key,
  cuenta_id bigint not null references cuidared.cuenta(cuenta_id),
  solicitante_id uuid references cuidared.usuario(usuario_id) on delete set null,
  usuario_objetivo_id uuid,
  tipo text not null check(tipo in ('eliminar_usuario','acceso','error','consulta')),
  asunto text not null check(length(btrim(asunto)) between 5 and 120),
  descripcion text not null check(length(btrim(descripcion)) between 10 and 2000),
  estado text not null default 'abierta' check(estado in ('abierta','en_revision','esperando_informacion','resuelta','rechazada')),
  asignado_a uuid references cuidared.usuario(usuario_id) on delete set null,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  check(tipo <> 'eliminar_usuario' or usuario_objetivo_id is not null)
);
create index soporte_cuenta_fecha on cuidared.solicitud_soporte(cuenta_id,solicitud_id desc);
create index soporte_estado_fecha on cuidared.solicitud_soporte(estado,solicitud_id desc);
create unique index soporte_eliminacion_abierta on cuidared.solicitud_soporte(cuenta_id,usuario_objetivo_id)
  where tipo='eliminar_usuario' and estado in ('abierta','en_revision','esperando_informacion');
create table cuidared.mensaje_soporte (
  mensaje_id bigint generated always as identity primary key,
  solicitud_id bigint not null references cuidared.solicitud_soporte(solicitud_id),
  autor_id uuid references cuidared.usuario(usuario_id) on delete set null,
  origen text not null check(origen in ('organizacion','backoffice')),
  texto text not null check(length(btrim(texto)) between 5 and 2000),
  estado text not null,
  creado_en timestamptz not null default now()
);
create index soporte_mensaje_solicitud on cuidared.mensaje_soporte(solicitud_id,mensaje_id);
alter table cuidared.solicitud_soporte enable row level security;
alter table cuidared.mensaje_soporte enable row level security;
revoke all on cuidared.solicitud_soporte,cuidared.mensaje_soporte from public,anon,authenticated,service_role;
revoke all on sequence cuidared.solicitud_soporte_solicitud_id_seq,cuidared.mensaje_soporte_mensaje_id_seq
  from public,anon,authenticated,service_role;
create trigger soporte_evento after insert or update or delete on cuidared.solicitud_soporte
  for each statement execute function cuidared_interno.bo_eventos('soporte');
create trigger soporte_mensaje_evento after insert on cuidared.mensaje_soporte
  for each statement execute function cuidared_interno.bo_eventos('soporte');

create function cuidared_interno.soporte_exigir(p_cuenta bigint) returns uuid
language plpgsql stable set search_path='' as $$
declare v_ctx jsonb := cuidared_interno.exigir_miembro(p_cuenta);
begin
  if v_ctx->>'tipo' <> 'organizacion' or v_ctx->>'rol' <> 'administrador' then raise insufficient_privilege; end if;
  return (v_ctx->>'usuario_id')::uuid;
end $$;

create function cuidared_interno.soporte_operador(p_actor uuid,p_sesion uuid,p_aal text,p_escritura boolean default false)
returns text language plpgsql stable set search_path='' as $$
declare v_rol text := cuidared_interno.bo_rol(p_actor,p_sesion);
begin
  if v_rol is null or (v_rol='super_admin' and p_aal is distinct from 'aal2')
    or (p_escritura and v_rol='auditor') then raise insufficient_privilege; end if;
  return v_rol;
end $$;

create function cuidared_interno.soporte_json(p_id bigint,p_detalle boolean default false) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'id',s.solicitud_id::text,'codigo','SOP-'||lpad(s.solicitud_id::text,6,'0'),
    'cuenta',jsonb_build_object('id',s.cuenta_id::text,'nombre',c.nombre),
    'tipo',s.tipo,'asunto',s.asunto,'descripcion',s.descripcion,'estado',s.estado,
    'creado_en',s.creado_en,'actualizado_en',s.actualizado_en,
    'solicitante',jsonb_build_object('id',s.solicitante_id,'nombre',coalesce(u.nombres||' '||u.apellidos,'Usuario eliminado')),
    'asignado',case when a.usuario_id is null then null else jsonb_build_object('id',a.usuario_id,'nombre',a.nombres||' '||a.apellidos) end,
    'usuario_objetivo',case when s.usuario_objetivo_id is null then null else jsonb_build_object(
      'id',s.usuario_objetivo_id,'nombre',coalesce(o.nombres||' '||o.apellidos,'Usuario eliminado'),
      'correo',o.correo,'estado',o.estado) end
  ) || case when p_detalle then jsonb_build_object('mensajes',(select coalesce(jsonb_agg(
    jsonb_build_object('id',m.mensaje_id::text,'origen',m.origen,'texto',m.texto,'estado',m.estado,'creado_en',m.creado_en,
      'autor',coalesce(mu.nombres||' '||mu.apellidos,case when m.origen='backoffice' then 'Equipo CuidaRed' else 'Usuario eliminado' end))
    order by m.mensaje_id),'[]') from cuidared.mensaje_soporte m left join cuidared.usuario mu on mu.usuario_id=m.autor_id
      where m.solicitud_id=s.solicitud_id)) else '{}'::jsonb end
  from cuidared.solicitud_soporte s join cuidared.cuenta c using(cuenta_id)
  left join cuidared.usuario u on u.usuario_id=s.solicitante_id
  left join cuidared.usuario a on a.usuario_id=s.asignado_a
  left join cuidared.usuario o on o.usuario_id=s.usuario_objetivo_id
  where s.solicitud_id=p_id
$$;

create function cuidared_interno.soporte_listar(p_cuenta bigint,p_estado text,p_buscar text,p_pagina integer,p_limite integer)
returns jsonb language plpgsql stable set search_path='' as $$
declare v_data jsonb; v_total bigint; v_totales jsonb;
begin
  if p_pagina is null or p_pagina not between 1 and 1000000 or p_limite is null or p_limite not between 1 and 50
    or length(coalesce(p_buscar,''))>120 or (p_estado is not null and p_estado not in
      ('abierta','en_revision','esperando_informacion','resuelta','rechazada')) then raise invalid_parameter_value; end if;
  with filtradas as materialized (
    select solicitud_id from cuidared.solicitud_soporte s join cuidared.cuenta c using(cuenta_id)
    where (p_cuenta is null or s.cuenta_id=p_cuenta) and (p_estado is null or s.estado=p_estado)
      and (p_buscar is null or strpos(lower(s.asunto||' '||c.nombre||' SOP-'||lpad(s.solicitud_id::text,6,'0')),lower(p_buscar))>0)
  ), pagina as (select solicitud_id from filtradas order by solicitud_id desc limit p_limite offset ((p_pagina-1)*p_limite))
  select (select coalesce(jsonb_agg(cuidared_interno.soporte_json(solicitud_id) order by solicitud_id desc),'[]') from pagina),
    (select count(*) from filtradas) into v_data,v_total;
  select jsonb_build_object(
    'abiertas',count(*) filter(where estado='abierta'),
    'en_revision',count(*) filter(where estado='en_revision'),
    'esperando_informacion',count(*) filter(where estado='esperando_informacion'),
    'cerradas',count(*) filter(where estado in ('resuelta','rechazada'))
  ) into v_totales from cuidared.solicitud_soporte where p_cuenta is null or cuenta_id=p_cuenta;
  return cuidared_interno.bo_pagina(v_data,v_total,p_pagina,p_limite)||jsonb_build_object('totales',v_totales);
end $$;

create function cuidared_api.api_soporte_listar(p_cuenta_id bigint,p_estado text default null,p_buscar text default null,
  p_pagina integer default 1,p_limite integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  perform cuidared_interno.soporte_exigir(p_cuenta_id);
  return cuidared_interno.soporte_listar(p_cuenta_id,p_estado,p_buscar,p_pagina,p_limite);
end $$;
create function cuidared_api.api_soporte_detalle(p_cuenta_id bigint,p_id bigint) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  perform cuidared_interno.soporte_exigir(p_cuenta_id);
  if not exists(select from cuidared.solicitud_soporte where solicitud_id=p_id and cuenta_id=p_cuenta_id) then raise no_data_found; end if;
  return cuidared_interno.soporte_json(p_id,true);
end $$;
create function cuidared_api.api_soporte_crear(p_cuenta_id bigint,p_tipo text,p_asunto text,p_descripcion text,
  p_usuario_objetivo uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_uid uuid := cuidared_interno.soporte_exigir(p_cuenta_id); v_id bigint;
begin
  -- Serializa el límite por cuenta y los duplicados; no acepta usuarios de otra cuenta.
  perform 1 from cuidared.cuenta where cuenta_id=p_cuenta_id for update;
  if p_tipo is null or p_tipo not in ('eliminar_usuario','acceso','error','consulta')
    or p_asunto is null or length(btrim(p_asunto)) not between 5 and 120
    or p_descripcion is null or length(btrim(p_descripcion)) not between 10 and 2000
    or (p_tipo='eliminar_usuario' and p_usuario_objetivo is null) then raise invalid_parameter_value; end if;
  if p_usuario_objetivo is not null and not exists(select from cuidared.membresia
    where usuario_id=p_usuario_objetivo and cuenta_id=p_cuenta_id) then raise no_data_found; end if;
  if (select count(*) from cuidared.solicitud_soporte where solicitante_id=v_uid and creado_en>now()-interval '15 minutes') >= 10
    then raise exception 'CR_SOPORTE_LIMITE' using errcode='P0001'; end if;
  if p_tipo='eliminar_usuario' and exists(select from cuidared.solicitud_soporte where cuenta_id=p_cuenta_id
    and usuario_objetivo_id=p_usuario_objetivo and tipo=p_tipo and estado in ('abierta','en_revision','esperando_informacion'))
    then raise exception 'CR_SOPORTE_DUPLICADO' using errcode='P0001'; end if;
  insert into cuidared.solicitud_soporte(cuenta_id,solicitante_id,usuario_objetivo_id,tipo,asunto,descripcion)
    values(p_cuenta_id,v_uid,p_usuario_objetivo,p_tipo,btrim(p_asunto),btrim(p_descripcion)) returning solicitud_id into v_id;
  return cuidared_interno.soporte_json(v_id,true);
end $$;

create function cuidared_api.api_soporte_responder(p_cuenta_id bigint,p_id bigint,p_mensaje text,p_version timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_uid uuid := cuidared_interno.soporte_exigir(p_cuenta_id); v_s cuidared.solicitud_soporte%rowtype;
begin
  select * into v_s from cuidared.solicitud_soporte where solicitud_id=p_id and cuenta_id=p_cuenta_id for update;
  if not found then raise no_data_found; end if;
  if p_version is distinct from v_s.actualizado_en then raise exception 'CR_SOPORTE_VERSION' using errcode='P0001'; end if;
  if v_s.estado in ('resuelta','rechazada') then raise exception 'CR_SOPORTE_CERRADO' using errcode='P0001'; end if;
  if p_mensaje is null or length(btrim(p_mensaje)) not between 5 and 2000 then raise invalid_parameter_value; end if;
  update cuidared.solicitud_soporte set actualizado_en=clock_timestamp(),
    estado=case when estado='esperando_informacion' then 'en_revision' else estado end where solicitud_id=p_id;
  insert into cuidared.mensaje_soporte(solicitud_id,autor_id,origen,texto,estado)
    select p_id,v_uid,'organizacion',btrim(p_mensaje),estado from cuidared.solicitud_soporte where solicitud_id=p_id;
  return cuidared_interno.soporte_json(p_id,true);
end $$;

create function cuidared_api.api_bo_soporte_leer(p_actor uuid,p_sesion uuid,p_aal text,p_id bigint default null,
  p_estado text default null,p_buscar text default null,p_pagina integer default 1,p_limite integer default 25)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform cuidared_interno.soporte_operador(p_actor,p_sesion,p_aal);
  if p_id is not null then
    if not exists(select from cuidared.solicitud_soporte where solicitud_id=p_id) then raise no_data_found; end if;
    return cuidared_interno.soporte_json(p_id,true);
  end if;
  return cuidared_interno.soporte_listar(null,p_estado,p_buscar,p_pagina,p_limite);
end $$;
create function cuidared_api.api_bo_soporte_actualizar(p_actor uuid,p_sesion uuid,p_aal text,p_id bigint,
  p_estado text,p_mensaje text,p_version timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_rol text := cuidared_interno.soporte_operador(p_actor,p_sesion,p_aal,true); v_s cuidared.solicitud_soporte%rowtype;
begin
  select * into v_s from cuidared.solicitud_soporte where solicitud_id=p_id for update;
  if not found then raise no_data_found; end if;
  if p_version is distinct from v_s.actualizado_en then raise exception 'CR_SOPORTE_VERSION' using errcode='P0001'; end if;
  if p_estado is null or p_estado not in ('abierta','en_revision','esperando_informacion','resuelta','rechazada')
    or p_mensaje is null or length(btrim(p_mensaje)) not between 5 and 2000 then raise invalid_parameter_value; end if;
  update cuidared.solicitud_soporte set estado=p_estado,asignado_a=p_actor,actualizado_en=clock_timestamp() where solicitud_id=p_id;
  insert into cuidared.mensaje_soporte(solicitud_id,autor_id,origen,texto,estado) values(p_id,p_actor,'backoffice',btrim(p_mensaje),p_estado);
  perform cuidared_interno.bo_auditar(p_actor,v_rol,v_s.cuenta_id,'soporte.actualizar','solicitud_soporte',p_id::text,
    jsonb_build_object('estado',v_s.estado),jsonb_build_object('estado',p_estado),'Respuesta y seguimiento de soporte');
  return cuidared_interno.soporte_json(p_id,true);
end $$;

-- El control de eliminación solo admite perfiles inactivos, de una sola cuenta y sin historial operativo.
create function cuidared_interno.bo_eliminacion_revision(p_cuenta bigint,p_usuario uuid) returns jsonb
language plpgsql set search_path='' as $$
declare v_u cuidared.usuario%rowtype; v_motivos text[] := '{}'; v_ref record; v_total bigint; v_hay_historial boolean := false;
begin
  select * into v_u from cuidared.usuario where usuario_id=p_usuario;
  if not found or not exists(select from cuidared.membresia where cuenta_id=p_cuenta and usuario_id=p_usuario) then raise no_data_found; end if;
  if exists(select from cuidared.usuario_backoffice where usuario_id=p_usuario) then v_motivos:=array_append(v_motivos,'Los operadores del backoffice no se eliminan por esta vía.'); end if;
  if v_u.estado='activo' then v_motivos:=array_append(v_motivos,'Primero debe deshabilitarse el acceso global del usuario.'); end if;
  if exists(select from cuidared.cuenta where usuario_titular_id=p_usuario) then v_motivos:=array_append(v_motivos,'El usuario es titular de una cuenta. Debe transferir la titularidad.'); end if;
  if exists(select from cuidared.membresia where usuario_id=p_usuario and estado in ('activa','pendiente')) then v_motivos:=array_append(v_motivos,'Conserva membresías activas o invitaciones pendientes. Deben desactivarse primero.'); end if;
  if exists(select from cuidared.membresia where usuario_id=p_usuario and cuenta_id<>p_cuenta) then v_motivos:=array_append(v_motivos,'Tiene membresías en otras cuentas. La eliminación global requiere revisar esas relaciones.'); end if;
  if exists(select from storage.objects where owner_id=p_usuario::text or owner=p_usuario) then v_motivos:=array_append(v_motivos,'Tiene archivos en Storage que requieren revisión.'); end if;
  -- Revisa todas las FK actuales, incluidas las que añadan futuras migraciones. No borra actividad.
  for v_ref in
    select c.conrelid::regclass tabla,a.attname columna,c.confrelid referencia from pg_catalog.pg_constraint c
    join pg_catalog.pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
    where c.contype='f' and array_length(c.conkey,1)=1 and c.confrelid in ('cuidared.usuario'::regclass,'cuidared.cuidador'::regclass)
      and c.conrelid not in ('cuidared.membresia'::regclass,'cuidared.notificacion'::regclass,'cuidared.push_suscripcion'::regclass,
        'cuidared.solicitud_soporte'::regclass,'cuidared.mensaje_soporte'::regclass)
  loop
    if v_ref.tabla='cuidared.cuidador'::regclass and v_ref.columna='usuario_id' then continue; end if;
    if v_ref.referencia='cuidared.usuario'::regclass then
      execute format('select count(*) from %s where %I=$1',v_ref.tabla,v_ref.columna) into v_total using p_usuario;
    else
      execute format('select count(*) from %s where %I in (select cuidador_id from cuidared.cuidador where usuario_id=$1)',v_ref.tabla,v_ref.columna) into v_total using p_usuario;
    end if;
    if v_total>0 then v_hay_historial:=true; exit; end if;
  end loop;
  if v_hay_historial then v_motivos:=array_append(v_motivos,'Tiene registros operativos o relaciones de cuidado. Se conserva su trazabilidad; soporte debe resolver el acceso sin borrar ese historial.'); end if;
  return jsonb_build_object('usuario_id',p_usuario,'cuenta_id',p_cuenta::text,'nombre',v_u.nombres||' '||v_u.apellidos,
    'correo',v_u.correo,'permitida',cardinality(v_motivos)=0,'motivos',to_jsonb(v_motivos));
end $$;

create table cuidared_interno.bo_eliminacion_usuario (
  usuario_id uuid primary key, operacion_id uuid not null unique, cuenta_id bigint not null,
  actor_id uuid not null, sesion_id uuid not null, aal text not null, motivo text not null,
  solicitud_id bigint, estado text not null check(estado in ('preparada','eliminado')),
  preparado_en timestamptz not null default now(),vence_en timestamptz not null,eliminado_en timestamptz
);
revoke all on cuidared_interno.bo_eliminacion_usuario from public,anon,authenticated,service_role;
alter table cuidared_interno.bo_eliminacion_usuario enable row level security;

create function cuidared_api.api_bo_eliminacion_leer(p_actor uuid,p_sesion uuid,p_aal text,p_cuenta bigint,p_usuario uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rol text := cuidared_interno.soporte_operador(p_actor,p_sesion,p_aal,true);
begin
  if v_rol <> 'super_admin' then raise insufficient_privilege; end if;
  return cuidared_interno.bo_eliminacion_revision(p_cuenta,p_usuario);
end $$;
create function cuidared_api.api_bo_eliminacion_preparar(p_actor uuid,p_sesion uuid,p_aal text,p_cuenta bigint,
  p_usuario uuid,p_confirmacion text,p_motivo text,p_solicitud bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_rol text := cuidared_interno.soporte_operador(p_actor,p_sesion,p_aal,true); v_revision jsonb; v_job cuidared_interno.bo_eliminacion_usuario%rowtype;
begin
  if v_rol<>'super_admin' or p_actor=p_usuario then raise insufficient_privilege; end if;
  select * into v_job from cuidared_interno.bo_eliminacion_usuario where usuario_id=p_usuario;
  if found and v_job.estado='eliminado' and v_job.cuenta_id=p_cuenta and v_job.actor_id=p_actor then
    return jsonb_build_object('operacion_id',v_job.operacion_id,'estado','eliminado'); end if;
  perform 1 from cuidared.usuario where usuario_id=p_usuario for update;
  if not found then raise no_data_found; end if;
  perform 1 from cuidared.membresia where usuario_id=p_usuario for update;
  select * into v_job from cuidared_interno.bo_eliminacion_usuario where usuario_id=p_usuario for update;
  v_revision:=cuidared_interno.bo_eliminacion_revision(p_cuenta,p_usuario);
  if not (v_revision->>'permitida')::boolean then raise exception 'CR_BO_ELIMINACION_BLOQUEADA' using errcode='P0001'; end if;
  if p_confirmacion is null or lower(btrim(p_confirmacion))<>lower(v_revision->>'correo')
    or p_motivo is null or length(btrim(p_motivo)) not between 5 and 400 then raise invalid_parameter_value; end if;
  if p_solicitud is not null and not exists(select from cuidared.solicitud_soporte where solicitud_id=p_solicitud
    and cuenta_id=p_cuenta and usuario_objetivo_id=p_usuario and tipo='eliminar_usuario' and estado not in ('resuelta','rechazada')) then raise no_data_found; end if;
  if v_job.estado='preparada' and v_job.vence_en>now() and (v_job.actor_id<>p_actor or v_job.sesion_id<>p_sesion)
    then raise exception 'CR_BO_ELIMINACION_OCUPADA' using errcode='P0001'; end if;
  if v_job.estado='preparada' and v_job.vence_en>now() then
    if v_job.solicitud_id is distinct from p_solicitud then raise exception 'CR_BO_ELIMINACION_OCUPADA' using errcode='P0001'; end if;
    return jsonb_build_object('operacion_id',v_job.operacion_id,'estado','preparada');
  end if;
  insert into cuidared_interno.bo_eliminacion_usuario(usuario_id,operacion_id,cuenta_id,actor_id,sesion_id,aal,motivo,solicitud_id,estado,vence_en)
    values(p_usuario,gen_random_uuid(),p_cuenta,p_actor,p_sesion,p_aal,btrim(p_motivo),p_solicitud,'preparada',now()+interval '5 minutes')
  on conflict(usuario_id) do update set operacion_id=excluded.operacion_id,actor_id=excluded.actor_id,sesion_id=excluded.sesion_id,
    aal=excluded.aal,motivo=excluded.motivo,solicitud_id=excluded.solicitud_id,estado='preparada',
    preparado_en=now(),vence_en=excluded.vence_en returning * into v_job;
  perform cuidared_interno.bo_revocar(array[p_usuario]);
  perform cuidared_interno.bo_auditar(p_actor,v_rol,p_cuenta,'usuario.eliminacion_preparada','usuario',p_usuario::text,null,
    jsonb_build_object('operacion_id',v_job.operacion_id),p_motivo);
  return jsonb_build_object('operacion_id',v_job.operacion_id,'estado','preparada');
end $$;
create function cuidared_api.api_bo_eliminacion_estado(p_actor uuid,p_sesion uuid,p_aal text,p_operacion uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if cuidared_interno.soporte_operador(p_actor,p_sesion,p_aal,true)<>'super_admin' then raise insufficient_privilege; end if;
  return (select jsonb_build_object('estado',estado) from cuidared_interno.bo_eliminacion_usuario
    where operacion_id=p_operacion and actor_id=p_actor and sesion_id=p_sesion);
end $$;

-- La API oficial de Auth elimina auth.users; la cascada y esta guarda hacen atómica la limpieza de nuestro perfil.
create function cuidared_interno.bo_eliminar_perfil_autorizado() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_job cuidared_interno.bo_eliminacion_usuario%rowtype; v_revision jsonb;
begin
  select * into v_job from cuidared_interno.bo_eliminacion_usuario where usuario_id=old.usuario_id for update;
  if not found or v_job.estado<>'preparada' or v_job.vence_en<=now()
    or cuidared_interno.soporte_operador(v_job.actor_id,v_job.sesion_id,v_job.aal,true)<>'super_admin'
    then raise insufficient_privilege; end if;
  perform 1 from cuidared.membresia where usuario_id=old.usuario_id for update;
  v_revision:=cuidared_interno.bo_eliminacion_revision(v_job.cuenta_id,old.usuario_id);
  if not (v_revision->>'permitida')::boolean then raise exception 'CR_BO_ELIMINACION_BLOQUEADA' using errcode='P0001'; end if;
  delete from cuidared.cuidador where usuario_id=old.usuario_id;
  delete from cuidared.membresia where usuario_id=old.usuario_id;
  update cuidared_interno.bo_eliminacion_usuario set estado='eliminado',eliminado_en=clock_timestamp() where usuario_id=old.usuario_id;
  if v_job.solicitud_id is not null then
    update cuidared.solicitud_soporte set estado='resuelta',asignado_a=v_job.actor_id,actualizado_en=clock_timestamp()
      where solicitud_id=v_job.solicitud_id and cuenta_id=v_job.cuenta_id and usuario_objetivo_id=old.usuario_id;
    insert into cuidared.mensaje_soporte(solicitud_id,autor_id,origen,texto,estado) values(v_job.solicitud_id,v_job.actor_id,'backoffice',
      'El usuario fue eliminado. Ya puedes invitarlo nuevamente desde Miembros y seleccionar su rol.','resuelta');
  end if;
  perform cuidared_interno.bo_auditar(v_job.actor_id,'super_admin',v_job.cuenta_id,'usuario.eliminar','usuario',old.usuario_id::text,
    jsonb_build_object('estado',old.estado),jsonb_build_object('eliminado',true,'operacion_id',v_job.operacion_id),v_job.motivo);
  return old;
end $$;
alter table cuidared.usuario drop constraint fk_usuario_auth;
alter table cuidared.usuario add constraint fk_usuario_auth foreign key(usuario_id) references auth.users(id) on delete cascade;
create trigger bo_eliminacion_autorizada before delete on cuidared.usuario
  for each row execute function cuidared_interno.bo_eliminar_perfil_autorizado();

-- Una fila por usuario con su membresía más reciente, incluidas las inactivas.
create function cuidared_interno.bo_usuarios_cuenta(p_id bigint) returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'usuario_id',u.usuario_id,'nombre',u.nombres,'apellido',u.apellidos,'email',u.correo,'rol',r.nombre,
    'rol_codigo',r.codigo,'estado',case when u.estado='activo' then 'activo' else 'deshabilitado' end,
    'estado_usuario',u.estado,'estado_membresia',me.estado,'membresia_id',me.membresia_id::text,'fecha_fin',me.fecha_fin,
    'es_titular',c.usuario_titular_id=u.usuario_id,'bloqueado_por_backoffice',u.bo_estado_anterior is not null,
    'ultimo_acceso',au.last_sign_in_at) order by u.nombres,u.apellidos,u.usuario_id),'[]')
  from (select distinct on (usuario_id) * from cuidared.membresia where cuenta_id=p_id order by usuario_id,membresia_id desc) me
  join cuidared.usuario u using(usuario_id) join cuidared.rol r using(rol_id)
  join cuidared.cuenta c using(cuenta_id) left join auth.users au on au.id=u.usuario_id
$$;

CREATE OR REPLACE FUNCTION cuidared_interno.bo_detalle(p_id bigint, p_rol text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select (to_jsonb(v)||jsonb_build_object('cuenta_id',v.cuenta_id::text,'municipio',m.nombre,'provincia',pv.nombre,
    'plan',jsonb_build_object('id',p.plan_id,'nombre',v.plan_nombre,'max_usuarios',l.limites->'usuarios',
      'max_envejecientes',l.limites->'envejecientes','precio_mensual',p.precio),
    'suscripcion',jsonb_build_object('estado',v.suscripcion_estado,'es_prueba',v.es_prueba,'fecha_inicio',c.fecha_inicio_prueba,
      'fecha_fin',case when v.es_prueba or c.suscripcion_estado='prueba' then c.fecha_fin_prueba
        else c.fecha_fin_vigencia::timestamp at time zone 'America/Santo_Domingo' end),
    'resumen_operativo',jsonb_build_object('total_usuarios',v.usuarios_count,'total_envejecientes',v.envejecientes_count) ||
      case when p_rol in ('super_admin','soporte') and v.es_prueba then jsonb_build_object('visitas_realizadas',
        (select count(*) from cuidared.visita x where x.cuenta_id=c.cuenta_id and x.fecha>=(c.fecha_inicio_prueba at time zone 'America/Santo_Domingo')::date and x.estado='completada'),
        'necesidades_registradas',(select count(*) from cuidared.envejeciente_necesidad n join cuidared.envejeciente e using(envejeciente_id)
          where e.cuenta_id=c.cuenta_id and n.fecha_necesidad>=c.fecha_inicio_prueba)) else '{}'::jsonb end,
    'usuarios',cuidared_interno.bo_usuarios_cuenta(c.cuenta_id),
    'historial_estados',(select coalesce(jsonb_agg(jsonb_build_object('fecha',a.creado_en,'estado',a.valor_nuevo->>'estado','motivo',a.motivo)
      order by a.creado_en desc),'[]') from (select * from cuidared.auditoria_backoffice x where x.cuenta_id=c.cuenta_id
        and x.accion='cuenta.estado' order by x.id desc limit 25) a)
  ))
  from cuidared_interno.bo_cuentas v join cuidared.cuenta c using(cuenta_id)
  left join cuidared.plan p on p.plan_id=c.plan_id left join cuidared.municipio m on m.municipio_cod=c.municipio_cod
  left join cuidared.provincia pv on pv.provincia_cod=m.provincia_cod
  cross join lateral (select cuidared_interno.limites(c.cuenta_id) limites) l where v.cuenta_id=p_id
$function$
;

-- Todas las funciones internas permanecen privadas; solo se conceden entradas con autorización explícita.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure firma from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('cuidared_interno','cuidared_api') and (p.proname like 'soporte_%' or p.proname like 'api_soporte_%'
      or p.proname like 'api_bo_soporte_%' or p.proname like 'api_bo_eliminacion_%' or p.proname like 'bo_eliminacion_%'
      or p.proname in ('bo_eliminar_perfil_autorizado','bo_usuarios_cuenta'))
  loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f.firma);
    if f.firma::text like 'cuidared_api.api_soporte_%' then execute format('grant execute on function %s to authenticated',f.firma);
    elsif f.firma::text like 'cuidared_api.api_bo_%' then execute format('grant execute on function %s to service_role',f.firma); end if;
  end loop;
end $$;
notify pgrst,'reload schema';
commit;
