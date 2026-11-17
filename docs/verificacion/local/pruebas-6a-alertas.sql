-- Pruebas de consulta RF-04/RF-18. Ejecutar solo en una base desechable con fase 6a y ayudas cargadas.
begin;

do $$
declare
  v_gestor uuid := pruebas.usuario('alertas-gestor@example.test', '00100007601');
  v_otro uuid := pruebas.usuario('alertas-otro@example.test', '00100007602');
  v_voluntario uuid := pruebas.usuario('alertas-voluntario@example.test', '00100007603');
  v_cuidador uuid := pruebas.usuario('alertas-cuidador@example.test', '00100007604');
  v_cuenta bigint := pruebas.cuenta('organizacion', v_gestor);
  v_otra bigint := pruebas.cuenta('organizacion', v_otro);
  v_adulto uuid := pruebas.envejeciente(v_cuenta, 'Adulto', 'Propio');
  v_adulto_ajeno uuid := pruebas.envejeciente(v_otra, 'Adulto', 'Ajeno');
  v_riesgo bigint;
  v_alerta uuid;
  v_aviso uuid;
  v_orden text[] := array['-fecha_alerta','alerta_envejeciente_id'];
  v_lectura text;
  v_tipo smallint;
  v_prioridad smallint;
  v_pagina jsonb;
begin
  perform pruebas.miembro(v_cuenta, v_voluntario, 'voluntario');
  perform pruebas.miembro(v_cuenta, v_cuidador, 'cuidador');
  insert into cuidared.prioridad(nombre,orden) values ('Alta', 1) on conflict do nothing;
  select prioridad_id into v_prioridad from cuidared.prioridad where nombre = 'Alta';
  insert into cuidared.tipo_alerta(codigo,nombre) values ('riesgo_alto','Riesgo alto')
    on conflict(codigo) do update set codigo = excluded.codigo returning tipo_alerta_id into v_tipo;
  insert into cuidared.envejeciente_riesgo(envejeciente_id,riesgo_id,nivel_riesgo_id,motivo)
    select v_adulto, r.riesgo_id, n.nivel_riesgo_id, 'Prueba'
    from cuidared.riesgo r cross join cuidared.nivel_riesgo n
    where r.codigo='riesgo_caida' and n.codigo='alto' returning envejeciente_riesgo_id into v_riesgo;
  -- Si el motor 6b ya generó el caso al crear el riesgo, reutilizarlo.
  select a.alerta_envejeciente_id into v_alerta from cuidared.alerta_envejeciente a where a.fuente_riesgo_id = v_riesgo;
  if not found then
    insert into cuidared.alerta_envejeciente(envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,fuente_riesgo_id)
      values(v_adulto,v_tipo,v_prioridad,'Riesgo de prueba',v_riesgo) returning alerta_envejeciente_id into v_alerta;
  end if;
  select n.notificacion_id into v_aviso from cuidared.notificacion n
    where n.alerta_envejeciente_id = v_alerta and n.usuario_id = v_gestor;
  if not found then
    insert into cuidared.notificacion(usuario_id,cuenta_id,alerta_envejeciente_id,mensaje)
      values(v_gestor,v_cuenta,v_alerta,'Alerta pendiente') returning notificacion_id into v_aviso;
  end if;

  perform pruebas.como(v_gestor);
  perform pruebas.afirmar((cuidared_api.api_alerta_obtener(v_cuenta,v_alerta)->'fuente'->>'referencia_id') = v_riesgo::text,'fuente de riesgo exacta con bigint como texto');
  v_pagina := cuidared_api.api_alertas_listar(v_cuenta,jsonb_build_object('estado','pendiente'),v_orden,1,0);
  perform pruebas.afirmar((v_pagina->>'total')::int = 1 and jsonb_array_length(v_pagina->'items') = 1,'página acotada a la cuenta');
  perform pruebas.afirmar((cuidared_api.api_alertas_listar(v_cuenta,'{}',v_orden,1,1)->>'total')::int = 1,'página vacía conserva total');
  perform pruebas.afirmar((cuidared_api.api_casos_prioritarios_listar(v_cuenta,'{}',array['-fecha_alerta','envejeciente_id'],20,0)->>'total')::int = 1,'caso prioritario agrupado');
  perform pruebas.afirmar((cuidared_api.api_notificaciones_alerta_listar(v_cuenta,'{}',array['-fecha_notificacion'],20,0)->>'total')::int = 1,'bandeja personal');
  v_lectura := cuidared_api.api_notificacion_alerta_leer(v_cuenta,v_aviso)->>'fecha_lectura';
  perform pruebas.afirmar(v_lectura is not null and v_lectura = (cuidared_api.api_notificacion_alerta_leer(v_cuenta,v_aviso)->>'fecha_lectura'),'lectura idempotente');
  perform pruebas.error(format('select cuidared_api.api_alertas_listar(%s,%L,array[%L],20,0)',v_cuenta,'{}','desconocido'),'22023');

  perform pruebas.como(v_cuidador);
  perform pruebas.afirmar((cuidared_api.api_alertas_listar(v_cuenta,'{}',v_orden,20,0)->>'total')::int = 0,'cuidador sin asignación no ve la alerta');
  perform pruebas.error(format('select cuidared_api.api_notificacion_alerta_leer(%s,%L)',v_cuenta,v_aviso),'P0002');
  perform pruebas.como(v_otro);
  perform pruebas.error(format('select cuidared_api.api_alerta_obtener(%s,%L)',v_otra,v_alerta),'P0002');
  perform pruebas.afirmar((cuidared_api.api_alertas_listar(v_otra,'{}',v_orden,20,0)->>'total')::int = 0,'otra cuenta no ve la alerta');
  perform pruebas.como(v_voluntario);
  perform pruebas.error(format('select cuidared_api.api_alerta_obtener(%s,%L)',v_cuenta,v_alerta),'42501');

  perform pruebas.afirmar(not has_table_privilege('authenticated','cuidared.alerta_envejeciente','SELECT')
    and not has_function_privilege('anon','cuidared_api.api_alerta_obtener(bigint,uuid)','EXECUTE'),'sin privilegios directos ni RPC anónima');
end $$;

rollback;
