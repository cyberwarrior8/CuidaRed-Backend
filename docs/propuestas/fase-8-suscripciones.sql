-- Fase 8 · Suscripción y pagos con Stripe Sandbox · ID08, RF-20, RF-21, CU-20.
-- Propuesta. Requiere aprobación específica antes de aplicar a Supabase.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

-- Una nueva tarifa usa un Price distinto. Los intentos y pagos conservan la tarifa original.
create table cuidared.stripe_oferta (
  price_id text primary key check (price_id ~ '^price_[A-Za-z0-9_]{1,240}$'),
  codigo text not null check (codigo ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  plan_id smallint not null references cuidared.plan(plan_id),
  cuenta_cotizada_id bigint references cuidared.cuenta(cuenta_id),
  periodicidad text not null check (periodicidad in ('mensual', 'anual')),
  importe_centavos integer not null check (importe_centavos between 1 and 99999999),
  moneda text not null check (moneda ~ '^[A-Z]{3}$'),
  divisor_moneda integer not null check (divisor_moneda in (1, 100, 1000)),
  activa boolean not null default true,
  creada_en timestamptz not null default now()
);

create unique index stripe_oferta_codigo_activo
  on cuidared.stripe_oferta(codigo, cuenta_cotizada_id) nulls not distinct where activa;
create index stripe_oferta_plan on cuidared.stripe_oferta(plan_id);
create index stripe_oferta_cuenta_cotizada on cuidared.stripe_oferta(cuenta_cotizada_id);

-- Un cliente de Stripe pertenece a una cuenta y a su pagador. Una transferencia no comparte métodos de pago.
create table cuidared.stripe_cliente (
  cuenta_id bigint not null references cuidared.cuenta(cuenta_id),
  titular_id uuid not null references cuidared.usuario(usuario_id),
  customer_id text not null unique check (customer_id ~ '^cus_[A-Za-z0-9_]{1,240}$'),
  primary key (cuenta_id, titular_id),
  unique (cuenta_id, titular_id, customer_id)
);

create index stripe_cliente_titular on cuidared.stripe_cliente(titular_id);

create table cuidared.stripe_intento (
  intento_id uuid primary key default gen_random_uuid(),
  cuenta_id bigint not null references cuidared.cuenta(cuenta_id),
  titular_id uuid not null references cuidared.usuario(usuario_id),
  price_id text not null references cuidared.stripe_oferta(price_id),
  session_id text unique check (session_id ~ '^cs_test_[A-Za-z0-9_]{1,240}$'),
  estado text not null default 'abierto' check (estado in ('abierto', 'completado', 'expirado')),
  creado_en timestamptz not null,
  vence_en timestamptz not null check (vence_en > creado_en),
  unique (intento_id, cuenta_id, titular_id)
);

create unique index stripe_intento_uno_abierto on cuidared.stripe_intento(cuenta_id) where estado = 'abierto';
create index stripe_intento_cuenta on cuidared.stripe_intento(cuenta_id);
create index stripe_intento_titular on cuidared.stripe_intento(titular_id);
create index stripe_intento_oferta on cuidared.stripe_intento(price_id);

create table cuidared.stripe_suscripcion (
  subscription_id text primary key check (subscription_id ~ '^sub_[A-Za-z0-9_]{1,240}$'),
  intento_id uuid not null unique,
  cuenta_id bigint not null,
  titular_id uuid not null,
  customer_id text not null,
  price_id text not null references cuidared.stripe_oferta(price_id),
  estado text not null
    check (estado in ('incomplete', 'incomplete_expired', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'paused')),
  cancelacion_programada boolean not null default false,
  gestionada boolean not null default true,
  vigencia_hasta timestamptz,
  pendiente_price_id text check (pendiente_price_id ~ '^price_[A-Za-z0-9_]{1,240}$'),
  schedule_id text check (schedule_id ~ '^sub_sched_[A-Za-z0-9_]{1,230}$'),
  snapshot_en timestamptz,
  creada_en timestamptz not null default now(),
  actualizada_en timestamptz not null default now(),
  foreign key (intento_id, cuenta_id, titular_id) references cuidared.stripe_intento(intento_id, cuenta_id, titular_id),
  foreign key (cuenta_id, titular_id, customer_id) references cuidared.stripe_cliente(cuenta_id, titular_id, customer_id),
  unique (subscription_id, cuenta_id)
);

create unique index stripe_suscripcion_actual on cuidared.stripe_suscripcion(cuenta_id) where gestionada;
create index stripe_suscripcion_cuenta_cliente on cuidared.stripe_suscripcion(cuenta_id, titular_id, customer_id);
create index stripe_suscripcion_oferta on cuidared.stripe_suscripcion(price_id);

create table cuidared.stripe_cambio (
  cambio_id uuid primary key default gen_random_uuid(),
  subscription_id text not null references cuidared.stripe_suscripcion(subscription_id),
  titular_id uuid not null references cuidared.usuario(usuario_id),
  price_id text not null references cuidared.stripe_oferta(price_id),
  factura_id text unique check (factura_id ~ '^in_[A-Za-z0-9_]{1,240}$'),
  modo text not null check (modo in ('inmediato', 'proximo_corte')),
  efectivo_en timestamptz not null,
  schedule_id text unique check (schedule_id is null
    or (schedule_id ~ '^sub_sched_[A-Za-z0-9_]{1,230}$' and modo = 'proximo_corte')),
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aplicado', 'descartado')),
  creado_en timestamptz not null default date_trunc('second', clock_timestamp())
);

create unique index stripe_cambio_uno_pendiente on cuidared.stripe_cambio(subscription_id) where estado = 'pendiente';
create index stripe_cambio_suscripcion on cuidared.stripe_cambio(subscription_id, price_id);
create index stripe_cambio_titular on cuidared.stripe_cambio(titular_id);
create index stripe_cambio_oferta on cuidared.stripe_cambio(price_id);

-- Correlaciona el evento confirmado con su intento. El cuerpo y los datos de tarjeta no se almacenan.
create table cuidared.stripe_evento (
  evento_id text primary key check (evento_id ~ '^evt_[A-Za-z0-9_]{1,240}$'),
  tipo text not null check (tipo ~ '^[a-z][a-z0-9_.]{0,99}$'),
  intento_id uuid not null references cuidared.stripe_intento(intento_id),
  fecha_proveedor timestamptz not null,
  procesado_en timestamptz not null default now()
);

create index stripe_evento_intento on cuidared.stripe_evento(intento_id, procesado_en desc);

-- Una notificación de reembolso puede llegar antes de la factura pagada.
create table cuidared.stripe_reembolso (
  invoice_id text primary key check (invoice_id ~ '^in_[A-Za-z0-9_]{1,240}$'),
  subscription_id text not null references cuidared.stripe_suscripcion(subscription_id),
  cargo_id text not null check (cargo_id ~ '^ch_[A-Za-z0-9_]{1,240}$'),
  importe_centavos integer not null check (importe_centavos between 1 and 99999999)
);

create index stripe_reembolso_suscripcion on cuidared.stripe_reembolso(subscription_id);

alter table cuidared.pago
  add column stripe_invoice_id text check (stripe_invoice_id ~ '^in_[A-Za-z0-9_]{1,240}$'),
  add column stripe_subscription_id text,
  add column stripe_price_id text references cuidared.stripe_oferta(price_id),
  add column stripe_periodo_desde timestamptz,
  add column stripe_periodo_hasta timestamptz,
  add column stripe_cargo_id text check (stripe_cargo_id ~ '^ch_[A-Za-z0-9_]{1,240}$'),
  add column stripe_importe_centavos integer check (stripe_importe_centavos between 1 and 99999999),
  add column stripe_reembolsado_centavos integer check (stripe_reembolsado_centavos >= 0),
  add constraint pago_stripe_suscripcion foreign key (stripe_subscription_id, cuenta_id)
    references cuidared.stripe_suscripcion(subscription_id, cuenta_id),
  add constraint pago_stripe_metadatos_coherentes check (
    (stripe_invoice_id is null and stripe_subscription_id is null and stripe_price_id is null
      and stripe_periodo_desde is null and stripe_periodo_hasta is null and stripe_cargo_id is null
      and stripe_importe_centavos is null and stripe_reembolsado_centavos is null)
    or
    (stripe_invoice_id is not null and stripe_subscription_id is not null and stripe_price_id is not null
      and stripe_periodo_desde is not null and stripe_periodo_hasta is not null
      and stripe_periodo_desde < stripe_periodo_hasta and stripe_importe_centavos is not null
      and stripe_reembolsado_centavos is not null and stripe_reembolsado_centavos <= stripe_importe_centavos)
  );

create unique index pago_stripe_factura on cuidared.pago(stripe_invoice_id) where stripe_invoice_id is not null;
create index pago_stripe_historial on cuidared.pago(cuenta_id, fecha_pago desc, pago_id desc)
  where stripe_invoice_id is not null;
create index pago_stripe_suscripcion_ref on cuidared.pago(stripe_subscription_id, cuenta_id)
  where stripe_subscription_id is not null;
create index pago_stripe_oferta on cuidared.pago(stripe_price_id) where stripe_price_id is not null;

alter table cuidared.stripe_oferta enable row level security;
alter table cuidared.stripe_cliente enable row level security;
alter table cuidared.stripe_intento enable row level security;
alter table cuidared.stripe_suscripcion enable row level security;
alter table cuidared.stripe_cambio enable row level security;
alter table cuidared.stripe_evento enable row level security;
alter table cuidared.stripe_reembolso enable row level security;
alter table cuidared.pago enable row level security;

revoke all on table cuidared.stripe_oferta, cuidared.stripe_cliente, cuidared.stripe_intento,
  cuidared.stripe_suscripcion, cuidared.stripe_cambio, cuidared.stripe_evento, cuidared.stripe_reembolso, cuidared.pago
  from public, anon, authenticated, service_role;

-- La vigencia del proveedor se comprueba como instante. Se conserva la semántica civil de los planes históricos.
create or replace function cuidared_interno.acceso_operativo(p_cuenta_id bigint) returns boolean
language sql stable set search_path = '' as $$
  select coalesce((
    select c.estado = 'activa' and case c.suscripcion_estado
      when 'prueba' then now() >= c.fecha_inicio_prueba and now() < c.fecha_fin_prueba
      when 'activa' then p.estado = 'activo' and case when s.vigencia_hasta is not null
        then now() < s.vigencia_hasta
        else c.fecha_fin_vigencia is null or c.fecha_fin_vigencia >= cuidared_interno.hoy()
      end
      else false end
    from cuidared.cuenta c
    left join cuidared.plan p using (plan_id)
    left join cuidared.stripe_suscripcion s on s.cuenta_id = c.cuenta_id and s.gestionada
    where c.cuenta_id = p_cuenta_id
  ), false)
$$;

-- El mantenimiento conserva planes gratuitos ya asignados y no otorga uno al expirar una prueba.
create or replace function cuidared_interno.actualizar_vencimientos() returns integer
language plpgsql set search_path = '' as $$
declare
  v_c cuidared.cuenta%rowtype;
  v_total int := 0;
begin
  for v_c in
    select c.* from cuidared.cuenta c
    left join cuidared.stripe_suscripcion s on s.cuenta_id = c.cuenta_id and s.gestionada
    where (c.suscripcion_estado = 'prueba' and c.fecha_fin_prueba <= now())
       or (c.suscripcion_estado = 'activa' and case when s.vigencia_hasta is not null
         then s.vigencia_hasta <= now() else c.fecha_fin_vigencia < cuidared_interno.hoy() end)
    order by c.cuenta_id for update of c skip locked
  loop
    update cuidared.cuenta set suscripcion_estado = 'vencida', fecha_actualizacion = now()
      where cuenta_id = v_c.cuenta_id;
    perform cuidared_interno.bo_auditar(null, 'sistema', v_c.cuenta_id, 'suscripcion.vencer', 'cuenta',
      v_c.cuenta_id::text, jsonb_build_object('estado', v_c.suscripcion_estado, 'plan_id', v_c.plan_id),
      jsonb_build_object('estado', 'vencida', 'plan_id', v_c.plan_id), 'Fin de vigencia');
    v_total := v_total + 1;
  end loop;
  return v_total;
end;
$$;

create function cuidared_api.api_stripe_gestion(p_cuenta_id bigint) returns jsonb
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
          'limites', jsonb_build_object('envejecientes', p.limite_envejecientes, 'usuarios', p.limite_usuarios,
                                       'familiares', p.limite_familiares),
          'funcionalidades', coalesce((select jsonb_agg(f.funcionalidad order by f.funcionalidad)
                                       from cuidared.plan_funcionalidad f where f.plan_id = p.plan_id), '[]'::jsonb),
          'actual', coalesce(s.price_id = o.price_id and a.operativo and c.suscripcion_estado = 'activa', false)
        ) order by o.importe_centavos, o.codigo), '[]'::jsonb)
        from cuidared.stripe_oferta o
        join cuidared.plan p using (plan_id)
        where o.activa and p.estado = 'activo' and not p.bo_gratuito and p.tipo_cuenta_id = c.tipo_cuenta_id
          and (o.cuenta_cotizada_id is null or o.cuenta_cotizada_id = c.cuenta_id)
      )
    )
    from cuidared.cuenta c
    cross join lateral (select cuidared_interno.acceso_operativo(c.cuenta_id) as operativo) a
    left join cuidared.stripe_suscripcion s on s.cuenta_id = c.cuenta_id and s.gestionada
    where c.cuenta_id = p_cuenta_id
  );
