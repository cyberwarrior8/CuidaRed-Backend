-- RF-21 e integración del alta y cierre de una necesidad con el motor de alertas.
begin;

do $$
declare
  v_gestor uuid := pruebas.usuario('auditoria-56-gestor@example.test','00100007621');
  v_ajeno uuid := pruebas.usuario('auditoria-56-ajeno@example.test','00100007622');
  v_coordinador uuid := pruebas.usuario('auditoria-56-coord@example.test','00100007623');
  v_cuenta bigint := pruebas.cuenta('organizacion',v_gestor);
  v_otra bigint := pruebas.cuenta('organizacion',v_ajeno);
  v_adulto uuid := pruebas.envejeciente(v_cuenta);
  v_catalogo smallint := (select n.necesidad_id from cuidared.necesidad n
    join cuidared.tipo_necesidad t using (tipo_necesidad_id)
    where t.codigo='medicamentos' and n.activo order by n.necesidad_id limit 1);
  v_prioridad smallint := (select min(prioridad_id) from cuidared.prioridad);
  v_necesidad uuid;
  v_alerta uuid;
  v_auditoria jsonb;
begin
  perform pruebas.miembro(v_cuenta,v_coordinador,'coordinador');
  perform pruebas.como(v_gestor);
  v_necesidad := (cuidared_api.api_necesidad_crear(v_cuenta,v_adulto,jsonb_build_object(
    'necesidad_id',v_catalogo,'prioridad_id',v_prioridad,'descripcion','Descripción privada de prueba'
  ))->>'envejeciente_necesidad_id')::uuid;
  select alerta_envejeciente_id into strict v_alerta from cuidared.alerta_envejeciente
    where fuente_necesidad_id = v_necesidad;
  perform cuidared_api.api_necesidad_estado(v_cuenta,v_necesidad,
    '{"estado":"resuelta","motivo":"Motivo privado de prueba"}');
  perform pruebas.afirmar((select cierre_automatico from cuidared.alerta_envejeciente
    where alerta_envejeciente_id = v_alerta),'el cierre desde la API resuelve la alerta de su fuente');

  perform pruebas.afirmar((select count(*) = 4 and bool_and(
    usuario_id = v_gestor and datos_anteriores is null and
    datos_nuevos = jsonb_build_object('envejeciente_id',v_adulto)
  ) from cuidared.auditoria where registro_id in (v_necesidad::text,v_alerta::text)),
    'una entrada por alta y cierre en ambas tablas, solo con la referencia del expediente');

  v_auditoria := cuidared_api.api_auditoria_cuenta(v_cuenta,20,0,true);
  perform pruebas.afirmar((select count(*) = 4 and bool_and(
    e ?& array['auditoria_id','actor','accion','entidad','fecha','resultado'] and
    (select count(*) from jsonb_object_keys(e)) = 6 and
    nullif(e->>'actor','') is not null and e->>'resultado' = 'confirmado'
  ) from jsonb_array_elements(v_auditoria->'items') e
    where e->>'entidad' in ('envejeciente_necesidad','alerta_envejeciente')),
    'los eventos muestran solo los campos permitidos en la auditoría de la cuenta');

  perform pruebas.como(v_coordinador);
  perform pruebas.error(format('select cuidared_api.api_auditoria_cuenta(%s,20,0,true)',v_cuenta),'42501');
  perform pruebas.como(v_ajeno);
  perform pruebas.afirmar(not exists (
    select from jsonb_array_elements(cuidared_api.api_auditoria_cuenta(v_otra,20,0,true)->'items') e
    where e->>'entidad' in ('envejeciente_necesidad','alerta_envejeciente')
  ),'el gestor de otra cuenta no recibe los eventos');
end $$;

rollback;
