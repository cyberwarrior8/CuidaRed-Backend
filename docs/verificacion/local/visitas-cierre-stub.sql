-- Dependencia de CUIDARED-008 para la base de validación local con fases 1 a 4.
alter table cuidared.envejeciente add column consentimiento_retirado_en timestamptz;

create function cuidared_interno.visita_con_expediente_retirado(p_visita uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select from cuidared.detalle_visita d join cuidared.envejeciente e using (envejeciente_id)
    where d.visita_id = p_visita and e.consentimiento_retirado_en is not null
  )
$$;