end;
$$;

create function cuidared_interno.stripe_exigir_capacidad(p_cuenta_id bigint, p_plan_id smallint) returns void
language plpgsql set search_path = '' as $$
declare
  v_plan cuidared.plan%rowtype;
  v_uso jsonb;
begin
  select * into strict v_plan from cuidared.plan where plan_id = p_plan_id;
  perform cuidared_interno.env_bloquear_limite(p_cuenta_id);
  v_uso := cuidared_interno.uso_de_cuenta(p_cuenta_id);
  if (v_uso->>'envejecientes')::bigint > v_plan.limite_envejecientes
     or (v_uso->>'usuarios')::bigint > v_plan.limite_usuarios
     or (v_uso->>'familiares')::bigint > v_plan.limite_familiares then
    raise exception 'CR_STRIPE_SUPERA_LIMITE' using errcode = 'P0001';
  end if;
end;
$$;

-- Acciones sobre la renovación y cambios: solo titular vigente y responsable del Checkout original.
create function cuidared_interno.stripe_suscripcion_gestionable(p_cuenta_id bigint)
returns cuidared.stripe_suscripcion
language plpgsql set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_cuenta cuidared.cuenta%rowtype;
  v_s cuidared.stripe_suscripcion%rowtype;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'cuenta:suscripcion');
  v_actor := (v_ctx->>'usuario_id')::uuid;
  select * into strict v_cuenta from cuidared.cuenta where cuenta_id = p_cuenta_id for update;
  if v_cuenta.usuario_titular_id <> v_actor then raise insufficient_privilege; end if;

  select s.* into v_s
    from cuidared.stripe_suscripcion s
    where s.cuenta_id = p_cuenta_id and s.gestionada and s.titular_id = v_actor
      and s.estado not in ('canceled', 'incomplete_expired')
    for update of s;
  if not found then raise no_data_found; end if;
  return v_s;
