-- CUIDARED-016 · Excel y análisis avanzado para Cuidado Integral. Requiere aprobación antes de aplicar.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

create or replace function cuidared_interno.stripe_catalogo_modelo() returns table (
  codigo text, nombre text, tipo text, categoria text, adultos integer, usuarios integer,
  familiares integer, funcionalidades text[]
)
language sql immutable set search_path = '' as $$
  values
    ('basico_familiar', 'Básico Familiar', 'familia', 'Básico', 2, null, 3,
      array['necesidades_diarias']),
    ('cuidado_integral', 'Cuidado Integral', 'familia', 'Premium', 6, null, null,
      array['necesidades_diarias', 'alertas_tiempo_real', 'historial_inmutable', 'dashboard_metricas', 'reportes_avanzados']),
    ('operacion_base', 'Operación Base', 'organizacion', 'Básico', 15, 20, null,
      array['registro_visitas', 'necesidades_diarias', 'tablon_notificaciones', 'dashboard_metricas']),
    ('gestion_comunitaria_avanzada', 'Gestión Comunitaria Avanzada', 'organizacion', 'Premium', null, null, null,
      array['registro_visitas', 'necesidades_diarias', 'tablon_notificaciones', 'dashboard_metricas',
        'visitas_recurrentes', 'alertas_tiempo_real', 'riesgo_completo', 'org_necesidad', 'reportes_avanzados'])
$$;

-- Las cuentas con el plan existente reciben el beneficio sin cambiar de suscripción.
insert into cuidared.plan_funcionalidad (plan_id, funcionalidad)
select p.plan_id, 'reportes_avanzados'
from cuidared.plan p
join cuidared.tipo_cuenta t using (tipo_cuenta_id)
where t.codigo = 'familia' and p.nombre = 'Cuidado Integral' and not p.bo_gratuito
on conflict (plan_id, funcionalidad) do nothing;

commit;
