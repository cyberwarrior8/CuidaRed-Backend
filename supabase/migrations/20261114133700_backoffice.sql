-- Backoffice CuidaRed · BO-01 a BO-34. Requiere las migraciones de acceso y fases 2 a 4.
begin;

alter table cuidared.cuenta add column estado text not null default 'activa' check (estado in ('activa','deshabilitada')),
  add column motivo_deshabilitacion text, add column deshabilitado_por uuid references auth.users(id),
  add column deshabilitado_en timestamptz;
alter table cuidared.usuario add column bo_estado_anterior text, add column motivo_deshabilitacion text,
  add column deshabilitado_por uuid references auth.users(id), add column deshabilitado_en timestamptz;
alter table cuidared.plan add column bo_gratuito boolean not null default false;
create unique index bo_plan_gratuito_tipo on cuidared.plan (tipo_cuenta_id) where bo_gratuito and estado = 'activo';

-- Catálogo base. Los planes comerciales se cargan por separado.
insert into cuidared.plan_categoria(nombre) values ('Gratuito') on conflict(nombre) do nothing;
insert into cuidared.plan(nombre,plan_categoria_id,tipo_cuenta_id,precio,periodicidad,estado,limite_envejecientes,bo_gratuito)
select case t.codigo when 'familia' then 'Gratuito' else 'Gratuito Organización' end,
  k.plan_categoria_id,t.tipo_cuenta_id,0,'sin_vencimiento','activo',1,true
from cuidared.tipo_cuenta t cross join cuidared.plan_categoria k
where t.codigo in ('familia','organizacion') and k.nombre='Gratuito'
on conflict(nombre) do nothing;
update cuidared.plan p set bo_gratuito=true from cuidared.tipo_cuenta t where t.tipo_cuenta_id=p.tipo_cuenta_id
  and p.nombre=case t.codigo when 'familia' then 'Gratuito' when 'organizacion' then 'Gratuito Organización' end
  and p.precio=0 and p.periodicidad='sin_vencimiento';
insert into cuidared.plan_funcionalidad(plan_id,funcionalidad)
select p.plan_id,f.funcionalidad from cuidared.plan p join cuidared.prueba_funcionalidad f using(tipo_cuenta_id)
where p.bo_gratuito and f.funcionalidad='registro_visitas' on conflict do nothing;

create table cuidared.usuario_backoffice (
  usuario_id uuid primary key references auth.users(id) on delete cascade,
  rol text not null check (rol in ('super_admin','soporte','auditor')), activo boolean not null default true,
  creado_en timestamptz not null default now()
);
create table cuidared.configuracion_sistema (
  clave text primary key, valor integer not null, minimo integer not null, maximo integer not null,
  descripcion text not null, actualizado_en timestamptz, actualizado_por uuid references auth.users(id),
  check (valor between minimo and maximo)
);
insert into cuidared.configuracion_sistema(clave,valor,minimo,maximo,descripcion) values
  ('prueba_duracion_dias',14,1,365,'Duración de las nuevas pruebas (días)'),
  ('prueba_max_extensiones',2,0,10,'Máximo de extensiones por cuenta'),
  ('prueba_max_dias_extension',30,0,30,'Máximo de días por extensión'),
  ('prueba_dias_preaviso',7,0,90,'Días de preaviso para pruebas por vencer'),
  ('prueba_dias_reactivacion',7,0,90,'Días disponibles para reactivar una prueba vencida'),
  ('log_retencion_dias',90,1,3650,'Retención de los logs técnicos (días)');
create table cuidared.extension_prueba (
  id bigint generated always as identity primary key, cuenta_id bigint not null references cuidared.cuenta,
  dias integer not null check (dias in (7,14,30)), motivo text not null,
  fin_anterior timestamptz not null, fin_nuevo timestamptz not null, creado_por uuid not null references auth.users,
  creado_en timestamptz not null default now()
);
create index bo_extension_cuenta on cuidared.extension_prueba(cuenta_id);
create table cuidared.marca_logo (
  id uuid primary key default gen_random_uuid(), variante text not null check (variante in ('completo_claro','completo_oscuro','isotipo')),
  ruta text, version integer not null, vigente boolean not null default true,
  creado_por uuid not null references auth.users, creado_en timestamptz not null default now(),
  unique(variante,version)
);
create unique index bo_logo_vigente on cuidared.marca_logo(variante) where vigente;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('cuidared-marca','cuidared-marca',true,2097152,array['image/png'])
on conflict (id) do nothing;
create table cuidared.log_sistema (
  id bigint generated always as identity primary key, creado_en timestamptz not null default now(),
  nivel text not null check (nivel in ('info','warn','error','critical')),
  origen text not null check (origen in ('api','auth','sync','job','frontend','backoffice')),
  request_id uuid, metodo text, ruta text, http_status integer, usuario_id uuid, cuenta_id bigint,
  mensaje text not null, detalle_sanitizado jsonb, stack_sanitizado text
);
create index bo_log_fecha on cuidared.log_sistema(creado_en desc,id desc);
create index bo_log_nivel on cuidared.log_sistema(nivel,creado_en desc);
create index bo_log_origen on cuidared.log_sistema(origen,creado_en desc);
create index bo_log_cuenta on cuidared.log_sistema(cuenta_id,creado_en desc);
create index bo_log_usuario on cuidared.log_sistema(usuario_id,creado_en desc);
create index bo_log_request on cuidared.log_sistema(request_id);
create table cuidared.auditoria_backoffice (
  id bigint generated always as identity primary key, creado_en timestamptz not null default now(),
  usuario_id uuid, rol text not null, cuenta_id bigint, accion text not null, entidad text not null, entidad_id text,
  valor_anterior jsonb, valor_nuevo jsonb, motivo text, ip inet, user_agent text
);
create index bo_audit_fecha on cuidared.auditoria_backoffice(creado_en desc,id desc);
create index bo_audit_cuenta on cuidared.auditoria_backoffice(cuenta_id,creado_en desc);
create index bo_audit_usuario on cuidared.auditoria_backoffice(usuario_id,creado_en desc);
create index bo_audit_entidad on cuidared.auditoria_backoffice(entidad,entidad_id,creado_en desc);
create index bo_audit_accion on cuidared.auditoria_backoffice(accion,creado_en desc);
create index bo_cuenta_estado_fecha on cuidared.cuenta(estado,fecha_creacion desc);
create index bo_cuenta_prueba_fecha on cuidared.cuenta(fecha_fin_prueba) where suscripcion_estado = 'prueba';
create index bo_cuenta_fecha on cuidared.cuenta(fecha_creacion desc,cuenta_id desc);

-- Señal sin identificadores ni contenido operativo. La API vuelve a comprobar el rol al releer.
create table cuidared.bo_evento (
  id bigint generated always as identity primary key, tema text not null,
  transaccion xid8 not null default pg_current_xact_id(),
  creado_en timestamptz not null default now()
);
create index bo_evento_transaccion on cuidared.bo_evento(transaccion);
create table cuidared.bo_intento (
  clave text primary key, intentos integer not null, vence_en timestamptz not null
);
create table cuidared.bo_sesion_admitida (
  sesion_id uuid primary key references auth.sessions(id) on delete cascade
);
do $$
declare objeto regclass;
begin
  foreach objeto in array array['cuidared.usuario_backoffice','cuidared.configuracion_sistema','cuidared.extension_prueba',
    'cuidared.marca_logo','cuidared.log_sistema','cuidared.auditoria_backoffice','cuidared.bo_evento',
    'cuidared.bo_intento','cuidared.bo_sesion_admitida']::regclass[]
  loop
    execute format('alter table %s enable row level security', objeto);
    execute format('revoke all on table %s from public, anon, authenticated, service_role', objeto);
  end loop;
end $$;

create function cuidared_interno.bo_auditoria_inmutable() returns trigger
language plpgsql set search_path = '' as $$
begin raise insufficient_privilege; end $$;
create trigger bo_auditoria_inmutable before update or delete or truncate on cuidared.auditoria_backoffice
for each statement execute function cuidared_interno.bo_auditoria_inmutable();

