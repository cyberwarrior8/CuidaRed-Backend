-- RF-10 e integración de auditoría. Datos sintéticos en una transacción local desechable.
begin;

-- El trigger adicional bo_cupo_necesidad de Supabase usa este mismo error.
-- Se simula solo la excepción para validar su manejo, sin reemplazar el control de cupos instalado.
create function pruebas.simular_cupo_necesidad() returns trigger language plpgsql as $$
begin
  if current_setting('pruebas.cupo_necesidad', true) = 'rechazar' then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger simular_cupo_necesidad before insert on cuidared.envejeciente_necesidad
  for each row execute function pruebas.simular_cupo_necesidad();

do $$
declare
  gestor uuid := pruebas.usuario('gestor-sync-5@example.test', '00100005011');
  otro uuid := pruebas.usuario('otro-sync-5@example.test', '00100005012');
  voluntario uuid := pruebas.usuario('voluntario-sync-5@example.test', '00100005013');
  cuenta bigint := pruebas.cuenta('familia', gestor);
  organizacion bigint := pruebas.cuenta('organizacion', otro);
  adulto uuid := pruebas.envejeciente(cuenta);
  adulto_ajeno uuid := pruebas.envejeciente(organizacion);
  necesidad uuid := gen_random_uuid();
  marca timestamptz := clock_timestamp();
  base text;
  clave_rechazo uuid := gen_random_uuid();
  alta_fuera_de_cupo jsonb;
  datos jsonb;
  operacion jsonb;
  cambio jsonb;
  salida jsonb;
