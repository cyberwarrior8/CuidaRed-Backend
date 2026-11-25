-- CUIDARED-018 · Verificar la vigencia del precio revisado al contratar o cambiar de plan.
-- Propuesta. Requiere aprobación específica antes de aplicar a Supabase.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

-- El identificador de Stripe permanece en el servidor. La versión directa es estable por Price.
create function cuidared_interno.stripe_version_oferta(p_oferta cuidared.stripe_oferta) returns uuid
language sql immutable set search_path = '' as $$
  select coalesce(p_oferta.version_cotizacion,
    overlay(overlay(left(encode(sha256(convert_to('cuidared/tarifa/' || p_oferta.price_id, 'UTF8')), 'hex'), 32)
      placing '8' from 13 for 1) placing 'a' from 17 for 1)::uuid)
$$;

create or replace function cuidared_interno.stripe_exigir_version(p_oferta cuidared.stripe_oferta, p_version uuid)
returns void language plpgsql set search_path = '' as $$
begin
  -- La versión sigue siendo obligatoria para las cotizaciones pactadas.
  -- En tarifas directas se conserva la compatibilidad con clientes que solo envían el código.
  if (p_oferta.version_cotizacion is not null or p_version is not null)
    and cuidared_interno.stripe_version_oferta(p_oferta) is distinct from p_version then
    raise exception 'CR_STRIPE_COTIZACION_ACTUALIZADA' using errcode = 'P0001';
  end if;
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
          'version', cuidared_interno.stripe_version_oferta(o),
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

revoke all on function cuidared_interno.stripe_version_oferta(cuidared.stripe_oferta)
from public, anon, authenticated, service_role;

commit;