create function cuidared_interno.bo_parametro(p_clave text) returns integer
language sql stable set search_path = '' as $$
  select valor from cuidared.configuracion_sistema where clave = p_clave
$$;
create function cuidared_interno.bo_rol(p_actor uuid, p_sesion uuid) returns text
language sql stable set search_path = '' as $$
  select b.rol from cuidared.usuario_backoffice b
  join auth.users u on u.id = b.usuario_id
  join auth.sessions s on s.user_id = b.usuario_id and s.id = p_sesion
  join cuidared.bo_sesion_admitida admitted on admitted.sesion_id = s.id
  left join cuidared.sesion_acceso a on a.sesion_id = s.id
  where b.usuario_id = p_actor and b.activo and u.email_confirmed_at is not null and u.deleted_at is null
    and (u.banned_until is null or u.banned_until <= now())
    and s.created_at + interval '12 hours' > now() and (s.not_after is null or s.not_after > now())
    and a.revocada_en is null and coalesce(a.ultima_actividad,s.created_at) + interval '30 minutes' > now()
$$;
create function cuidared_interno.bo_auditar(p_actor uuid,p_rol text,p_cuenta bigint,p_accion text,p_entidad text,
  p_id text,p_antes jsonb,p_despues jsonb,p_motivo text,p_ip inet default null,p_agente text default null)
returns void language sql set search_path = '' as $$
  insert into cuidared.auditoria_backoffice(usuario_id,rol,cuenta_id,accion,entidad,entidad_id,
    valor_anterior,valor_nuevo,motivo,ip,user_agent)
  values(p_actor,p_rol,p_cuenta,p_accion,p_entidad,p_id,p_antes,p_despues,p_motivo,p_ip,left(p_agente,256))
$$;
create function cuidared_interno.bo_revocar(p_usuarios uuid[]) returns void
language sql set search_path = '' as $$
  insert into cuidared.sesion_acceso(sesion_id,ultima_actividad,revocada_en)
  select id,now(),now() from auth.sessions where user_id = any(p_usuarios)
  on conflict (sesion_id) do update set revocada_en = excluded.revocada_en
$$;
create function cuidared_interno.bo_eventos() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into cuidared.bo_evento(tema) values (tg_argv[0]);
  return null;
end $$;
do $$
declare evento text[];
begin
  foreach evento slice 1 in array array[
    ['cuenta','operacion'],['membresia','operacion'],['usuario','operacion'],['envejeciente','operacion'],
    ['visita','operacion'],['envejeciente_necesidad','operacion'],['pago','operacion'],['plan','operacion'],
    ['configuracion_sistema','configuracion'],['parametro','configuracion'],['marca_logo','marca'],
    ['log_sistema','logs'],['auditoria_backoffice','auditoria']
  ] loop
    execute format('create trigger bo_evento after insert or update or delete on cuidared.%I for each statement execute function cuidared_interno.bo_eventos(%L)',evento[1],evento[2]);
  end loop;
end $$;
create function cuidared_api.api_bo_eventos(p_cursor text) returns jsonb
language sql stable security definer set search_path = '' as $$
  with limite as (select pg_snapshot_xmin(pg_current_snapshot()) proximo)
  select jsonb_build_object('cursor',proximo::text,'temas',
    case when p_cursor is null then '["conexion"]'::jsonb else
      coalesce((select jsonb_agg(distinct tema) from cuidared.bo_evento
        where transaccion>=p_cursor::xid8 and transaccion<proximo),'[]') end)
  from limite
$$;

-- Prórroga y alta configurable. Las fechas históricas y el inicio de la prueba se conservan.
alter table cuidared.cuenta drop constraint ck_cuenta_prueba_7_dias;
alter table cuidared.cuenta add constraint bo_cuenta_prueba_coherente check (case when prueba_historica then
  fecha_inicio_prueba is null and fecha_fin_prueba is null
  else (fecha_inicio_prueba is null and fecha_fin_prueba is null and not prueba_gratuita and suscripcion_estado <> 'prueba')
    or (prueba_gratuita and fecha_inicio_prueba is not null and fecha_fin_prueba > fecha_inicio_prueba) end);
create or replace function cuidared.fn_prueba_inmutable() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.prueba_historica or new.fecha_inicio_prueba_historica is not null or new.fecha_fin_prueba_historica is not null then
      raise check_violation;
    end if;
    if new.suscripcion_estado = 'prueba' then
      new.fecha_fin_prueba := new.fecha_inicio_prueba
        + make_interval(hours => 24 * cuidared_interno.bo_parametro('prueba_duracion_dias'));
    end if;
    return new;
  end if;
  if new.fecha_inicio_prueba is distinct from old.fecha_inicio_prueba
     or new.fecha_inicio_prueba_historica is distinct from old.fecha_inicio_prueba_historica
     or new.fecha_fin_prueba_historica is distinct from old.fecha_fin_prueba_historica
     or new.prueba_historica is distinct from old.prueba_historica
     or new.prueba_gratuita is distinct from old.prueba_gratuita
     or (new.fecha_fin_prueba is distinct from old.fecha_fin_prueba and not exists (
       select 1 from cuidared.extension_prueba e where e.cuenta_id = old.cuenta_id
       and e.fin_anterior = old.fecha_fin_prueba and e.fin_nuevo = new.fecha_fin_prueba)) then
    raise check_violation;
  end if;
  return new;
end $$;

create or replace function cuidared_interno.acceso_operativo(p_cuenta_id bigint) returns boolean
language sql stable set search_path = '' as $$
  select coalesce((select c.estado = 'activa' and case c.suscripcion_estado
    when 'prueba' then now() >= c.fecha_inicio_prueba and now() < c.fecha_fin_prueba
    when 'activa' then p.estado = 'activo' and (c.fecha_fin_vigencia is null or c.fecha_fin_vigencia >= cuidared_interno.hoy())
    else false end from cuidared.cuenta c left join cuidared.plan p using(plan_id) where c.cuenta_id = p_cuenta_id),false)
$$;
-- El control central abarca también llamadas directas a RPC y sincronizaciones offline.
create or replace function cuidared_interno.membresia_activa(p_cuenta_id bigint,p_usuario_id uuid)
returns table (membresia_id bigint,rol text,tipo text,tipo_cuenta_id smallint,rol_id smallint)
language sql stable set search_path = '' as $$
  select m.membresia_id,r.codigo::text,t.codigo::text,t.tipo_cuenta_id,r.rol_id
  from cuidared.membresia m join cuidared.rol r on r.rol_id=m.rol_id and r.activo
  join cuidared.cuenta c on c.cuenta_id=m.cuenta_id
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id=c.tipo_cuenta_id
  join cuidared.usuario u on u.usuario_id=m.usuario_id and u.estado='activo'
  where m.cuenta_id=p_cuenta_id and m.usuario_id=p_usuario_id and m.estado='activa'
    and m.fecha_inicio<=cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin>=cuidared_interno.hoy())
    and c.estado='activa' limit 1
$$;

create function cuidared_interno.bo_verificar_cuenta(p_cuenta bigint,p_actor uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if exists(select 1 from cuidared.cuenta c join cuidared.membresia m using(cuenta_id)
    where c.cuenta_id=p_cuenta and m.usuario_id=p_actor and m.estado='activa' and c.estado='deshabilitada') then
    raise exception 'CR_CUENTA_DESHABILITADA';
  end if;
end $$;
create or replace function cuidared_api.api_contexto_cuenta(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := cuidared_interno.exigir_sesion();
begin
  if p_cuenta_id is null or p_cuenta_id<=0 then raise invalid_parameter_value; end if;
  perform cuidared_interno.bo_verificar_cuenta(p_cuenta_id,v_uid);
  return cuidared_interno.contexto(p_cuenta_id,v_uid);
end $$;

-- Una sesión PWA es válida si hay al menos otra cuenta habilitada o si el usuario todavía puede autorregistrarse.
alter function cuidared_api.api_sesion(text) set schema cuidared_interno;
alter function cuidared_interno.api_sesion(text) rename to bo_sesion_base;
revoke all on function cuidared_interno.bo_sesion_base(text) from public,anon,authenticated,service_role;
create function cuidared_api.api_sesion(p_accion text default 'validar') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare resultado jsonb;
begin
  if exists(select 1 from cuidared.usuario_backoffice where usuario_id=auth.uid() and activo) then
    return jsonb_build_object('vigente',false,'motivo','usuario_inactivo');
  end if;
  if p_accion in ('validar','actividad') and exists (
    select 1 from cuidared.membresia m where m.usuario_id=auth.uid() and m.estado='activa'
      and m.fecha_inicio<=cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin>=cuidared_interno.hoy())
  ) and not exists (
    select 1 from cuidared.membresia m join cuidared.cuenta c using(cuenta_id)
    where m.usuario_id=auth.uid() and c.estado='activa' and (m.estado='pendiente' or (m.estado='activa'
      and m.fecha_inicio<=cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin>=cuidared_interno.hoy())))
  ) then return jsonb_build_object('vigente',false,'motivo','cuenta_deshabilitada'); end if;
  resultado := cuidared_interno.bo_sesion_base(p_accion);
  return resultado;
