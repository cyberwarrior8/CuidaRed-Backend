-- pruebas-3a-estado.sql — Cambio de estado del adulto y sus efectos en cascada (fase 3, bloque 3a, CR-172).
-- Al inactivar o registrar el fallecimiento: tareas abiertas canceladas, alertas abiertas resueltas con acción
-- automática y visitas programadas de un solo adulto canceladas. Fallecido es terminal; reactivar respeta el plan.
-- Las filas de tareas, alertas y visitas se insertan como superusuario (las construyen los bloques 4a y 6). © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('es.coord@x.test', '00100000301', 'Patricia') as coord \gset
select pruebas.usuario('es.cuid@x.test', '00100000302') as cuid \gset
select pruebas.usuario('es.fami@x.test', '00100000303') as fami \gset
select pruebas.usuario('es.otra@x.test', '00100000304') as otra \gset
select pruebas.cuenta('familia', :'coord') as cta \gset
select pruebas.miembro(:cta, :'cuid', 'cuidador');
select pruebas.miembro(:cta, :'fami', 'familiar');
select pruebas.cuenta('familia', :'otra') as cta_otra \gset
insert into cuidared.municipio values ('0102', 'Boca Chica', '01');

create function pruebas.datos(p_cedula text) returns jsonb language sql as $$
  select jsonb_build_object('nombres', 'Rosa', 'apellidos', 'Pena', 'cedula', p_cedula, 'fecha_nacimiento', '1950-03-15',
    'sexo', 'F', 'municipio_cod', '0101', 'zona', 'Centro', 'autonomia', 'parcial',
    'consentimiento', jsonb_build_object('otorgado', true, 'otorgado_por', 'adulto'),
    'contactos', jsonb_build_array(jsonb_build_object('nombres', 'Luis', 'apellidos', 'Pena', 'parentesco', 'Hijo/a',
                                                      'telefono', '8295550101', 'es_principal', true)))
$$;
create function pruebas.estado(p_cuenta bigint, p_adulto uuid, p_estado text, p_motivo text default null)
returns jsonb language sql as $$ select cuidared_api.api_estado_envejeciente(p_cuenta, p_adulto, p_estado, p_motivo) $$;

-- Con los bloques 4a y 4b cargados, las tareas completadas y las visitas exigen columnas adicionales: estos ayudantes
-- las rellenan solo si existen, para que la prueba valga con o sin ellos.
create function pruebas.completar_tarea(p_titulo text) returns void language plpgsql as $$
begin
  if cuidared_interno.env_tiene_columna('cuidared.tarea_agenda', 'completada_por') then
    execute 'update cuidared.tarea_agenda set estado = ''completada'', completada_por = (select usuario_id from cuidared.usuario limit 1),
             fecha_completada = now() where titulo = $1' using p_titulo;
  else
    update cuidared.tarea_agenda set estado = 'completada' where titulo = p_titulo;
  end if;
end $$;
create function pruebas.visita_3a(p_fecha date, p_estado text, p_cuenta bigint) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  if cuidared_interno.env_tiene_columna('cuidared.visita', 'cuenta_id') then
    execute 'insert into cuidared.visita (visita_id, fecha, estado, cuenta_id) values ($1, $2, $3, $4)'
      using v_id, p_fecha, p_estado, p_cuenta;
  else
    insert into cuidared.visita (visita_id, fecha, estado) values (v_id, p_fecha, p_estado);
  end if;
  return v_id;
end $$;

-- Dos adultos activos (el tope de la prueba de Familia) y uno de otra cuenta.
select pruebas.como(:'coord');
set local role authenticated;
select (cuidared_api.api_crear_envejeciente(:cta, pruebas.datos('00100000001'))->>'envejeciente_id')::uuid as a1 \gset
select (cuidared_api.api_crear_envejeciente(:cta, pruebas.datos('00100000002'))->>'envejeciente_id')::uuid as a2 \gset
reset role;
select pruebas.como(:'otra');
set local role authenticated;
select (cuidared_api.api_crear_envejeciente(:cta_otra, pruebas.datos('00100000003'))->>'envejeciente_id')::uuid as a_otra \gset
reset role;

