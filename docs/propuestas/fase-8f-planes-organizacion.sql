-- CUIDARED-017 · Operación Base de contratación directa y límites pactados de Gestión Comunitaria Avanzada.
-- Propuesta. Requiere aprobación específica antes de aplicar a Supabase.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

create function cuidared_interno.stripe_es_cotizable(p_codigo text) returns boolean
language sql immutable set search_path = '' as $$
  select p_codigo in ('gestion_comunitaria_avanzada_mensual', 'gestion_comunitaria_avanzada_anual')
$$;

create function cuidared_interno.stripe_limites_validos(p_limites jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_limites) = 'object' then
    p_limites ?& array['envejecientes', 'usuarios', 'cuidadores', 'familiares']
    and p_limites - array['envejecientes', 'usuarios', 'cuidadores', 'familiares'] = '{}'::jsonb
    and not exists (
      select from jsonb_each(p_limites) x
      where not case jsonb_typeof(x.value)
        when 'null' then true
        when 'number' then x.value::text ~ '^[0-9]+$' and x.value::numeric between 1 and 100000
        else false end
    )
  else false end
$$;

alter table cuidared.stripe_oferta
  add column limites_cotizados jsonb,
  add column version_cotizacion uuid unique,
  add constraint stripe_oferta_terminos_cotizacion check (
    (limites_cotizados is null and version_cotizacion is null)
    or (cuenta_cotizada_id is not null and cuidared_interno.stripe_es_cotizable(codigo)
      and version_cotizacion is not null and cuidared_interno.stripe_limites_validos(limites_cotizados))
  );

alter table cuidared.stripe_cotizacion
  add column usuarios integer check (usuarios >= 0),
  add column familiares integer check (familiares >= 0);

-- Preservar Price, intentos y contratos anteriores. Las ofertas heredadas quedan fuera de nuevas selecciones.
update cuidared.stripe_oferta set activa = false
where activa and cuenta_cotizada_id is not null
  and (not cuidared_interno.stripe_es_cotizable(codigo) or limites_cotizados is null);

create function cuidared_interno.stripe_cupos_plan(p_plan cuidared.plan) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('envejecientes', p_plan.limite_envejecientes, 'usuarios', p_plan.limite_usuarios,
    'cuidadores', p_plan.limite_cuidadores, 'familiares', p_plan.limite_familiares)
$$;

create or replace function cuidared_interno.limites(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select case when c.suscripcion_estado::text = 'activa' then
    coalesce(o.limites_cotizados, cuidared_interno.stripe_cupos_plan(p))
    else jsonb_build_object('envejecientes', t.prueba_limite_envejecientes, 'usuarios', t.prueba_limite_usuarios,
      'familiares', t.prueba_limite_familiares, 'cuidadores', b.limite_cuidadores) end
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t using (tipo_cuenta_id)
  left join cuidared.plan p on p.plan_id = c.plan_id
  left join cuidared.plan b on t.codigo = 'familia' and b.nombre = 'Básico Familiar'
    and b.tipo_cuenta_id = t.tipo_cuenta_id and b.estado = 'activo'
  left join cuidared.stripe_suscripcion s on s.cuenta_id = c.cuenta_id and s.gestionada and s.vigencia_hasta is not null
  left join cuidared.stripe_oferta o on o.price_id = s.price_id
    and o.cuenta_cotizada_id = c.cuenta_id and o.plan_id = c.plan_id
  where c.cuenta_id = p_cuenta_id
$$;

create function cuidared_interno.stripe_exigir_cupos_oferta(p_cuenta_id bigint, p_oferta cuidared.stripe_oferta)
returns void language plpgsql set search_path = '' as $$
declare
  v_cupos jsonb := coalesce(p_oferta.limites_cotizados,
    (select cuidared_interno.stripe_cupos_plan(p) from cuidared.plan p where p.plan_id = p_oferta.plan_id));
  v_uso jsonb;
begin
  perform cuidared_interno.env_bloquear_limite(p_cuenta_id);
  v_uso := cuidared_interno.uso_de_cuenta(p_cuenta_id) ||
    case when p_oferta.limites_cotizados is not null then cuidared_interno.uso_miembros(p_cuenta_id)
    else jsonb_build_object('cuidadores', cuidared_interno.uso_miembros(p_cuenta_id)->'cuidadores') end;
  if exists (
    select from jsonb_each_text(v_cupos) x
    where (v_uso->>x.key)::bigint > x.value::integer
  ) then raise exception 'CR_STRIPE_SUPERA_LIMITE' using errcode = 'P0001'; end if;
end $$;

create function cuidared_interno.stripe_exigir_version(p_oferta cuidared.stripe_oferta, p_version uuid)
returns void language plpgsql set search_path = '' as $$
begin
  if p_oferta.version_cotizacion is distinct from p_version then
    raise exception 'CR_STRIPE_COTIZACION_ACTUALIZADA' using errcode = 'P0001';
  end if;
end $$;

create or replace function cuidared_interno.stripe_volumen(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select cuidared_interno.uso_de_cuenta(p_cuenta_id) || jsonb_build_object(
    'cuidadores', (
      select count(distinct m.usuario_id)
      from cuidared.membresia m join cuidared.rol r using (rol_id) join cuidared.usuario u using (usuario_id)
      where m.cuenta_id = p_cuenta_id and m.estado = 'activa' and r.codigo = 'cuidador'
        and r.activo and u.estado = 'activo' and m.fecha_inicio <= cuidared_interno.hoy()
        and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
    ))
$$;

create or replace function cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'codigo', t.codigo, 'nombre', t.nombre, 'periodicidad', t.periodicidad, 'moneda', 'USD',
    'estado', case when o.price_id is not null then 'cotizada'
      when q.cuenta_id is not null then 'solicitada' else 'sin_cotizar' end,
    'importe_centavos', o.importe_centavos, 'limites', o.limites_cotizados, 'version', o.version_cotizacion,
    'cuidadores', coalesce(q.cuidadores, (v.uso->>'cuidadores')::integer),
    'envejecientes', coalesce(q.envejecientes, (v.uso->>'envejecientes')::integer),
    'usuarios', case when q.cuenta_id is null then (v.uso->>'usuarios')::integer else q.usuarios end,
    'familiares', case when q.cuenta_id is null then (v.uso->>'familiares')::integer else q.familiares end)
    order by t.periodicidad), '[]'::jsonb)
  from (select cuidared_interno.stripe_volumen(p_cuenta_id) as uso) v
  cross join cuidared_interno.stripe_codigos('organizacion') t
  left join cuidared.stripe_cotizacion q on q.cuenta_id = p_cuenta_id and q.codigo = t.codigo
  left join cuidared.stripe_oferta o on o.cuenta_cotizada_id = p_cuenta_id and o.codigo = t.codigo and o.activa
  where cuidared_interno.stripe_es_cotizable(t.codigo)
