-- Fase 8 · Tarifas USD, cotizaciones de Organización y asignación gratuita manual.
-- Propuesta dependiente de fase-8-suscripciones.sql. Requiere aprobación antes de aplicar.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

create table cuidared.stripe_cotizacion (
  cuenta_id bigint not null references cuidared.cuenta(cuenta_id),
  codigo text not null check (codigo in ('operacion_base_mensual','operacion_base_anual',
    'gestion_comunitaria_avanzada_mensual','gestion_comunitaria_avanzada_anual')),
  solicitada_por uuid not null references cuidared.usuario(usuario_id),
  cuidadores integer not null check (cuidadores >= 0),
  envejecientes integer not null check (envejecientes >= 0),
  solicitada_en timestamptz not null default now(),
  publicada_por uuid references cuidared.usuario(usuario_id),
  publicada_en timestamptz,
  primary key (cuenta_id,codigo),
  check ((publicada_por is null) = (publicada_en is null))
);
create index stripe_cotizacion_solicitante on cuidared.stripe_cotizacion(solicitada_por);
create index stripe_cotizacion_publicador on cuidared.stripe_cotizacion(publicada_por) where publicada_por is not null;
alter table cuidared.stripe_cotizacion enable row level security;
revoke all on cuidared.stripe_cotizacion from public, anon, authenticated, service_role;

create function cuidared_interno.stripe_codigos(p_tipo text)
returns table (codigo text,nombre text,periodicidad text,importe_sugerido_centavos integer)
language sql immutable set search_path = '' as $$
  select m.codigo || '_' || f.periodicidad,m.nombre,f.periodicidad,
    case m.codigo
      when 'basico_familiar' then case f.periodicidad when 'mensual' then 900 else 9000 end
      when 'cuidado_integral' then case f.periodicidad when 'mensual' then 1900 else 19000 end
    end
  from cuidared_interno.stripe_catalogo_modelo() m
  cross join (values ('mensual'::text),('anual'::text)) f(periodicidad)
  where m.tipo=p_tipo
$$;

create function cuidared_interno.stripe_volumen(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'envejecientes', (select count(*) from cuidared.envejeciente e where e.cuenta_id = p_cuenta_id and e.estado = 'activo'),
    'cuidadores', (
      select count(distinct m.usuario_id)
      from cuidared.membresia m join cuidared.rol r using(rol_id) join cuidared.usuario u using(usuario_id)
      where m.cuenta_id = p_cuenta_id and m.estado = 'activa' and r.codigo = 'cuidador'
        and r.activo and u.estado = 'activo' and m.fecha_inicio <= cuidared_interno.hoy()
        and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
    )
  )
$$;

create function cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'codigo', t.codigo, 'nombre', t.nombre, 'periodicidad', t.periodicidad, 'moneda', 'USD',
    'estado', case when o.price_id is not null then 'cotizada' when q.cuenta_id is not null then 'solicitada' else 'sin_cotizar' end,
    'importe_centavos', o.importe_centavos,
    'cuidadores', coalesce(q.cuidadores, (v.uso->>'cuidadores')::integer),
    'envejecientes', coalesce(q.envejecientes, (v.uso->>'envejecientes')::integer))
    order by t.codigo,t.periodicidad), '[]'::jsonb)
  from (select cuidared_interno.stripe_volumen(p_cuenta_id) as uso) v
  cross join cuidared_interno.stripe_codigos('organizacion') t
  left join cuidared.stripe_cotizacion q on q.cuenta_id = p_cuenta_id and q.codigo = t.codigo
  left join cuidared.stripe_oferta o on o.cuenta_cotizada_id = p_cuenta_id and o.codigo = t.codigo and o.activa
$$;

create function cuidared_api.api_stripe_cotizaciones(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id,'cuenta:suscripcion');
begin
  if v_ctx->>'tipo' is distinct from 'organizacion' then raise no_data_found; end if;
  return jsonb_build_object('cotizaciones', cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id));
end $$;

