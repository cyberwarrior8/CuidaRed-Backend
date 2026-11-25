-- CUIDARED-014 · Retiro del plan gratuito de Backoffice. Requiere aprobación antes de aplicar.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

lock table cuidared.cuenta, cuidared.plan in share row exclusive mode;

-- Si una cuenta combina la asignación antigua y un pago vigente, requiere conciliación.
do $$
begin
  if exists (
    select 1
    from cuidared.cuenta c
    join cuidared.plan p using (plan_id)
    where p.bo_gratuito and (
      exists (
        select 1 from cuidared.stripe_suscripcion s
        where s.cuenta_id = c.cuenta_id and s.gestionada and s.vigencia_hasta > now()
      )
      or exists (
        select 1 from cuidared.pago x
        where x.cuenta_id = c.cuenta_id and x.estado = 'completado'
          and x.stripe_periodo_hasta > now()
      )
    )
  ) then
    raise check_violation using message = 'Revisar vigencia pagada de una cuenta con plan gratuito';
  end if;
end $$;

with anteriores as materialized (
  select c.cuenta_id, c.plan_id, c.suscripcion_estado as estado_anterior,
    case
      when c.suscripcion_estado in ('cancelada', 'suspendida') then c.suscripcion_estado
      when c.prueba_gratuita and now() >= c.fecha_inicio_prueba and now() < c.fecha_fin_prueba then 'prueba'
      else 'vencida'
    end as estado_nuevo
  from cuidared.cuenta c join cuidared.plan p using (plan_id)
  where p.bo_gratuito
), ajustes as (
  update cuidared.cuenta c
  set plan_id = null,
      plan_precio = 0,
      fecha_fin_vigencia = null,
      suscripcion_estado = a.estado_nuevo
  from anteriores a
  where c.cuenta_id = a.cuenta_id
  returning c.cuenta_id, a.plan_id, a.estado_anterior, a.estado_nuevo
)
select cuidared_interno.bo_auditar(
  null, 'sistema', cuenta_id, 'suscripcion.retirar_plan_gratuito', 'cuenta', cuenta_id::text,
  jsonb_build_object('plan_id', plan_id, 'estado', estado_anterior),
  jsonb_build_object('plan_id', null, 'estado', estado_nuevo),
  'Retiro del plan gratuito de Backoffice'
)
from ajustes;

-- El trigger existente solo permite asignar planes activos. El catálogo también filtra por estado.
update cuidared.plan set estado = 'inactivo' where bo_gratuito and estado <> 'inactivo';
alter table cuidared.plan add constraint ck_plan_gratuito_historico
  check (not bo_gratuito or estado = 'inactivo');
revoke execute on function cuidared_api.api_bo_stripe_plan_gratuito(uuid, uuid, text, bigint, text)
  from public, anon, authenticated, service_role;

commit;
