-- Datos sintéticos con el esquema anterior a 2a. Solo para la base desechable de integración.
begin;
alter table cuidared.envejeciente
  add column consentimiento_otorgado boolean,
  add column consentimiento_otorgado_por varchar,
  add column consentimiento_representante varchar,
  add column consentimiento_fecha timestamptz,
  add column consentimiento_registrado_por uuid;

do $$
declare
  titular uuid := 'a1000000-0000-4000-8000-000000000001';
  adulto uuid := 'a1000000-0000-4000-8000-000000000002';
  otro_adulto uuid := 'a1000000-0000-4000-8000-000000000003';
  visita_identificada uuid := 'a1000000-0000-4000-8000-000000000004';
  visita_ambigua uuid := 'a1000000-0000-4000-8000-000000000005';
  tarea uuid := 'a1000000-0000-4000-8000-000000000006';
  tipo smallint; categoria smallint; plan_categoria smallint; plan smallint;
  cuenta_prueba bigint; cuenta_paga bigint; cuidador bigint;
  tipo_cuidado smallint; prioridad smallint;
begin
  insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  values (titular, 'historico@integracion.test', now(),
          '{"cedula":"00100009101","nombres":"Perfil","apellidos":"Histórico"}');
  insert into cuidared.provincia values ('01','Distrito Nacional');
  insert into cuidared.municipio values ('0101','Santo Domingo de Guzmán','01');
  insert into cuidared.tipo_cuenta (nombre) values ('Familia') returning tipo_cuenta_id into tipo;
  insert into cuidared.categoria_cuenta (nombre) values ('Monitoreo a distancia') returning categoria_cuenta_id into categoria;
  insert into cuidared.plan_categoria (nombre) values ('Categoría histórica de prueba') returning plan_categoria_id into plan_categoria;
  insert into cuidared.plan (nombre, plan_categoria_id, tipo_cuenta_id)
  values ('Plan histórico de prueba', plan_categoria, tipo) returning plan_id into plan;
  insert into cuidared.cuenta (nombre, tipo_cuenta_id, categoria_cuenta_id, municipio_cod, plan_id, usuario_titular_id,
                               suscripcion_estado, prueba_gratuita, fecha_inicio_prueba, fecha_fin_prueba)
  values ('Prueba histórica', tipo, categoria, '0101', plan, titular, 'prueba', true, date '2025-01-01', date '2025-01-08')
  returning cuenta_id into cuenta_prueba;
  insert into cuidared.cuenta (nombre, tipo_cuenta_id, categoria_cuenta_id, municipio_cod, plan_id, usuario_titular_id)
  values ('Cuenta histórica', tipo, categoria, '0101', plan, titular) returning cuenta_id into cuenta_paga;

  insert into cuidared.envejeciente (envejeciente_id, cuenta_id, usuario_registrador_id, nombres, apellidos, cedula,
    fecha_nacimiento, sexo, municipio_cod, direccion, consentimiento_otorgado, consentimiento_otorgado_por,
    consentimiento_fecha, consentimiento_registrado_por)
  values (adulto, cuenta_paga, titular, 'Persona', 'Prueba', '00100009102', '1945-02-01', 'F', '0101', 'Sintética', true, 'adulto', now(), titular),
         (otro_adulto, cuenta_prueba, titular, 'Otra', 'Persona', '00100009103', '1945-02-01', 'F', '0101', 'Sintética', true, 'adulto', now(), titular);
  insert into cuidared.contacto_emergencia (envejeciente_id, nombres, apellidos, parentesco, telefono, es_principal)
  select id, 'Contacto', 'Prueba', 'Hermana', '8095550101', true from unnest(array[adulto, otro_adulto]) id;

  insert into cuidared.visita (visita_id, fecha, estado)
  values (visita_identificada, current_date, 'completada'), (visita_ambigua, current_date, 'completada');
  insert into cuidared.detalle_visita (visita_id, envejeciente_id, observacion)
  values (visita_identificada, adulto, 'Prueba de una cuenta'), (visita_ambigua, adulto, 'Prueba ambigua'),
         (visita_ambigua, otro_adulto, 'Prueba de otra cuenta');

  insert into cuidared.tipo_cuidado (nombre) values ('Cuidador remunerado') returning tipo_cuidado_id into tipo_cuidado;
  insert into cuidared.cuidador (usuario_id, tipo_cuidado_id) values (titular, tipo_cuidado) returning cuidador_id into cuidador;
  insert into cuidared.prioridad (nombre, orden) values ('Alta', 1) returning prioridad_id into prioridad;
  insert into cuidared.tarea_agenda (tarea_agenda_id, cuidador_id, envejeciente_id, prioridad_id, usuario_creador_id,
                                    titulo, fecha_programada, estado)
  values (tarea, cuidador, adulto, prioridad, titular, 'X', current_date, 'completada');
  insert into cuidared.evidencia (tarea_agenda_id, archivo_url, estado_validacion)
  values (tarea, format('cuenta/%s/tarea/%s/a1000000-0000-4000-8000-000000000007.png', cuenta_paga, tarea), 'validada');
end $$;
commit;