end $$;
revoke all on function cuidared_api.api_sesion(text) from public,anon;
grant execute on function cuidared_api.api_sesion(text) to authenticated;

-- API privada para Express. Una clave publicable no puede ejecutar estas operaciones.
create function cuidared_api.api_bo_admitir(p_actor uuid,p_sesion uuid,p_ip inet,p_agente text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from cuidared.usuario_backoffice b join auth.sessions s on s.user_id=b.usuario_id
    where b.usuario_id=p_actor and b.activo and s.id=p_sesion
      and not exists(select 1 from cuidared.membresia m where m.usuario_id=b.usuario_id)) then
    perform cuidared_interno.bo_auditar(p_actor,'sin_rol',null,'acceso.denegado','sesion',p_sesion::text,null,null,
      'Identidad sin membresía activa de backoffice',p_ip,p_agente);
    return false;
  end if;
  insert into cuidared.bo_sesion_admitida values(p_sesion) on conflict do nothing;
  return true;
end $$;

create function cuidared_api.api_bo_sesion(p_actor uuid,p_sesion uuid,p_aal text,p_accion text,p_ip inet,p_agente text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_rol text; v_miembro boolean;
begin
  select activo into v_miembro from cuidared.usuario_backoffice where usuario_id=p_actor;
  if v_miembro is not true then
    perform cuidared_interno.bo_auditar(p_actor,'sin_rol',null,'acceso.denegado','sesion',p_sesion::text,null,null,
      'Identidad sin membresía activa de backoffice',p_ip,p_agente);
    return jsonb_build_object('estado','denegado');
  end if;
  if not exists(select 1 from cuidared.bo_sesion_admitida where sesion_id=p_sesion) then
    perform cuidared_interno.bo_auditar(p_actor,'sin_rol',null,'acceso.denegado','sesion',p_sesion::text,null,null,
      'Sesión sin ingreso por el backoffice',p_ip,p_agente);
    return jsonb_build_object('estado','denegado');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_sesion::text,0));
  v_rol := cuidared_interno.bo_rol(p_actor,p_sesion);
  if v_rol is null then return jsonb_build_object('estado','expirada'); end if;
  if v_rol='super_admin' and p_aal is distinct from 'aal2' then return jsonb_build_object('estado','mfa'); end if;
  if p_accion in ('ingreso','actividad','salida') then
    insert into cuidared.sesion_acceso(sesion_id,ultima_actividad,revocada_en)
    values(p_sesion,now(),case when p_accion='salida' then now() end)
    on conflict(sesion_id) do update set ultima_actividad=excluded.ultima_actividad,revocada_en=excluded.revocada_en;
  end if;
  if p_accion in ('ingreso','salida') then
    perform cuidared_interno.bo_auditar(p_actor,v_rol,null,'sesion.'||p_accion,'sesion',p_sesion::text,null,null,null,p_ip,p_agente);
  end if;
  return (select jsonb_build_object('estado','ok','usuario_id',u.id,'rol',v_rol,
    'nombre',coalesce(v.nombres||' '||v.apellidos,u.email),'correo',u.email)
    from auth.users u left join cuidared.usuario v on v.usuario_id=u.id where u.id=p_actor);
end $$;

create function cuidared_api.api_bo_intento(p_clave text,p_accion text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_clave !~ '^[0-9a-f]{64}$' then raise invalid_parameter_value; end if;
  if p_accion='fallo' then
    insert into cuidared.bo_intento values(p_clave,1,now()+interval '15 minutes')
    on conflict(clave) do update set intentos=case when bo_intento.vence_en<=now() then 1 else bo_intento.intentos+1 end,
      vence_en=case when bo_intento.vence_en<=now() then excluded.vence_en else bo_intento.vence_en end;
  elsif p_accion='exito' then
    delete from cuidared.bo_intento where clave=p_clave;
  end if;
  return exists(select 1 from cuidared.bo_intento where clave=p_clave and vence_en>now() and intentos>=5);
end $$;

create function cuidared_api.api_bo_log(p_evento jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into cuidared.log_sistema(nivel,origen,request_id,metodo,ruta,http_status,usuario_id,cuenta_id,mensaje,detalle_sanitizado,stack_sanitizado)
  values(p_evento->>'nivel',p_evento->>'origen',(p_evento->>'request_id')::uuid,p_evento->>'metodo',p_evento->>'ruta',
    (p_evento->>'http_status')::int,(p_evento->>'usuario_id')::uuid,(p_evento->>'cuenta_id')::bigint,
    left(p_evento->>'mensaje',200),p_evento->'detalle_sanitizado',left(p_evento->>'stack_sanitizado',4000))
$$;

create function cuidared_api.api_bo_auditar(p_actor uuid,p_rol text,p_accion text,p_ip inet,p_agente text,p_motivo text)
returns void language sql security definer set search_path = '' as $$
  select cuidared_interno.bo_auditar(p_actor,p_rol,null,p_accion,'sesion',null,null,null,p_motivo,p_ip,p_agente)
$$;


create view cuidared_interno.bo_pruebas as
select c.cuenta_id,c.nombre,t.nombre tipo,c.fecha_inicio_prueba fecha_inicio,c.fecha_fin_prueba fecha_fin,
  ceil(extract(epoch from c.fecha_fin_prueba-now())/86400)::int dias_restantes,
  (select count(*) from cuidared.extension_prueba e where e.cuenta_id=c.cuenta_id) extensiones_aplicadas,
  case when c.suscripcion_estado<>'prueba' or c.fecha_fin_prueba<=now() then 'vencida'
       when c.fecha_fin_prueba<=now()+make_interval(hours=>24*cuidared_interno.bo_parametro('prueba_dias_preaviso')) then 'por_vencer'
       else 'activa' end estado_prueba
from cuidared.cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id)
left join cuidared.plan p using(plan_id)
where c.fecha_fin_prueba is not null and (c.suscripcion_estado in ('prueba','vencida') or p.bo_gratuito);

create view cuidared_interno.bo_cuentas as
select c.cuenta_id,c.nombre,c.correo,c.telefono,c.direccion,t.nombre tipo,t.codigo tipo_codigo,cat.nombre categoria,
  c.estado,c.motivo_deshabilitacion,c.plan_id,coalesce(p.nombre,case when c.suscripcion_estado='prueba' then 'Prueba gratuita' end) plan_nombre,
  case when c.suscripcion_estado='prueba' and c.fecha_fin_prueba<=now()
         or c.suscripcion_estado='activa' and c.fecha_fin_vigencia<cuidared_interno.hoy() then 'vencida'
       else c.suscripcion_estado end suscripcion_estado,
  c.suscripcion_estado='prueba' and c.fecha_fin_prueba>now() es_prueba,
  greatest(0,pr.dias_restantes_prueba) dias_restantes_prueba,
  (select count(distinct m.usuario_id) from cuidared.membresia m join cuidared.usuario u using(usuario_id)
    where m.cuenta_id=c.cuenta_id and m.estado='activa' and u.estado='activo'
    and m.fecha_inicio<=cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin>=cuidared_interno.hoy())) usuarios_count,
  (select count(*) from cuidared.envejeciente e where e.cuenta_id=c.cuenta_id) envejecientes_count,
  c.fecha_creacion fecha_registro,
  (select max(u.last_sign_in_at) from cuidared.membresia m join auth.users u on u.id=m.usuario_id where m.cuenta_id=c.cuenta_id) ultimo_acceso
