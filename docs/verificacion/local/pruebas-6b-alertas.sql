-- Pruebas de RF-04/RF-05/RF-18. Solo en una base local desechable, con fase 5, 6a y 6b.
begin;

do $$
declare
  v_admin uuid := pruebas.usuario('alertas-motor-admin@example.test','00100007611');
  v_coordinador uuid := pruebas.usuario('alertas-motor-coord@example.test','00100007612');
  v_pendiente uuid := pruebas.usuario('alertas-motor-pend@example.test','00100007613');
  v_ajeno uuid := pruebas.usuario('alertas-motor-ajeno@example.test','00100007614');
  v_cuenta bigint := pruebas.cuenta('organizacion',v_admin);
  v_otra bigint := pruebas.cuenta('organizacion',v_ajeno);
  v_adulto uuid := pruebas.envejeciente(v_cuenta,'Adulto','Motor');
  v_adulto_ajeno uuid := pruebas.envejeciente(v_otra,'Adulto','Otro');
  v_fecha date := cuidared_interno.hoy();
  v_riesgo bigint;
  v_alto smallint := (select nivel_riesgo_id from cuidared.nivel_riesgo where codigo = 'alto');
  v_prioridad smallint;
  v_farmaco smallint;
  v_alimento smallint;
  v_necesidad uuid;
  v_ausencia uuid;
  v_visita uuid;
  v_visita_posterior uuid;
  v_programada uuid;
  v_tipos integer;
  v_parametro smallint;
  v_parametro_aviso smallint;
  v_alerta_inactiva uuid;
  v_aviso_inactivo uuid;