$$;

create or replace function cuidared_api.api_stripe_solicitar_cotizacion(p_cuenta_id bigint, p_codigo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir_miembros(p_cuenta_id, 'cuenta:suscripcion');
  v_actor uuid := (v_ctx->>'usuario_id')::uuid;
  v_volumen jsonb;
begin
  if v_ctx->>'tipo' is distinct from 'organizacion' then raise no_data_found; end if;
  if not exists (select from cuidared.cuenta where cuenta_id = p_cuenta_id
    and usuario_titular_id = v_actor for update) then raise insufficient_privilege; end if;
  if cuidared_interno.stripe_es_cotizable(p_codigo) is distinct from true then raise invalid_parameter_value; end if;
  v_volumen := cuidared_interno.stripe_volumen(p_cuenta_id);
  insert into cuidared.stripe_cotizacion(cuenta_id, codigo, solicitada_por, cuidadores, envejecientes, usuarios, familiares)
  values (p_cuenta_id, p_codigo, v_actor, (v_volumen->>'cuidadores')::integer,
    (v_volumen->>'envejecientes')::integer, (v_volumen->>'usuarios')::integer, (v_volumen->>'familiares')::integer)
  on conflict (cuenta_id, codigo) do nothing;
  return jsonb_build_object('cotizaciones', cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id));
end $$;

create or replace function cuidared_api.api_bo_stripe_leer(
  p_actor uuid, p_sesion uuid, p_aal text, p_cuenta_id bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor, p_sesion, p_aal);
  if p_cuenta_id is not null then
    if not exists (select from cuidared.cuenta c join cuidared.tipo_cuenta t using (tipo_cuenta_id)
      where c.cuenta_id = p_cuenta_id and t.codigo = 'organizacion') then raise no_data_found; end if;
    return jsonb_build_object('cotizaciones', cuidared_interno.stripe_cotizaciones_de_cuenta(p_cuenta_id));
  end if;
  return (
    select jsonb_build_object('tarifas', coalesce(jsonb_agg(jsonb_build_object(
      'codigo', t.codigo, 'nombre', t.nombre, 'periodicidad', t.periodicidad, 'moneda', 'USD',
      'tipo', v.tipo, 'importe_centavos', o.importe_centavos, 'importe_sugerido_centavos', t.importe_sugerido_centavos
    ) order by v.tipo, t.codigo, t.periodicidad), '[]'::jsonb))
    from (values ('familia'), ('organizacion')) v(tipo)
    cross join lateral cuidared_interno.stripe_codigos(v.tipo) t
    left join cuidared.stripe_oferta o on o.codigo = t.codigo and o.cuenta_cotizada_id is null and o.activa
    where not cuidared_interno.stripe_es_cotizable(t.codigo)
  );
end $$;

drop function cuidared_api.api_bo_stripe_publicar_tarifa(uuid, uuid, text, bigint, text, integer, text, text);
drop function cuidared_api.api_bo_stripe_preparar_tarifa(uuid, uuid, text, bigint, text);

