-- Metadatos simulados de Supabase CuidaRed que no figuran en DB.sql. Solo para validación local.
-- © 2026 Equipo CuidaRed – INTEC.
alter table cuidared.envejeciente_necesidad
  alter column cantidad type numeric(10,2),
  alter column unidad_medida type varchar(30);

create function cuidared.fn_set_fecha_actualizacion() returns trigger language plpgsql as $$
begin
  new.fecha_actualizacion := now();
  return new;
end;
$$;

create trigger trg_envejeciente_necesidad_fecha_actualizacion
  before update on cuidared.envejeciente_necesidad
  for each row execute function cuidared.fn_set_fecha_actualizacion();

create view cuidared.v_necesidades_activas with (security_invoker = true) as
  select envejeciente_necesidad_id, cantidad, unidad_medida from cuidared.envejeciente_necesidad
  where estado in ('pendiente','en_proceso');

create function cuidared.fn_trg_alerta_por_necesidad() returns trigger language plpgsql as $$
begin
  return null;
end;
$$;

create trigger trg_envejeciente_necesidad_alerta
  after insert or update of estado, prioridad_id, cantidad, umbral_alerta on cuidared.envejeciente_necesidad
  for each row execute function cuidared.fn_trg_alerta_por_necesidad();
