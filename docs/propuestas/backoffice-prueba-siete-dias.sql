-- Fase 2 · Configura 168 horas para el alta de nuevas pruebas.
begin;

do $$
declare
  v_anterior integer;
  v_motivo constant text := 'Ajuste aprobado a 7 días para las pruebas nuevas de CuidaRed.';
begin
  select valor into strict v_anterior
    from cuidared.configuracion_sistema
    where clave = 'prueba_duracion_dias'
    for update;

  if v_anterior = 7 then return; end if;
  if v_anterior <> 14 then
    raise exception 'La configuración de duración cambió desde la revisión.';
  end if;

  update cuidared.configuracion_sistema
    set valor = 7, actualizado_en = now(), actualizado_por = null
    where clave = 'prueba_duracion_dias';

  perform cuidared_interno.bo_auditar(
    null, 'sistema', null, 'configuracion.actualizar', 'configuracion', 'prueba_duracion_dias',
    jsonb_build_object('valor',v_anterior), jsonb_build_object('valor',7), v_motivo
  );
end;
$$;

commit;
