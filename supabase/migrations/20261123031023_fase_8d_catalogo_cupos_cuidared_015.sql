-- CUIDARED-015 · Catálogo dinámico y cupo de cuidadores. Requiere aprobación antes de aplicar.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

alter table cuidared.plan add column limite_cuidadores integer
  check (limite_cuidadores is null or limite_cuidadores > 0);

-- Provisionar el contenido del catálogo incluso en entornos sin precios de Stripe.
-- Los planes existentes conservan su configuración; los importes comerciales provienen de las ofertas.
insert into cuidared.plan_categoria (nombre)
select distinct m.categoria from cuidared_interno.stripe_catalogo_modelo() m
on conflict (nombre) do nothing;

with nuevos as (
  insert into cuidared.plan (nombre, plan_categoria_id, tipo_cuenta_id, precio, periodicidad, duracion_dias,
    limite_envejecientes, limite_usuarios, limite_familiares, limite_cuidadores)
  select m.nombre, pc.plan_categoria_id, t.tipo_cuenta_id,
    coalesce(c.importe_sugerido_centavos, 0)::numeric / 100, 'mensual', 30,
    m.adultos, m.usuarios, m.familiares, case when m.codigo = 'basico_familiar' then 5 end
  from cuidared_interno.stripe_catalogo_modelo() m
  join cuidared.plan_categoria pc on pc.nombre = m.categoria
  join cuidared.tipo_cuenta t on t.codigo = m.tipo
  left join cuidared_interno.stripe_codigos('familia') c on c.codigo = m.codigo || '_mensual'
  on conflict (nombre) do nothing
  returning plan_id, nombre
)
insert into cuidared.plan_funcionalidad (plan_id, funcionalidad)
select n.plan_id, unnest(m.funcionalidades)
from nuevos n join cuidared_interno.stripe_catalogo_modelo() m on m.nombre = n.nombre;

update cuidared.plan p set limite_cuidadores = 5
from cuidared.tipo_cuenta t
where p.tipo_cuenta_id = t.tipo_cuenta_id and t.codigo = 'familia'
  and p.nombre = 'Básico Familiar' and not p.bo_gratuito;

alter table cuidared.plan add constraint ck_plan_basico_cupo_cuidadores
  check (nombre <> 'Básico Familiar' or limite_cuidadores is not null);

create or replace function cuidared_interno.limites(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select case when c.suscripcion_estado::text = 'activa' then
      jsonb_build_object('envejecientes', p.limite_envejecientes, 'usuarios', p.limite_usuarios, 'familiares', p.limite_familiares, 'cuidadores', p.limite_cuidadores)
    else
      jsonb_build_object('envejecientes', t.prueba_limite_envejecientes, 'usuarios', t.prueba_limite_usuarios,
                         'familiares', t.prueba_limite_familiares, 'cuidadores', b.limite_cuidadores)
    end
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id
  left join cuidared.plan p on p.plan_id = c.plan_id
  left join cuidared.plan b on t.codigo = 'familia' and b.nombre = 'Básico Familiar'
    and b.tipo_cuenta_id = t.tipo_cuenta_id and b.estado = 'activo'
  where c.cuenta_id = p_cuenta_id
$$;

create or replace function cuidared_interno.uso_miembros(p_cuenta_id bigint, p_excluir_membresia_id bigint default null) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'usuarios', count(*) filter (where r.codigo::text in ('administrador','coordinador','cuidador')),
    'familiares', count(*) filter (where r.codigo::text = 'familiar'),
    'cuidadores', count(*) filter (where r.codigo::text = 'cuidador'))
  from cuidared.membresia m
  join cuidared.rol r on r.rol_id = m.rol_id
  where m.cuenta_id = p_cuenta_id and m.estado::text = 'activa'
    and m.fecha_inicio <= cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
    and m.membresia_id is distinct from p_excluir_membresia_id
$$;

create or replace function cuidared_interno.exigir_cupo_miembro(p_cuenta_id bigint, p_rol_nuevo text, p_rol_actual text default null,
                                                     p_excluir_membresia_id bigint default null) returns void
language plpgsql stable set search_path = '' as $$
declare
  v_lim jsonb := cuidared_interno.limites(p_cuenta_id);
  v_uso jsonb := cuidared_interno.uso_miembros(p_cuenta_id, p_excluir_membresia_id);
  v_cuenta_usuario_nuevo boolean := p_rol_nuevo in ('administrador','coordinador','cuidador');
  v_cuenta_usuario_actual boolean := coalesce(p_rol_actual in ('administrador','coordinador','cuidador'), false);