create function cuidared_api.api_bo_stripe_preparar_tarifa(p_actor uuid, p_sesion uuid, p_aal text,
  p_cuenta_id bigint, p_codigo text, p_limites jsonb default null, p_importe_centavos integer default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_periodicidad text;
  v_oferta cuidared.stripe_oferta%rowtype;
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor, p_sesion, p_aal);
  if p_cuenta_id is not null then
    if not exists (
      select from cuidared.stripe_cotizacion q join cuidared.cuenta c using (cuenta_id)
      join cuidared.tipo_cuenta t using (tipo_cuenta_id)
      where q.cuenta_id = p_cuenta_id and q.codigo = p_codigo and c.estado = 'activa' and t.codigo = 'organizacion'
    ) then raise no_data_found; end if;
    if not cuidared_interno.stripe_limites_validos(p_limites) then raise invalid_parameter_value; end if;
  elsif p_limites is not null then
    raise invalid_parameter_value;
  end if;
  select t.periodicidad into v_periodicidad
  from (values ('familia'), ('organizacion')) v(tipo)
  cross join lateral cuidared_interno.stripe_codigos(v.tipo) t
  where t.codigo = p_codigo and cuidared_interno.stripe_es_cotizable(t.codigo) = (p_cuenta_id is not null);
  if not found then raise no_data_found; end if;
  if p_importe_centavos is not null and p_importe_centavos not between 50 and 99999999 then
    raise invalid_parameter_value;
  end if;
  select * into v_oferta from cuidared.stripe_oferta
  where codigo = p_codigo and cuenta_cotizada_id is not distinct from p_cuenta_id and activa;
  return jsonb_build_object('periodicidad', v_periodicidad, 'version_actual', v_oferta.version_cotizacion,
    'sin_cambios', coalesce(p_cuenta_id is not null and v_oferta.importe_centavos = p_importe_centavos
      and v_oferta.limites_cotizados = p_limites, false));
end $$;

-- Solo las tarifas directas son globales. Cada versión de una cotización usa un Price distinto.
drop function cuidared_interno.stripe_catalogo_sembrar(text, text, text, integer, text, integer, bigint);
drop function cuidared_interno.stripe_catalogo_registrar(text, smallint, text, text, integer, text, integer, bigint);

create function cuidared_interno.stripe_catalogo_registrar(
  p_codigo text, p_plan_id smallint, p_price_id text, p_periodicidad text, p_importe_centavos integer, p_moneda text,
  p_divisor_moneda integer, p_cuenta_cotizada_id bigint default null, p_limites jsonb default null
) returns void
language plpgsql set search_path = '' as $$
declare
  v_oferta cuidared.stripe_oferta%rowtype;
begin
  if cuidared_interno.stripe_es_cotizable(p_codigo) is distinct from (p_cuenta_cotizada_id is not null)
    or (p_cuenta_cotizada_id is not null and not cuidared_interno.stripe_limites_validos(p_limites))
    or (p_cuenta_cotizada_id is null and p_limites is not null)
    or p_periodicidad is null or p_periodicidad not in ('mensual', 'anual')
    or p_price_id is null or p_price_id !~ '^price_[A-Za-z0-9_]{1,240}$'
    or p_moneda is distinct from 'USD'
    or p_importe_centavos is null or p_importe_centavos not between 1 and 99999999
    or p_divisor_moneda is distinct from 100
    or not exists (
      select 1 from cuidared_interno.stripe_catalogo_modelo() m
      join cuidared.plan p on p.nombre = m.nombre and p.estado = 'activo' and not p.bo_gratuito
      join cuidared.tipo_cuenta t on t.tipo_cuenta_id = p.tipo_cuenta_id and t.codigo = m.tipo
      where p.plan_id = p_plan_id and m.codigo || '_' || p_periodicidad = p_codigo
        and (
          p_cuenta_cotizada_id is null or (m.tipo = 'organizacion' and exists (
            select 1 from cuidared.cuenta c where c.cuenta_id = p_cuenta_cotizada_id
              and c.tipo_cuenta_id = p.tipo_cuenta_id
          ))
        )
    ) then
    raise invalid_parameter_value;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cuidared.stripe.oferta:' || p_codigo
    || ':' || coalesce(p_cuenta_cotizada_id::text, 'global'), 0));
  select * into v_oferta from cuidared.stripe_oferta where price_id = p_price_id for update;
  if found and (v_oferta.codigo <> p_codigo or v_oferta.plan_id <> p_plan_id
    or v_oferta.periodicidad <> p_periodicidad or v_oferta.importe_centavos <> p_importe_centavos
    or v_oferta.moneda <> p_moneda or v_oferta.divisor_moneda <> p_divisor_moneda
    or v_oferta.cuenta_cotizada_id is distinct from p_cuenta_cotizada_id
    or v_oferta.limites_cotizados is distinct from p_limites) then
    raise invalid_parameter_value;
  end if;
  if found and p_cuenta_cotizada_id is not null and not v_oferta.activa then
    raise exception 'CR_STRIPE_COTIZACION_ACTUALIZADA' using errcode = 'P0001';
  end if;
  update cuidared.stripe_oferta set activa = false
    where codigo = p_codigo and activa and price_id <> p_price_id
      and cuenta_cotizada_id is not distinct from p_cuenta_cotizada_id;
  insert into cuidared.stripe_oferta (price_id, codigo, plan_id, periodicidad, importe_centavos, moneda, divisor_moneda,
    cuenta_cotizada_id, limites_cotizados, version_cotizacion)
    values (p_price_id, p_codigo, p_plan_id, p_periodicidad, p_importe_centavos, p_moneda, p_divisor_moneda,
      p_cuenta_cotizada_id, p_limites, case when p_limites is not null then gen_random_uuid() end)
    on conflict (price_id) do update set activa = true;