end;
$$;

create function cuidared_api.api_stripe_preparar_cancelacion(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_s cuidared.stripe_suscripcion := cuidared_interno.stripe_suscripcion_gestionable(p_cuenta_id);
begin
  if exists (select 1 from cuidared.stripe_cambio ca
    where ca.subscription_id = v_s.subscription_id and ca.estado = 'pendiente' and ca.modo = 'inmediato') then
    raise exception 'CR_STRIPE_CAMBIO_EN_CURSO' using errcode = 'P0001';
  end if;
  return jsonb_build_object('subscription_id', v_s.subscription_id);
end;
$$;

create function cuidared_api.api_stripe_preparar_cambio(p_cuenta_id bigint, p_oferta text) returns jsonb
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
  else
    if v_s.pendiente_price_id is not null or v_s.schedule_id is not null then
      raise exception 'CR_STRIPE_CAMBIO_EN_CURSO' using errcode = 'P0001';
    end if;
    select o.* into v_oferta
    from cuidared.stripe_oferta o join cuidared.plan p using (plan_id)
    join cuidared.cuenta c on c.cuenta_id = p_cuenta_id and c.tipo_cuenta_id = p.tipo_cuenta_id
    where o.codigo = p_oferta and o.activa and p.estado = 'activo' and not p.bo_gratuito
      and (o.cuenta_cotizada_id is null or o.cuenta_cotizada_id = p_cuenta_id);
    if not found then raise no_data_found; end if;
    if v_oferta.price_id = v_s.price_id then raise invalid_parameter_value; end if;
    select * into strict v_oferta_anterior from cuidared.stripe_oferta where price_id = v_s.price_id;
    if v_oferta.moneda <> v_oferta_anterior.moneda then raise invalid_parameter_value; end if;
    perform cuidared_interno.stripe_exigir_capacidad(p_cuenta_id, v_oferta.plan_id);
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

create function cuidared_api.api_stripe_asociar_programacion(p_cambio_id uuid, p_schedule_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_cambio_id is null or p_schedule_id is null or p_schedule_id !~ '^sub_sched_[A-Za-z0-9_]{1,230}$' then
    raise invalid_parameter_value;
  end if;
  update cuidared.stripe_cambio set schedule_id = p_schedule_id
    where cambio_id = p_cambio_id and modo = 'proximo_corte' and (schedule_id is null or schedule_id = p_schedule_id);
  if not found then raise invalid_parameter_value; end if;
end;
$$;

create function cuidared_api.api_stripe_asociar_cambio(p_cambio_id uuid, p_factura_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_cambio cuidared.stripe_cambio%rowtype;
begin
  if p_cambio_id is null or p_factura_id is null or p_factura_id !~ '^in_[A-Za-z0-9_]{1,240}$' then
    raise invalid_parameter_value;
  end if;
  select * into strict v_cambio from cuidared.stripe_cambio where cambio_id = p_cambio_id for update;
  if v_cambio.factura_id = p_factura_id then return; end if;
  if v_cambio.factura_id is not null then raise invalid_parameter_value; end if;
  update cuidared.stripe_cambio set factura_id = p_factura_id where cambio_id = p_cambio_id;
end;
$$;

create function cuidared_api.api_stripe_pagos(
  p_cuenta_id bigint, p_limite integer, p_desplazamiento bigint, p_desc boolean
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'cuenta:suscripcion');
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
      or p_desc is null then
    raise invalid_parameter_value;
  end if;
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(x.item order by
        case when p_desc then x.fecha_pago end desc, case when p_desc then x.pago_id end desc,
        x.fecha_pago, x.pago_id), '[]'::jsonb)
      from (
        select pa.pago_id, pa.fecha_pago, jsonb_build_object(
          'pago_id', pa.pago_id::text,
          'plan', p.nombre,
          'periodicidad', o.periodicidad,
          'importe_centavos', pa.stripe_importe_centavos,
          'moneda', pa.moneda::text,
          'estado', pa.estado,
          'fecha', pa.fecha_pago,
          'importe_reembolsado_centavos', pa.stripe_reembolsado_centavos
        ) as item
        from cuidared.pago pa
        join cuidared.plan p using (plan_id)
        join cuidared.stripe_oferta o on o.price_id = pa.stripe_price_id
        where pa.cuenta_id = p_cuenta_id and pa.stripe_invoice_id is not null
        order by case when p_desc then pa.fecha_pago end desc, case when p_desc then pa.pago_id end desc,
          pa.fecha_pago, pa.pago_id
        limit p_limite offset p_desplazamiento
      ) x),
    'total', (select count(*) from cuidared.pago pa
              where pa.cuenta_id = p_cuenta_id and pa.stripe_invoice_id is not null)
  );
end;
$$;

create function cuidared_api.api_stripe_preparar_checkout(p_cuenta_id bigint, p_oferta text) returns jsonb
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
        and (o.cuenta_cotizada_id is null or o.cuenta_cotizada_id = p_cuenta_id);
    if not found then raise no_data_found; end if;
    perform cuidared_interno.stripe_exigir_capacidad(p_cuenta_id, v_oferta.plan_id);
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