from cuidared.cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id)
left join cuidared.categoria_cuenta cat using(categoria_cuenta_id)
left join cuidared.plan p using(plan_id)
left join lateral (select dias_restantes dias_restantes_prueba from cuidared_interno.bo_pruebas pp where pp.cuenta_id=c.cuenta_id) pr on true;

create function cuidared_interno.bo_pagina(p_data jsonb,p_total bigint,p_page int,p_limit int) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('data',coalesce(p_data,'[]'::jsonb),'meta',jsonb_build_object(
    'total',p_total,'page',p_page,'limit',p_limit,'totalPages',greatest(1,ceil(p_total::numeric/p_limit))))
$$;

create function cuidared_interno.bo_detalle(p_id bigint,p_rol text) returns jsonb
language sql stable set search_path = '' as $$
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
    'usuarios',(select coalesce(jsonb_agg(jsonb_build_object('usuario_id',u.usuario_id,'nombre',u.nombres,'apellido',u.apellidos,
      'email',u.correo,'rol',r.nombre,'estado',case when u.estado='activo' then 'activo' else 'deshabilitado' end,
      'bloqueado_por_backoffice',u.bo_estado_anterior is not null,'ultimo_acceso',au.last_sign_in_at) order by r.nombre,u.nombres,u.usuario_id),'[]')
      from cuidared.membresia me join cuidared.usuario u using(usuario_id) join cuidared.rol r using(rol_id)
  left join auth.users au on au.id=u.usuario_id where me.cuenta_id=c.cuenta_id and me.estado in ('activa','pendiente')),
    'historial_estados',(select coalesce(jsonb_agg(jsonb_build_object('fecha',a.creado_en,'estado',a.valor_nuevo->>'estado','motivo',a.motivo)
      order by a.creado_en desc),'[]') from (select * from cuidared.auditoria_backoffice x where x.cuenta_id=c.cuenta_id
        and x.accion='cuenta.estado' order by x.id desc limit 25) a)
  ))
  from cuidared_interno.bo_cuentas v join cuidared.cuenta c using(cuenta_id)
  left join cuidared.plan p on p.plan_id=c.plan_id left join cuidared.municipio m on m.municipio_cod=c.municipio_cod
  left join cuidared.provincia pv on pv.provincia_cod=m.provincia_cod
  cross join lateral (select cuidared_interno.limites(c.cuenta_id) limites) l where v.cuenta_id=p_id
$$;

create function cuidared_interno.bo_resumen() returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'cuentas_totales',count(*),'cuentas_activas',count(*) filter(where estado='activa'),
    'cuentas_deshabilitadas',count(*) filter(where estado='deshabilitada'),
    'usuarios_activos',(select count(*) from cuidared.usuario where estado='activo'),
    'pruebas_activas',(select count(*) from cuidared_interno.bo_pruebas where estado_prueba in ('activa','por_vencer')),
    'pruebas_por_vencer',(select count(*) from cuidared_interno.bo_pruebas where estado_prueba='por_vencer'),
    'pruebas_vencidas',(select count(*) from cuidared_interno.bo_pruebas where estado_prueba='vencida'),
    'errores_24h',(select count(*) from cuidared.log_sistema where nivel in ('error','critical') and creado_en>=now()-interval '24 hours'),
    'adultos_mayores_total',(select count(*) from cuidared.envejeciente),
    'visitas_mes',(select count(*) from cuidared.visita where fecha>=date_trunc('month',cuidared_interno.hoy())::date and fecha<=cuidared_interno.hoy() and estado='completada'),
    'necesidades_mes',(select count(*) from cuidared.envejeciente_necesidad where fecha_necesidad>=date_trunc('month',now(),'America/Santo_Domingo'))
  ) from cuidared.cuenta
$$;