-- Filas dependientes del adulto a1 (y alguna compartida con a2).
insert into cuidared.tipo_alerta (codigo, nombre) values ('sin_visita', 'Sin visita') on conflict do nothing;
insert into cuidared.cuidador (usuario_id, tipo_cuidado_id, cuenta_id)
  select :'cuid', tipo_cuidado_id, :cta from cuidared.tipo_cuidado order by tipo_cuidado_id limit 1;
select cuidador_id as cuidador from cuidared.cuidador where usuario_id = :'cuid' \gset
select prioridad_id as prioridad from cuidared.prioridad where codigo = 'alta' \gset
select tipo_alerta_id as tipo_alerta from cuidared.tipo_alerta limit 1 \gset
insert into cuidared.tarea_agenda (cuidador_id, envejeciente_id, prioridad_id, usuario_creador_id, titulo, fecha_programada, estado) values
  (:cuidador, :'a1', :prioridad, :'coord', 'Tarea pendiente', current_date + 1, 'pendiente'),
  (:cuidador, :'a1', :prioridad, :'coord', 'Tarea en progreso', current_date + 1, 'en_progreso'),
  (:cuidador, :'a1', :prioridad, :'coord', 'Tarea completada', current_date - 1, 'pendiente'),
  (:cuidador, :'a1', :prioridad, :'coord', 'Tarea ya cancelada', current_date - 1, 'cancelada'),
  (:cuidador, :'a2', :prioridad, :'coord', 'Tarea de a2', current_date + 1, 'pendiente');
select pruebas.completar_tarea('Tarea completada');
insert into cuidared.alerta_envejeciente (envejeciente_id, tipo_alerta_id, prioridad_id, descripcion, estado) values
  (:'a1', :tipo_alerta, :prioridad, 'Alerta pendiente', 'pendiente'),
  (:'a1', :tipo_alerta, :prioridad, 'Alerta en proceso', 'en_proceso'),
  (:'a1', :tipo_alerta, :prioridad, 'Alerta ya resuelta', 'resuelta'),
  (:'a2', :tipo_alerta, :prioridad, 'Alerta de a2', 'pendiente');
update cuidared.alerta_envejeciente set accion_tomada = 'Atendida por la familia', fecha_atencion = now() - interval '1 day'
  where descripcion = 'Alerta ya resuelta';
select pruebas.visita_3a(current_date + 2, 'programada', :cta) as v_sola \gset
select pruebas.visita_3a(current_date + 2, 'programada', :cta) as v_doble \gset
select pruebas.visita_3a(current_date - 3, 'completada', :cta) as v_hecha \gset
select pruebas.visita_3a(current_date, 'en_curso', :cta) as v_curso \gset
select pruebas.visita_3a(current_date + 5, 'programada', :cta) as v_a2 \gset
insert into cuidared.detalle_visita (visita_id, envejeciente_id) values
  (:'v_sola', :'a1'), (:'v_doble', :'a1'), (:'v_doble', :'a2'), (:'v_hecha', :'a1'), (:'v_curso', :'a1'), (:'v_a2', :'a2');