-- El gateway registra el identificador generado por Stripe. Una respuesta repetida conserva el mismo vínculo.
create function cuidared_api.api_stripe_asociar_checkout(p_intento_id uuid, p_session_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_intento cuidared.stripe_intento%rowtype;
begin
  if p_intento_id is null or p_session_id is null or p_session_id !~ '^cs_test_[A-Za-z0-9_]{1,240}$' then
    raise invalid_parameter_value;
  end if;
  select * into strict v_intento from cuidared.stripe_intento where intento_id = p_intento_id for update;
  if v_intento.session_id = p_session_id then return; end if;
  if v_intento.session_id is not null then raise invalid_parameter_value; end if;
  update cuidared.stripe_intento set session_id = p_session_id where intento_id = p_intento_id;
end;
$$;

-- Catálogo de capacidades de V2. Un código identifica el producto por familia o entidad, nunca un Trial.
create function cuidared_interno.stripe_catalogo_modelo() returns table (
  codigo text, nombre text, tipo text, categoria text, adultos integer, usuarios integer,
  familiares integer, funcionalidades text[]
)
language sql immutable set search_path = '' as $$
  values
    ('basico_familiar', 'Básico Familiar', 'familia', 'Básico', 2, null, 3,
      array['necesidades_diarias']),
    ('cuidado_integral', 'Cuidado Integral', 'familia', 'Premium', 6, null, null,
      array['necesidades_diarias', 'alertas_tiempo_real', 'historial_inmutable', 'dashboard_metricas']),
    ('operacion_base', 'Operación Base', 'organizacion', 'Básico', 15, 20, null,
      array['registro_visitas', 'necesidades_diarias', 'tablon_notificaciones', 'dashboard_metricas']),
    ('gestion_comunitaria_avanzada', 'Gestión Comunitaria Avanzada', 'organizacion', 'Premium', null, null, null,
      array['registro_visitas', 'necesidades_diarias', 'tablon_notificaciones', 'dashboard_metricas',
        'visitas_recurrentes', 'alertas_tiempo_real', 'riesgo_completo', 'org_necesidad', 'reportes_avanzados'])
$$;

create function cuidared_api.api_stripe_catalogo_planes() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('plan_id', p.plan_id, 'nombre', p.nombre,
    'tipo', t.codigo, 'codigo', m.codigo) order by m.codigo), '[]'::jsonb)
  from cuidared_interno.stripe_catalogo_modelo() m
  join cuidared.plan p on p.nombre = m.nombre and p.estado = 'activo' and not p.bo_gratuito
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = p.tipo_cuenta_id and t.codigo = m.tipo
$$;

-- La aplicación llama esta operación solo después de cotejar la tarifa recurrente de Sandbox con Stripe.
create function cuidared_interno.stripe_catalogo_registrar(
  p_codigo text, p_plan_id smallint, p_price_id text, p_periodicidad text, p_importe_centavos integer, p_moneda text,
  p_divisor_moneda integer, p_cuenta_cotizada_id bigint default null
) returns void
language plpgsql set search_path = '' as $$
declare
  v_oferta cuidared.stripe_oferta%rowtype;
begin
  if p_periodicidad is null or p_periodicidad not in ('mensual', 'anual')
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
          (m.tipo = 'familia' and p_cuenta_cotizada_id is null)
          or (m.tipo = 'organizacion' and exists (
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
    or v_oferta.cuenta_cotizada_id is distinct from p_cuenta_cotizada_id) then
    raise invalid_parameter_value;
  end if;
  update cuidared.stripe_oferta set activa = false
    where codigo = p_codigo and activa and price_id <> p_price_id
      and cuenta_cotizada_id is not distinct from p_cuenta_cotizada_id;
  insert into cuidared.stripe_oferta (price_id, codigo, plan_id, periodicidad, importe_centavos, moneda, divisor_moneda,
    cuenta_cotizada_id)
    values (p_price_id, p_codigo, p_plan_id, p_periodicidad, p_importe_centavos, p_moneda, p_divisor_moneda,
      p_cuenta_cotizada_id)
    on conflict (price_id) do update set activa = true;
end;
$$;

-- Alta explícita de los planes que falten. El precio/ciclo base se toma del primer Price verificado.
create function cuidared_interno.stripe_catalogo_sembrar(
  p_codigo text, p_price_id text, p_periodicidad text, p_importe_centavos integer, p_moneda text,
  p_divisor_moneda integer, p_cuenta_cotizada_id bigint default null
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
      limite_envejecientes, limite_usuarios, limite_familiares)
    select v_modelo.nombre, pc.plan_categoria_id, v_modelo.tipo_cuenta_id,
      case when v_modelo.tipo = 'familia' then p_importe_centavos::numeric / p_divisor_moneda else 0 end,
      p_periodicidad, v_modelo.adultos, v_modelo.usuarios, v_modelo.familiares
    from cuidared.plan_categoria pc where pc.nombre = v_modelo.categoria
    returning plan_id into strict v_plan_id;
    insert into cuidared.plan_funcionalidad (plan_id, funcionalidad)
    select v_plan_id, f from unnest(v_modelo.funcionalidades) f;
  end if;
  perform cuidared_interno.stripe_catalogo_registrar(p_codigo, v_plan_id, p_price_id,
    p_periodicidad, p_importe_centavos, p_moneda, p_divisor_moneda, p_cuenta_cotizada_id);
  return v_plan_id;
end;
$$;

create function cuidared_api.api_stripe_catalogo_importar(p_ofertas jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_oferta record;
begin
  if p_ofertas is null or jsonb_typeof(p_ofertas) <> 'array' then raise invalid_parameter_value; end if;
  if jsonb_array_length(p_ofertas) <> 4
    or (select count(distinct x->>'codigo') from jsonb_array_elements(p_ofertas) x) <> jsonb_array_length(p_ofertas)
    or (select count(distinct x->>'price_id') from jsonb_array_elements(p_ofertas) x) <> jsonb_array_length(p_ofertas)
    or not ((select array_agg(x->>'codigo') from jsonb_array_elements(p_ofertas) x) @>
      array['basico_familiar_mensual', 'basico_familiar_anual', 'cuidado_integral_mensual', 'cuidado_integral_anual']) then
    raise invalid_parameter_value;
  end if;
  for v_oferta in
    select * from jsonb_to_recordset(p_ofertas) as o(codigo text, price_id text, periodicidad text,
      importe_centavos integer, moneda text, divisor_moneda integer)
    order by codigo
  loop
    perform cuidared_interno.stripe_catalogo_sembrar(v_oferta.codigo, v_oferta.price_id, v_oferta.periodicidad,
      v_oferta.importe_centavos, v_oferta.moneda, v_oferta.divisor_moneda);
  end loop;
  return jsonb_array_length(p_ofertas);
end;
$$;

-- La preparación y la transferencia definitiva comparten las mismas reglas de membresía y de prueba.
create function cuidared_interno.stripe_validar_transferencia(p_cuenta_id bigint, p_membresia_id bigint)
returns uuid
language plpgsql set search_path = '' as $$
declare
  v_ctx jsonb;
  v_actor uuid;
  v_m record;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'usuarios:gestionar');
  v_actor := (v_ctx->>'usuario_id')::uuid;
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  if not exists (select 1 from cuidared.cuenta c
    where c.cuenta_id = p_cuenta_id and c.usuario_titular_id = v_actor) then raise insufficient_privilege; end if;
  select m.usuario_id, m.estado::text as estado, u.estado::text as usuario_estado
    into v_m
    from cuidared.membresia m join cuidared.usuario u using (usuario_id)
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if v_m.usuario_id = v_actor or v_m.estado <> 'activa' or v_m.usuario_estado <> 'activo' then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, v_m.usuario_id) m
    where cuidared_interno.rol_gestor(m.rol_id, m.tipo_cuenta_id)) then
    raise exception 'CR_DESTINO_NO_GESTOR' using errcode = 'P0001';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cuidared.registrar_cuenta:' || v_m.usuario_id::text, 0));
  if exists (select 1 from cuidared.cuenta c where c.cuenta_id = p_cuenta_id and c.suscripcion_estado = 'prueba'
             and cuidared_interno.acceso_operativo(c.cuenta_id))
     and exists (select 1 from cuidared.cuenta c where c.usuario_titular_id = v_m.usuario_id
                 and c.suscripcion_estado = 'prueba' and cuidared_interno.acceso_operativo(c.cuenta_id)) then
    raise exception 'CR_PRUEBA_EN_CURSO' using errcode = 'P0001';
  end if;
  return v_m.usuario_id;