begin
  if v_cuenta_usuario_nuevo and not v_cuenta_usuario_actual and (v_lim->>'usuarios') is not null
     and (v_uso->>'usuarios')::integer + 1 > (v_lim->>'usuarios')::integer then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
  if p_rol_nuevo = 'familiar' and p_rol_actual is distinct from 'familiar' and (v_lim->>'familiares') is not null
     and (v_uso->>'familiares')::integer + 1 > (v_lim->>'familiares')::integer then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
  if p_rol_nuevo = 'cuidador' and p_rol_actual is distinct from 'cuidador'
     and (v_uso->>'cuidadores')::integer + 1 > (v_lim->>'cuidadores')::integer then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function cuidared_interno.stripe_exigir_capacidad(p_cuenta_id bigint, p_plan_id smallint) returns void
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
     or (v_uso->>'familiares')::bigint > v_plan.limite_familiares
     or (cuidared_interno.uso_miembros(p_cuenta_id)->>'cuidadores')::bigint > v_plan.limite_cuidadores then
    raise exception 'CR_STRIPE_SUPERA_LIMITE' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function cuidared_interno.stripe_catalogo_sembrar(
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
    p_periodicidad, p_importe_centavos, p_moneda, p_divisor_moneda, p_cuenta_cotizada_id);
  return v_plan_id;
end;
$$;

-- Lectura comercial por cuenta. Las ofertas comprables siguen en api_stripe_gestion.
create function cuidared_api.api_stripe_catalogo_cuenta(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'cuenta:suscripcion');
begin
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'codigo', m.codigo, 'nombre', p.nombre,
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

-- Conservar la lectura administrativa instalada, incluida la autorización de otros recursos.
alter function cuidared_api.api_bo_leer(uuid,uuid,text,text,jsonb) set schema cuidared_interno;
alter function cuidared_interno.api_bo_leer(uuid,uuid,text,text,jsonb) rename to bo_leer_previo_catalogo;
revoke all on function cuidared_interno.bo_leer_previo_catalogo(uuid,uuid,text,text,jsonb)
  from public, anon, authenticated, service_role;

create function cuidared_api.api_bo_leer(p_actor uuid, p_sesion uuid, p_aal text, p_recurso text, p_filtros jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_data jsonb := cuidared_interno.bo_leer_previo_catalogo(p_actor,p_sesion,p_aal,p_recurso,p_filtros);
begin
  if p_recurso is distinct from 'planes' then return v_data; end if;
  return (
    select coalesce(jsonb_agg(x.plan || jsonb_build_object(
      'limite_cuidadores', p.limite_cuidadores, 'limite_familiares', p.limite_familiares,
      'cuidadores_editable', p.nombre = 'Básico Familiar' and t.codigo = 'familia'
    ) order by x.pos), '[]'::jsonb)
    from jsonb_array_elements(v_data) with ordinality x(plan,pos)
    join cuidared.plan p on p.plan_id = (x.plan->>'plan_id')::smallint
    join cuidared.tipo_cuenta t using (tipo_cuenta_id)
  );
end $$;

create function cuidared_interno.bo_limites_catalogo(p_actor uuid, p_sesion uuid, p_aal text,
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

create or replace function cuidared_api.api_bo_mutar(p_actor uuid,p_sesion uuid,p_aal text,p_accion text,p_datos jsonb,
  p_motivo text,p_ip inet,p_agente text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_accion in ('cuenta.cambiar_plan','pago.registrar') then
    perform cuidared_interno.stripe_exigir_backoffice(p_actor,p_sesion,p_aal);
    raise exception 'CR_STRIPE_ACTIVACION_REQUERIDA' using errcode = 'P0001';
  end if;
  if p_accion = 'plan.limites' then
    return cuidared_interno.bo_limites_catalogo(p_actor,p_sesion,p_aal,p_datos,p_motivo,p_ip,p_agente);
  end if;
  return cuidared_interno.stripe_bo_mutar_previo(p_actor,p_sesion,p_aal,p_accion,p_datos,p_motivo,p_ip,p_agente);
end $$;

revoke all on function cuidared_interno.bo_limites_catalogo(uuid,uuid,text,jsonb,text,inet,text),
  cuidared_api.api_stripe_catalogo_cuenta(bigint), cuidared_api.api_bo_leer(uuid,uuid,text,text,jsonb)
from public, anon, authenticated, service_role;
grant execute on function cuidared_api.api_stripe_catalogo_cuenta(bigint) to authenticated;
grant execute on function cuidared_api.api_bo_leer(uuid,uuid,text,text,jsonb) to service_role;

commit;