end;
$$;

create function cuidared_interno.stripe_catalogo_sembrar(
  p_codigo text, p_price_id text, p_periodicidad text, p_importe_centavos integer, p_moneda text,
  p_divisor_moneda integer, p_cuenta_cotizada_id bigint default null, p_limites jsonb default null
) returns smallint
language plpgsql set search_path = '' as $$
declare
  v_modelo record;
  v_plan_id smallint;
begin
  select m.*, t.tipo_cuenta_id into v_modelo
    from cuidared_interno.stripe_catalogo_modelo() m join cuidared.tipo_cuenta t on t.codigo = m.tipo
    where m.codigo || '_' || p_periodicidad = p_codigo;
  if not found then raise invalid_parameter_value; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('cuidared.stripe.plan:' || v_modelo.codigo, 0));

  select plan_id into v_plan_id from cuidared.plan where nombre = v_modelo.nombre;
  if not found then
    if p_importe_centavos is null or p_importe_centavos not between 1 and 99999999
       or p_divisor_moneda is null or p_divisor_moneda not in (1, 100, 1000) then
      raise invalid_parameter_value;
    end if;
    insert into cuidared.plan_categoria (nombre) values (v_modelo.categoria) on conflict (nombre) do nothing;
    insert into cuidared.plan (nombre, plan_categoria_id, tipo_cuenta_id, precio, periodicidad,
      limite_envejecientes, limite_usuarios, limite_familiares, limite_cuidadores)
    select v_modelo.nombre, pc.plan_categoria_id, v_modelo.tipo_cuenta_id,
      case when v_modelo.tipo = 'familia' then p_importe_centavos::numeric / p_divisor_moneda else 0 end,
      p_periodicidad, v_modelo.adultos, v_modelo.usuarios, v_modelo.familiares,
      case when v_modelo.codigo = 'basico_familiar' then 5 end
    from cuidared.plan_categoria pc where pc.nombre = v_modelo.categoria
    returning plan_id into strict v_plan_id;
    insert into cuidared.plan_funcionalidad (plan_id, funcionalidad)
    select v_plan_id, f from unnest(v_modelo.funcionalidades) f;
  end if;
  perform cuidared_interno.stripe_catalogo_registrar(p_codigo, v_plan_id, p_price_id,
    p_periodicidad, p_importe_centavos, p_moneda, p_divisor_moneda, p_cuenta_cotizada_id, p_limites);
  return v_plan_id;
end;
$$;

create function cuidared_api.api_bo_stripe_publicar_tarifa(p_actor uuid, p_sesion uuid, p_aal text,
  p_cuenta_id bigint, p_codigo text, p_importe_centavos integer, p_price_id text, p_motivo text,
  p_limites jsonb default null, p_version_esperada uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_periodicidad text;
  v_anterior cuidared.stripe_oferta%rowtype;
  v_volumen jsonb;
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor, p_sesion, p_aal);
  if p_cuenta_id is not null then
    perform 1 from cuidared.cuenta where cuenta_id = p_cuenta_id for update;
    if not found then raise no_data_found; end if;
    perform 1 from cuidared.stripe_cotizacion
    where cuenta_id = p_cuenta_id and codigo = p_codigo for update;
    if not found then raise no_data_found; end if;
  end if;
  v_periodicidad := cuidared_api.api_bo_stripe_preparar_tarifa(p_actor, p_sesion, p_aal, p_cuenta_id,
    p_codigo, p_limites, p_importe_centavos)->>'periodicidad';
  if p_importe_centavos is null or p_version_esperada is not null and p_cuenta_id is null
    or p_motivo is null or char_length(btrim(p_motivo)) not between 5 and 500 then raise invalid_parameter_value; end if;
  select * into v_anterior from cuidared.stripe_oferta
  where codigo = p_codigo and cuenta_cotizada_id is not distinct from p_cuenta_id and activa;
  if p_cuenta_id is not null and v_anterior.price_id is distinct from p_price_id
    and p_version_esperada is distinct from v_anterior.version_cotizacion then
    raise exception 'CR_STRIPE_COTIZACION_ACTUALIZADA' using errcode = 'P0001';
  end if;
  perform cuidared_interno.stripe_catalogo_sembrar(p_codigo, p_price_id, v_periodicidad,
    p_importe_centavos, 'USD', 100, p_cuenta_id, p_limites);
  if p_cuenta_id is not null then
    if v_anterior.price_id = p_price_id then return; end if;
    v_volumen := cuidared_interno.stripe_volumen(p_cuenta_id);
    update cuidared.stripe_cotizacion set publicada_en = now(), publicada_por = p_actor,
      cuidadores = (v_volumen->>'cuidadores')::integer, envejecientes = (v_volumen->>'envejecientes')::integer,
      usuarios = (v_volumen->>'usuarios')::integer, familiares = (v_volumen->>'familiares')::integer
    where cuenta_id = p_cuenta_id and codigo = p_codigo;
  end if;
  perform cuidared_interno.bo_auditar(p_actor, 'super_admin', p_cuenta_id,
    case when p_cuenta_id is null then 'stripe.tarifa.publicar' else 'stripe.cotizacion.publicar' end,
    'oferta_stripe', p_codigo,
    jsonb_build_object('importe_centavos', v_anterior.importe_centavos, 'limites', v_anterior.limites_cotizados),
    jsonb_build_object('moneda', 'USD', 'importe_centavos', p_importe_centavos, 'limites', p_limites)
      || coalesce(v_volumen, '{}'::jsonb), btrim(p_motivo));