/* ───────────── Inactivar ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
-- El motivo es obligatorio al inactivar; estado y motivo inválidos se rechazan.
select pruebas.error(format('select pruebas.estado(%s, %L, %L)', :cta, :'a1', 'inactivo'), '22023');
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'inactivo', '   '), '22023');
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'inactivo', 'ab'), '22023');
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'inactivo', repeat('x', 201)), '22023');
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'borrado', 'motivo valido'), '22023');
select pruebas.error(format('select pruebas.estado(%s, %L, null, %L)', :cta, :'a1', 'motivo valido'), '22023');
-- Sin permiso (cuidador y familiar con alcance) no cambia nada.
reset role;
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'a1', :'cuid', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'a1', :'fami', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'familiar_responsable';
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'inactivo', 'motivo valido'), '42501');
reset role;
select pruebas.como(:'fami');
set local role authenticated;
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'inactivo', 'motivo valido'), '42501');
reset role;
select pruebas.afirmar((select estado from cuidared.envejeciente where envejeciente_id = :'a1') = 'activo', 'denegado: sigue activo');
select pruebas.afirmar((select count(*) from cuidared.tarea_agenda where envejeciente_id = :'a1' and estado in ('pendiente', 'en_progreso')) = 2, 'denegado: tareas intactas');

-- Un adulto de otra cuenta responde P0002 (no 403) y nada cambia.
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a_otra', 'inactivo', 'motivo valido'), 'P0002');
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, gen_random_uuid(), 'inactivo', 'motivo valido'), 'P0002');

-- Inactivar a1: cascada en la misma transacción.
select pruebas.estado(:cta, :'a1', 'inactivo', 'Se  mudó   de ciudad') as r \gset
select pruebas.afirmar((:'r'::jsonb->>'tareas_canceladas')::int = 2, 'cascada: 2 tareas');
select pruebas.afirmar((:'r'::jsonb->>'alertas_resueltas')::int = 2, 'cascada: 2 alertas');
select pruebas.afirmar((:'r'::jsonb->>'visitas_canceladas')::int = 1, 'cascada: 1 visita');
select pruebas.afirmar((:'r'::jsonb->>'estado') = 'inactivo' and (:'r'::jsonb->>'fecha_estado') ~ 'Z$', 'respuesta con estado y fecha UTC');
select pruebas.afirmar((:'r'::jsonb->>'motivo_estado') like 'Se mud% de ciudad', 'motivo con espacios colapsados');
reset role;
select pruebas.afirmar((select estado from cuidared.envejeciente where envejeciente_id = :'a1') = 'inactivo', 'a1 inactivo en la base');
select pruebas.afirmar((select motivo_estado is not null and fecha_estado is not null from cuidared.envejeciente where envejeciente_id = :'a1'), 'motivo y fecha del estado');
-- Tareas: abiertas → canceladas; completada y cancelada previas intactas; las de a2 intactas.
select pruebas.afirmar((select estado from cuidared.tarea_agenda where titulo = 'Tarea pendiente') = 'cancelada', 'tarea pendiente cancelada');
select pruebas.afirmar((select estado from cuidared.tarea_agenda where titulo = 'Tarea en progreso') = 'cancelada', 'tarea en progreso cancelada');
select pruebas.afirmar((select estado from cuidared.tarea_agenda where titulo = 'Tarea completada') = 'completada', 'tarea completada intacta');
select pruebas.afirmar((select estado from cuidared.tarea_agenda where titulo = 'Tarea de a2') = 'pendiente', 'tarea de otro adulto intacta');
-- Alertas: abiertas → resueltas con acción automática, autor y fecha; la ya resuelta conserva su acción.
select pruebas.afirmar((select count(*) from cuidared.alerta_envejeciente where envejeciente_id = :'a1' and estado = 'resuelta') = 3, 'alertas de a1 resueltas');
select pruebas.afirmar((select accion_tomada from cuidared.alerta_envejeciente where descripcion = 'Alerta pendiente') like 'Cerrada autom%ticamente: el adulto pas% a inactivo. Motivo: Se mud% de ciudad',
  'acción automática con estado y motivo');
select pruebas.afirmar((select usuario_atendio_id = :'coord'::uuid and fecha_atencion is not null from cuidared.alerta_envejeciente where descripcion = 'Alerta en proceso'),
  'alerta atendida por quien cambió el estado');
select pruebas.afirmar((select accion_tomada from cuidared.alerta_envejeciente where descripcion = 'Alerta ya resuelta') = 'Atendida por la familia', 'alerta previa intacta');
select pruebas.afirmar((select estado from cuidared.alerta_envejeciente where descripcion = 'Alerta de a2') = 'pendiente', 'alerta de otro adulto intacta');
-- Visitas: solo la programada de un único adulto se cancela.
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v_sola') = 'cancelada', 'visita de un solo adulto cancelada');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v_doble') = 'programada', 'visita de varios adultos conservada');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v_hecha') = 'completada', 'visita completada intacta');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v_curso') = 'en_curso', 'visita en curso intacta');
select pruebas.afirmar((select estado from cuidared.visita where visita_id = :'v_a2') = 'programada', 'visita de otro adulto intacta');
-- Si los bloques 4a y 4b están cargados, la cancelación deja motivo y autor (4a los exige en visitas canceladas).
do $$
declare v_malas integer;
begin
  if cuidared_interno.env_tiene_columna('cuidared.visita', 'motivo_cancelacion') then
    execute $q$select count(*) from cuidared.visita
               where estado = 'cancelada' and (motivo_cancelacion is null or cancelada_por is null)$q$ into v_malas;
    if v_malas > 0 then raise exception 'FALLA: visita cancelada sin motivo ni autor'; end if;
  end if;
  if cuidared_interno.env_tiene_columna('cuidared.tarea_agenda', 'motivo_cancelacion') then
    execute $q$select count(*) from cuidared.tarea_agenda
               where titulo in ('Tarea pendiente', 'Tarea en progreso') and (motivo_cancelacion is null or cancelada_por is null)$q$ into v_malas;
    if v_malas > 0 then raise exception 'FALLA: tarea cancelada sin motivo ni autor'; end if;
  end if;
end $$;
-- Se conservan vínculos y contactos (historial).
select pruebas.afirmar((select count(*) from cuidared.vinculo where envejeciente_id = :'a1') = 2, 'vínculos conservados');
select pruebas.afirmar((select count(*) from cuidared.contacto_emergencia where envejeciente_id = :'a1') = 1, 'contactos conservados');

/* ───────────── Transiciones ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
-- Mismo estado: inválido.
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a1', 'inactivo', 'otra vez'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select pruebas.estado(%s, %L, %L)', :cta, :'a2', 'activo'), 'P0001', 'CR_ESTADO_INVALIDO');
-- El adulto inactivo no aparece en el filtro activo y sí en el inactivo.
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta, 'activo')->>'total')::int = 1, 'listado activo');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta, 'inactivo')->>'total')::int = 1, 'listado inactivo');
-- Reactivar a1 con a2 activo y el tope en 2: cabe (1 activo + 1). Con un tercero activo no cabe.
select pruebas.afirmar((pruebas.estado(:cta, :'a1', 'activo', 'Regresó')->>'estado') = 'activo', 'reactivar con cupo');
reset role;
select pruebas.afirmar((select count(*) from cuidared.tarea_agenda where envejeciente_id = :'a1' and estado = 'cancelada') = 3,
  'reactivar no restaura lo cancelado');
select pruebas.afirmar((select count(*) from cuidared.alerta_envejeciente where envejeciente_id = :'a1' and estado = 'resuelta') = 3,
  'reactivar no reabre alertas');
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.estado(:cta, :'a1', 'inactivo', 'Hospitalizada') ->> 'estado';
-- Con a1 inactivo y a2 activo hay un cupo libre; se ocupa con otro adulto y la reactivación de a1 falla por el plan.
select (cuidared_api.api_crear_envejeciente(:cta, pruebas.datos('00100000004'))->>'envejeciente_id')::uuid as a3 \gset
select pruebas.error(format('select pruebas.estado(%s, %L, %L)', :cta, :'a1', 'activo'), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta, :'a1')->>'estado') = 'inactivo', 'sigue inactivo tras CR_LIMITE_PLAN');
-- Fallecido: el motivo es opcional, cancela lo abierto y es terminal.
select pruebas.estado(:cta, :'a3', 'fallecido') as r3 \gset
select pruebas.afirmar((:'r3'::jsonb->>'estado') = 'fallecido' and (:'r3'::jsonb->>'motivo_estado') is null, 'fallecido sin motivo');
select pruebas.error(format('select pruebas.estado(%s, %L, %L)', :cta, :'a3', 'activo'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select pruebas.estado(%s, %L, %L, %L)', :cta, :'a3', 'inactivo', 'motivo valido'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select pruebas.estado(%s, %L, %L)', :cta, :'a3', 'fallecido'), 'P0001', 'CR_ESTADO_INVALIDO');
-- Inactivo → fallecido también cancela lo que aún estuviera abierto.
reset role;
insert into cuidared.tarea_agenda (cuidador_id, envejeciente_id, prioridad_id, usuario_creador_id, titulo, fecha_programada, estado)
  values (:cuidador, :'a1', :prioridad, :'coord', 'Tarea tardia', current_date + 3, 'pendiente');
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.afirmar((pruebas.estado(:cta, :'a1', 'fallecido', 'Fallecio')->>'tareas_canceladas')::int = 1, 'inactivo a fallecido cancela lo abierto');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta, :'a1')->>'motivo_estado') = 'Fallecio', 'motivo visible para quien ve lo sensible');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta, 'fallecido')->>'total')::int = 2, 'listado fallecidos');
reset role;
-- El perfil de un fallecido y sus datos se conservan.
select pruebas.afirmar((select count(*) from cuidared.envejeciente where cuenta_id = :cta) = 3, 'los perfiles se conservan');
rollback;
