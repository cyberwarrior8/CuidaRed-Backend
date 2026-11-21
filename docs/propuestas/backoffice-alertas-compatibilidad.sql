-- Compatibilidad del mantenimiento de Backoffice con el motor de alertas de CUIDARED-009.
-- Requiere ambas migraciones. Aplicación en Supabase pendiente de aprobación.
begin;

create or replace function cuidared_interno.bo_alertas_seguimiento() returns integer
language plpgsql set search_path = '' as $$
declare
  v_adulto uuid;
  v_hoy date := cuidared_interno.hoy();
  v_total integer := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended('cuidared.bo.alertas_seguimiento',0));
  for v_adulto in
    select e.envejeciente_id
    from cuidared.envejeciente e
    join cuidared.cuenta c using (cuenta_id)
    join cuidared.tipo_cuenta t using (tipo_cuenta_id)
    where t.codigo = 'familia' and e.estado = 'activo'
      and e.consentimiento_retirado_en is null
      and cuidared_interno.acceso_operativo(e.cuenta_id)
    order by e.envejeciente_id
  loop
    v_total := v_total + cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_hoy,'ausencia_visitas');
  end loop;
  return v_total;
end;
$$;

commit;
