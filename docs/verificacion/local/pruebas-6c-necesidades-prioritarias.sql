-- Regresión de alertas por necesidad pendiente. Ejecutar en la base local desechable.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('prioridad-admin@example.test','00100007621');
  v_coordinador uuid := pruebas.usuario('prioridad-coord@example.test','00100007622');
  v_ajeno uuid := pruebas.usuario('prioridad-otra-cuenta@example.test','00100007623');
  v_cuenta bigint := pruebas.cuenta('organizacion',v_admin);
  v_adulto uuid := pruebas.envejeciente(v_cuenta,'Adulto','Necesidades');
  v_alta smallint := (select prioridad_id from cuidared.prioridad where codigo = 'alta');
  v_media smallint := (select prioridad_id from cuidared.prioridad where codigo = 'media');
  v_baja smallint := (select prioridad_id from cuidared.prioridad where codigo = 'baja');
  v_transporte smallint := (select n.necesidad_id from cuidared.necesidad n
    join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'transporte' limit 1);
  v_farmaco smallint := (select n.necesidad_id from cuidared.necesidad n
    join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'medicamentos' limit 1);
  v_transporte_alta uuid;
  v_transporte_media uuid;
  v_transporte_baja uuid;
  v_medicamento uuid;
  v_alerta uuid;
  v_datos jsonb := jsonb_build_object('necesidad_id',v_transporte,'descripcion','Traslado de prueba');
  v_respuesta jsonb;
begin
  perform pruebas.miembro(v_cuenta,v_coordinador,'coordinador');
  perform pruebas.cuenta('organizacion',v_ajeno);
  perform pruebas.como(v_admin);

  v_respuesta := cuidared_api.api_necesidad_crear(v_cuenta,v_adulto,v_datos || jsonb_build_object('prioridad_id',v_alta));
  v_transporte_alta := (v_respuesta->>'envejeciente_necesidad_id')::uuid;
  v_respuesta := cuidared_api.api_necesidad_crear(v_cuenta,v_adulto,v_datos || jsonb_build_object('prioridad_id',v_media));
  v_transporte_media := (v_respuesta->>'envejeciente_necesidad_id')::uuid;
  v_respuesta := cuidared_api.api_necesidad_crear(v_cuenta,v_adulto,v_datos || jsonb_build_object('prioridad_id',v_baja));
  v_transporte_baja := (v_respuesta->>'envejeciente_necesidad_id')::uuid;

  select a.alerta_envejeciente_id into strict v_alerta
    from cuidared.alerta_envejeciente a join cuidared.tipo_alerta t using (tipo_alerta_id)
    join cuidared.prioridad p using (prioridad_id)
    where a.fuente_necesidad_id = v_transporte_alta and a.estado = 'pendiente'
      and t.codigo = 'necesidad_prioritaria' and p.codigo = 'alta';
  perform pruebas.afirmar(not exists (select from cuidared.alerta_envejeciente a
    where a.fuente_necesidad_id in (v_transporte_media,v_transporte_baja)),'transporte de prioridad media o baja sin alerta');
  perform pruebas.afirmar((select count(*) = 2 and bool_and(usuario_id in (v_admin,v_coordinador))
    from cuidared.notificacion where alerta_envejeciente_id = v_alerta and cuenta_id = v_cuenta),
    'solo los dos gestores activos de la organización reciben el aviso');
  perform pruebas.afirmar(not exists (select from cuidared.notificacion
    where alerta_envejeciente_id = v_alerta and usuario_id = v_ajeno),'un gestor de otra cuenta no recibe el aviso');

  perform pruebas.como(v_coordinador);
  v_respuesta := cuidared_api.api_casos_prioritarios_listar(v_cuenta,'{}',array['-fecha_alerta'],20,0);
  perform pruebas.afirmar(v_respuesta#>>'{items,0,alertas,0,fuente,referencia_id}' = v_transporte_alta::text
    and v_respuesta#>>'{items,0,alertas,0,es_prioritaria}' = 'true','el coordinador ve la fuente agrupada en el caso');
  v_respuesta := cuidared_api.api_alertas_listar(v_cuenta,'{"tipo":"necesidad_prioritaria"}',array['-fecha_alerta'],20,0);
  perform pruebas.afirmar(v_respuesta->>'total' = '1' and v_respuesta#>>'{items,0,alerta_envejeciente_id}' = v_alerta::text,
    'el nuevo tipo es consultable desde el listado');

  perform pruebas.como(v_admin);
  v_respuesta := cuidared_api.api_necesidad_crear(v_cuenta,v_adulto,jsonb_build_object(
    'necesidad_id',v_farmaco,'prioridad_id',v_alta,'descripcion','Medicamento de prueba'));
  v_medicamento := (v_respuesta->>'envejeciente_necesidad_id')::uuid;
  perform pruebas.afirmar((select count(*) = 1 and bool_and(t.codigo = 'medicamento_pendiente')
    from cuidared.alerta_envejeciente a join cuidared.tipo_alerta t using (tipo_alerta_id)
    where a.fuente_necesidad_id = v_medicamento),'medicamento de prioridad alta origina solo su alerta habitual');

  perform cuidared_api.api_necesidad_actualizar(v_cuenta,v_transporte_media,jsonb_build_object('prioridad_id',v_alta));
  perform pruebas.afirmar((select count(*) = 1 from cuidared.alerta_envejeciente
    where fuente_necesidad_id = v_transporte_media and estado = 'pendiente'),'elevar a alta genera la alerta');
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,cuidared_interno.hoy()) = 0,
    'la reconciliación no duplica alertas existentes');

  perform cuidared_api.api_necesidad_actualizar(v_cuenta,v_transporte_alta,jsonb_build_object('prioridad_id',v_media));
  perform pruebas.afirmar((select estado = 'resuelta' and cierre_automatico from cuidared.alerta_envejeciente
    where alerta_envejeciente_id = v_alerta),'la prioridad más baja cierra la alerta');
  perform cuidared_api.api_necesidad_actualizar(v_cuenta,v_transporte_alta,jsonb_build_object('prioridad_id',v_alta));
  perform pruebas.afirmar((select count(*) = 1 and bool_and(estado = 'resuelta')
    from cuidared.alerta_envejeciente where fuente_necesidad_id = v_transporte_alta),
    'una ocurrencia ya atendida no reabre ni duplica su alerta');

  perform cuidared_api.api_necesidad_estado(v_cuenta,v_transporte_media,'{"estado":"en_proceso"}');
  perform pruebas.afirmar((select estado = 'resuelta' and cierre_automatico from cuidared.alerta_envejeciente
    where fuente_necesidad_id = v_transporte_media),'la alerta termina al dejar de estar pendiente');
end;
$$;

rollback;