create function cuidared_api.api_bo_leer(p_actor uuid,p_sesion uuid,p_aal text,p_recurso text,p_filtros jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rol text := cuidared_interno.bo_rol(p_actor,p_sesion);
  v_page integer := coalesce((p_filtros->>'page')::int,1);
  v_limit integer := coalesce((p_filtros->>'limit')::int,25);
  v_offset bigint := (v_page::bigint-1)*v_limit;
  v_cuenta bigint := (p_filtros->>'cuenta')::bigint;
  v_usuario uuid := (p_filtros->>'usuario')::uuid;
  v_desde timestamptz := (p_filtros->>'desde')::timestamptz;
  v_hasta timestamptz := (p_filtros->>'hasta')::timestamptz;
  v_corte timestamptz := (p_filtros->>'corte')::timestamptz;
  v_search text := lower(p_filtros->>'search');
  v_data jsonb; v_total bigint;
begin
  if v_rol is null or (v_rol='super_admin' and p_aal is distinct from 'aal2') then raise insufficient_privilege; end if;
  if v_page<1 or v_limit not between 25 and 50 then raise invalid_parameter_value; end if;
  if (p_recurso in ('logos') and v_rol<>'super_admin')
     or (p_recurso='configuracion' and v_rol='soporte')
     or (p_recurso='auditoria' and v_rol='soporte' and v_cuenta is null)
     or (v_rol='auditor' and p_filtros->>'origen'='sync' and p_filtros->>'vista'='sync') then raise insufficient_privilege; end if;

  case p_recurso
    when 'resumen' then return cuidared_interno.bo_resumen();
    when 'detalle' then
      v_data := cuidared_interno.bo_detalle(v_cuenta,v_rol);
      if v_data is null then raise no_data_found; end if;
      return v_data;
    when 'planes' then
      return (select coalesce(jsonb_agg(to_jsonb(p) order by p.tipo,p.nombre),'[]') from (
        select p.plan_id,p.nombre,p.limite_usuarios,p.limite_envejecientes,p.precio,p.periodicidad,p.bo_gratuito,t.codigo tipo
        from cuidared.plan p join cuidared.tipo_cuenta t using(tipo_cuenta_id) where p.estado='activo') p);
    when 'metodos' then
      return (select coalesce(jsonb_agg(jsonb_build_object('id',metodo_pago_id,'nombre',nombre) order by nombre),'[]')
        from cuidared.metodo_pago where activo);
    when 'pagos' then
      with filas as materialized (select p.pago_id::text id,p.monto,p.moneda,p.estado,p.fecha_pago fecha,m.nombre metodo
        from cuidared.pago p join cuidared.metodo_pago m using(metodo_pago_id) where p.cuenta_id=v_cuenta),
      pagina as (select * from filas order by fecha desc,id desc limit v_limit offset v_offset)
      select (select jsonb_agg(to_jsonb(p) order by fecha desc,id desc) from pagina p),(select count(*) from filas)
      into v_data,v_total;
    when 'cuentas' then
      with filtradas as materialized (
        select c.cuenta_id,c.fecha_creacion from cuidared.cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id)
        where (v_search is null or strpos(lower(c.nombre),v_search)>0 or strpos(lower(c.correo),v_search)>0)
          and (p_filtros->>'tipo' is null or t.codigo=p_filtros->>'tipo')
          and (p_filtros->>'estado' is null or c.estado=p_filtros->>'estado')
          and (p_filtros->>'plan' is null or c.plan_id=(p_filtros->>'plan')::smallint)
          and (v_desde is null or c.fecha_creacion>=v_desde) and (v_hasta is null or c.fecha_creacion<v_hasta)
          and (p_filtros->>'filtro' is null or exists (select 1 from cuidared_interno.bo_pruebas pr where pr.cuenta_id=c.cuenta_id
             and (pr.estado_prueba=p_filtros->>'filtro' or (p_filtros->>'filtro'='extendida' and pr.extensiones_aplicadas>0))))
      ), pagina as (select cuenta_id from filtradas order by fecha_creacion desc,cuenta_id desc limit v_limit offset v_offset)
      select (select jsonb_agg((to_jsonb(v)-'correo'-'telefono'-'direccion')||jsonb_build_object('cuenta_id',v.cuenta_id::text)
        order by v.fecha_registro desc,v.cuenta_id desc) from pagina f join cuidared_interno.bo_cuentas v using(cuenta_id)),
        (select count(*) from filtradas) into v_data,v_total;
    when 'pruebas' then
      with filas as materialized (select * from cuidared_interno.bo_pruebas pr where p_filtros->>'filtro' is null
        or pr.estado_prueba=p_filtros->>'filtro' or (p_filtros->>'filtro'='extendida' and pr.extensiones_aplicadas>0)),
      pagina as (select * from filas order by fecha_fin,cuenta_id limit v_limit offset v_offset)
      select (select jsonb_agg(to_jsonb(p)||jsonb_build_object('cuenta_id',cuenta_id::text) order by fecha_fin,cuenta_id) from pagina p),
        (select count(*) from filas) into v_data,v_total;
    when 'logos' then
      return (select coalesce(jsonb_agg(to_jsonb(m) order by variante,version desc),'[]') from cuidared.marca_logo m);
    when 'configuracion' then
      return (select jsonb_agg(to_jsonb(c) order by clave) from (
        select clave,valor::text,'number' tipo,descripcion,actualizado_en from cuidared.configuracion_sistema
        union all select nombre,valor,'number',descripcion,null from cuidared.parametro where nombre='dias_sin_visita_alerta') c);
    when 'logs' then
      with filtradas as materialized (select id,creado_en from cuidared.log_sistema l where
        (v_desde is null or l.creado_en>=v_desde) and (v_hasta is null or l.creado_en<v_hasta)
        and (v_corte is null or l.creado_en<=v_corte)
        and (v_cuenta is null or l.cuenta_id=v_cuenta) and (v_usuario is null or l.usuario_id=v_usuario)
        and (p_filtros->>'nivel' is null or l.nivel=p_filtros->>'nivel')
        and (p_filtros->>'origen' is null or l.origen=p_filtros->>'origen')
        and (coalesce(p_filtros->>'vista','') not in ('sync','sync_exportacion') or l.nivel in ('warn','error','critical'))
        and (p_filtros->>'http' is null or l.http_status=(p_filtros->>'http')::int)
        and (v_search is null or strpos(lower(concat_ws(' ',l.mensaje,l.ruta,l.request_id)),v_search)>0)),
      pagina as (select id from filtradas order by creado_en desc,id desc limit v_limit offset v_offset)
      select (select jsonb_agg((to_jsonb(l)-'stack_sanitizado')||jsonb_build_object('id',l.id::text,'cuenta_id',l.cuenta_id::text)
        order by l.creado_en desc,l.id desc) from pagina p join cuidared.log_sistema l using(id)),(select count(*) from filtradas)
      into v_data,v_total;
    when 'log' then
      select (to_jsonb(l)-'stack_sanitizado')||jsonb_build_object('id',l.id::text,'cuenta_id',l.cuenta_id::text,'relacionados',
        coalesce((select jsonb_agg(to_jsonb(r) order by creado_en,id) from (select id::text,creado_en,nivel,mensaje,origen
          from cuidared.log_sistema x where x.request_id=l.request_id and x.id<>l.id order by x.creado_en,x.id limit 50) r),'[]')) ||
        case when v_rol='super_admin' then jsonb_build_object('stack_sanitizado',l.stack_sanitizado) else '{}' end
      into v_data from cuidared.log_sistema l where l.id=(p_filtros->>'id')::bigint;
      if v_data is null then raise no_data_found; end if;
      return v_data;
    when 'auditoria' then
      with filtradas as materialized (select id,creado_en from cuidared.auditoria_backoffice a where
        (v_desde is null or a.creado_en>=v_desde) and (v_hasta is null or a.creado_en<v_hasta)
        and (v_corte is null or a.creado_en<=v_corte)
        and (v_cuenta is null or a.cuenta_id=v_cuenta) and (v_usuario is null or a.usuario_id=v_usuario)
        and (p_filtros->>'entidad' is null or a.entidad=p_filtros->>'entidad')
        and (p_filtros->>'entidad_id' is null or a.entidad_id=p_filtros->>'entidad_id')
        and (p_filtros->>'accion' is null or a.accion=p_filtros->>'accion')),
      pagina as (select id from filtradas order by creado_en desc,id desc limit v_limit offset v_offset)
      select (select jsonb_agg(to_jsonb(a)||jsonb_build_object('id',a.id::text,'cuenta_id',a.cuenta_id::text)
        order by a.creado_en desc,a.id desc) from pagina p join cuidared.auditoria_backoffice a using(id)),(select count(*) from filtradas)
      into v_data,v_total;
    else raise no_data_found;
  end case;
  return cuidared_interno.bo_pagina(v_data,v_total,v_page,v_limit);
end $$;

create function cuidared_api.api_publico_bo_marca() returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(variante,jsonb_build_object('ruta',ruta,'version',version)),'{}')
  from cuidared.marca_logo where vigente
$$;