begin
  insert into cuidared.prioridad (nombre,orden) values ('Alta',1),('Media',2),('Baja',3) on conflict do nothing;
  select prioridad_id into strict v_prioridad from cuidared.prioridad where nombre='Media';
  select n.necesidad_id into strict v_farmaco from cuidared.necesidad n
    join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo='medicamentos' limit 1;
  select n.necesidad_id into strict v_alimento from cuidared.necesidad n
    join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo='alimentacion' limit 1;
  perform pruebas.miembro(v_cuenta,v_coordinador,'coordinador');
  perform pruebas.miembro(v_cuenta,v_pendiente,'coordinador','pendiente');
  perform pruebas.como(v_admin);
  insert into cuidared.envejeciente_riesgo (envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto,r.riesgo_id,v_alto,'Prueba de riesgo',v_admin from cuidared.riesgo r where r.codigo='riesgo_caida'
    returning envejeciente_riesgo_id into v_riesgo;
  insert into cuidared.envejeciente_riesgo (envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto,r.riesgo_id,v_alto,'Prueba de riesgo',v_admin from cuidared.riesgo r where r.codigo='aislamiento_social';
  insert into cuidared.envejeciente_necesidad (envejeciente_id,necesidad_id,prioridad_id,registrado_por)
    values(v_adulto,v_farmaco,v_prioridad,v_admin) returning envejeciente_necesidad_id into v_necesidad;
  insert into cuidared.envejeciente_necesidad (envejeciente_id,necesidad_id,prioridad_id,registrado_por)
    values(v_adulto,v_alimento,v_prioridad,v_admin);
  select count(*) into v_tipos from cuidared.alerta_envejeciente where envejeciente_id = v_adulto and estado = 'pendiente';
  perform pruebas.afirmar(v_tipos = 3,'dos factores de riesgo alto y un medicamento pendiente, cada uno con su alerta');
  perform pruebas.afirmar(
    (cuidared_api.api_casos_prioritarios_listar(v_cuenta,'{}',array['-fecha_alerta'],20,0)->'items'->0->>'total_alertas')::integer = 3,
    'un caso agrupa las tres alertas sin fusionarlas');
  perform pruebas.afirmar((select count(*) = 6 from cuidared.notificacion where alerta_envejeciente_id is not null and cuenta_id = v_cuenta),'un aviso por alerta a los dos gestores activos');
  perform pruebas.afirmar((select count(*) = 0 from cuidared.notificacion where usuario_id in (v_pendiente,v_ajeno)),'sin avisos a destinatarios de otra cuenta o pendientes');
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_fecha) = 0,'la revisión no repite alertas al reintentar');
  update cuidared.envejeciente_riesgo set estado = 'resuelto',fecha_resolucion=now(),resuelto_por=v_admin
    where envejeciente_riesgo_id = v_riesgo;
  perform pruebas.afirmar((select a.estado='resuelta' and a.cierre_automatico and a.usuario_atendio_id is null
    from cuidared.alerta_envejeciente a where a.fuente_riesgo_id=v_riesgo),'cierre automático al resolver el factor');
  update cuidared.envejeciente_necesidad set estado='en_proceso' where envejeciente_necesidad_id=v_necesidad;
  perform pruebas.afirmar((select a.estado='resuelta' and a.cierre_automatico from cuidared.alerta_envejeciente a
    where a.fuente_necesidad_id=v_necesidad),'solo el estado pendiente activa la alerta de medicamentos');

  update cuidared.envejeciente set fecha_creacion = (v_fecha - 15)::timestamp at time zone 'America/Santo_Domingo'
    where envejeciente_id=v_adulto;
  insert into cuidared.visita(cuenta_id,fecha,hora_programada,razon,estado,creada_por)
    values(v_cuenta,v_fecha-3,'08:00','Visita programada de prueba','programada',v_admin) returning visita_id into v_programada;
  insert into cuidared.detalle_visita(visita_id,envejeciente_id) values(v_programada,v_adulto);
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_fecha,'ausencia_visitas') = 0,'a 15 días no alerta');
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_fecha+1,'ausencia_visitas') = 1,'a 16 días alerta y una programada no reinicia');
  select a.alerta_envejeciente_id into strict v_ausencia from cuidared.alerta_envejeciente a where a.fuente_perfil_id = v_adulto;
  perform pruebas.afirmar((cuidared_api.api_alerta_en_atencion(v_cuenta,v_ausencia)->>'estado') = 'en_proceso','gestor pasa a atención');
  perform pruebas.error(format('select cuidared_api.api_alerta_resolver(%s,%L,%L)',v_cuenta,v_ausencia,''),'22023');
  perform pruebas.afirmar((cuidared_api.api_alerta_resolver(v_cuenta,v_ausencia,'Seguimiento realizado por el gestor')->>'estado') = 'resuelta','cierre con acción');
  perform pruebas.afirmar((cuidared_api.api_alerta_obtener(v_cuenta,v_ausencia)->>'atendida_por') is not null,
    'la alerta muestra el nombre del gestor que la resolvió');
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_fecha+2,'ausencia_visitas') = 0,'resuelta manualmente no reaparece en la misma ventana');
  perform pruebas.error(format('select cuidared_api.api_alerta_en_atencion(%s,%L)',v_cuenta,v_ausencia),'P0001','CR_ESTADO_INVALIDO');
  insert into cuidared.visita(cuenta_id,fecha,hora_programada,razon,estado,creada_por)
    values(v_cuenta,v_fecha,'09:00','Visita realizada de prueba','completada',v_admin) returning visita_id into v_visita;
  insert into cuidared.detalle_visita(visita_id,envejeciente_id) values(v_visita,v_adulto);
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_fecha+15,'ausencia_visitas') = 0,'la visita completada reinicia el plazo');
  perform pruebas.afirmar(cuidared_interno.alertas_reconciliar_adulto(v_adulto,v_fecha+16,'ausencia_visitas') = 1,'la otra ventana permite alerta nueva');
  perform pruebas.afirmar((select count(*) = 1 and bool_and(envejeciente_id=v_adulto) from cuidared.alerta_envejeciente
    where fuente_visita_id=v_visita),'la fuente es la última visita de este adulto');
  insert into cuidared.visita(visita_id,cuenta_id,fecha,hora_programada,hora_inicio,hora_fin,razon,estado,creada_por)
    values('ffffffff-ffff-4fff-8fff-ffffffffffff',v_cuenta,v_fecha,'15:00','15:00','16:00',
           'Segunda visita de prueba','completada',v_admin) returning visita_id into v_visita_posterior;
  insert into cuidared.detalle_visita(visita_id,envejeciente_id) values(v_visita_posterior,v_adulto);
  perform pruebas.afirmar((select visita_id = v_visita_posterior from cuidared_interno.alerta_ventana_sin_visita(v_adulto,v_cuenta,v_fecha)),
    'para una misma fecha el contacto efectivo más reciente prevalece sobre el orden del UUID');

  insert into cuidared.parametro(nombre,valor,valor_defecto,tipo_dato)
    values('dias_sin_visita_alerta','15','15','entero') on conflict (nombre) do update set valor='15'
    returning parametro_id into v_parametro;
  insert into cuidared.configuracion_cuenta(cuenta_id,parametro_id,valor) values(v_otra,v_parametro,'5');
  perform pruebas.afirmar((select umbral = 15 from cuidared_interno.alerta_ventana_sin_visita(v_adulto,v_cuenta,v_fecha)),'override ajeno no afecta el umbral');
  perform pruebas.afirmar((select umbral = 5 from cuidared_interno.alerta_ventana_sin_visita(v_adulto_ajeno,v_otra,v_fecha)),'aplica override de cuenta');
  insert into cuidared.parametro(nombre,valor,valor_defecto,tipo_dato)
    values('notificar_casos_prioritarios','true','true','booleano') on conflict (nombre) do update set valor='true'
    returning parametro_id into v_parametro_aviso;
  insert into cuidared.configuracion_cuenta(cuenta_id,parametro_id,valor) values(v_otra,v_parametro_aviso,'false');
  -- Simula un factor que ya existía cuando se habilitó el motor.
  alter table cuidared.envejeciente_riesgo disable trigger alertas_riesgo_vigente;
  insert into cuidared.envejeciente_riesgo (envejeciente_id,riesgo_id,nivel_riesgo_id,motivo,registrado_por)
    select v_adulto_ajeno,r.riesgo_id,v_alto,'Factor anterior al motor',v_ajeno
      from cuidared.riesgo r where r.codigo='riesgo_caida';
  alter table cuidared.envejeciente_riesgo enable trigger alertas_riesgo_vigente;
  update cuidared.envejeciente set fecha_creacion = (v_fecha - 6)::timestamp at time zone 'America/Santo_Domingo'
    where envejeciente_id=v_adulto_ajeno;
  perform pruebas.afirmar(cuidared_interno.alertas_evaluar_diario() = 2,'la ejecución inicial encuentra riesgo previo y ausencia');
  perform pruebas.afirmar((select count(*) = 1 from cuidared.notificacion where cuenta_id = v_otra
    and alerta_envejeciente_id is not null),'desactivar avisos prioritarios conserva la alerta y el aviso de seguimiento');
  perform pruebas.afirmar((select a.cierre_automatico from cuidared.alerta_envejeciente a where a.fuente_visita_id=v_visita),
    'el ciclo diario cierra una alerta de ausencia abierta tras registrar nuevo contacto efectivo');

  perform pruebas.error(format('insert into cuidared.alerta_envejeciente(envejeciente_id,tipo_alerta_id,prioridad_id,descripcion)
    select %L,tipo_alerta_id,%s,%L from cuidared.tipo_alerta where codigo=%L',v_adulto,v_prioridad,'Sin fuente','riesgo_alto'),'23514');
  perform pruebas.error(format('insert into cuidared.alerta_envejeciente(envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,sin_fuente_historica)
    select %L,tipo_alerta_id,%s,%L,true from cuidared.tipo_alerta where codigo=%L',v_adulto,v_prioridad,'Excepción de histórico','riesgo_alto'),'23514');
  perform pruebas.error(format('insert into cuidared.alerta_envejeciente(envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,fuente_riesgo_id)
    select %L,tipo_alerta_id,%s,%L,%s from cuidared.tipo_alerta where codigo=%L',v_adulto_ajeno,v_prioridad,'Fuente ajena',v_riesgo,'riesgo_alto'),'23514');
  perform pruebas.error(format('insert into cuidared.alerta_envejeciente(envejeciente_id,tipo_alerta_id,prioridad_id,descripcion,fuente_visita_id)
    select %L,tipo_alerta_id,%s,%L,%L from cuidared.tipo_alerta where codigo=%L',v_adulto,v_prioridad,'Visita pendiente',v_programada,'ausencia_visitas'),'23514');
  perform pruebas.error(format('update cuidared.alerta_envejeciente set fuente_visita_id = %L where fuente_visita_id = %L',
    v_visita_posterior,v_visita),'23514');

  perform pruebas.afirmar(not has_function_privilege('authenticated','cuidared_interno.alertas_evaluar_diario()','EXECUTE'),
    'el proceso diario queda fuera de clientes');
  perform pruebas.afirmar(cuidared_interno.alertas_evaluar_diario() = 0,'el proceso revisa datos existentes sin repetir las fuentes');

  perform pruebas.como(v_ajeno);
  select n.notificacion_id, n.alerta_envejeciente_id into strict v_aviso_inactivo,v_alerta_inactiva
    from cuidared.notificacion n where n.cuenta_id=v_otra and n.alerta_envejeciente_id is not null;
  perform cuidared_api.api_estado_envejeciente(v_otra,v_adulto_ajeno,'inactivo','Pausar seguimiento temporalmente');
  perform pruebas.afirmar((select count(*) = 2 from cuidared.alerta_envejeciente
    where envejeciente_id=v_adulto_ajeno and estado='resuelta' and usuario_atendio_id=v_ajeno),
    'la inactivación cierra las alertas y conserva los registros con actor');
  perform pruebas.afirmar((cuidared_api.api_alertas_listar(v_otra,'{}',array['-fecha_alerta'],20,0)->>'total')::integer = 0,
    'el expediente inactivo queda fuera de la bandeja de alertas');
  perform pruebas.afirmar((cuidared_api.api_notificaciones_alerta_listar(v_otra,'{}',array['-fecha_notificacion'],20,0)->>'total')::integer = 0,
    'los avisos del expediente inactivo quedan fuera de la bandeja');
  perform pruebas.error(format('select cuidared_api.api_alerta_obtener(%s,%L)',v_otra,v_alerta_inactiva),'P0002');
  perform pruebas.error(format('select cuidared_api.api_notificacion_alerta_leer(%s,%L)',v_otra,v_aviso_inactivo),'P0002');

  perform pruebas.como(v_admin);
  perform cuidared_api.api_retirar_consentimiento(v_cuenta,v_adulto,'Retiro de prueba');
  perform pruebas.afirmar((cuidared_api.api_alertas_listar(v_cuenta,'{}',array['-fecha_alerta'],20,0)->>'total')::integer = 0,
    'el retiro oculta alertas operativas');
  perform pruebas.afirmar((cuidared_api.api_notificaciones_alerta_listar(v_cuenta,'{}',array['-fecha_notificacion'],20,0)->>'total')::integer = 0,
    'el retiro oculta avisos');
  perform pruebas.afirmar((select count(*) > 0 from cuidared.alerta_envejeciente where envejeciente_id=v_adulto and estado='resuelta'),
    'retirar consentimiento conserva los registros resueltos');
end $$;

rollback;
