-- ID05/RF-03. Ejecutar solo en la base local desechable con las ayudas de pruebas.
begin;
do $$
declare
  titular uuid := pruebas.usuario('coord-f5@ejemplo.test','00100005001','Titular');
  admin uuid := pruebas.usuario('admin-f5@ejemplo.test','00100005002','Administrador');
  familiar uuid := pruebas.usuario('familiar-f5@ejemplo.test','00100005003','Familiar');
  voluntario uuid := pruebas.usuario('voluntario-f5@ejemplo.test','00100005004','Voluntario');
  cuenta bigint := pruebas.cuenta('familia', titular);
  otra bigint := pruebas.cuenta('organizacion', admin);
  adulto uuid := pruebas.envejeciente(cuenta, 'Adulto','Con permiso');
  sin_permiso uuid := pruebas.envejeciente(cuenta, 'Adulto','Sin permiso');
  ajeno uuid := pruebas.envejeciente(otra, 'Adulto','Otra cuenta');
  tipo smallint;
  catalogo smallint;
  alta smallint := (select prioridad_id from cuidared.prioridad where codigo='alta');
  media smallint := (select prioridad_id from cuidared.prioridad where codigo='media');
  uno uuid;
  dos uuid;
  privado uuid;
  resultado jsonb;
  datos jsonb;
  marca text;