create function cuidared_api.api_bo_mutar(p_actor uuid,p_sesion uuid,p_aal text,p_accion text,p_datos jsonb,
  p_motivo text,p_ip inet,p_agente text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rol text := cuidared_interno.bo_rol(p_actor,p_sesion);
  v_cuenta bigint := (p_datos->>'cuenta')::bigint;
  v_actor_objetivo uuid := (p_datos->>'usuario')::uuid;
  v_estado text := p_datos->>'estado';
  v_id text := p_datos->>'id';
  v_antes jsonb; v_despues jsonb; v_entidad text;
  v_c cuidared.cuenta; v_u cuidared.usuario; v_p cuidared.plan; v_m cuidared.marca_logo;
  v_config cuidared.configuracion_sistema;
  v_dias int; v_fin timestamptz; v_fecha date; v_version int; v_valor int; v_ruta text; v_pago bigint;
begin
  if v_rol is null or v_rol='auditor' or (v_rol='super_admin' and p_aal is distinct from 'aal2') then raise insufficient_privilege; end if;
  if v_rol<>'super_admin' and p_accion not in ('cuenta.estado','cuenta.editar','usuario.estado','prueba.extender','usuario.revocar','usuario.recuperacion') then
    raise insufficient_privilege;
  end if;
  if p_motivo is null or char_length(btrim(p_motivo)) not between 5 and 400 then raise invalid_parameter_value; end if;
  if v_cuenta is not null then
    if p_accion='usuario.estado' then
      -- El estado del usuario es global. Serializar estas operaciones y coordinar el cupo de gestores con la PWA.
      perform pg_advisory_xact_lock(hashtextextended('cuidared.bo.estado_usuario',0));
      perform cuidared_interno.bloquear_miembros(m.cuenta_id) from (
        select distinct cuenta_id from cuidared.membresia where usuario_id=v_actor_objetivo order by cuenta_id) m;
    end if;
    select * into strict v_c from cuidared.cuenta where cuenta_id=v_cuenta for update;
  end if;
  if p_accion like 'usuario.%' then
    select * into strict v_u from cuidared.usuario u where u.usuario_id=v_actor_objetivo
      and exists(select 1 from cuidared.membresia m where m.cuenta_id=v_cuenta and m.usuario_id=u.usuario_id and m.estado in ('activa','pendiente'))
      and not exists(select 1 from cuidared.usuario_backoffice b where b.usuario_id=u.usuario_id)
      for update;
  end if;
  case p_accion
    when 'cuenta.editar' then
      if not exists(select 1 from cuidared.tipo_cuenta t where t.tipo_cuenta_id=v_c.tipo_cuenta_id and t.codigo='organizacion')
        then raise insufficient_privilege; end if;
      if char_length(btrim(p_datos->>'nombre')) not between 2 and 120 then raise invalid_parameter_value; end if;
      v_entidad:='cuenta'; v_id:=v_cuenta::text;
      v_antes:=jsonb_build_object('nombre',v_c.nombre,'correo',v_c.correo,'telefono',v_c.telefono);
      update cuidared.cuenta set nombre=p_datos->>'nombre',correo=p_datos->>'correo',telefono=p_datos->>'telefono',
        fecha_actualizacion=now() where cuenta_id=v_cuenta;
      v_despues:=jsonb_build_object('nombre',p_datos->>'nombre','correo',p_datos->>'correo','telefono',p_datos->>'telefono');
    when 'cuenta.estado' then
      if v_estado not in ('activa','deshabilitada') or v_estado is null then raise invalid_parameter_value; end if;
      if v_estado=v_c.estado then raise exception 'CR_ESTADO_INVALIDO'; end if;
      v_entidad:='cuenta'; v_id:=v_cuenta::text;
      v_antes:=jsonb_build_object('estado',v_c.estado,'motivo',v_c.motivo_deshabilitacion);
      update cuidared.cuenta set estado=v_estado,fecha_actualizacion=now(),
        motivo_deshabilitacion=case when v_estado='deshabilitada' then p_motivo end,
        deshabilitado_por=case when v_estado='deshabilitada' then p_actor end,
        deshabilitado_en=case when v_estado='deshabilitada' then now() end where cuenta_id=v_cuenta;
      if v_estado='deshabilitada' then
        perform cuidared_interno.bo_revocar(array(select distinct usuario_id from cuidared.membresia where cuenta_id=v_cuenta and estado='activa'));
      end if;
      v_despues:=jsonb_build_object('estado',v_estado,'motivo',case when v_estado='deshabilitada' then p_motivo end);
    when 'usuario.estado' then
      if v_estado not in ('activo','deshabilitado') or v_estado is null then raise invalid_parameter_value; end if;
      v_entidad:='usuario'; v_id:=v_actor_objetivo::text;
      v_antes:=jsonb_build_object('estado',v_u.estado,'motivo',v_u.motivo_deshabilitacion);
      if v_estado='deshabilitado' then
        if v_u.estado<>'activo' then raise exception 'CR_ESTADO_INVALIDO'; end if;
        if exists (
          select 1 from cuidared.membresia m join cuidared.rol r using(rol_id) join cuidared.cuenta c using(cuenta_id)
            join cuidared.tipo_cuenta t using(tipo_cuenta_id)
          where m.usuario_id=v_actor_objetivo and m.estado='activa' and r.activo and r.codigo in ('administrador','coordinador')
            and t.codigo='organizacion' and m.fecha_inicio<=cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin>=cuidared_interno.hoy())
            and not exists (
              select 1 from cuidared.membresia otro join cuidared.usuario u using(usuario_id) join cuidared.rol rr using(rol_id)
              where otro.cuenta_id=m.cuenta_id and otro.usuario_id<>m.usuario_id and otro.estado='activa' and u.estado='activo'
                and rr.activo and rr.codigo in ('administrador','coordinador') and otro.fecha_inicio<=cuidared_interno.hoy()
                and (otro.fecha_fin is null or otro.fecha_fin>=cuidared_interno.hoy()))
        ) then raise exception 'CR_BO_ULTIMO_GESTOR'; end if;
        update cuidared.usuario set estado='suspendido',bo_estado_anterior=v_u.estado,motivo_deshabilitacion=p_motivo,
          deshabilitado_por=p_actor,deshabilitado_en=now(),fecha_actualizacion=now() where usuario_id=v_actor_objetivo;
        perform cuidared_interno.bo_revocar(array[v_actor_objetivo]);
        v_estado:='suspendido';
      else
        if v_u.bo_estado_anterior is null then raise exception 'CR_ESTADO_INVALIDO'; end if;
        v_estado:=v_u.bo_estado_anterior;
        update cuidared.usuario set estado=v_estado,bo_estado_anterior=null,motivo_deshabilitacion=null,
          deshabilitado_por=null,deshabilitado_en=null,fecha_actualizacion=now() where usuario_id=v_actor_objetivo;
      end if;
      v_despues:=jsonb_build_object('estado',v_estado);
    when 'usuario.revocar','usuario.recuperacion' then
      v_entidad:='usuario'; v_id:=v_actor_objetivo::text;
      if p_accion='usuario.revocar' then
        perform cuidared_interno.bo_revocar(array[v_actor_objetivo]);
        v_despues:=jsonb_build_object('sesiones_revocadas',true);
      else
        v_despues:=jsonb_build_object('solicitud_registrada',true);
      end if;
    when 'prueba.extender' then
      v_entidad:='cuenta'; v_id:=v_cuenta::text; v_dias:=(p_datos->>'dias')::int;
      if v_dias is null or v_dias not in (7,14,30) or v_dias>cuidared_interno.bo_parametro('prueba_max_dias_extension')
        or (select count(*) from cuidared.extension_prueba where cuenta_id=v_cuenta)>=cuidared_interno.bo_parametro('prueba_max_extensiones')
      then raise exception 'CR_BO_EXTENSION_LIMITE'; end if;
      perform pg_advisory_xact_lock(hashtextextended('cuidared.registrar_cuenta:'||v_c.usuario_titular_id::text,0));
      if v_c.estado<>'activa' or v_c.fecha_fin_prueba is null or
        v_c.fecha_fin_prueba<now()-make_interval(hours=>24*cuidared_interno.bo_parametro('prueba_dias_reactivacion'))
        or (v_c.suscripcion_estado not in ('prueba','vencida','activa'))
        or (v_c.plan_id is not null and not exists(select 1 from cuidared.plan where plan_id=v_c.plan_id and bo_gratuito))
        or exists(select 1 from cuidared.cuenta c where c.cuenta_id<>v_cuenta and c.usuario_titular_id=v_c.usuario_titular_id
          and c.suscripcion_estado='prueba' and c.fecha_fin_prueba>now()) then raise exception 'CR_BO_PRUEBA_NO_EXTENSIBLE'; end if;
      v_fin:=greatest(now(),v_c.fecha_fin_prueba)+make_interval(hours=>24*v_dias);
      insert into cuidared.extension_prueba(cuenta_id,dias,motivo,fin_anterior,fin_nuevo,creado_por)
        values(v_cuenta,v_dias,p_motivo,v_c.fecha_fin_prueba,v_fin,p_actor);
      update cuidared.cuenta set suscripcion_estado='prueba',fecha_fin_prueba=v_fin,plan_id=null,plan_precio=0,
        fecha_fin_vigencia=null,fecha_actualizacion=now() where cuenta_id=v_cuenta;
      v_antes:=jsonb_build_object('fecha_fin',v_c.fecha_fin_prueba,'estado',v_c.suscripcion_estado);
      v_despues:=jsonb_build_object('fecha_fin',v_fin,'estado','prueba','dias',v_dias);
    when 'cuenta.cambiar_plan' then
      v_entidad:='cuenta'; v_id:=v_cuenta::text; v_fecha:=(p_datos->>'fechaFin')::date;
      select * into strict v_p from cuidared.plan where plan_id=(p_datos->>'planId')::smallint
        and estado='activo' and not bo_gratuito and tipo_cuenta_id=v_c.tipo_cuenta_id;
      if v_fecha<cuidared_interno.hoy() then raise invalid_parameter_value; end if;
      v_antes:=jsonb_build_object('plan_id',v_c.plan_id,'estado',v_c.suscripcion_estado,'fecha_fin',v_c.fecha_fin_vigencia);
      update cuidared.cuenta set plan_id=v_p.plan_id,plan_precio=v_p.precio,fecha_fin_vigencia=v_fecha,
        suscripcion_estado='activa',fecha_actualizacion=now() where cuenta_id=v_cuenta;
      v_despues:=jsonb_build_object('plan_id',v_p.plan_id,'estado','activa','fecha_fin',v_fecha);
    when 'pago.registrar' then
      if (p_datos->>'monto')::numeric not between 0.01 and 9999999 or v_c.plan_id is null
        or not exists(select 1 from cuidared.metodo_pago where activo and metodo_pago_id=(p_datos->>'metodoId')::smallint)
        or (p_datos->>'fecha')::date>cuidared_interno.hoy() then raise invalid_parameter_value; end if;
      insert into cuidared.pago(cuenta_id,plan_id,usuario_id,metodo_pago_id,monto,moneda,estado,fecha_pago)
        values(v_cuenta,v_c.plan_id,v_c.usuario_titular_id,(p_datos->>'metodoId')::smallint,(p_datos->>'monto')::numeric,
          'DOP','completado',(p_datos->>'fecha')::date::timestamp at time zone 'America/Santo_Domingo')
        returning pago_id into v_pago;
      v_entidad:='pago'; v_id:=v_pago::text;
      v_despues:=jsonb_build_object('monto',p_datos->'monto','metodo_id',p_datos->'metodoId','fecha',p_datos->'fecha','estado','completado');
    when 'configuracion.actualizar' then
      v_entidad:='configuracion'; v_valor:=(p_datos->>'valor')::int;
      if v_id='dias_sin_visita_alerta' then
        if v_valor not between 1 and 90 then raise invalid_parameter_value; end if;
        select jsonb_build_object('valor',valor::int) into strict v_antes from cuidared.parametro where nombre=v_id for update;
        update cuidared.parametro set valor=v_valor::text where nombre=v_id;
      else
        select * into strict v_config from cuidared.configuracion_sistema where clave=v_id for update;
        if v_valor not between v_config.minimo and v_config.maximo then raise invalid_parameter_value; end if;
        v_antes:=jsonb_build_object('valor',v_config.valor);
        update cuidared.configuracion_sistema set valor=v_valor,actualizado_en=now(),actualizado_por=p_actor where clave=v_id;
      end if;
      v_despues:=jsonb_build_object('valor',v_valor);
    when 'plan.limites' then
      v_entidad:='plan';
      select * into strict v_p from cuidared.plan where plan_id=v_id::smallint for update;
      v_antes:=jsonb_build_object('adultos',v_p.limite_envejecientes,'usuarios',v_p.limite_usuarios);
      update cuidared.plan set limite_envejecientes=(p_datos->>'adultos')::int,limite_usuarios=(p_datos->>'usuarios')::int
        where plan_id=v_p.plan_id;
      v_despues:=jsonb_build_object('adultos',p_datos->'adultos','usuarios',p_datos->'usuarios');
    when 'logo.publicar','logo.restaurar' then
      v_entidad:='marca_logo'; v_id:=p_datos->>'variante';
      if v_id is null or v_id not in ('completo_claro','completo_oscuro','isotipo') then raise invalid_parameter_value; end if;
      perform pg_advisory_xact_lock(hashtextextended('cuidared.bo.marca:'||v_id,0));
      if p_accion='logo.publicar' then
        v_ruta:=p_datos->>'ruta';
        if v_ruta is null or v_ruta !~ ('^'||v_id||'/[0-9a-f-]{36}[.]png$') then raise invalid_parameter_value; end if;
        if not exists(select 1 from storage.objects where bucket_id='cuidared-marca' and name=v_ruta) then raise no_data_found; end if;
      elsif p_datos->>'id' is not null then
        select ruta into strict v_ruta from cuidared.marca_logo where variante=v_id and id=(p_datos->>'id')::uuid;
      end if;
      select to_jsonb(m) into v_antes from cuidared.marca_logo m where variante=v_id and vigente;
      select coalesce(max(version),0)+1 into v_version from cuidared.marca_logo where variante=v_id;
      update cuidared.marca_logo set vigente=false where variante=v_id and vigente;
      insert into cuidared.marca_logo(variante,ruta,version,creado_por) values(v_id,v_ruta,v_version,p_actor) returning * into v_m;
      delete from cuidared.marca_logo where variante=v_id and version<=v_version-5;
      v_despues:=to_jsonb(v_m);
    else raise no_data_found;
  end case;
  perform cuidared_interno.bo_auditar(p_actor,v_rol,v_cuenta,p_accion,v_entidad,v_id,v_antes,v_despues,p_motivo,p_ip,p_agente);
  return v_despues;
