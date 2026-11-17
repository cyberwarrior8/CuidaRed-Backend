-- Ejecutar en una base local con Backoffice, CUIDARED-009 y la propuesta de compatibilidad.
begin;

do $$
declare
  v_titular uuid := pruebas.usuario('bo-alertas@example.test','00100007701');
  v_cuenta bigint := pruebas.cuenta('familia',v_titular);
  v_adulto uuid := pruebas.envejeciente(v_cuenta,'Adulto','Seguimiento');
  v_hoy date := cuidared_interno.hoy();
  v_parametro smallint;
begin
  select parametro_id into strict v_parametro from cuidared.parametro where nombre = 'dias_sin_visita_alerta';
  insert into cuidared.configuracion_cuenta(cuenta_id,parametro_id,valor) values(v_cuenta,v_parametro,'15');
  update cuidared.envejeciente set fecha_creacion=(v_hoy - 15)::timestamp at time zone 'America/Santo_Domingo'
    where envejeciente_id = v_adulto;
  perform pruebas.afirmar(cuidared_interno.bo_alertas_seguimiento() = 0,
    'el umbral exacto no genera una alerta de ausencia');

  update cuidared.envejeciente set fecha_creacion=(v_hoy - 16)::timestamp at time zone 'America/Santo_Domingo'
    where envejeciente_id = v_adulto;
  perform pruebas.afirmar(cuidared_interno.bo_alertas_seguimiento() = 1,
    'el mantenimiento crea una alerta al exceder el umbral');
  perform pruebas.afirmar((select count(*) = 1 and bool_and(a.fuente_perfil_id = v_adulto and not a.sin_fuente_historica)
    from cuidared.alerta_envejeciente a join cuidared.tipo_alerta t using (tipo_alerta_id)
    where a.envejeciente_id = v_adulto and t.codigo = 'ausencia_visitas'),
    'la alerta generada por mantenimiento tiene la fuente obligatoria');
  perform pruebas.afirmar(cuidared_interno.alertas_evaluar_diario() = 0
    and cuidared_interno.bo_alertas_seguimiento() = 0,'los dos trabajos diarios son idempotentes');
end;
$$;

rollback;