create function cuidared_api.api_stripe_solicitar_cotizacion(p_cuenta_id bigint,p_codigo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir_miembros(p_cuenta_id,'cuenta:suscripcion');
  v_actor uuid := (v_ctx->>'usuario_id')::uuid;
  v_volumen jsonb;
begin
  if v_ctx->>'tipo' is distinct from 'organizacion' then raise no_data_found; end if;
  if not exists (select 1 from cuidared.cuenta where cuenta_id=p_cuenta_id and usuario_titular_id=v_actor for update) then
    raise insufficient_privilege;
  end if;
  if not exists (select 1 from cuidared_interno.stripe_codigos('organizacion') where codigo=p_codigo) then
    raise invalid_parameter_value;
  end if;
  v_volumen := cuidared_interno.stripe_volumen(p_cuenta_id);
  insert into cuidared.stripe_cotizacion(cuenta_id,codigo,solicitada_por,cuidadores,envejecientes)
  values (p_cuenta_id,p_codigo,v_actor,(v_volumen->>'cuidadores')::integer,(v_volumen->>'envejecientes')::integer)
  on conflict (cuenta_id,codigo) do nothing;
  return jsonb_build_object('cotizaciones', cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id));
end $$;

create function cuidared_interno.stripe_exigir_backoffice(p_actor uuid,p_sesion uuid,p_aal text) returns void
language plpgsql stable set search_path = '' as $$
begin
  if cuidared_interno.bo_rol(p_actor,p_sesion) is distinct from 'super_admin' or p_aal is distinct from 'aal2' then
    raise insufficient_privilege;
  end if;
end $$;

create function cuidared_api.api_bo_stripe_leer(
  p_actor uuid,p_sesion uuid,p_aal text,p_cuenta_id bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor,p_sesion,p_aal);
  if p_cuenta_id is not null then
    if not exists (select 1 from cuidared.cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id)
      where c.cuenta_id=p_cuenta_id and t.codigo='organizacion') then raise no_data_found; end if;
    return jsonb_build_object('cotizaciones',cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id));
  end if;
  return (select jsonb_build_object('tarifas', jsonb_agg(jsonb_build_object(
    'codigo',t.codigo,'nombre',t.nombre,'periodicidad',t.periodicidad,'moneda','USD',
    'importe_centavos',o.importe_centavos,'importe_sugerido_centavos',t.importe_sugerido_centavos
  ) order by t.codigo,t.periodicidad))
  from cuidared_interno.stripe_codigos('familia') t
  left join cuidared.stripe_oferta o on o.codigo=t.codigo and o.cuenta_cotizada_id is null and o.activa);
end $$;

create function cuidared_api.api_bo_stripe_preparar_tarifa(
  p_actor uuid,p_sesion uuid,p_aal text,p_cuenta_id bigint,p_codigo text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_tipo text := case when p_cuenta_id is null then 'familia' else 'organizacion' end;
  v_tarifa record;
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor,p_sesion,p_aal);
  if p_cuenta_id is not null and not exists (
    select 1 from cuidared.stripe_cotizacion q join cuidared.cuenta c using(cuenta_id)
    where q.cuenta_id=p_cuenta_id and q.codigo=p_codigo and c.estado='activa'
  ) then raise no_data_found; end if;
  select * into v_tarifa from cuidared_interno.stripe_codigos(v_tipo) where codigo=p_codigo;
  if not found then raise no_data_found; end if;
  return jsonb_build_object('periodicidad',v_tarifa.periodicidad);
end $$;