end $$;

-- Proyección de auditoría por lista permitida. No incorpora cédulas, nombres, observaciones ni información clínica.
create function cuidared_interno.bo_auditar_negocio() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  antes jsonb; despues jsonb; fila jsonb; v_id text; v_cuenta bigint; v_rol text; v_accion text;
  v_usuario uuid:=auth.uid();
  v_headers jsonb:=coalesce(nullif(current_setting('request.headers',true),'')::jsonb,'{}');
  v_ip inet;
begin
  if tg_op<>'INSERT' then antes:=to_jsonb(old); end if;
  if tg_op<>'DELETE' then despues:=to_jsonb(new); end if;
  fila:=coalesce(despues,antes);
  v_id:=fila->>tg_argv[0];
  v_cuenta:=(fila->>'cuenta_id')::bigint;
  if v_cuenta is null and fila->>'envejeciente_id' is not null then
    select cuenta_id into v_cuenta from cuidared.envejeciente where envejeciente_id=(fila->>'envejeciente_id')::uuid;
  end if;
  if v_usuario is not null then
    select r.codigo into v_rol from cuidared.membresia m join cuidared.rol r using(rol_id)
    where m.cuenta_id=v_cuenta and m.usuario_id=v_usuario and m.estado='activa' limit 1;
  end if;
  if antes is not null then select coalesce(jsonb_object_agg(k,v),'{}') into antes from jsonb_each(antes) j(k,v) where k=any(tg_argv[1:]); end if;
  if despues is not null then select coalesce(jsonb_object_agg(k,v),'{}') into despues from jsonb_each(despues) j(k,v) where k=any(tg_argv[1:]); end if;
  if tg_table_name='alerta_envejeciente' and tg_op='UPDATE' and antes=despues then return null; end if;
  v_accion:=tg_table_name||'.'||case tg_op when 'INSERT' then 'crear' when 'DELETE' then 'eliminar' else 'editar' end;
  begin v_ip:=nullif(split_part(v_headers->>'x-forwarded-for',',',1),'')::inet;
  exception when invalid_text_representation then v_ip:=null; end;
  perform cuidared_interno.bo_auditar(v_usuario,coalesce(v_rol,case when v_usuario is null then 'sistema' else 'pwa' end),
    v_cuenta,v_accion,tg_table_name,v_id,antes,despues,null,v_ip,v_headers->>'user-agent');
  return null;
end $$;
create trigger bo_audit_cuenta after insert on cuidared.cuenta for each row
execute function cuidared_interno.bo_auditar_negocio('cuenta_id','estado','suscripcion_estado','plan_id');
create trigger bo_audit_adulto after insert or update on cuidared.envejeciente for each row
execute function cuidared_interno.bo_auditar_negocio('envejeciente_id','estado');
create trigger bo_audit_alerta after insert or update of estado on cuidared.alerta_envejeciente for each row
execute function cuidared_interno.bo_auditar_negocio('alerta_envejeciente_id','estado');
create trigger bo_audit_necesidad after insert or update or delete on cuidared.envejeciente_necesidad for each row
execute function cuidared_interno.bo_auditar_negocio('envejeciente_necesidad_id','estado');
create trigger bo_audit_membresia after insert or update or delete on cuidared.membresia for each row
execute function cuidared_interno.bo_auditar_negocio('usuario_id','rol_id','estado');
create trigger bo_audit_usuario after insert or update of estado on cuidared.usuario for each row
execute function cuidared_interno.bo_auditar_negocio('usuario_id','estado');

create function cuidared_interno.bo_auditar_auth() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_accion text := new.payload->>'action'; v_actor text:=new.payload->>'actor_id';
begin
  if v_accion in ('login','logout','login_failed','login_failure','user_login_failed') then
    perform cuidared_interno.bo_auditar(case when v_actor ~ '^[0-9a-f-]{36}$' then v_actor::uuid end,
      'auth',null,'auth.'||v_accion,'sesion',null,null,null,null,nullif(new.ip_address,'')::inet);
  end if;
  return null;
end $$;
create trigger bo_audit_auth after insert on auth.audit_log_entries for each row execute function cuidared_interno.bo_auditar_auth();