begin
  perform pruebas.miembro(organizacion, voluntario, 'voluntario');
  datos := jsonb_build_object(
    'envejeciente_id', adulto,
    'necesidad_id', (select n.necesidad_id from cuidared.necesidad n
      join cuidared.tipo_necesidad t using (tipo_necesidad_id) where t.codigo = 'alimentacion' and n.activo limit 1),
    'prioridad_id', (select min(prioridad_id) from cuidared.prioridad),
    'descripcion', 'Suministros básicos'
  );
  operacion := jsonb_build_object(
    'id_cliente', gen_random_uuid(), 'entidad', 'necesidad', 'tipo', 'registrar', 'registro_id', necesidad,
    'actualizado_en', cuidared_interno.sync_iso(marca), 'datos', datos
  );
  perform pruebas.como(gestor);
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta, operacion);
  perform pruebas.afirmar(salida->>'resultado' = 'aplicada', 'crea la necesidad con UUID propio de la captura');
  base := salida->>'actualizado_en_servidor';
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta, operacion);
  perform pruebas.afirmar(salida->>'resultado' = 'duplicada' and salida->>'resultado_original' = 'aplicada',
    'reintenta el alta sin repetirla');
  perform pruebas.afirmar((select count(*) = 1 from cuidared.envejeciente_necesidad n
    where n.envejeciente_necesidad_id = necesidad), 'solo existe una necesidad para esa captura');
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta, operacion ||
    jsonb_build_object('id_cliente',gen_random_uuid()));
  perform pruebas.afirmar(salida->>'resultado' = 'rechazada' and salida->>'motivo' = 'NOT_FOUND',
    'otra clave no sobrescribe el registro');
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta, operacion ||
    jsonb_build_object('id_cliente',clave_rechazo, 'registro_id',gen_random_uuid(),
      'datos',datos || jsonb_build_object('envejeciente_id',adulto_ajeno)));
  perform pruebas.afirmar(salida->>'resultado' = 'rechazada' and salida->>'actualizado_en_servidor' is null,
    'alta para adulto ajeno rechazada sin marca ni datos');
  salida := cuidared_api.api_sync_obtener_operacion(cuenta, clave_rechazo);
  perform pruebas.afirmar(salida->>'resultado' = 'rechazada' and salida->>'motivo' = 'NOT_FOUND'
    and salida->>'actualizado_en_servidor' is null, 'recupera su rechazo sin revelar versión ni datos del expediente');
  perform pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%L,%L)',
    cuenta,gen_random_uuid()),'P0002');

  alta_fuera_de_cupo := operacion ||
    jsonb_build_object('id_cliente',gen_random_uuid(),'registro_id',gen_random_uuid());
  perform set_config('pruebas.cupo_necesidad','rechazar',true);
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%L,%L,%L)',
    cuenta,adulto,datos - 'envejeciente_id'),'P0001','CR_LIMITE_PLAN');
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta,alta_fuera_de_cupo);
  perform pruebas.afirmar(salida->>'resultado' = 'rechazada' and salida->>'motivo' = 'PLAN_LIMIT_REACHED'
    and salida->>'actualizado_en_servidor' is null, 'el cupo rechaza solo esa operación de sincronización');
  perform pruebas.afirmar(not exists (select from cuidared.envejeciente_necesidad n
    where n.envejeciente_necesidad_id = (alta_fuera_de_cupo->>'registro_id')::uuid),
    'el rechazo por cupo no conserva la ocurrencia');
  perform set_config('pruebas.cupo_necesidad','aceptar',true);
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta,alta_fuera_de_cupo);
  perform pruebas.afirmar(salida->>'resultado' = 'aplicada','se puede reintentar el rechazo al recuperar cupo');

  cambio := operacion || jsonb_build_object('id_cliente', gen_random_uuid(), 'tipo', 'cambiar_estado',
    'actualizado_en', cuidared_interno.sync_iso(marca + interval '3 seconds'), 'base_actualizado_en', base,
    'datos', jsonb_build_object('estado','en_proceso'));
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta, cambio);
  perform pruebas.afirmar(salida->>'resultado' = 'aplicada', 'actualiza estado a partir de la versión capturada');
  salida := cuidared_api.api_sync_aplicar_operacion(cuenta, cambio ||
    jsonb_build_object('id_cliente',gen_random_uuid(), 'actualizado_en',cuidared_interno.sync_iso(marca),
      'base_actualizado_en',cuidared_interno.sync_iso(marca - interval '1 second'),
      'datos',jsonb_build_object('estado','resuelta','motivo','Tarea terminada')));
  perform pruebas.afirmar(salida->>'resultado' = 'conflicto' and salida->>'gana' = 'servidor',
    'una captura anterior pierde frente a la versión guardada');
  perform pruebas.como(voluntario);
  salida := cuidared_api.api_sync_aplicar_operacion(organizacion, operacion ||
    jsonb_build_object('id_cliente',gen_random_uuid(),'registro_id',gen_random_uuid(),
      'datos',datos || jsonb_build_object('envejeciente_id',adulto_ajeno)));
  perform pruebas.afirmar(salida->>'resultado' = 'rechazada' and salida->>'motivo' = 'FORBIDDEN',
    'el Voluntario puede sincronizar visitas pero no registrar necesidades');

  perform pruebas.como(gestor);
  perform pruebas.afirmar(
    exists (select from jsonb_array_elements(cuidared_api.api_auditoria_cuenta(cuenta,20,0,true)->'items') e
      where e->>'entidad' = 'envejeciente_necesidad'),
    'gestor puede consultar auditoría de necesidades de su cuenta'
  );
  perform pruebas.como(otro);
  perform pruebas.afirmar(
    not exists (select from jsonb_array_elements(cuidared_api.api_auditoria_cuenta(organizacion,20,0,true)->'items') e
      where e->>'entidad' = 'envejeciente_necesidad'),
    'la auditoría no muestra necesidades de otra cuenta'
  );

  perform pruebas.como(gestor);
  perform cuidared_api.api_retirar_consentimiento(cuenta,adulto,null);
  perform pruebas.error(format('select cuidared_api.api_sync_obtener_operacion(%L,%L)',
    cuenta,operacion->>'id_cliente'),'P0002');
end;
$$;
rollback;