create function cuidared_api.api_bo_stripe_publicar_tarifa(
  p_actor uuid,p_sesion uuid,p_aal text,p_cuenta_id bigint,p_codigo text,p_importe_centavos integer,
  p_price_id text,p_motivo text
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_periodicidad text;
  v_anterior integer;
  v_volumen jsonb;
begin
  v_periodicidad := cuidared_api.api_bo_stripe_preparar_tarifa(p_actor,p_sesion,p_aal,p_cuenta_id,p_codigo)->>'periodicidad';
  if p_importe_centavos is null or p_importe_centavos not between 50 and 99999999 or
     p_motivo is null or char_length(btrim(p_motivo)) not between 5 and 500 then raise invalid_parameter_value; end if;
  select importe_centavos into v_anterior from cuidared.stripe_oferta
    where codigo=p_codigo and cuenta_cotizada_id is not distinct from p_cuenta_id and activa;
  perform cuidared_interno.stripe_catalogo_sembrar(p_codigo,p_price_id,v_periodicidad,p_importe_centavos,'USD',100,p_cuenta_id);
  if p_cuenta_id is not null then
    v_volumen := cuidared_interno.stripe_volumen(p_cuenta_id);
    update cuidared.stripe_cotizacion set publicada_en=now(), publicada_por=p_actor,
      cuidadores=(v_volumen->>'cuidadores')::integer, envejecientes=(v_volumen->>'envejecientes')::integer
      where cuenta_id=p_cuenta_id and codigo=p_codigo;
  end if;
  perform cuidared_interno.bo_auditar(p_actor,'super_admin',p_cuenta_id,
    case when p_cuenta_id is null then 'stripe.tarifa.publicar' else 'stripe.cotizacion.publicar' end,
    'oferta_stripe',p_codigo,jsonb_build_object('importe_centavos',v_anterior),
    jsonb_build_object('moneda','USD','importe_centavos',p_importe_centavos) || coalesce(v_volumen,'{}'::jsonb),
    btrim(p_motivo));
end $$;

create function cuidared_api.api_bo_stripe_plan_gratuito(
  p_actor uuid,p_sesion uuid,p_aal text,p_cuenta_id bigint,p_motivo text
) returns void language plpgsql security definer set search_path = '' as $$
declare v_cuenta cuidared.cuenta%rowtype; v_plan smallint;
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor,p_sesion,p_aal);
  if p_motivo is null or char_length(btrim(p_motivo)) not between 5 and 500 then raise invalid_parameter_value; end if;
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  select * into strict v_cuenta from cuidared.cuenta where cuenta_id=p_cuenta_id for update;
  if v_cuenta.estado <> 'activa' or v_cuenta.suscripcion_estado = 'suspendida'
    or cuidared_interno.acceso_operativo(p_cuenta_id)
    or exists (select 1 from cuidared.stripe_suscripcion s where s.cuenta_id=p_cuenta_id and s.gestionada
      and (s.vigencia_hasta > now() or (s.estado not in ('canceled','incomplete_expired') and not s.cancelacion_programada))) then
    raise exception 'CR_STRIPE_GRATUITO_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  select plan_id into strict v_plan from cuidared.plan
    where tipo_cuenta_id=v_cuenta.tipo_cuenta_id and bo_gratuito and estado='activo';
  update cuidared.stripe_suscripcion set gestionada=false,actualizada_en=now()
    where cuenta_id=p_cuenta_id and gestionada;
  update cuidared.cuenta set plan_id=v_plan,plan_precio=0,suscripcion_estado='activa',
    fecha_fin_vigencia=null,fecha_actualizacion=now() where cuenta_id=p_cuenta_id;
  perform cuidared_interno.bo_auditar(p_actor,'super_admin',p_cuenta_id,'stripe.gratuito.asignar','cuenta',
    p_cuenta_id::text,jsonb_build_object('plan_id',v_cuenta.plan_id,'estado',v_cuenta.suscripcion_estado),
    jsonb_build_object('plan_id',v_plan,'estado','activa'),btrim(p_motivo));
end $$;

