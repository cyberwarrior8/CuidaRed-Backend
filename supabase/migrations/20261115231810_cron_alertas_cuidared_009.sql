-- Propuesta operativa separada. Ejecutar solo tras aplicar las fases 5/6 y aprobar la programación.
-- Cron de Supabase en UTC/GMT. 04:05 UTC equivale a 00:05 en Santo Domingo.
begin;
do $$
declare
  v_zona text := current_setting('cron.timezone', true);
begin
  if to_regclass('cron.job') is null then
    raise exception 'Se requiere Supabase Cron instalado.';
  end if;
  if v_zona is null or v_zona not in ('UTC', 'Etc/UTC', 'GMT', 'Etc/GMT') then
    raise exception 'Revisar cron.timezone antes de programar el trabajo.';
  end if;
  if not has_schema_privilege(current_user, 'cuidared_interno', 'USAGE')
     or not has_function_privilege(current_user, 'cuidared_interno.alertas_evaluar_diario()', 'EXECUTE') then
    raise insufficient_privilege;
  end if;
  if not exists (select from cuidared.prioridad p where lower(p.nombre) = 'alta')
     or not exists (select from cuidared.prioridad p where lower(p.nombre) = 'media')
     or not exists (select from cuidared.tipo_necesidad t where t.codigo = 'medicamentos') then
    raise exception 'Revisar los catálogos de prioridad y medicamentos antes de activar las alertas.';
  end if;
  if exists (
    select from cron.job j where j.active and j.jobname is distinct from 'cuidared_alertas_diarias'
      and j.command ~ 'sp_generar_alertas_ausencia_visita|alertas_evaluar_diario'
  ) then
    raise exception 'Revisar el trabajo previo de alertas antes de programar otro.';
  end if;
end;
$$;
-- Evalúa las fuentes ya existentes y programa el siguiente ciclo en la misma transacción.
select cuidared_interno.alertas_evaluar_diario() as alertas_generadas_en_evaluacion_inicial;
select cron.schedule('cuidared_alertas_diarias', '5 4 * * *',
  'select cuidared_interno.alertas_evaluar_diario()');
commit;