end $$;

create or replace function cuidared_api.api_stripe_gestion(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'cuenta:suscripcion');
begin
  return (
    select jsonb_build_object(
      'es_titular', c.usuario_titular_id = (v_ctx->>'usuario_id')::uuid,
      'estado', case when c.suscripcion_estado in ('activa', 'prueba') and not a.operativo
                then 'vencida' else c.suscripcion_estado end,
      'acceso_operativo', a.operativo,
      'limites', cuidared_interno.limites(c.cuenta_id),
      'vigencia_hasta', case
        when c.suscripcion_estado = 'prueba' then c.fecha_fin_prueba
        when s.vigencia_hasta is not null then s.vigencia_hasta
        when c.fecha_fin_vigencia is not null
          then (c.fecha_fin_vigencia + 1)::timestamp at time zone 'America/Santo_Domingo'
      end,
      'cancelacion_programada', coalesce(s.cancelacion_programada, false),
      'suscripcion_stripe', coalesce(s.vigencia_hasta > now() or (s.estado not in ('canceled', 'incomplete_expired')
        and (s.titular_id = c.usuario_titular_id or not s.cancelacion_programada)), false),
      'puede_modificar', coalesce(
        c.usuario_titular_id = (v_ctx->>'usuario_id')::uuid and s.titular_id = c.usuario_titular_id
        and s.estado in ('active', 'past_due', 'unpaid', 'paused'), false
      ),
      'checkout_en_curso', (
        select o.codigo from cuidared.stripe_intento i join cuidared.stripe_oferta o using (price_id)
        where i.cuenta_id = c.cuenta_id and i.titular_id = c.usuario_titular_id
          and c.usuario_titular_id = (v_ctx->>'usuario_id')::uuid and i.estado = 'abierto'
          and (i.session_id is not null or i.vence_en > now() or s.intento_id = i.intento_id)
      ),
      'cambio_en_curso', (
        select jsonb_build_object('codigo', o.codigo, 'modo', ca.modo, 'efectivo_en', ca.efectivo_en)
        from cuidared.stripe_cambio ca join cuidared.stripe_oferta o using (price_id)
        where ca.subscription_id = s.subscription_id and ca.estado = 'pendiente'
      ),
      'ofertas', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'codigo', o.codigo,
          'nombre', p.nombre,
          'periodicidad', o.periodicidad,
          'importe_centavos', o.importe_centavos,
          'moneda', o.moneda,
          'limites', coalesce(o.limites_cotizados, cuidared_interno.stripe_cupos_plan(p)),
          'version', o.version_cotizacion,
          'en_curso', tramite.activo,
          'publicada', o.activa,
          'funcionalidades', coalesce((select jsonb_agg(f.funcionalidad order by f.funcionalidad)
                                       from cuidared.plan_funcionalidad f where f.plan_id = p.plan_id), '[]'::jsonb),
          'actual', coalesce(s.price_id = o.price_id and a.operativo and c.suscripcion_estado = 'activa', false)
        ) order by tramite.activo desc, o.activa desc, o.importe_centavos, o.codigo), '[]'::jsonb)
        from cuidared.stripe_oferta o
        join cuidared.plan p using (plan_id)
        cross join lateral (select
          exists (
            select from cuidared.stripe_intento i
            where i.cuenta_id = c.cuenta_id and i.titular_id = c.usuario_titular_id
              and c.usuario_titular_id = (v_ctx->>'usuario_id')::uuid and i.estado = 'abierto'
              and i.price_id = o.price_id and (i.session_id is not null or i.vence_en > now() or s.intento_id = i.intento_id)
          ) or exists (
            select from cuidared.stripe_cambio ca
            where ca.subscription_id = s.subscription_id and ca.estado = 'pendiente' and ca.price_id = o.price_id
          ) as activo) tramite
        where p.tipo_cuenta_id = c.tipo_cuenta_id and not p.bo_gratuito
          and (o.cuenta_cotizada_id is null or o.cuenta_cotizada_id = c.cuenta_id)
          and ((o.activa and p.estado = 'activo') or tramite.activo
            or (o.price_id = s.price_id and s.vigencia_hasta is not null and a.operativo))
      )
    )
    from cuidared.cuenta c
    cross join lateral (select cuidared_interno.acceso_operativo(c.cuenta_id) as operativo) a
    left join cuidared.stripe_suscripcion s on s.cuenta_id = c.cuenta_id and s.gestionada
    where c.cuenta_id = p_cuenta_id
  );