-- El flujo operativo no puede publicar un precio de una cotización en el catálogo de otra cuenta.
alter function cuidared_api.api_obtener_suscripcion(bigint) set schema cuidared_interno;
alter function cuidared_interno.api_obtener_suscripcion(bigint) rename to stripe_suscripcion_previa;
revoke all on function cuidared_interno.stripe_suscripcion_previa(bigint) from public,anon,authenticated,service_role;
create function cuidared_api.api_obtener_suscripcion(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_resultado jsonb := cuidared_interno.stripe_suscripcion_previa(p_cuenta_id);
  v_plan record;
begin
  select t.codigo,o.periodicidad,c.plan_precio,
    exists(select 1 from cuidared.stripe_suscripcion s2 where s2.cuenta_id=c.cuenta_id and s2.gestionada and s2.vigencia_hasta is not null) as stripe
  into v_plan from cuidared.cuenta c join cuidared.tipo_cuenta t using(tipo_cuenta_id)
  left join cuidared.stripe_suscripcion s on s.cuenta_id=c.cuenta_id and s.gestionada
  left join cuidared.stripe_oferta o on o.price_id=s.price_id
  where c.cuenta_id=p_cuenta_id;
  if v_resultado->'planes' <> 'null'::jsonb and v_plan.codigo='organizacion' then
    v_resultado := jsonb_set(v_resultado, '{planes}', '[]'::jsonb);
  end if;
  if v_plan.stripe and v_resultado->'plan' <> 'null'::jsonb then
    v_resultado := jsonb_set(v_resultado,'{plan}',v_resultado->'plan' || jsonb_build_object(
      'periodicidad',v_plan.periodicidad,'precio',v_plan.plan_precio));
  end if;
  return v_resultado;
end $$;

-- La activación comercial requiere factura confirmada. Las demás operaciones de soporte se conservan.
alter function cuidared_api.api_bo_mutar(uuid,uuid,text,text,jsonb,text,inet,text) set schema cuidared_interno;
alter function cuidared_interno.api_bo_mutar(uuid,uuid,text,text,jsonb,text,inet,text) rename to stripe_bo_mutar_previo;
revoke all on function cuidared_interno.stripe_bo_mutar_previo(uuid,uuid,text,text,jsonb,text,inet,text)
  from public,anon,authenticated,service_role;
create function cuidared_api.api_bo_mutar(p_actor uuid,p_sesion uuid,p_aal text,p_accion text,p_datos jsonb,
  p_motivo text,p_ip inet,p_agente text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_accion in ('cuenta.cambiar_plan','pago.registrar') then
    perform cuidared_interno.stripe_exigir_backoffice(p_actor,p_sesion,p_aal);
    raise exception 'CR_STRIPE_ACTIVACION_REQUERIDA' using errcode = 'P0001';
  end if;
  return cuidared_interno.stripe_bo_mutar_previo(p_actor,p_sesion,p_aal,p_accion,p_datos,p_motivo,p_ip,p_agente);
end $$;

-- Solo las reservas sin factura pueden descartarse al verificar que el proveedor no cobrará el aumento.
create function cuidared_api.api_stripe_descartar_prevision(p_cambio_id uuid) returns void
language sql security definer set search_path = '' as $$
  update cuidared.stripe_cambio set estado='descartado'
  where cambio_id=p_cambio_id and modo='inmediato' and estado='pendiente' and factura_id is null
$$;

create function cuidared_api.api_stripe_programacion_completada(p_subscription_id text,p_schedule_id text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from cuidared.stripe_cambio
    where subscription_id=p_subscription_id and schedule_id=p_schedule_id and modo='proximo_corte' and estado='aplicado')
$$;

revoke all on function
  cuidared_interno.stripe_codigos(text), cuidared_interno.stripe_volumen(bigint),
  cuidared_interno.stripe_cotizaciones_de_cuenta(bigint),
  cuidared_interno.stripe_exigir_backoffice(uuid,uuid,text),
  cuidared_api.api_stripe_cotizaciones(bigint),cuidared_api.api_stripe_solicitar_cotizacion(bigint,text),
  cuidared_api.api_bo_stripe_leer(uuid,uuid,text,bigint),
  cuidared_api.api_bo_stripe_preparar_tarifa(uuid,uuid,text,bigint,text),
  cuidared_api.api_bo_stripe_publicar_tarifa(uuid,uuid,text,bigint,text,integer,text,text),
  cuidared_api.api_bo_stripe_plan_gratuito(uuid,uuid,text,bigint,text),
  cuidared_api.api_stripe_descartar_prevision(uuid),cuidared_api.api_stripe_programacion_completada(text,text),
  cuidared_api.api_obtener_suscripcion(bigint),cuidared_api.api_bo_mutar(uuid,uuid,text,text,jsonb,text,inet,text)
  from public,anon,authenticated,service_role;
grant execute on function cuidared_api.api_stripe_cotizaciones(bigint),
  cuidared_api.api_stripe_solicitar_cotizacion(bigint,text),cuidared_api.api_obtener_suscripcion(bigint) to authenticated;
grant execute on function cuidared_api.api_bo_stripe_leer(uuid,uuid,text,bigint),
  cuidared_api.api_bo_stripe_preparar_tarifa(uuid,uuid,text,bigint,text),
  cuidared_api.api_bo_stripe_publicar_tarifa(uuid,uuid,text,bigint,text,integer,text,text),
  cuidared_api.api_bo_stripe_plan_gratuito(uuid,uuid,text,bigint,text),
  cuidared_api.api_stripe_descartar_prevision(uuid),cuidared_api.api_stripe_programacion_completada(text,text),
  cuidared_api.api_bo_mutar(uuid,uuid,text,text,jsonb,text,inet,text) to service_role;
commit;