begin
  perform pruebas.miembro(cuenta, familiar, 'familiar');
  perform pruebas.miembro(otra, voluntario, 'voluntario');
  insert into cuidared.tipo_necesidad(nombre,codigo) values ('Categoría sintética F5','prueba_local') returning tipo_necesidad_id into tipo;
  insert into cuidared.necesidad(nombre,tipo_necesidad_id) values ('Ítem sintético F5',tipo) returning necesidad_id into catalogo;
  perform pruebas.como(titular);
  perform cuidared_interno.seg_vincular(cuenta, adulto, familiar, 'familiar_responsable', titular);

  perform pruebas.afirmar((select count(*) = 5 from cuidared.necesidad n join cuidared.tipo_necesidad t using (tipo_necesidad_id)
    where n.activo and n.nombre = t.nombre || ' (general)'
      and t.codigo in ('medicamentos','alimentacion','transporte','compania','otros_apoyos')),'cinco opciones generales');
  datos := jsonb_build_object('necesidad_id',catalogo,'prioridad_id',media,'descripcion','Primera ocurrencia',
    'cantidad',0.004,'unidad_medida',repeat('u',64),'usuario_responsable_id',titular);
  resultado := cuidared_api.api_necesidad_crear(cuenta,adulto,datos);
  uno := (resultado->>'envejeciente_necesidad_id')::uuid;
  perform pruebas.afirmar(resultado->>'estado' = 'pendiente' and resultado->>'envejeciente_estado' = 'activo'
    and (resultado->>'registrado_por')::uuid = titular
    and (resultado->>'cantidad')::numeric = 0.004 and length(resultado->>'unidad_medida') = 64
    and resultado->>'responsable' like 'Titular%','alta con decimal sin redondeo, unidad de 64 caracteres y autoría');
  perform pruebas.afirmar((select cantidad = 0.004 and length(unidad_medida) = 64
    from cuidared.v_necesidades_activas where envejeciente_necesidad_id = uno)
    and (select reloptions = array['security_invoker=true'] and relacl is null from pg_catalog.pg_class
      where oid = 'cuidared.v_necesidades_activas'::regclass),'compatibilidad y permisos de la vista previa');
  resultado := cuidared_api.api_necesidad_crear(cuenta,adulto,datos ||
    jsonb_build_object('prioridad_id',alta,'descripcion','Una nueva ocurrencia'));
  dos := (resultado->>'envejeciente_necesidad_id')::uuid;
  perform pruebas.afirmar(uno <> dos,'a igual tipo, otra ocurrencia');
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%s,%L,%L)',
    cuenta,adulto,datos - 'unidad_medida'),'22023');
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%s,%L,%L)',
    cuenta,adulto,datos || '{"cantidad":0}'),'22023');
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%s,%L,%L)',
    cuenta,adulto,datos || jsonb_build_object('unidad_medida',repeat('u',65))),'22023');
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%s,%L,%L)',
    cuenta,adulto,datos || jsonb_build_object('usuario_responsable_id',admin)),'P0001','CR_RESPONSABLE_NECESIDAD_INVALIDO');
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%s,%L,%L)',
    cuenta,ajeno,datos),'P0002');
  resultado := cuidared_api.api_necesidad_candidatos(cuenta,adulto,'["nombre"]',20,0);
  perform pruebas.afirmar((resultado->>'total')::int = 1 and (resultado#>>'{items,0,usuario_id}')::uuid = titular,
    'candidatos con permiso y ámbito');

  insert into cuidared.envejeciente_necesidad(envejeciente_id,necesidad_id,prioridad_id,descripcion)
    values (sin_permiso,catalogo,alta,'Fuera de alcance') returning envejeciente_necesidad_id into privado;
  insert into cuidared.envejeciente_necesidad(envejeciente_id,necesidad_id,prioridad_id,descripcion,usuario_responsable_id)
    values (ajeno,catalogo,alta,'Otra cuenta',titular);

  resultado := cuidared_api.api_necesidades_listar(cuenta,'{"activas":true}','["prioridad"]',1,0);
  perform pruebas.afirmar((resultado->>'total')::bigint = 3
    and (resultado#>>'{items,0,prioridad_id}')::int = alta,'paginación y prioridad sobre la misma cuenta');
  resultado := cuidared_api.api_necesidades_listar(cuenta,
    jsonb_build_object('envejeciente_id',adulto,'tipo_necesidad_id',tipo,'prioridad_id',alta),'["-fecha_necesidad"]',20,0);
  perform pruebas.afirmar((resultado->>'total')::bigint = 1 and (resultado#>>'{items,0,envejeciente_necesidad_id}')::uuid = dos,'filtros combinados');
  resultado := cuidared_api.api_necesidades_listar(cuenta,'{}','["-fecha_necesidad"]',20,100);
  perform pruebas.afirmar(resultado->'items' = '[]'::jsonb and (resultado->>'total')::bigint = 3,'página vacía conserva total');
  resultado := cuidared_api.api_necesidad_actualizar(cuenta,uno,jsonb_build_object('prioridad_id',alta,'usuario_responsable_id',null));
  marca := resultado->>'fecha_actualizacion';
  perform pruebas.afirmar(resultado->>'responsable' is null and (resultado->>'prioridad_id')::int = alta,'prioriza y permite quitar responsable');
  resultado := cuidared_api.api_necesidad_actualizar(cuenta,uno,jsonb_build_object('prioridad_id',alta));
  perform pruebas.afirmar(resultado->>'fecha_actualizacion' = marca,'cambio de prioridad idempotente');
  resultado := cuidared_api.api_necesidad_estado(cuenta,uno,'{"estado":"en_proceso"}');
  perform pruebas.afirmar(cuidared_interno.sync_ms((resultado->>'fecha_actualizacion')::timestamptz)
    > cuidared_interno.sync_ms(marca::timestamptz),
    'dos cambios consecutivos se distinguen en milisegundos aunque sean de la misma transacción');
  perform pruebas.error(format('select cuidared_api.api_necesidad_estado(%s,%L,%L)',
    cuenta,uno,'{"estado":"resuelta"}'),'22023');
  resultado := cuidared_api.api_necesidad_estado(cuenta,uno,'{"estado":"resuelta","motivo":"Entrega registrada"}');
  perform pruebas.afirmar((resultado->>'resuelto_por')::uuid = titular and resultado->>'fecha_resolucion' is not null,'identifica cierre');
  perform pruebas.error(format('select cuidared_api.api_necesidad_estado(%s,%L,%L)',
    cuenta,uno,'{"estado":"en_proceso"}'),'P0001','CR_ESTADO_INVALIDO');
  perform pruebas.error(format('select cuidared_api.api_necesidad_actualizar(%s,%L,%L)',
    cuenta,uno,jsonb_build_object('prioridad_id',media)),'P0001','CR_ESTADO_INVALIDO');
  resultado := cuidared_api.api_necesidad_historial(cuenta,uno,'["-fecha"]',20,0);
  perform pruebas.afirmar((resultado->>'total')::bigint = 4
    and resultado#>>'{items,0,motivo}' = 'Entrega registrada'
    and resultado#>>'{items,1,estado}' = 'en_proceso' and resultado#>>'{items,2,prioridad_anterior}' = 'Media'
    and resultado#>>'{items,2,responsable_anterior}' like 'Titular%','historial ordenado con anterior y actual');
  resultado := cuidared_api.api_necesidades_listar(cuenta,'{"activas":true}','["prioridad"]',20,0);
  perform pruebas.afirmar((resultado->>'total')::bigint = 2,'activas excluye cerradas');

  perform pruebas.como(familiar);
  resultado := cuidared_api.api_necesidades_listar(cuenta,'{}','["-fecha_necesidad"]',20,0);
  perform pruebas.afirmar((resultado->>'total')::bigint = 2,'familiar limitado al expediente autorizado');
  perform pruebas.error(format('select cuidared_api.api_necesidad_obtener(%s,%L)',cuenta,privado),'P0002');
  perform pruebas.error(format('select cuidared_api.api_necesidad_crear(%s,%L,%L)',cuenta,adulto,datos),'42501');
  perform pruebas.error(format('select cuidared_api.api_necesidad_candidatos(%s,%L,%L,20,0)',cuenta,adulto,'["nombre"]'),'42501');
  perform pruebas.error(format('select cuidared_api.api_necesidades_listar(%s,%L,%L,20,0)',
    cuenta,jsonb_build_object('envejeciente_id',ajeno),'["-fecha_necesidad"]'),'P0002');
  perform pruebas.error(format('select cuidared_api.api_necesidades_listar(%s,%L,%L,20,0)',cuenta,'{}','["descripcion"]'),'22023');
  perform pruebas.como(voluntario);
  perform pruebas.error(format('select cuidared_api.api_necesidades_listar(%s,%L,%L,20,0)',otra,'{}','["prioridad"]'),'42501');

  perform pruebas.como(titular);
  perform cuidared_api.api_estado_envejeciente(cuenta,adulto,'inactivo','Pausa de seguimiento');
  resultado := cuidared_api.api_necesidad_obtener(cuenta,dos);
  perform pruebas.afirmar(resultado->>'envejeciente_estado' = 'inactivo' and resultado->>'estado' = 'pendiente',
    'se informa el estado del adulto sin modificar la necesidad pendiente');
  perform pruebas.error(format('select cuidared_api.api_necesidad_estado(%s,%L,%L)',
    cuenta,dos,'{"estado":"en_proceso"}'),'P0001','CR_ADULTO_INACTIVO');
  perform cuidared_api.api_retirar_consentimiento(cuenta,adulto,null);
  perform pruebas.error(format('select cuidared_api.api_necesidad_obtener(%s,%L)',cuenta,dos),'P0002');
  perform pruebas.error(format('select cuidared_api.api_necesidad_estado(%s,%L,%L)',cuenta,dos,'{"estado":"en_proceso"}'),'P0002');
  perform pruebas.afirmar(not has_table_privilege('authenticated','cuidared.necesidad_evento','SELECT'),
    'historial se lee por RPC');
  perform pruebas.afirmar(not has_function_privilege('anon','cuidared_api.api_necesidad_obtener(bigint,uuid)','EXECUTE'),
    'RPC no disponible para acceso anónimo');
end;
$$;
rollback;