end;
$$;

drop function cuidared_api.api_stripe_preparar_cambio(bigint, text);
drop function cuidared_api.api_stripe_preparar_checkout(bigint, text);

create function cuidared_api.api_stripe_preparar_cambio(p_cuenta_id bigint, p_oferta text, p_version uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s cuidared.stripe_suscripcion := cuidared_interno.stripe_suscripcion_gestionable(p_cuenta_id);
  v_oferta cuidared.stripe_oferta%rowtype;
  v_oferta_anterior cuidared.stripe_oferta%rowtype;
  v_cambio cuidared.stripe_cambio%rowtype;
  v_modo text;
begin
  if v_s.estado <> 'active' or v_s.vigencia_hasta is null or not cuidared_interno.acceso_operativo(p_cuenta_id)
      or v_s.cancelacion_programada then
    raise exception 'CR_STRIPE_SUSCRIPCION_NO_MODIFICABLE' using errcode = 'P0001';
  end if;
  if p_oferta is null or p_oferta !~ '^[a-z0-9][a-z0-9_-]{0,63}$' then raise invalid_parameter_value; end if;

  select * into v_cambio from cuidared.stripe_cambio
    where subscription_id = v_s.subscription_id and estado = 'pendiente' for update;
  if found then
    select * into strict v_oferta from cuidared.stripe_oferta where price_id = v_cambio.price_id;
    if v_oferta.codigo <> p_oferta then raise exception 'CR_STRIPE_CAMBIO_EN_CURSO' using errcode = 'P0001'; end if;
    perform cuidared_interno.stripe_exigir_version(v_oferta, p_version);
  else
    if v_s.pendiente_price_id is not null or v_s.schedule_id is not null then
      raise exception 'CR_STRIPE_CAMBIO_EN_CURSO' using errcode = 'P0001';
    end if;
    select o.* into v_oferta
    from cuidared.stripe_oferta o join cuidared.plan p using (plan_id)
    join cuidared.cuenta c on c.cuenta_id = p_cuenta_id and c.tipo_cuenta_id = p.tipo_cuenta_id
    where o.codigo = p_oferta and o.activa and p.estado = 'activo' and not p.bo_gratuito
      and (o.cuenta_cotizada_id is null or o.cuenta_cotizada_id = p_cuenta_id)
    for share of o;
    if not found then raise no_data_found; end if;
    perform cuidared_interno.stripe_exigir_version(v_oferta, p_version);
    if v_oferta.price_id = v_s.price_id then raise invalid_parameter_value; end if;
    select * into strict v_oferta_anterior from cuidared.stripe_oferta where price_id = v_s.price_id;
    if v_oferta.moneda <> v_oferta_anterior.moneda then raise invalid_parameter_value; end if;
    perform cuidared_interno.stripe_exigir_cupos_oferta(p_cuenta_id, v_oferta);
    v_modo := case when v_oferta.periodicidad = v_oferta_anterior.periodicidad
      and v_oferta.importe_centavos > v_oferta_anterior.importe_centavos then 'inmediato' else 'proximo_corte' end;
    insert into cuidared.stripe_cambio(subscription_id, titular_id, price_id, modo, efectivo_en)
      values (v_s.subscription_id, auth.uid(), v_oferta.price_id, v_modo,
        case when v_modo = 'inmediato' then date_trunc('second', clock_timestamp()) else v_s.vigencia_hasta end)
      returning * into v_cambio;
  end if;

  return jsonb_build_object('cambio_id', v_cambio.cambio_id, 'subscription_id', v_s.subscription_id,
    'price_id', v_oferta.price_id, 'importe_centavos', v_oferta.importe_centavos,
    'moneda', v_oferta.moneda, 'periodicidad', v_oferta.periodicidad,
    'price_id_actual', v_s.price_id, 'modo', v_cambio.modo, 'efectivo_en', v_cambio.efectivo_en,
    'schedule_id', v_cambio.schedule_id, 'vigencia_hasta', v_s.vigencia_hasta);
end;
$$;

create function cuidared_api.api_stripe_preparar_checkout(p_cuenta_id bigint, p_oferta text, p_version uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_cuenta cuidared.cuenta%rowtype;
  v_oferta cuidared.stripe_oferta%rowtype;
  v_intento cuidared.stripe_intento%rowtype;
  v_ahora timestamptz;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'cuenta:suscripcion');
  v_actor := (v_ctx->>'usuario_id')::uuid;

  select * into strict v_cuenta from cuidared.cuenta where cuenta_id = p_cuenta_id for update;
  if v_cuenta.usuario_titular_id <> v_actor then raise insufficient_privilege; end if;

  if p_oferta is null or p_oferta !~ '^[a-z0-9][a-z0-9_-]{0,63}$' then raise invalid_parameter_value; end if;
  v_ahora := date_trunc('second', clock_timestamp());
  update cuidared.stripe_intento i set estado = 'expirado'
    where i.cuenta_id = p_cuenta_id and i.estado = 'abierto' and i.session_id is null and i.vence_en <= v_ahora
      and not exists (select 1 from cuidared.stripe_suscripcion s where s.intento_id = i.intento_id);
  select * into v_intento from cuidared.stripe_intento
    where cuenta_id = p_cuenta_id and estado = 'abierto' for update;

  if found then
    select * into strict v_oferta from cuidared.stripe_oferta where price_id = v_intento.price_id;
    if v_oferta.codigo <> p_oferta or v_intento.titular_id <> v_actor then
      raise exception 'CR_STRIPE_CHECKOUT_EN_CURSO' using errcode = 'P0001';
    end if;
    perform cuidared_interno.stripe_exigir_version(v_oferta, p_version);
  else
    if exists (select 1 from cuidared.stripe_suscripcion s where s.cuenta_id = p_cuenta_id and s.gestionada
               and (s.vigencia_hasta > now() or (s.estado not in ('canceled', 'incomplete_expired')
                 and (s.titular_id = v_actor or not s.cancelacion_programada)))) then
      raise exception 'CR_STRIPE_SUSCRIPCION_EN_CURSO' using errcode = 'P0001';
    end if;
    select o.* into v_oferta
      from cuidared.stripe_oferta o join cuidared.plan p using (plan_id)
      where o.codigo = p_oferta and o.activa and p.tipo_cuenta_id = v_cuenta.tipo_cuenta_id
        and p.estado = 'activo' and not p.bo_gratuito
        and (o.cuenta_cotizada_id is null or o.cuenta_cotizada_id = p_cuenta_id)
      for share of o;
    if not found then raise no_data_found; end if;
    perform cuidared_interno.stripe_exigir_version(v_oferta, p_version);
    perform cuidared_interno.stripe_exigir_cupos_oferta(p_cuenta_id, v_oferta);
    insert into cuidared.stripe_intento (cuenta_id, titular_id, price_id, creado_en, vence_en)
      values (p_cuenta_id, v_actor, v_oferta.price_id, v_ahora, v_ahora + interval '45 minutes')
      returning * into v_intento;
  end if;

  return jsonb_build_object(
    'intento_id', v_intento.intento_id,
    'price_id', v_intento.price_id,
    'customer_id', (select customer_id from cuidared.stripe_cliente where cuenta_id = p_cuenta_id and titular_id = v_actor),
    'session_id', v_intento.session_id,
    'vence_en', v_intento.vence_en,
    'moneda', v_oferta.moneda,
    'importe_centavos', v_oferta.importe_centavos,
    'periodicidad', v_oferta.periodicidad
  );
end;
$$;

create or replace function cuidared_api.api_stripe_catalogo_cuenta(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'cuenta:suscripcion');
begin
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigo', m.codigo, 'nombre', p.nombre,
      'cotizado', m.codigo = 'gestion_comunitaria_avanzada',
      'limites', jsonb_build_object('envejecientes', p.limite_envejecientes,
        'usuarios', p.limite_usuarios, 'familiares', p.limite_familiares, 'cuidadores', p.limite_cuidadores),
      'funcionalidades', coalesce((select jsonb_agg(f.funcionalidad order by f.funcionalidad)
        from cuidared.plan_funcionalidad f where f.plan_id = p.plan_id
        and f.funcionalidad <> 'org_necesidad'
        and (m.tipo <> 'familia' or f.funcionalidad not in ('registro_visitas', 'visitas_recurrentes'))), '[]'::jsonb),
      'precios_referencia', (select jsonb_object_agg(c.periodicidad, c.importe_sugerido_centavos)
        from cuidared_interno.stripe_codigos('familia') c
        where c.codigo = m.codigo || '_' || c.periodicidad)
    ) order by p.limite_envejecientes nulls last, p.plan_id), '[]'::jsonb)
    from cuidared_interno.stripe_catalogo_modelo() m
    join cuidared.tipo_cuenta t on t.codigo = m.tipo
    join cuidared.plan p on p.nombre = m.nombre and p.tipo_cuenta_id = t.tipo_cuenta_id
    where m.tipo = v_ctx->>'tipo' and p.estado = 'activo' and not p.bo_gratuito
  );
