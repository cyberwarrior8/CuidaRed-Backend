begin;
-- Seguimiento de visitas: contacto externo, confirmación organizativa y aportes privados.
-- © 2026 Equipo CuidaRed – INTEC. Cambios autorizados por el usuario en esta conversación.
alter table cuidared.solicitud_visita add column hora_fin_propuesta time;
alter table cuidared.solicitud_visita add column referencia_codigo uuid;
alter table cuidared.solicitud_visita add column creada_por_usuario_id uuid references cuidared.usuario(usuario_id);
create index solicitud_visita_creador on cuidared.solicitud_visita(creada_por_usuario_id) where creada_por_usuario_id is not null;
-- Las altas administrativas no inventan cédulas ni apellidos de un contacto externo.
alter table cuidared.solicitud_visita alter column visitante_cedula drop not null;
alter table cuidared.solicitud_visita alter column visitante_nombres type varchar(120);
alter table cuidared.solicitud_visita drop constraint solicitud_visita_visitante_nombres_check;
alter table cuidared.solicitud_visita add constraint solicitud_visita_visitante_nombres_check check(length(btrim(visitante_nombres)) between 2 and 120);
alter table cuidared.solicitud_visita drop constraint solicitud_visita_visitante_apellidos_check;
alter table cuidared.solicitud_visita add constraint solicitud_visita_visitante_apellidos_check check(length(btrim(visitante_apellidos)) between (case when creada_por_usuario_id is null then 2 else 0 end) and 60);
alter table cuidared.solicitud_visita add constraint solicitud_identidad_origen check(creada_por_usuario_id is not null or visitante_cedula is not null);
alter table cuidared.solicitud_visita alter column visitante_telefono drop not null;
alter table cuidared.solicitud_visita add constraint solicitud_telefono_origen check(creada_por_usuario_id is not null or visitante_telefono is not null);
alter table cuidared.solicitud_visita add constraint solicitud_ventana_propuesta check(hora_fin_propuesta is null or hora_fin_propuesta>hora_propuesta);
alter table cuidared.visita
  add column visitante_externo jsonb not null default '{}'::jsonb check(jsonb_typeof(visitante_externo)='object'),
  add column registro_campo_en timestamptz,
  add column confirmada_por uuid references cuidared.usuario(usuario_id),
  add column confirmada_en timestamptz,
  add column confirmacion_notas text check(confirmacion_notas is null or length(btrim(confirmacion_notas)) between 3 and 600);
create index visita_confirmada_por on cuidared.visita(confirmada_por) where confirmada_por is not null;

create table cuidared.evidencia_solicitud_visita (
  evidencia_id uuid primary key,
  solicitud_id uuid not null references cuidared.solicitud_visita(solicitud_visita_id),
  ruta text not null unique,
  nombre_archivo text not null check(length(nombre_archivo) between 1 and 100),
  tamano_bytes integer not null check(tamano_bytes between 1 and 2097152),
  archivo_hash text not null check(archivo_hash~'^[0-9a-f]{64}$'),
  creada_en timestamptz not null default now(),
  adjunta_en timestamptz,
  unique(solicitud_id,archivo_hash)
);
create index evidencia_solicitud_fecha on cuidared.evidencia_solicitud_visita(solicitud_id,creada_en);
alter table cuidared.evidencia_solicitud_visita enable row level security;
revoke all on cuidared.evidencia_solicitud_visita from public,anon,authenticated,service_role;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('visitas-visitantes','visitas-visitantes',false,2097152,array['image/jpeg']);
create trigger evidencia_solicitud_evento after insert or update or delete on cuidared.evidencia_solicitud_visita
 for each statement execute function cuidared_interno.bo_eventos('operacion');