insert into cuidared.tipo_alerta(codigo,nombre) values('ausencia_visitas','Seguimiento familiar sin visita')
on conflict do nothing;
create function cuidared_interno.bo_alertas_seguimiento() returns integer
language plpgsql set search_path = '' as $$
declare v_n int;
begin
  perform pg_advisory_xact_lock(hashtextextended('cuidared.bo.alertas_seguimiento',0));
  insert into cuidared.alerta_envejeciente(envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,origen,estado)
  select e.envejeciente_id,a.tipo_alerta_id,p.prioridad_id,
    'Se alcanzó el umbral de seguimiento sin una visita completada.','sistema','pendiente'
  from cuidared.envejeciente e join cuidared.cuenta c using(cuenta_id) join cuidared.tipo_cuenta t using(tipo_cuenta_id)
  cross join cuidared.tipo_alerta a cross join cuidared.prioridad p
  cross join (select parametro_id,valor from cuidared.parametro where nombre='dias_sin_visita_alerta') param
  left join cuidared.configuracion_cuenta cfg on cfg.cuenta_id=c.cuenta_id and cfg.parametro_id=param.parametro_id
  cross join lateral (select max(v.fecha) fecha from cuidared.detalle_visita d join cuidared.visita v using(visita_id)
    where d.envejeciente_id=e.envejeciente_id and v.estado='completada') ultima
  where t.codigo='familia' and a.codigo='ausencia_visitas' and p.codigo='media' and e.estado='activo'
    and cuidared_interno.acceso_operativo(c.cuenta_id)
    and cuidared_interno.hoy()-coalesce(ultima.fecha,(e.fecha_creacion at time zone 'America/Santo_Domingo')::date)
      >=coalesce(cfg.valor,param.valor)::int
    and not exists(select 1 from cuidared.alerta_envejeciente anterior where anterior.envejeciente_id=e.envejeciente_id
      and anterior.tipo_alerta_id=a.tipo_alerta_id
      and (anterior.estado<>'resuelta' or (anterior.fecha_alerta at time zone 'America/Santo_Domingo')::date>=coalesce(ultima.fecha,'-infinity'::date)));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Degradación y limpieza programadas. No se altera el estado ni la historia de los perfiles.
create or replace function cuidared_interno.actualizar_vencimientos() returns integer
language plpgsql set search_path = '' as $$
declare v_c cuidared.cuenta; v_gratis smallint; v_n int:=0; v_estado text;
begin
  for v_c in select c.* from cuidared.cuenta c
    where (c.suscripcion_estado in ('prueba','vencida') and c.fecha_fin_prueba<=now() and c.plan_id is null)
       or (c.suscripcion_estado='activa' and c.fecha_fin_vigencia<cuidared_interno.hoy())
    order by c.cuenta_id for update skip locked
  loop
    v_gratis:=null;
    if v_c.plan_id is null then
      select plan_id into v_gratis from cuidared.plan where tipo_cuenta_id=v_c.tipo_cuenta_id and bo_gratuito and estado='activo';
      if v_gratis is null and v_c.suscripcion_estado='vencida' then continue; end if;
    end if;
    v_estado:=case when v_gratis is null then 'vencida' else 'activa' end;
    update cuidared.cuenta set suscripcion_estado=v_estado,plan_id=coalesce(v_gratis,v_c.plan_id),
      plan_precio=case when v_gratis is not null then 0 else v_c.plan_precio end,
      fecha_fin_vigencia=case when v_gratis is null then v_c.fecha_fin_vigencia end,fecha_actualizacion=now()
      where cuenta_id=v_c.cuenta_id;
    perform cuidared_interno.bo_auditar(null,'sistema',v_c.cuenta_id,'suscripcion.vencer','cuenta',v_c.cuenta_id::text,
      jsonb_build_object('estado',v_c.suscripcion_estado,'plan_id',v_c.plan_id),
      jsonb_build_object('estado',v_estado,'plan_id',coalesce(v_gratis,v_c.plan_id)),'Fin de vigencia');
    v_n:=v_n+1;
  end loop;
  return v_n;
end $$;
create function cuidared_interno.bo_mantenimiento() returns void
language plpgsql set search_path = '' as $$
declare v_n integer; v_alertas integer;
begin
  v_n:=cuidared_interno.actualizar_vencimientos();
  v_alertas:=cuidared_interno.bo_alertas_seguimiento();
  delete from cuidared.log_sistema where creado_en < now()-make_interval(days=>cuidared_interno.bo_parametro('log_retencion_dias'));
  delete from cuidared.bo_evento where creado_en < now()-interval '1 day';
  delete from cuidared.bo_intento where vence_en < now();
  insert into cuidared.log_sistema(nivel,origen,mensaje,detalle_sanitizado)
  values ('info','job','Mantenimiento diario completado',jsonb_build_object('cuentas_actualizadas',v_n,'alertas_generadas',v_alertas));
end $$;

-- El plan gratuito admite solo los primeros perfiles activos según antigüedad; los demás recuperan
-- acceso al ampliar el plan. Las escrituras a perfiles usan además los límites de la API de la PWA.
create function cuidared_interno.bo_perfil_operativo(p_cuenta bigint,p_adulto uuid) returns boolean
language sql stable set search_path = '' as $$
  select coalesce((select not p.bo_gratuito or p.limite_envejecientes is null or exists (
    select 1 from (select e.envejeciente_id from cuidared.envejeciente e
      where e.cuenta_id=p_cuenta and e.estado='activo' order by e.fecha_creacion,e.envejeciente_id
      limit p.limite_envejecientes) q where q.envejeciente_id=p_adulto)
    from cuidared.cuenta c join cuidared.plan p using(plan_id) where c.cuenta_id=p_cuenta),true)
$$;
create function cuidared_interno.bo_limitar_operacion() returns trigger
language plpgsql set search_path = '' as $$
declare v_id uuid:=new.envejeciente_id; v_cuenta bigint;
begin
  if v_id is null then return new; end if;
  if tg_op='UPDATE' and to_jsonb(new)->>'estado' in ('cancelada','cancelado','resuelta','resuelto','inactivo','suspendido')
    then return new; end if;
  select cuenta_id into v_cuenta from cuidared.envejeciente where envejeciente_id=v_id;
  if not cuidared_interno.bo_perfil_operativo(v_cuenta,v_id) then raise exception 'CR_LIMITE_PLAN'; end if;
  return new;
end $$;
create trigger bo_cupo_visita before insert or update on cuidared.detalle_visita
for each row execute function cuidared_interno.bo_limitar_operacion();
create trigger bo_cupo_necesidad before insert or update on cuidared.envejeciente_necesidad
for each row execute function cuidared_interno.bo_limitar_operacion();
create trigger bo_cupo_agenda before insert or update on cuidared.tarea_agenda
for each row execute function cuidared_interno.bo_limitar_operacion();
create trigger bo_cupo_indicacion before insert or update on cuidared.indicacion_medica
for each row execute function cuidared_interno.bo_limitar_operacion();
create trigger bo_cupo_evaluacion before insert on cuidared.evaluacion_riesgo
for each row execute function cuidared_interno.bo_limitar_operacion();
create trigger bo_cupo_riesgo before insert or update on cuidared.envejeciente_riesgo
for each row execute function cuidared_interno.bo_limitar_operacion();
create trigger bo_cupo_perfil before update of nombres,apellidos,cedula,fecha_nacimiento,sexo,direccion,telefono,zona,autonomia,
  condiciones,nota_condicion on cuidared.envejeciente
for each row execute function cuidared_interno.bo_limitar_operacion();

revoke all on all functions in schema cuidared_interno from public,anon,authenticated;
revoke all on cuidared_interno.bo_cuentas,cuidared_interno.bo_pruebas from public,anon,authenticated,service_role;
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='cuidared_api'::regnamespace and p.proname like 'api_bo_%'
  loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;
revoke all on function cuidared_api.api_publico_bo_marca() from public,anon,authenticated;
grant usage on schema cuidared_api to anon,service_role;
grant execute on function cuidared_api.api_publico_bo_marca() to anon,authenticated;
notify pgrst,'reload schema';
commit;