end;
$$;

create function cuidared_interno.stripe_verificar_pago_en_curso(
  p_cuenta_id bigint, p_permitir_programado boolean default false
) returns void
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from cuidared.stripe_intento
    where cuenta_id = p_cuenta_id and estado = 'abierto' and (session_id is not null or vence_en > now())) then
    raise exception 'CR_STRIPE_CHECKOUT_EN_CURSO' using errcode = 'P0001';
  end if;
  if exists (select 1 from cuidared.stripe_cambio ca join cuidared.stripe_suscripcion s using (subscription_id)
    where s.cuenta_id = p_cuenta_id and s.gestionada and ca.estado = 'pendiente'
      and (not p_permitir_programado or ca.modo = 'inmediato')) then
    raise exception 'CR_STRIPE_CAMBIO_EN_CURSO' using errcode = 'P0001';
  end if;
end;
$$;

create function cuidared_api.api_stripe_preparar_transferencia(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.stripe_validar_transferencia(p_cuenta_id, p_membresia_id);
  perform cuidared_interno.stripe_verificar_pago_en_curso(p_cuenta_id, true);
  return jsonb_build_object('subscription_id', (
    select s.subscription_id
    from cuidared.stripe_suscripcion s join cuidared.cuenta c using (cuenta_id)
    where s.cuenta_id = p_cuenta_id and s.gestionada and s.titular_id = c.usuario_titular_id
      and s.estado not in ('canceled', 'incomplete_expired')
  ));
end;
$$;

-- Operación de sistema posterior a comprobar la cancelación en la API de Stripe Sandbox.
create function cuidared_api.api_stripe_confirmar_cancelacion(p_cuenta_id bigint, p_subscription_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  perform 1 from cuidared.cuenta where cuenta_id = p_cuenta_id for update;
  update cuidared.stripe_suscripcion
    set cancelacion_programada = true, actualizada_en = now(),
      snapshot_en = greatest(snapshot_en, date_trunc('second', clock_timestamp()))
    where cuenta_id = p_cuenta_id and subscription_id = p_subscription_id and gestionada;
  if not found then raise no_data_found; end if;
  update cuidared.stripe_cambio set estado = 'descartado'
    where subscription_id = p_subscription_id and modo = 'proximo_corte' and estado = 'pendiente';
end;
$$;

create function cuidared_interno.trg_stripe_validar_transferencia() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.usuario_titular_id = old.usuario_titular_id then return new; end if;
  perform cuidared_interno.stripe_verificar_pago_en_curso(old.cuenta_id);
  if exists (select 1 from cuidared.stripe_suscripcion
    where cuenta_id = old.cuenta_id and gestionada and titular_id = old.usuario_titular_id
      and estado not in ('canceled', 'incomplete_expired') and not cancelacion_programada) then
    raise exception 'CR_STRIPE_CANCELACION_REQUERIDA' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger trg_stripe_validar_transferencia before update of usuario_titular_id on cuidared.cuenta
for each row execute function cuidared_interno.trg_stripe_validar_transferencia();

create or replace function cuidared_api.api_transferir_titularidad(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_destino uuid := cuidared_interno.stripe_validar_transferencia(p_cuenta_id, p_membresia_id);
begin
  update cuidared.cuenta set usuario_titular_id = v_destino, fecha_actualizacion = now() where cuenta_id = p_cuenta_id;
  return jsonb_build_object('cuenta_id', p_cuenta_id::text, 'usuario_titular_id', v_destino,
    'membresia_id', p_membresia_id::text);
end;
$$;

create function cuidared_interno.stripe_vincular_suscripcion(
  p_intento cuidared.stripe_intento, p_suscripcion text, p_cliente text, p_estado text,
  p_cancelacion boolean, p_fecha timestamptz, p_pendiente_price_id text, p_schedule_id text
) returns cuidared.stripe_suscripcion
language plpgsql set search_path = '' as $$
declare
  v_s cuidared.stripe_suscripcion%rowtype;
  v_anterior cuidared.stripe_suscripcion%rowtype;
begin
  -- El llamante ya tiene el bloqueo de cuenta. Los dos identificadores del proveedor no se reasignan.
  insert into cuidared.stripe_cliente(cuenta_id, titular_id, customer_id)
    values (p_intento.cuenta_id, p_intento.titular_id, p_cliente) on conflict (cuenta_id, titular_id) do nothing;
  if not exists (select 1 from cuidared.stripe_cliente
    where cuenta_id = p_intento.cuenta_id and titular_id = p_intento.titular_id and customer_id = p_cliente) then
    raise invalid_parameter_value;
  end if;

  select * into v_s from cuidared.stripe_suscripcion where subscription_id = p_suscripcion for update;
  if found then
    if v_s.intento_id <> p_intento.intento_id or v_s.cuenta_id <> p_intento.cuenta_id
       or v_s.customer_id <> p_cliente then raise invalid_parameter_value; end if;
    -- El terminal gana ante dos eventos con la misma marca de tiempo.
    if v_s.snapshot_en is null or p_fecha > v_s.snapshot_en
       or (p_fecha = v_s.snapshot_en and p_estado in ('canceled', 'incomplete_expired')) then
      update cuidared.stripe_suscripcion set estado = p_estado, snapshot_en = p_fecha,
        cancelacion_programada = p_cancelacion, pendiente_price_id = p_pendiente_price_id,
        schedule_id = p_schedule_id, actualizada_en = now()
        where subscription_id = v_s.subscription_id returning * into v_s;
    end if;
    if v_s.estado in ('incomplete_expired', 'canceled') then
      update cuidared.stripe_intento set estado = 'expirado'
        where intento_id = p_intento.intento_id and estado = 'abierto';
    end if;
    return v_s;
  end if;

  select * into v_anterior from cuidared.stripe_suscripcion
    where cuenta_id = p_intento.cuenta_id and gestionada for update;
  if found then
    if (v_anterior.estado not in ('canceled', 'incomplete_expired') and
       (v_anterior.titular_id = p_intento.titular_id or not v_anterior.cancelacion_programada))
       or v_anterior.vigencia_hasta > now()
       or v_anterior.creada_en > p_intento.creado_en then
      raise invalid_parameter_value;
    end if;
    update cuidared.stripe_suscripcion set gestionada = false, actualizada_en = now()
      where subscription_id = v_anterior.subscription_id;
  end if;
  insert into cuidared.stripe_suscripcion (subscription_id, intento_id, cuenta_id, titular_id, customer_id, price_id,
    estado, cancelacion_programada, snapshot_en, pendiente_price_id, schedule_id)
  values (p_suscripcion, p_intento.intento_id, p_intento.cuenta_id, p_intento.titular_id, p_cliente, p_intento.price_id, p_estado,
    p_cancelacion, p_fecha, p_pendiente_price_id, p_schedule_id)
  returning * into v_s;
  if p_estado in ('incomplete_expired', 'canceled') then
    update cuidared.stripe_intento set estado = 'expirado'
      where intento_id = p_intento.intento_id and estado = 'abierto';
  end if;
  return v_s;
end;
$$;

-- La etiqueta identifica la pasarela en el registro. No se ofrece para asientos manuales.
insert into cuidared.metodo_pago(nombre, activo) values ('Stripe Sandbox', false) on conflict (nombre) do nothing;

-- Cambia el acceso solo si el contrato pertenece al titular actual y la ventana pagada es autoritativa.
create function cuidared_interno.stripe_aplicar_vigencia(
  p_s cuidared.stripe_suscripcion, p_oferta cuidared.stripe_oferta, p_titular_actual uuid,
  p_fin timestamptz, p_cambio_id uuid default null
) returns void
language plpgsql set search_path = '' as $$
begin
  update cuidared.stripe_intento set estado = 'completado' where intento_id = p_s.intento_id;
  if not p_s.gestionada or p_titular_actual <> p_s.titular_id then return; end if;
  if p_cambio_id is null then
    if p_oferta.price_id <> p_s.price_id or p_fin <= p_s.vigencia_hasta then return; end if;
  else
    update cuidared.stripe_cambio set estado = 'aplicado' where cambio_id = p_cambio_id and estado = 'pendiente';
    if not found then return; end if;
  end if;
  update cuidared.stripe_suscripcion set vigencia_hasta = p_fin, price_id = p_oferta.price_id, actualizada_en = now()
    where subscription_id = p_s.subscription_id;
  if p_fin > now() then
    update cuidared.cuenta set plan_id = p_oferta.plan_id,
      plan_precio = p_oferta.importe_centavos::numeric / p_oferta.divisor_moneda,
      fecha_fin_vigencia = (p_fin at time zone 'America/Santo_Domingo')::date, suscripcion_estado = 'activa',
      fecha_actualizacion = now()
      where cuenta_id = p_s.cuenta_id and suscripcion_estado <> 'suspendida';
  end if;
end;
$$;

-- Serializa por cuenta y procesa cada ID de evento junto con la factura y la vigencia en una transacción.
-- El gateway solo llama este RPC después de verificar firma, modo de prueba y objetos recuperados de Stripe.
create function cuidared_api.api_stripe_procesar_evento(
  p_evento_id text, p_tipo text, p_fecha timestamptz, p_datos jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_intento cuidared.stripe_intento%rowtype;
  v_s cuidared.stripe_suscripcion%rowtype;
  v_oferta cuidared.stripe_oferta%rowtype;
  v_pago cuidared.pago%rowtype;
  v_cambio cuidared.stripe_cambio%rowtype;
  v_reembolso cuidared.stripe_reembolso%rowtype;
  v_intento_id uuid;
  v_cuenta_id bigint;
  v_titular_actual uuid;
  v_suscripcion text := p_datos->>'suscripcion_id';
  v_cliente text := p_datos->>'cliente_id';
  v_estado text := p_datos->>'estado_proveedor';
  v_cancela boolean;
  v_sesion text := p_datos->>'session_id';
  v_factura text := p_datos->>'factura_id';
  v_cargo text := p_datos->>'cargo_id';
  v_cambio_id uuid := (p_datos->>'cambio_id')::uuid;
  v_ultima_factura text := p_datos->>'latest_invoice_id';
  v_price_actual text := p_datos->>'subscription_price_id';
  v_price_pendiente text := p_datos->>'pending_price_id';
  v_schedule_id text := p_datos->>'schedule_id';
  v_importe integer;
  v_reembolsado integer;
  v_inicio timestamptz;
  v_fin timestamptz;
  v_fecha_pago timestamptz;
  v_pagado boolean := p_tipo = 'invoice.paid';
  v_prorrateo boolean := coalesce((p_datos->>'es_prorrateo')::boolean, false);
  v_aplicar_cambio boolean := false;
  v_metodo smallint;
begin
  if p_evento_id is null or p_evento_id !~ '^evt_[A-Za-z0-9_]{1,240}$' or p_fecha is null
     or p_tipo is null or p_tipo not in ('invoice.paid', 'invoice.payment_failed', 'charge.refunded',
       'customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted',
       'customer.subscription.pending_update_applied', 'customer.subscription.pending_update_expired',
       'checkout.session.expired')
     or p_datos is null or jsonb_typeof(p_datos) <> 'object' then
    raise invalid_parameter_value;
  end if;

  if exists (select 1 from cuidared.stripe_evento where evento_id = p_evento_id) then
    return jsonb_build_object('duplicado', true);
  end if;

  v_intento_id := (p_datos->>'intento_id')::uuid;
  select cuenta_id into strict v_cuenta_id from cuidared.stripe_intento where intento_id = v_intento_id;
  perform cuidared_interno.bloquear_miembros(v_cuenta_id);
  select usuario_titular_id into strict v_titular_actual from cuidared.cuenta where cuenta_id = v_cuenta_id for update;
  select * into strict v_intento from cuidared.stripe_intento where intento_id = v_intento_id for update;

  insert into cuidared.stripe_evento (evento_id, tipo, intento_id, fecha_proveedor)
    values (p_evento_id, p_tipo, v_intento_id, p_fecha) on conflict (evento_id) do nothing;
  if not found then return jsonb_build_object('duplicado', true); end if;

  if p_tipo = 'checkout.session.expired' then
    if (v_sesion is not null and v_sesion !~ '^cs_test_[A-Za-z0-9_]{1,240}$')
       or (v_intento.session_id is not null and v_sesion is distinct from v_intento.session_id) then
      raise invalid_parameter_value;
    end if;
    update cuidared.stripe_intento set estado = 'expirado', session_id = coalesce(session_id, v_sesion)
      where intento_id = v_intento_id and estado = 'abierto';
    return jsonb_build_object('duplicado', false);
  end if;

  v_cancela := (p_datos->>'cancelacion_programada')::boolean;
  if v_suscripcion is null or v_suscripcion !~ '^sub_[A-Za-z0-9_]{1,240}$'
     or v_cliente is null or v_cliente !~ '^cus_[A-Za-z0-9_]{1,240}$'
     or v_estado is null or v_estado not in ('incomplete', 'incomplete_expired', 'trialing', 'active',
         'past_due', 'canceled', 'unpaid', 'paused')
     or v_cancela is null then
    raise invalid_parameter_value;
  end if;
  v_s := cuidared_interno.stripe_vincular_suscripcion(v_intento, v_suscripcion, v_cliente, v_estado, v_cancela, p_fecha,
    v_price_pendiente, v_schedule_id);

  if p_tipo = 'customer.subscription.pending_update_expired' then
    update cuidared.stripe_cambio set estado = 'descartado'
      where subscription_id = v_suscripcion and estado = 'pendiente' and creado_en <= p_fecha
        and (factura_id = v_ultima_factura or (factura_id is null and v_ultima_factura is not null));
    return jsonb_build_object('duplicado', false);
  end if;
  if p_tipo in ('customer.subscription.pending_update_applied', 'customer.subscription.updated') then
    select ca.* into v_cambio from cuidared.stripe_cambio ca
      join cuidared.pago pa on pa.stripe_invoice_id = ca.factura_id and pa.stripe_subscription_id = ca.subscription_id
      where ca.subscription_id = v_suscripcion and ca.price_id = v_price_actual and ca.factura_id = v_ultima_factura
        and ca.estado = 'pendiente' and pa.estado in ('completado', 'reembolsado')
      for update of ca;
    if found then
      select * into strict v_pago from cuidared.pago where stripe_invoice_id = v_ultima_factura;
      select * into strict v_oferta from cuidared.stripe_oferta where price_id = v_cambio.price_id;
      perform cuidared_interno.stripe_aplicar_vigencia(v_s, v_oferta, v_titular_actual,
        v_pago.stripe_periodo_hasta, v_cambio.cambio_id);
    end if;
    return jsonb_build_object('duplicado', false);
  end if;
  if p_tipo in ('customer.subscription.created', 'customer.subscription.deleted') then
    return jsonb_build_object('duplicado', false);
  end if;

  if v_factura is null or v_factura !~ '^in_[A-Za-z0-9_]{1,240}$'
     or (v_cargo is not null and v_cargo !~ '^ch_[A-Za-z0-9_]{1,240}$') then
    raise invalid_parameter_value;
  end if;
  select * into v_pago from cuidared.pago where stripe_invoice_id = v_factura for update;
  if found and (v_pago.stripe_subscription_id <> v_suscripcion or v_pago.cuenta_id <> v_cuenta_id
     or (v_pago.stripe_cargo_id is not null and v_cargo is not null and v_pago.stripe_cargo_id <> v_cargo)) then
    raise invalid_parameter_value;
  end if;

  if p_tipo = 'charge.refunded' then
    v_reembolsado := (p_datos->>'importe_reembolsado_centavos')::integer;
    if v_cargo is null or v_reembolsado is null or v_reembolsado not between 1 and 99999999
      or (v_pago.pago_id is not null and v_reembolsado > v_pago.stripe_importe_centavos) then
      raise invalid_parameter_value;
    end if;
    select * into v_reembolso from cuidared.stripe_reembolso where invoice_id = v_factura for update;
    if found and (v_reembolso.subscription_id <> v_suscripcion or v_reembolso.cargo_id <> v_cargo) then
      raise invalid_parameter_value;
    end if;
    insert into cuidared.stripe_reembolso (invoice_id, subscription_id, cargo_id, importe_centavos)
      values (v_factura, v_suscripcion, v_cargo, v_reembolsado)
      on conflict (invoice_id) do update
      set importe_centavos = greatest(stripe_reembolso.importe_centavos, excluded.importe_centavos)
      where stripe_reembolso.subscription_id = excluded.subscription_id
        and stripe_reembolso.cargo_id = excluded.cargo_id
      returning importe_centavos into v_reembolsado;
    if not found then raise invalid_parameter_value; end if;
    update cuidared.pago set stripe_reembolsado_centavos = v_reembolsado, stripe_cargo_id = v_cargo,
      estado = case when v_reembolsado = stripe_importe_centavos then 'reembolsado' else 'completado' end
      where pago_id = v_pago.pago_id and estado in ('completado', 'reembolsado');
    return jsonb_build_object('duplicado', false);
  end if;

  select * into strict v_oferta from cuidared.stripe_oferta where price_id = p_datos->>'price_id';
  v_inicio := (p_datos->>'periodo_inicio')::timestamptz;
  v_fin := (p_datos->>'periodo_fin')::timestamptz;
  if v_prorrateo then
    select * into v_cambio from cuidared.stripe_cambio ca
      where ca.subscription_id = v_suscripcion and ca.price_id = v_oferta.price_id and ca.modo = 'inmediato'
        and ca.titular_id = v_intento.titular_id
        and (v_cambio_id is null or ca.cambio_id = v_cambio_id)
        and (ca.factura_id = v_factura or
             (ca.factura_id is null and ca.estado = 'pendiente' and ca.creado_en <= p_fecha))
      order by (ca.factura_id is not null) desc, ca.creado_en desc
      limit 1 for update;
    if not found then raise invalid_parameter_value; end if;
    update cuidared.stripe_cambio set factura_id = v_factura
      where cambio_id = v_cambio.cambio_id and factura_id is null;
    v_aplicar_cambio := v_pagado and v_cambio.estado = 'pendiente'
      and v_price_actual is not distinct from v_cambio.price_id;
    if not v_pagado and v_cambio.estado = 'pendiente' and v_pago.pago_id is null
      and v_price_pendiente is distinct from v_cambio.price_id
      and v_price_actual is distinct from v_cambio.price_id then
      raise invalid_parameter_value;
    end if;
  else
    select * into v_cambio from cuidared.stripe_cambio ca where ca.subscription_id = v_suscripcion
      and ca.modo = 'proximo_corte' and ca.estado = 'pendiente' and ca.price_id = v_oferta.price_id
      and (ca.factura_id is null or ca.factura_id = v_factura) and v_inicio >= ca.efectivo_en
      for update;
    if found then
      update cuidared.stripe_cambio set factura_id = v_factura
        where cambio_id = v_cambio.cambio_id and factura_id is null;
      v_aplicar_cambio := v_pagado and v_price_actual is not distinct from v_cambio.price_id;
    elsif v_oferta.price_id not in (v_s.price_id, v_intento.price_id)
      and not exists (select 1 from cuidared.stripe_cambio ca
        where ca.subscription_id = v_suscripcion and ca.price_id = v_oferta.price_id and ca.estado = 'aplicado') then
      raise invalid_parameter_value;
    end if;
  end if;

  v_importe := (p_datos->>'importe_centavos')::integer;
  v_fecha_pago := (p_datos->>'fecha_pago')::timestamptz;
  if v_importe is null or v_importe not between 1 and 99999999
     or (not v_prorrateo and v_importe <> v_oferta.importe_centavos)
     or p_datos->>'moneda' is distinct from v_oferta.moneda or v_inicio is null or v_fin is null
     or v_inicio >= v_fin or v_fecha_pago is null then raise invalid_parameter_value; end if;
  if v_pago.pago_id is not null and (v_pago.stripe_periodo_desde <> v_inicio or v_pago.stripe_periodo_hasta <> v_fin
      or v_pago.stripe_importe_centavos <> v_importe or v_pago.stripe_price_id <> v_oferta.price_id) then
    raise invalid_parameter_value;
  end if;
  if v_pago.estado in ('completado', 'reembolsado') then
    if v_aplicar_cambio then
      perform cuidared_interno.stripe_aplicar_vigencia(v_s, v_oferta, v_titular_actual, v_fin, v_cambio.cambio_id);
    end if;
    return jsonb_build_object('duplicado', false);
  end if;

  select * into v_reembolso from cuidared.stripe_reembolso where invoice_id = v_factura;
  if found and (v_reembolso.subscription_id <> v_suscripcion
     or (v_cargo is not null and v_reembolso.cargo_id <> v_cargo)
     or v_reembolso.importe_centavos > v_importe) then raise invalid_parameter_value; end if;
  v_reembolsado := case when v_pagado then coalesce(v_reembolso.importe_centavos, 0) else 0 end;
  select metodo_pago_id into strict v_metodo from cuidared.metodo_pago where nombre = 'Stripe Sandbox';

  insert into cuidared.pago (cuenta_id, plan_id, usuario_id, metodo_pago_id, monto, moneda, estado,
    referencia_pasarela, fecha_pago, stripe_invoice_id, stripe_subscription_id, stripe_price_id,
    stripe_periodo_desde, stripe_periodo_hasta, stripe_cargo_id, stripe_importe_centavos, stripe_reembolsado_centavos)
  values (v_cuenta_id, v_oferta.plan_id, v_intento.titular_id, v_metodo,
    v_importe::numeric / v_oferta.divisor_moneda, v_oferta.moneda,
    case when not v_pagado then 'fallido' when v_importe = v_reembolsado then 'reembolsado' else 'completado' end,
    v_factura, v_fecha_pago, v_factura, v_suscripcion, v_oferta.price_id, v_inicio, v_fin,
    coalesce(v_cargo, v_reembolso.cargo_id), v_importe, v_reembolsado)
  on conflict (stripe_invoice_id) where stripe_invoice_id is not null do update
  set estado = excluded.estado, fecha_pago = excluded.fecha_pago,
      stripe_cargo_id = coalesce(excluded.stripe_cargo_id, pago.stripe_cargo_id),
      stripe_reembolsado_centavos = excluded.stripe_reembolsado_centavos
  where pago.cuenta_id = excluded.cuenta_id and pago.stripe_subscription_id = excluded.stripe_subscription_id
    and pago.estado = 'fallido';
  if not found then raise invalid_parameter_value; end if;

  if v_aplicar_cambio then
    perform cuidared_interno.stripe_aplicar_vigencia(v_s, v_oferta, v_titular_actual, v_fin, v_cambio.cambio_id);
  elsif v_pagado and not v_prorrateo then
    -- Una renovación rezagada queda en historial sin cambiar el precio actual ni acortar la vigencia.
    perform cuidared_interno.stripe_aplicar_vigencia(v_s, v_oferta, v_titular_actual, v_fin);
  end if;

  return jsonb_build_object('duplicado', false);
end;
$$;

revoke all on function cuidared_api.api_stripe_gestion(bigint),
  cuidared_api.api_stripe_pagos(bigint, integer, bigint, boolean), cuidared_api.api_stripe_preparar_checkout(bigint, text),
  cuidared_api.api_stripe_asociar_checkout(uuid, text) from public, anon, authenticated, service_role;

grant execute on function cuidared_api.api_stripe_gestion(bigint),
  cuidared_api.api_stripe_pagos(bigint, integer, bigint, boolean), cuidared_api.api_stripe_preparar_checkout(bigint, text)
  to authenticated;

grant execute on function cuidared_api.api_stripe_asociar_checkout(uuid, text) to service_role;

revoke all on function cuidared_interno.stripe_suscripcion_gestionable(bigint),
  cuidared_interno.stripe_exigir_capacidad(bigint, smallint),
  cuidared_api.api_stripe_preparar_cancelacion(bigint), cuidared_api.api_stripe_preparar_cambio(bigint, text),
  cuidared_api.api_stripe_asociar_cambio(uuid, text), cuidared_api.api_stripe_asociar_programacion(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function cuidared_api.api_stripe_preparar_cancelacion(bigint),
  cuidared_api.api_stripe_preparar_cambio(bigint, text) to authenticated;
grant execute on function cuidared_api.api_stripe_asociar_cambio(uuid, text),
  cuidared_api.api_stripe_asociar_programacion(uuid, text) to service_role;

revoke all on function cuidared_interno.stripe_validar_transferencia(bigint, bigint),
  cuidared_interno.stripe_verificar_pago_en_curso(bigint, boolean), cuidared_interno.trg_stripe_validar_transferencia(),
  cuidared_api.api_stripe_preparar_transferencia(bigint, bigint),
  cuidared_api.api_stripe_confirmar_cancelacion(bigint, text) from public, anon, authenticated, service_role;
grant execute on function cuidared_api.api_stripe_preparar_transferencia(bigint, bigint) to authenticated;
grant execute on function cuidared_api.api_stripe_confirmar_cancelacion(bigint, text) to service_role;

revoke all on function cuidared_interno.stripe_catalogo_modelo(),
  cuidared_api.api_stripe_catalogo_planes(), cuidared_api.api_stripe_catalogo_importar(jsonb),
  cuidared_interno.stripe_catalogo_registrar(text, smallint, text, text, integer, text, integer, bigint),
  cuidared_interno.stripe_catalogo_sembrar(text, text, text, integer, text, integer, bigint)
  from public, anon, authenticated, service_role;
grant execute on function cuidared_api.api_stripe_catalogo_planes(), cuidared_api.api_stripe_catalogo_importar(jsonb)
  to service_role;

revoke all on function cuidared_interno.stripe_vincular_suscripcion(
    cuidared.stripe_intento, text, text, text, boolean, timestamptz, text, text),
  cuidared_interno.stripe_aplicar_vigencia(cuidared.stripe_suscripcion, cuidared.stripe_oferta, uuid, timestamptz, uuid),
  cuidared_api.api_stripe_procesar_evento(text, text, timestamptz, jsonb) from public, anon, authenticated, service_role;
grant execute on function cuidared_api.api_stripe_procesar_evento(text, text, timestamptz, jsonb) to service_role;

commit;