end $$;

create or replace function cuidared_api.api_bo_leer(p_actor uuid, p_sesion uuid, p_aal text, p_recurso text, p_filtros jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_data jsonb := cuidared_interno.bo_leer_previo_catalogo(p_actor,p_sesion,p_aal,p_recurso,p_filtros);
  v_limites jsonb;
begin
  if p_recurso = 'detalle' then
    v_limites := cuidared_interno.limites((v_data->>'cuenta_id')::bigint);
    return jsonb_set(v_data, '{plan}', v_data->'plan' || jsonb_build_object(
      'max_cuidadores', v_limites->'cuidadores', 'max_familiares', v_limites->'familiares'));
  end if;
  if p_recurso is distinct from 'planes' then return v_data; end if;
  return (
    select coalesce(jsonb_agg(x.plan || jsonb_build_object(
      'limite_cuidadores', p.limite_cuidadores, 'limite_familiares', p.limite_familiares,
      'cuidadores_editable', p.nombre = 'Básico Familiar' and t.codigo = 'familia',
      'cotizado', p.nombre = 'Gestión Comunitaria Avanzada' and t.codigo = 'organizacion'
    ) order by x.pos), '[]'::jsonb)
    from jsonb_array_elements(v_data) with ordinality x(plan,pos)
    join cuidared.plan p on p.plan_id = (x.plan->>'plan_id')::smallint
    join cuidared.tipo_cuenta t using (tipo_cuenta_id)
  );
end $$;

create or replace function cuidared_interno.bo_limites_catalogo(p_actor uuid, p_sesion uuid, p_aal text,
  p_datos jsonb, p_motivo text, p_ip inet, p_agente text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_plan cuidared.plan%rowtype;
  v_adultos integer := (p_datos->>'adultos')::integer;
  v_usuarios integer := (p_datos->>'usuarios')::integer;
  v_cuidadores integer;
  v_nuevo jsonb;
begin
  perform cuidared_interno.stripe_exigir_backoffice(p_actor,p_sesion,p_aal);
  if p_motivo is null or char_length(btrim(p_motivo)) not between 5 and 400
    or not (p_datos ? 'adultos' and p_datos ? 'usuarios')
    or v_adultos not between 1 and 100000 or v_usuarios not between 1 and 100000 then
    raise invalid_parameter_value;
  end if;
  select * into strict v_plan from cuidared.plan
  where plan_id = (p_datos->>'id')::smallint and estado = 'activo' and not bo_gratuito for update;
  if v_plan.nombre = 'Gestión Comunitaria Avanzada' then raise invalid_parameter_value; end if;
  v_cuidadores := v_plan.limite_cuidadores;
  if p_datos ? 'cuidadores' then
    v_cuidadores := (p_datos->>'cuidadores')::integer;
    if v_plan.nombre <> 'Básico Familiar' or v_cuidadores is null or v_cuidadores not between 1 and 100000 then
      raise invalid_parameter_value;
    end if;
  end if;
  update cuidared.plan set limite_envejecientes = v_adultos, limite_usuarios = v_usuarios,
    limite_cuidadores = v_cuidadores where plan_id = v_plan.plan_id;
  v_nuevo := jsonb_build_object('adultos', v_adultos, 'usuarios', v_usuarios, 'cuidadores', v_cuidadores);
  perform cuidared_interno.bo_auditar(p_actor,'super_admin',null,'plan.limites','plan',v_plan.plan_id::text,
    jsonb_build_object('adultos',v_plan.limite_envejecientes,'usuarios',v_plan.limite_usuarios,
      'cuidadores',v_plan.limite_cuidadores),v_nuevo,btrim(p_motivo),p_ip,p_agente);
  return v_nuevo;
end $$;

revoke all on function
  cuidared_interno.stripe_es_cotizable(text), cuidared_interno.stripe_limites_validos(jsonb),
  cuidared_interno.stripe_cupos_plan(cuidared.plan),
  cuidared_interno.stripe_exigir_cupos_oferta(bigint, cuidared.stripe_oferta),
  cuidared_interno.stripe_exigir_version(cuidared.stripe_oferta, uuid),
  cuidared_interno.stripe_catalogo_sembrar(text, text, text, integer, text, integer, bigint, jsonb),
  cuidared_interno.stripe_catalogo_registrar(text, smallint, text, text, integer, text, integer, bigint, jsonb),
  cuidared_api.api_bo_stripe_preparar_tarifa(uuid, uuid, text, bigint, text, jsonb, integer),
  cuidared_api.api_bo_stripe_publicar_tarifa(uuid, uuid, text, bigint, text, integer, text, text, jsonb, uuid),
  cuidared_api.api_stripe_preparar_cambio(bigint, text, uuid),
  cuidared_api.api_stripe_preparar_checkout(bigint, text, uuid)
from public, anon, authenticated, service_role;

grant execute on function
  cuidared_api.api_bo_stripe_preparar_tarifa(uuid, uuid, text, bigint, text, jsonb, integer),
  cuidared_api.api_bo_stripe_publicar_tarifa(uuid, uuid, text, bigint, text, integer, text, text, jsonb, uuid)
to service_role;
grant execute on function
  cuidared_api.api_stripe_preparar_cambio(bigint, text, uuid),
  cuidared_api.api_stripe_preparar_checkout(bigint, text, uuid)
to authenticated;

commit;