create function cuidared_interno.validar_visitante_programado(p_datos jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare v_tipo text; v_nombre text; v_correo text; v_entidad text; v_clase text; v_tel text; v_cantidad integer; v_aporte text;
begin
  -- Compatibilidad con visitas internas ya integradas: el nuevo formulario siempre aporta el contacto.
  if p_datos is null or p_datos='{}'::jsonb then return '{}'::jsonb; end if;
  if jsonb_typeof(p_datos)<>'object' or p_datos-array['tipo','nombre','correo','telefono','entidad','tipo_entidad','cantidad','aporte']<>'{}'::jsonb then raise invalid_parameter_value; end if;
  v_tipo:=cuidared_interno.v_texto(p_datos->'tipo',1,20);
  v_nombre:=cuidared_interno.v_texto(p_datos->'nombre',3,120);
  v_correo:=lower(cuidared_interno.v_texto(p_datos->'correo',5,254));
  v_tel:=cuidared_interno.v_texto(p_datos->'telefono',10,16,false);
  v_entidad:=cuidared_interno.v_texto(p_datos->'entidad',2,160,v_tipo='institucional');
  v_clase:=cuidared_interno.v_texto(p_datos->'tipo_entidad',1,30,v_tipo='institucional');
  v_aporte:=cuidared_interno.v_texto(p_datos->'aporte',1,300,false);
  if jsonb_typeof(p_datos->'cantidad') is distinct from 'number' or p_datos->>'cantidad'!~'^[1-9][0-9]{0,3}$' then raise invalid_parameter_value; end if;
  v_cantidad:=(p_datos->>'cantidad')::integer;
  if v_tipo not in ('personal','institucional') or v_correo!~*'^[^@\s]+@[^@\s]+\.[^@\s]+$'
    or (v_tel is not null and v_tel!~'^\+?[0-9]{10,15}$')
    or (v_tipo='personal' and (v_entidad is not null or v_clase is not null or v_aporte is not null))
    or (v_tipo='institucional' and v_clase not in ('fundacion','iglesia','universidad','centro_educativo','empresa','grupo_comunitario','otro')) then raise invalid_parameter_value; end if;
  return jsonb_strip_nulls(jsonb_build_object('tipo',v_tipo,'nombre',v_nombre,'correo',v_correo,'telefono',v_tel,'entidad',v_entidad,'tipo_entidad',v_clase,'cantidad',v_cantidad,'aporte',v_aporte));
end $$;

create function cuidared_interno.visita_solicitud_administrativa(p_visita uuid,p_uid uuid,p_hash text,p_referencia uuid) returns void
language plpgsql set search_path='' as $$
declare v cuidared.visita; s uuid; contacto jsonb; destinatarios text;
begin
  select * into v from cuidared.visita where visita_id=p_visita;
  contacto:=v.visitante_externo;
  if contacto='{}'::jsonb then return; end if;
  if p_hash is null or p_hash!~'^[0-9a-f]{64}$' or p_referencia is null or v.pendiente_autorizacion then raise invalid_parameter_value; end if;
  select string_agg(e.nombres||' '||e.apellidos,', ' order by e.envejeciente_id) into destinatarios
    from cuidared.detalle_visita d join cuidared.envejeciente e using(envejeciente_id) where d.visita_id=p_visita;
  insert into cuidared.solicitud_visita(cuenta_id,visitante_nombres,visitante_apellidos,visitante_correo,visitante_telefono,
    visitante_cedula,creada_por_usuario_id,persona_a_visitar,fecha_propuesta,hora_propuesta,hora_fin_propuesta,motivo,codigo_hash,referencia_codigo,
    tipo_visita,entidad_visitante,tipo_entidad,cantidad_visitantes,aporte_previsto)
  values(v.cuenta_id,contacto->>'nombre','',contacto->>'correo',contacto->>'telefono',null,p_uid,
    case when contacto->>'tipo'='personal' then left(destinatarios,120) end,v.fecha,v.hora_programada,v.hora_fin_programada,v.razon,p_hash,p_referencia,
    contacto->>'tipo',contacto->>'entidad',contacto->>'tipo_entidad',(contacto->>'cantidad')::integer,contacto->>'aporte') returning solicitud_visita_id into s;
  update cuidared.visita set origen='solicitud',solicitud_visita_id=s where visita_id=p_visita;
  update cuidared.solicitud_visita set estado='autorizada',visita_id=p_visita,revisada_por=p_uid,revisada_en=now(),
    envejeciente_id=case when contacto->>'tipo'='personal' then (select envejeciente_id from cuidared.detalle_visita where visita_id=p_visita order by envejeciente_id limit 1) end
    where solicitud_visita_id=s;
end $$;

create or replace function cuidared_interno.es_visita_institucional(p_visita uuid) returns boolean
language sql stable set search_path='' as $$
 select exists(select from cuidared.visita v left join cuidared.solicitud_visita s on s.solicitud_visita_id=v.solicitud_visita_id
 where v.visita_id=p_visita and (s.tipo_visita='institucional' or v.visitante_externo->>'tipo'='institucional'))
$$;

create function cuidared_interno.publico_exigir_aporte(p_hash text) returns cuidared.solicitud_visita
language plpgsql set search_path='' as $$
declare v_s cuidared.solicitud_visita; v_v cuidared.visita;
begin
  if p_hash is null or p_hash!~'^[0-9a-f]{64}$' then raise no_data_found; end if;
  select * into v_s from cuidared.solicitud_visita where codigo_hash=p_hash for update;
  if not found then raise no_data_found; end if;
  select * into v_v from cuidared.visita where visita_id=v_s.visita_id and cuenta_id=v_s.cuenta_id;
  if v_s.estado not in ('autorizada','realizada') or v_v.visita_id is null
    or v_v.estado not in ('programada','en_curso','completada') or v_v.pendiente_autorizacion
    or (v_v.fecha+v_v.hora_programada) at time zone 'America/Santo_Domingo'>now()
    or not cuidared_interno.acceso_operativo(v_s.cuenta_id) then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode='P0001';
  end if;
  return v_s;
end $$;

create or replace function cuidared_api.api_publico_consultar_solicitud(p_codigo_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r jsonb;
begin
  if p_codigo_hash is null or p_codigo_hash!~'^[0-9a-f]{64}$' then raise no_data_found; end if;
  select jsonb_build_object('organizacion',c.nombre,'estado',s.estado,'fecha',coalesce(v.fecha,s.fecha_propuesta),
    'hora',cuidared_interno.hhmm(coalesce(v.hora_programada,s.hora_propuesta)),
    'hora_fin_programada',cuidared_interno.hhmm(coalesce(v.hora_fin_programada,s.hora_fin_propuesta)),
    'reprogramada',coalesce(v.reprogramada_en is not null or v.fecha<>s.fecha_propuesta or v.hora_programada<>s.hora_propuesta or (s.hora_fin_propuesta is not null and v.hora_fin_programada<>s.hora_fin_propuesta),false),
    'motivo_rechazo',s.motivo_rechazo,'observacion',s.observacion_visitante,
    'inicio_observaciones',(v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo',
    'puede_registrar_observacion',coalesce(s.estado in ('autorizada','realizada') and v.estado in ('programada','en_curso','completada')
      and not v.pendiente_autorizacion and s.observacion_visitante is null and (v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo'<=now() and cuidared_interno.acceso_operativo(s.cuenta_id),false),
    'puede_adjuntar_evidencias',coalesce(s.estado in ('autorizada','realizada') and v.estado in ('programada','en_curso','completada')
      and not v.pendiente_autorizacion and (v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo'<=now() and cuidared_interno.acceso_operativo(s.cuenta_id)
      and (select count(*) from cuidared.evidencia_solicitud_visita e where e.solicitud_id=s.solicitud_visita_id)<3,false),
    'evidencias',(select coalesce(jsonb_agg(jsonb_build_object('evidencia_id',e.evidencia_id,'nombre_archivo',e.nombre_archivo,'fecha',e.adjunta_en) order by e.adjunta_en),'[]') from cuidared.evidencia_solicitud_visita e where e.solicitud_id=s.solicitud_visita_id and e.adjunta_en is not null))
    into r from cuidared.solicitud_visita s join cuidared.cuenta c using(cuenta_id)
    left join cuidared.visita v on v.visita_id=s.visita_id and v.cuenta_id=s.cuenta_id where s.codigo_hash=p_codigo_hash;
  if not found then raise no_data_found; end if;
  return r;
end $$;

create or replace function cuidared_api.api_publico_registrar_observacion_posterior(p_codigo_hash text,p_observacion text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_s cuidared.solicitud_visita; v_texto text:=cuidared_interno.v_texto(to_jsonb(p_observacion),3,600);
begin
  v_s:=cuidared_interno.publico_exigir_aporte(p_codigo_hash);
  if v_s.observacion_visitante=v_texto then return cuidared_api.api_publico_consultar_solicitud(p_codigo_hash); end if;
  if v_s.observacion_visitante is not null then raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode='P0001'; end if;
  update cuidared.solicitud_visita set observacion_visitante=v_texto,observacion_en=now() where solicitud_visita_id=v_s.solicitud_visita_id;
  insert into cuidared.notificacion(usuario_id,cuenta_id,mensaje)
    select g,v_s.cuenta_id,'El visitante agregó observaciones a una visita. Revísalas en Visitas → Solicitudes.' from cuidared_interno.gestores_cuenta(v_s.cuenta_id) g;
  return cuidared_api.api_publico_consultar_solicitud(p_codigo_hash);
end $$;

create function cuidared_api.api_publico_preparar_evidencia(p_codigo_hash text,p_id uuid,p_nombre text,p_bytes integer,p_sha text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_s cuidared.solicitud_visita; e cuidared.evidencia_solicitud_visita; v_ruta text;
begin
  v_s:=cuidared_interno.publico_exigir_aporte(p_codigo_hash);
  if p_id is null or p_nombre is null or length(p_nombre) not between 1 and 100 or p_nombre~'[[:cntrl:]/]' or strpos(p_nombre,chr(92))>0
    or p_bytes is null or p_bytes not between 1 and 2097152 or p_sha is null or p_sha!~'^[0-9a-f]{64}$' then raise invalid_parameter_value; end if;
  select * into e from cuidared.evidencia_solicitud_visita where solicitud_id=v_s.solicitud_visita_id and archivo_hash=p_sha;
  if found then return jsonb_build_object('id',e.evidencia_id,'ruta',e.ruta,'adjunta',e.adjunta_en is not null); end if;
  if (select count(*) from cuidared.evidencia_solicitud_visita where solicitud_id=v_s.solicitud_visita_id)>=3 then
    raise exception 'CR_EVIDENCIA_VISITANTE_LIMITE' using errcode='P0001'; end if;
  if exists(select from cuidared.evidencia_solicitud_visita where evidencia_id=p_id) then raise no_data_found; end if;
  v_ruta:='solicitud/'||v_s.solicitud_visita_id||'/'||p_id||'.jpg';
  insert into cuidared.evidencia_solicitud_visita(evidencia_id,solicitud_id,ruta,nombre_archivo,tamano_bytes,archivo_hash)
    values(p_id,v_s.solicitud_visita_id,v_ruta,p_nombre,p_bytes,p_sha) returning * into e;
  return jsonb_build_object('id',e.evidencia_id,'ruta',e.ruta,'adjunta',false);
end $$;

create function cuidared_api.api_publico_adjuntar_evidencia(p_codigo_hash text,p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_s cuidared.solicitud_visita; e cuidared.evidencia_solicitud_visita;
begin
  v_s:=cuidared_interno.publico_exigir_aporte(p_codigo_hash);
  select * into e from cuidared.evidencia_solicitud_visita where evidencia_id=p_id and solicitud_id=v_s.solicitud_visita_id for update;
  if not found then raise no_data_found; end if;
  if not exists(select from storage.objects o where o.bucket_id='visitas-visitantes' and o.name=e.ruta and (o.metadata->>'size')::bigint=e.tamano_bytes and o.metadata->>'mimetype'='image/jpeg') then
    raise exception 'CR_EVIDENCIA_VISITANTE_ARCHIVO' using errcode='P0001'; end if;
  update cuidared.evidencia_solicitud_visita set adjunta_en=coalesce(adjunta_en,now()) where evidencia_id=p_id;
  return cuidared_api.api_publico_consultar_solicitud(p_codigo_hash);
end $$;

create function cuidared_api.api_publico_descartar_evidencia(p_codigo_hash text,p_id uuid) returns text
language plpgsql security definer set search_path='' as $$
declare v_ruta text;
begin
  delete from cuidared.evidencia_solicitud_visita e using cuidared.solicitud_visita s
    where s.codigo_hash=p_codigo_hash and e.solicitud_id=s.solicitud_visita_id and e.evidencia_id=p_id and e.adjunta_en is null returning e.ruta into v_ruta;
  return v_ruta;
end $$;

create function cuidared_api.api_publico_evidencia_descarga(p_codigo_hash text,p_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare r jsonb;
begin
  select jsonb_build_object('ruta',e.ruta,'nombre',e.nombre_archivo) into r from cuidared.evidencia_solicitud_visita e
    join cuidared.solicitud_visita s on s.solicitud_visita_id=e.solicitud_id where s.codigo_hash=p_codigo_hash and e.evidencia_id=p_id and e.adjunta_en is not null;
  if not found then raise no_data_found; end if;
  return r;
end $$;

create function cuidared_api.api_visita_evidencias_visitante(p_cuenta_id bigint,p_visita_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_uid uuid:=(cuidared_interno.exigir(p_cuenta_id,'visitas:ver')->>'usuario_id')::uuid;
begin
  if not cuidared_interno.visita_visible(p_cuenta_id,p_visita_id,v_uid) then raise no_data_found; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('evidencia_id',e.evidencia_id,'nombre_archivo',e.nombre_archivo,'ruta',e.ruta,'fecha',e.adjunta_en) order by e.adjunta_en),'[]')
    from cuidared.evidencia_solicitud_visita e join cuidared.visita v on v.solicitud_visita_id=e.solicitud_id where v.visita_id=p_visita_id and v.cuenta_id=p_cuenta_id and e.adjunta_en is not null);
end $$;

create function cuidared_api.api_confirmar_realizacion_visita(p_cuenta_id bigint,p_visita_id uuid,p_datos jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ctx jsonb:=cuidared_interno.exigir(p_cuenta_id,'visitas:autorizar'); uid uuid:=(ctx->>'usuario_id')::uuid;
  v cuidared.visita; ids uuid[]; a uuid; nota text; realizada boolean; fin timestamptz;
begin
  if ctx->>'tipo'<>'organizacion' or ctx->>'rol' not in ('administrador','coordinador') then raise insufficient_privilege; end if;
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos-array['realizada','nota','envejeciente_ids']<>'{}'::jsonb
    or jsonb_typeof(p_datos->'realizada') is distinct from 'boolean' then raise invalid_parameter_value; end if;
  nota:=cuidared_interno.v_texto(p_datos->'nota',3,600); realizada:=(p_datos->>'realizada')::boolean;
  perform pg_advisory_xact_lock(hashtextextended(p_visita_id::text,0));
  v:=cuidared_interno.bloquear_visita(p_visita_id);
  if v.visita_id is null or v.cuenta_id is distinct from p_cuenta_id then raise no_data_found; end if;
  if v.estado in ('completada','cancelada') then
    if v.confirmada_por=uid and ((v.estado='completada')=realizada) and v.confirmacion_notas=nota then return cuidared_interno.visita_json(p_visita_id,uid,true); end if;
    raise exception 'CR_VISITA_CERRADA' using errcode='P0001';
  end if;
  if v.pendiente_autorizacion then raise exception 'CR_ESTADO_INVALIDO' using errcode='P0001'; end if;
  fin:=(v.fecha+coalesce(v.hora_fin_programada,v.hora_programada)) at time zone 'America/Santo_Domingo';
  fin:=greatest(fin,(v.fecha+coalesce(v.hora_fin,v.hora_inicio)) at time zone 'America/Santo_Domingo');
  if fin is null or now()<fin then raise exception 'CR_VISITA_CONFIRMACION_ANTICIPADA' using errcode='P0001'; end if;
  if realizada then
    if cuidared_interno.es_visita_institucional(p_visita_id) then
      ids:=cuidared_interno.v_uuids(coalesce(p_datos->'envejeciente_ids','[]'::jsonb),0,100);
      foreach a in array ids loop
        perform cuidared_interno.exigir_envejeciente(p_cuenta_id,'visitas:autorizar',a);
        if not exists(select from cuidared.envejeciente where envejeciente_id=a and cuenta_id=p_cuenta_id and estado='activo') then raise insufficient_privilege; end if;
        insert into cuidared.detalle_visita(visita_id,envejeciente_id) values(p_visita_id,a) on conflict do nothing;
      end loop;
    elsif p_datos ? 'envejeciente_ids' then raise invalid_parameter_value; end if;
    update cuidared.visita set estado='completada',hora_inicio=coalesce(hora_inicio,hora_programada),
      hora_fin=coalesce(hora_fin,greatest(hora_fin_programada,hora_inicio),hora_programada),
      fecha_realizacion=(fecha+coalesce(hora_fin,greatest(hora_fin_programada,hora_inicio),hora_programada)) at time zone 'America/Santo_Domingo',
      confirmada_por=uid,confirmada_en=now(),confirmacion_notas=nota,fecha_actualizacion=now() where visita_id=p_visita_id;
  else
    update cuidared.visita set estado='cancelada',cancelada_por=uid,fecha_cancelacion=now(),motivo_cancelacion=left(nota,300),
      confirmada_por=uid,confirmada_en=now(),confirmacion_notas=nota,fecha_actualizacion=now() where visita_id=p_visita_id;
  end if;
  return cuidared_interno.visita_json(p_visita_id,uid,true);
end $$;

alter table cuidared.aviso_visita drop constraint aviso_visita_evento_check;
alter table cuidared.aviso_visita add constraint aviso_visita_evento_check check(evento in ('autorizada','rechazada','reprogramada','cancelada','recordatorio','recibida','nueva_solicitud','observaciones','realizada'));
create or replace function cuidared_interno.encolar_aviso_visita(p_solicitud uuid,p_evento text,p_cita timestamptz,p_fin time) returns void
language plpgsql set search_path='' as $$
begin
  if not exists(select from cuidared.solicitud_visita where solicitud_visita_id=p_solicitud and visitante_correo is not null) then return; end if;
  if p_evento in ('autorizada','rechazada','reprogramada','cancelada') then
    update cuidared.aviso_visita set cierre='omitido',reclamo=null where solicitud_id=p_solicitud and evento in ('recordatorio','observaciones') and cierre is null;
  end if;
  insert into cuidared.aviso_visita(solicitud_id,evento,cita,fin) values(p_solicitud,p_evento,p_cita,p_fin);
  if p_evento in ('autorizada','reprogramada') then
    if p_cita>now()+interval '10 minutes' then
      insert into cuidared.aviso_visita(solicitud_id,evento,cita,fin,disponible_en) values(p_solicitud,'recordatorio',p_cita,p_fin,greatest(now()+interval '10 minutes',p_cita-interval '24 hours'));
    end if;
    insert into cuidared.aviso_visita(solicitud_id,evento,cita,fin,disponible_en) values(p_solicitud,'observaciones',p_cita,p_fin,greatest(now(),p_cita));
  end if;
end $$;

-- No se envían mensajes retroactivos al instalar la migración.
-- Las citas futuras ya autorizadas también reciben su enlace al comenzar.
insert into cuidared.aviso_visita(solicitud_id,evento,cita,fin,disponible_en)
 select s.solicitud_visita_id,'observaciones',(v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo',v.hora_fin_programada,
   (v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo'
 from cuidared.solicitud_visita s join cuidared.visita v on v.visita_id=s.visita_id
 where s.estado='autorizada' and v.estado in ('programada','en_curso') and not v.pendiente_autorizacion and s.visitante_correo is not null
   and (v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo'>now()
   and not exists(select from cuidared.aviso_visita a where a.solicitud_id=s.solicitud_visita_id and a.evento='observaciones');

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
  v_fin time;
  v_referencia uuid;
  v_motivo text;
  v_hash text;
  v_org text;
  v_id uuid;
  v_existente cuidared.solicitud_visita;
  v_tipo text;
  v_entidad text;
  v_tipo_entidad text;
  v_cantidad integer;
  v_aporte text;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['cuenta_id', 'nombres', 'apellidos', 'cedula', 'telefono', 'correo', 'persona_a_visitar',
                        'fecha_propuesta', 'hora_propuesta', 'hora_fin_propuesta', 'referencia_codigo', 'motivo', 'codigo_hash', 'tipo_visita', 'entidad_visitante', 'tipo_entidad', 'cantidad_visitantes', 'aporte_previsto'] <> '{}'::jsonb
     or jsonb_typeof(p_datos->'cuenta_id') is distinct from 'number'
     or (p_datos->>'cuenta_id') !~ '^[1-9][0-9]{0,17}$' then
    raise invalid_parameter_value;
  end if;
  v_cuenta := (p_datos->>'cuenta_id')::bigint;
  v_nombres := cuidared_interno.v_texto(p_datos->'nombres', 2, 60);
  v_apellidos := cuidared_interno.v_texto(p_datos->'apellidos', 2, 60);
  v_cedula := cuidared_interno.v_texto(p_datos->'cedula', 11, 11);
  v_telefono := cuidared_interno.v_texto(p_datos->'telefono', 10, 16);
  v_correo := cuidared_interno.v_texto(p_datos->'correo', 5, 254);
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
  v_fin := cuidared_interno.v_hora(p_datos->'hora_fin_propuesta');
  v_referencia := cuidared_interno.v_uuid(p_datos->'referencia_codigo',false);
  if v_fin<=v_hora then raise invalid_parameter_value; end if;
  v_motivo := cuidared_interno.v_texto(p_datos->'motivo', 3, 300);
  v_hash := cuidared_interno.v_texto(p_datos->'codigo_hash', 64, 64);
  if v_cedula !~ '^[0-9]{11}$' or v_telefono !~ '^\+?[0-9]{10,15}$' or v_hash !~ '^[0-9a-f]{64}$'
     or (v_correo is not null and v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
     or v_fecha < cuidared_interno.hoy() then
    raise invalid_parameter_value;
  end if;
  -- Serializa los reintentos con la misma huella antes de evaluar cupos o notificar.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_hash, 1979));
  select * into v_existente from cuidared.solicitud_visita where codigo_hash = v_hash;
  if found then
    if row(v_existente.cuenta_id, v_existente.visitante_nombres, v_existente.visitante_apellidos,
           v_existente.visitante_cedula, v_existente.visitante_telefono, v_existente.visitante_correo,
           v_existente.persona_a_visitar, v_existente.fecha_propuesta, v_existente.hora_propuesta, v_existente.hora_fin_propuesta,
           v_existente.motivo, v_existente.tipo_visita, v_existente.entidad_visitante,
           v_existente.tipo_entidad, v_existente.cantidad_visitantes, v_existente.aporte_previsto)
       is distinct from
       row(v_cuenta, v_nombres, v_apellidos, v_cedula, v_telefono, lower(v_correo),
           v_persona, v_fecha, v_hora, v_fin, v_motivo, v_tipo, v_entidad, v_tipo_entidad, v_cantidad, v_aporte) then
      raise exception 'CR_CONFLICTO' using errcode = 'P0001';
    end if;
    select nombre into v_org from cuidared.cuenta where cuenta_id = v_cuenta;
    return jsonb_build_object('organizacion', v_org, 'estado', 'pendiente',
      'fecha_propuesta', v_existente.fecha_propuesta,
      'hora_propuesta', cuidared_interno.hhmm(v_existente.hora_propuesta), 'hora_fin_propuesta',cuidared_interno.hhmm(v_existente.hora_fin_propuesta));
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
                                        visitante_correo, persona_a_visitar, fecha_propuesta, hora_propuesta, hora_fin_propuesta, referencia_codigo, motivo, codigo_hash, tipo_visita, entidad_visitante, tipo_entidad, cantidad_visitantes, aporte_previsto)
    values (v_cuenta, v_nombres, v_apellidos, v_cedula, v_telefono, lower(v_correo), v_persona, v_fecha, v_hora, v_fin, v_referencia, v_motivo, v_hash, v_tipo, v_entidad, v_tipo_entidad, v_cantidad, v_aporte)
    returning solicitud_visita_id into v_id;
  -- Aviso a los usuarios principales de la cuenta (sin datos del adulto: aún no está confirmado ni identificado).
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
    select g, v_cuenta, format('Nueva solicitud de visita de %s %s para el %s.', v_nombres, v_apellidos, to_char(v_fecha, 'DD/MM/YYYY'))
    from cuidared_interno.gestores_cuenta(v_cuenta) g;
  return jsonb_build_object('organizacion', v_org, 'estado', 'pendiente', 'fecha_propuesta', v_fecha,
                            'hora_propuesta', cuidared_interno.hhmm(v_hora), 'hora_fin_propuesta',cuidared_interno.hhmm(v_fin));
end $function$
;

CREATE OR REPLACE FUNCTION cuidared_api.api_programar_visita(p_cuenta_id bigint, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_visitante jsonb;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  -- Programar equivale a autorizar: solo programa un usuario principal.
  if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'visitas:autorizar') then raise insufficient_privilege; end if;
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['fecha', 'hora_programada', 'hora_fin_programada', 'autorizar', 'razon', 'notas', 'envejeciente_ids', 'participante_ids', 'visitante_externo', 'codigo_hash', 'referencia_codigo'] <> '{}'::jsonb
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
  v_visitante := cuidared_interno.validar_visitante_programado(p_datos->'visitante_externo');
  if v_visitante<>'{}'::jsonb then v_autorizar:=true; end if;
  v_adultos := cuidared_interno.v_uuids(p_datos->'envejeciente_ids',case when v_visitante->>'tipo'='institucional' then 0 else 1 end,4);
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
    if not found or v_m.rol not in ('cuidador','voluntario','administrador','coordinador')
       or (v_m.rol in ('cuidador','voluntario') and not ('visitas:registrar'=any(cuidared_interno.permisos(v_m.rol_id,v_m.tipo_cuenta_id))))
       or (v_m.rol in ('administrador','coordinador') and not ('visitas:autorizar'=any(cuidared_interno.permisos(v_m.rol_id,v_m.tipo_cuenta_id)))) then
      raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
    end if;
  end loop;

  perform cuidared_interno.exigir_horario_visita(p_cuenta_id, v_fecha, v_hora, v_fin, v_parts, v_adultos);
  insert into cuidared.visita (visita_id, cuenta_id, fecha, hora_programada, hora_fin_programada, razon, estado, origen, creada_por, notas, pendiente_autorizacion, visitante_externo)
    values (v_id, p_cuenta_id, v_fecha, v_hora, v_fin, v_razon, 'programada', 'interna', v_uid, v_notas, not v_autorizar, v_visitante);
  foreach v_p in array v_parts loop
    insert into cuidared.registro_visita (visita_id, usuario_id, autorizada_por_usuario_id) values (v_id, v_p, case when v_autorizar then v_uid end);
    select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_p);
    if v_autorizar then
      foreach v_a in array v_adultos loop
        -- Si falta un vínculo vigente, 3b abre un nuevo periodo y registra a quien programa como autorizador (RF-12/RF-13).
        if v_m.rol in ('cuidador','voluntario') and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_a, v_p) then
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
  perform cuidared_interno.visita_solicitud_administrativa(v_id,v_uid,p_datos->>'codigo_hash',cuidared_interno.v_uuid(p_datos->'referencia_codigo',false));
  return cuidared_interno.visita_json(v_id, v_uid, true);
end $function$
;

CREATE OR REPLACE FUNCTION cuidared_api.api_programar_visitas_recurrentes(p_cuenta_id bigint, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'visitas:programar');
  v_rep jsonb := p_datos -> 'repeticion';
  v_desde date;
  v_hasta date;
  v_frecuencia text;
  v_dias integer[];
  v_fechas date[];
  v_fecha date;
  v_serie uuid := gen_random_uuid();
  v_visita jsonb;
  v_indice integer:=0;
  v_visitas jsonb := '[]'::jsonb;
begin
  if not cuidared_interno.tiene_permiso(p_cuenta_id, (v_ctx->>'usuario_id')::uuid, 'visitas:autorizar')
     or not cuidared_interno.cuenta_tiene_funcionalidad(p_cuenta_id, 'visitas_recurrentes') then
    raise insufficient_privilege;
  end if;
  if jsonb_typeof(v_rep) is distinct from 'object'
     or v_rep - array['frecuencia','hasta','dias_semana'] <> '{}'::jsonb then raise invalid_parameter_value; end if;
  v_desde := cuidared_interno.v_fecha(p_datos->'fecha');
  v_hasta := cuidared_interno.v_fecha(v_rep->'hasta');
  v_frecuencia := v_rep->>'frecuencia';
  if v_desde < cuidared_interno.hoy() or v_hasta < v_desde or v_hasta - v_desde > 730 then
    raise invalid_parameter_value;
  end if;
  if v_frecuencia = 'semanal' then
    if jsonb_typeof(v_rep->'dias_semana') is distinct from 'array' then raise invalid_parameter_value; end if;
    if jsonb_array_length(v_rep->'dias_semana') not between 1 and 7
       or exists (select from jsonb_array_elements(v_rep->'dias_semana') d
                  where jsonb_typeof(d) <> 'number' or (d #>> '{}') !~ '^[1-7]$') then
      raise invalid_parameter_value;
    end if;
    select array_agg(distinct (d #>> '{}')::integer) into v_dias from jsonb_array_elements(v_rep->'dias_semana') d;
    if cardinality(v_dias) <> jsonb_array_length(v_rep->'dias_semana') then raise invalid_parameter_value; end if;
  elsif v_frecuencia is distinct from 'diaria' or v_rep ? 'dias_semana' then
    raise invalid_parameter_value;
  end if;
  select array_agg(d::date order by d) into v_fechas
    from generate_series(v_desde::timestamp, v_hasta::timestamp, interval '1 day') d
    where v_frecuencia = 'diaria' or extract(isodow from d)::integer = any(v_dias);
  if v_fechas is null or cardinality(v_fechas) > 60 then
    raise exception 'CR_SERIE_VISITA_INVALIDA' using errcode = 'P0001';
  end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  foreach v_fecha in array v_fechas loop
    v_visita := cuidared_api.api_programar_visita(p_cuenta_id, (p_datos - array['repeticion','referencias']) || jsonb_build_object('fecha',v_fecha) || coalesce(p_datos->'referencias'->v_indice,'{}'::jsonb));
    v_indice:=v_indice+1;
    update cuidared.visita set serie_id = v_serie where visita_id = (v_visita->>'visita_id')::uuid;
    v_visitas := v_visitas || jsonb_build_array(v_visita);
  end loop;
  return jsonb_build_object('serie_id', v_serie, 'visitas', v_visitas);
end;
$function$
;

CREATE OR REPLACE FUNCTION cuidared_api.api_autorizar_visita(p_cuenta_id bigint, p_visita_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    if v_persona.rol is null or v_persona.rol not in ('cuidador','voluntario','administrador','coordinador') then
      raise exception 'CR_PARTICIPANTE_INVALIDO' using errcode = 'P0001';
    end if;
    for v_adulto in select envejeciente_id from cuidared.detalle_visita where visita_id = p_visita_id loop
      perform cuidared_interno.exigir_envejeciente(p_cuenta_id, 'visitas:autorizar', v_adulto);
      if not exists (select from cuidared.envejeciente where envejeciente_id = v_adulto and estado = 'activo') then
        raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
      end if;
      if v_persona.rol in ('cuidador','voluntario') and not cuidared_interno.alcanza_envejeciente(p_cuenta_id, v_adulto, v_persona.usuario_id) then
        if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'adultos:asignar') then raise insufficient_privilege; end if;
        perform cuidared_interno.seg_vincular(p_cuenta_id, v_adulto, v_persona.usuario_id,
          case v_persona.rol when 'cuidador' then 'cuidador_asignado' else 'voluntario_asignado' end, v_uid);
      end if;
    end loop;
  end loop;
  update cuidared.registro_visita set autorizada_por_usuario_id = v_uid where visita_id = p_visita_id;
  update cuidared.visita set pendiente_autorizacion = false, fecha_actualizacion = now() where visita_id = p_visita_id;
  return cuidared_interno.visita_json(p_visita_id, v_uid, true);
end $function$
;

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
  if not found or v_m.rol not in ('cuidador','voluntario','administrador','coordinador')
    or (v_m.rol in ('cuidador','voluntario') and not ('visitas:registrar'=any(cuidared_interno.permisos(v_m.rol_id,v_m.tipo_cuenta_id))))
    or (v_m.rol in ('administrador','coordinador') and not ('visitas:autorizar'=any(cuidared_interno.permisos(v_m.rol_id,v_m.tipo_cuenta_id)))) then
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
end $function$
;

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
    'hora_propuesta', cuidared_interno.hhmm(s.hora_propuesta), 'hora_fin_propuesta',cuidared_interno.hhmm(s.hora_fin_propuesta),
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
$function$
;

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
    'registro_campo_en',v.registro_campo_en,'confirmada_en',v.confirmada_en,'confirmacion_notas',v.confirmacion_notas,
    'puede_confirmar_realizacion',coalesce(v.estado in ('programada','en_curso') and not v.pendiente_autorizacion and cuidared_interno.es_gestor(v.cuenta_id,p_usuario_id) and (v.fecha+v.hora_fin_programada) at time zone 'America/Santo_Domingo'<=now(),false),
    'observacion_visitante',(select observacion_visitante from cuidared.solicitud_visita where solicitud_visita_id=v.solicitud_visita_id),
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
$function$
;

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
    if v_v.registro_campo_en is not null and v_v.estado::text='en_curso' then
      return jsonb_build_object('visita_id',v_id,'ya_registrada',true,'estado','en_curso','pendiente_confirmacion',true);
    end if;
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
      set estado = 'en_curso', registro_campo_en=now(), informe_general = v_informe, hora_inicio = v_ini, hora_fin = v_fin, checklist = v_checklist, fecha_actualizacion = now()
      where visita_id = v_id;
    update cuidared.detalle_visita d
      set estado_general = x.estado_general, observacion = x.observacion, registrado_por = p_usuario_id, fecha_registro = now()
      from jsonb_to_recordset(v_detalles) as x(envejeciente_id uuid, estado_general text, observacion text)
      where d.visita_id = v_id and d.envejeciente_id = x.envejeciente_id;

  if exists (select 1 from jsonb_to_recordset(v_detalles) as x(envejeciente_id uuid, estado_general text, observacion text)
             where x.estado_general = 'situacion_critica') then
    perform cuidared_interno.notificar_situacion_critica(p_cuenta_id, v_id, p_usuario_id);
  end if;
  return jsonb_build_object('visita_id', v_id, 'ya_registrada', false, 'estado', 'en_curso','pendiente_confirmacion',true);
end $function$
;

CREATE OR REPLACE FUNCTION cuidared_api.api_visita_reclamar_avisos()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_reclamo uuid := gen_random_uuid(); v_avisos jsonb;
begin
  update cuidared.aviso_visita set cierre = 'omitido', reclamo = null
    where cierre is null and evento = 'recordatorio' and cita <= now() and disponible_en <= now();
  update cuidared.aviso_visita a set cierre = 'omitido', reclamo = null
    where a.cierre is null and a.evento = 'nueva_solicitud' and a.destinatario_usuario_id is null
      and not exists(select from cuidared.solicitud_visita s join cuidared.cuenta c using(cuenta_id)
        where s.solicitud_visita_id = a.solicitud_id and c.correo is not null);
  update cuidared.aviso_visita a set cierre = 'omitido', reclamo = null
    where a.cierre is null and a.destinatario_usuario_id is not null and not exists (
      select from cuidared.solicitud_visita s
      cross join lateral cuidared_interno.gestores_cuenta(s.cuenta_id) g(usuario_id)
      join auth.users u on u.id = g.usuario_id
      where s.solicitud_visita_id = a.solicitud_id and g.usuario_id = a.destinatario_usuario_id
        and u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= now()) and not u.is_anonymous
    );
  update cuidared.aviso_visita a set cierre='omitido',reclamo=null where a.cierre is null and a.evento='observaciones' and not exists(
    select from cuidared.solicitud_visita s join cuidared.visita v on v.visita_id=s.visita_id where s.solicitud_visita_id=a.solicitud_id
      and s.estado in ('autorizada','realizada') and v.estado in ('programada','en_curso','completada')
      and a.cita=(v.fecha+v.hora_programada) at time zone 'America/Santo_Domingo');
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
      'evento', a.evento, 'correo', case
        when a.evento = 'nueva_solicitud' and a.destinatario_usuario_id is null then c.correo
        when a.destinatario_usuario_id is not null then u.email else s.visitante_correo end,
      'destinatario', case when a.evento = 'nueva_solicitud' then 'organizacion' else 'visitante' end,
      'organizacion', c.nombre,'referencia_codigo',s.referencia_codigo,'motivo',coalesce(s.motivo_rechazo,v.motivo_cancelacion), 'cita', a.cita, 'fin', cuidared_interno.hhmm(a.fin))
      order by e.disponible_en, a.aviso_id), '[]'::jsonb) into v_avisos
    from tomados a join cuidared.solicitud_visita s on s.solicitud_visita_id = a.solicitud_id
    join elegidos e on e.aviso_id = a.aviso_id
    join cuidared.cuenta c on c.cuenta_id = s.cuenta_id
    left join auth.users u on u.id = a.destinatario_usuario_id
    left join cuidared.visita v on v.visita_id=s.visita_id;
  return v_avisos;
end $function$
;

CREATE OR REPLACE FUNCTION cuidared_interno.trg_aviso_solicitud()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_visita cuidared.visita;
begin
  if new.estado = old.estado then return new; end if;
  select * into v_visita from cuidared.visita where visita_id = new.visita_id and cuenta_id = new.cuenta_id;
  perform cuidared_interno.encolar_aviso_visita(new.solicitud_visita_id,
    case when new.estado = 'autorizada' and (new.fecha_propuesta <> v_visita.fecha or new.hora_propuesta <> v_visita.hora_programada)
      then 'reprogramada' else new.estado end,
    coalesce((v_visita.fecha+v_visita.hora_programada) at time zone 'America/Santo_Domingo',(new.fecha_propuesta+new.hora_propuesta) at time zone 'America/Santo_Domingo'),coalesce(v_visita.hora_fin_programada,new.hora_fin_propuesta));
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION cuidared_interno.trg_correo_nueva_solicitud()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_cita timestamptz := (new.fecha_propuesta + new.hora_propuesta) at time zone 'America/Santo_Domingo';
begin
  if new.creada_por_usuario_id is not null then return new; end if;
  if new.visitante_correo is not null then
    insert into cuidared.aviso_visita(solicitud_id, evento, cita)
      values(new.solicitud_visita_id, 'recibida', v_cita);
  end if;
  if exists(select from cuidared.cuenta where cuenta_id = new.cuenta_id and correo is not null) then
    insert into cuidared.aviso_visita(solicitud_id, evento, cita)
      values(new.solicitud_visita_id, 'nueva_solicitud', v_cita);
  else
    insert into cuidared.aviso_visita(solicitud_id, evento, cita, destinatario_usuario_id)
      select new.solicitud_visita_id, 'nueva_solicitud', v_cita, g.usuario_id
      from cuidared_interno.gestores_cuenta(new.cuenta_id) g(usuario_id)
      join auth.users u on u.id = g.usuario_id
      where u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= now()) and not u.is_anonymous;
  end if;
  return new;
end $function$
;
do $$ declare f record; begin
 for f in select p.oid::regprocedure firma,p.proname nombre,n.nspname esquema from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('cuidared_interno','cuidared_api') and p.proname in ('validar_visitante_programado','visita_solicitud_administrativa','publico_exigir_aporte','api_publico_crear_solicitud','api_publico_consultar_solicitud','api_publico_registrar_observacion_posterior','api_publico_preparar_evidencia','api_publico_adjuntar_evidencia','api_publico_descartar_evidencia','api_publico_evidencia_descarga','api_visita_evidencias_visitante','api_confirmar_realizacion_visita') loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f.firma);
 if f.esquema='cuidared_api' then execute format('grant execute on function %s to %I',f.firma,case when f.nombre like 'api_publico_%' then 'service_role' else 'authenticated' end); end if;
 end loop; end $$;
notify pgrst,'reload schema';
commit;
