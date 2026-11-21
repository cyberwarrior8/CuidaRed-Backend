-- pruebas-3b-asignaciones.sql — Asignaciones y permiso familiar explícito (RF-12, RF-13; V2: el vínculo no concede acceso por sí solo).
-- © 2026 Equipo CuidaRed – INTEC.
begin;
-- Familia: coordinadora (titular), cuidadora, segunda cuidadora sin asignar, familiar y el cuidador de otra cuenta.
select pruebas.usuario('coord.fam3b@x.test', '00130000001', 'Patricia') as fam_coord \gset
select pruebas.usuario('cuid.fam3b@x.test', '00130000002', 'Carla') as fam_cuid \gset
select pruebas.usuario('cuid2.fam3b@x.test', '00130000003', 'Camila') as fam_cuid2 \gset
select pruebas.usuario('fami.fam3b@x.test', '00130000004', 'Fabio') as fam_fami \gset
-- Organización: administradora (titular), coordinadora, voluntaria, cuidador y familiar.
select pruebas.usuario('adm.org3b@x.test', '00130000005', 'Andrea') as org_adm \gset
select pruebas.usuario('coord.org3b@x.test', '00130000006', 'Laura') as org_coord \gset
select pruebas.usuario('vol.org3b@x.test', '00130000007', 'Vera') as org_vol \gset
select pruebas.usuario('cuid.org3b@x.test', '00130000008', 'Carlos') as org_cuid \gset
select pruebas.usuario('fami.org3b@x.test', '00130000009', 'Fernando') as org_fami \gset
select pruebas.usuario('otra.fam3b@x.test', '00130000010', 'Olga') as otra_coord \gset
select pruebas.usuario('externo3b@x.test', '00130000011', 'Esteban') as externo \gset

select pruebas.cuenta('familia', :'fam_coord') as cta_fam \gset
select pruebas.miembro(:cta_fam, :'fam_cuid', 'cuidador');
select pruebas.miembro(:cta_fam, :'fam_cuid2', 'cuidador');
select pruebas.miembro(:cta_fam, :'fam_fami', 'familiar');
select pruebas.cuenta('organizacion', :'org_adm', 'activa', 'Operación Base') as cta_org \gset
select pruebas.miembro(:cta_org, :'org_coord', 'coordinador');
select pruebas.miembro(:cta_org, :'org_vol', 'voluntario');
select pruebas.miembro(:cta_org, :'org_cuid', 'cuidador');
select pruebas.miembro(:cta_org, :'org_fami', 'familiar');
select pruebas.cuenta('familia', :'otra_coord') as cta_otra \gset
select pruebas.cuenta('organizacion', :'externo', 'prueba', null, cuidared_interno.hoy() - 1) as cta_vencida \gset

select pruebas.adulto_3b(:cta_fam, '93000000001') as a_fam \gset
select pruebas.adulto_3b(:cta_org, '93000000002') as a_org \gset
select pruebas.adulto_3b(:cta_otra, '93000000003') as a_otra \gset
select pruebas.adulto_3b(:cta_fam, '93000000004', 'inactivo') as a_inactivo \gset
select pruebas.adulto_3b(:cta_vencida, '93000000005') as a_vencida \gset

/* ───────────── Alcance: sin vínculo no hay acceso ───────────── */
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_cuid'), 'cuidador sin asignación no alcanza al adulto');
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_fami'), 'familiar sin autorización no alcanza al adulto');
select pruebas.afirmar(cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_coord'), 'coordinadora alcanza a todos los adultos de su cuenta');
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_otra', :'fam_coord'), 'adulto de otra cuenta no se alcanza');

select pruebas.como(:'fam_cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_fam, :'a_fam'), '42501');
reset role;

/* ───────────── Asignar cuidadores (RF-12) ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar(
  (cuidared_api.api_asignar(:cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid')->>'tipo') = 'cuidador_asignado'
  and (cuidared_api.api_asignar(:cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid')->>'autorizado_por_usuario_id') = :'fam_coord',
  'asigna cuidadora y registra al autorizador');
reset role;
select pruebas.afirmar((select count(*) from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_cuid') = 1, 'primer vínculo por pareja');
select pruebas.afirmar(cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_cuid'), 'la asignación concede alcance');
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_cuid2'), 'la otra cuidadora sigue sin alcance');

-- Reasignar una asignación vigente no cambia nada (idempotente).
select fecha_autorizacion as fecha_1 from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_cuid' \gset
select pg_sleep(0.05);
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_asignar(:cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid');
reset role;
select pruebas.afirmar((select fecha_autorizacion from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_cuid') = :'fecha_1', 'reasignar lo vigente no reescribe la fila');

-- Validaciones y roles compatibles.
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'familiar_responsable', :'fam_fami'), '22023');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'cuidador_asignado', :'fam_fami'), 'P0001', 'CR_ROL_NO_COMPATIBLE');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'voluntario_asignado', :'fam_cuid2'), 'P0001', 'CR_ROL_NO_PERMITIDO');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'cuidador_asignado', :'org_cuid'), 'P0001', 'CR_ROL_NO_COMPATIBLE');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'cuidador_asignado', gen_random_uuid()), 'P0001', 'CR_ROL_NO_COMPATIBLE');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'cuidador_asignado', :'fam_coord'), 'P0001', 'CR_ROL_NO_COMPATIBLE');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_inactivo', 'cuidador_asignado', :'fam_cuid2'), 'P0001', 'CR_ADULTO_INACTIVO');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, null)', :cta_fam, :'a_fam', 'cuidador_asignado'), '22023');
-- Un adulto de otra cuenta se trata igual que uno inexistente.
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_otra', 'cuidador_asignado', :'fam_cuid2'), '42501');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, gen_random_uuid(), 'cuidador_asignado', :'fam_cuid2'), '42501');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_otra, :'a_otra', 'cuidador_asignado', :'fam_cuid2'), '42501');
reset role;

/* ───────────── Consulta: gestores ven todo; el resto, solo nombres ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')::text as lista_gestor \gset
select pruebas.afirmar((:'lista_gestor'::jsonb ? 'familiares') and (:'lista_gestor'::jsonb ? 'voluntarios'), 'el gestor recibe cuidadores, voluntarios y familiares');
select pruebas.afirmar((:'lista_gestor'::jsonb->'cuidadores'->0->>'usuario_id') = :'fam_cuid', 'el gestor ve el id del cuidador');
reset role;

select pruebas.como(:'fam_cuid');
set local role authenticated;
select cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')::text as lista_cuid \gset
select pruebas.afirmar(jsonb_array_length(:'lista_cuid'::jsonb->'cuidadores') = 1, 'el cuidador asignado ve a los cuidadores');
select pruebas.afirmar(not (:'lista_cuid'::jsonb ? 'familiares'), 'quien no gestiona no ve a los familiares');
select pruebas.afirmar(not (:'lista_cuid'::jsonb->'cuidadores'->0 ? 'usuario_id')
  and (:'lista_cuid'::jsonb->'cuidadores'->0 ? 'nombres') and (:'lista_cuid'::jsonb->'cuidadores'->0 ? 'apellidos'),
  'quien no gestiona recibe solo nombres');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid2'), '42501');
select pruebas.error(format('select cuidared_api.api_familiar_autorizar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_fami'), '42501');
-- Las funciones internas y las tablas no se exponen.
select pruebas.error(format('select cuidared_interno.alcanza_envejeciente(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_cuid'), '42501');
select pruebas.error('select * from cuidared.vinculo', '42501');
reset role;

/* ───────────── Permiso familiar explícito (RF-13) ───────────── */
select pruebas.como(:'fam_fami');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_fam, :'a_fam'), '42501');
reset role;

select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_familiar_autorizar(:cta_fam, :'a_fam', :'fam_fami')->>'tipo') = 'familiar_responsable', 'la coordinadora autoriza al familiar');
select pruebas.error(format('select cuidared_api.api_familiar_autorizar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_cuid2'), 'P0001', 'CR_ROL_NO_COMPATIBLE');
select pruebas.error(format('select cuidared_api.api_familiar_autorizar(%s, %L, %L)', :cta_fam, :'a_otra', :'fam_fami'), '42501');
select cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')::text as lista_gestor2 \gset
select pruebas.afirmar(jsonb_array_length(:'lista_gestor2'::jsonb->'familiares') = 1
  and (:'lista_gestor2'::jsonb->'familiares'->0->>'autorizado_por_usuario_id') = :'fam_coord', 'el gestor ve al familiar autorizado y quién lo autorizó');
reset role;

select pruebas.como(:'fam_fami');
set local role authenticated;
select cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')::text as lista_fami \gset
select pruebas.afirmar(not (:'lista_fami'::jsonb ? 'familiares') and jsonb_array_length(:'lista_fami'::jsonb->'cuidadores') = 1, 'el familiar autorizado consulta solo nombres');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid2'), '42501');
select pruebas.error(format('select cuidared_api.api_familiar_revocar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_fami'), '42501');
reset role;

-- Revocar: el familiar pierde el acceso y queda constancia (fecha y motivo).
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_familiar_revocar(:cta_fam, :'a_fam', :'fam_fami', 'Ya no es responsable');
select pruebas.error(format('select cuidared_api.api_familiar_revocar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_fami'), 'P0002');
select pruebas.error(format('select cuidared_api.api_familiar_revocar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_cuid'), 'P0002');
select pruebas.error(format('select cuidared_api.api_asignacion_revocar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_fami'), 'P0002');
select pruebas.error(format('select cuidared_api.api_familiar_revocar(%s, %L, %L, %L)', :cta_fam, :'a_fam', :'fam_fami', repeat('x', 301)), '22023');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')->'familiares') = 0, 'el listado ya no incluye al familiar revocado');
reset role;
select pruebas.afirmar((select fecha_revocacion is not null and motivo_revocacion = 'Ya no es responsable'
  from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_fami'), 'se conserva la revocación con su motivo');
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_fami'), 'el vínculo revocado no concede acceso');
select pruebas.como(:'fam_fami');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_fam, :'a_fam'), '42501');
reset role;

-- Volver a autorizar registra otro periodo y conserva la revocación anterior.
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_familiar_autorizar(:cta_fam, :'a_fam', :'fam_fami');
reset role;
select pruebas.afirmar((select count(*) = 2 and count(*) filter (where fecha_revocacion is null) = 1
  from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_fami'), 'reautorizar conserva el periodo anterior');
select pruebas.afirmar(exists (select 1 from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_fami'
  and fecha_revocacion is not null and motivo_revocacion = 'Ya no es responsable'), 'reautorizar conserva el motivo anterior');
select pruebas.afirmar(cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_fami'), 'el acceso familiar se restablece');

/* ───────────── Revocar una asignación ───────────── */
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_asignacion_revocar(:cta_fam, :'a_fam', :'fam_cuid');
select pruebas.error(format('select cuidared_api.api_asignacion_revocar(%s, %L, %L)', :cta_fam, :'a_fam', :'fam_cuid'), 'P0002');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')->'cuidadores') = 0, 'el listado ya no incluye al cuidador revocado');
reset role;
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_cuid'), 'la cuidadora revocada pierde el alcance');
select pruebas.como(:'fam_cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_fam, :'a_fam'), '42501');
reset role;
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_asignar(:cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid');
reset role;
select pruebas.afirmar(cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_cuid'), 'reasignar restablece el alcance');
select pruebas.afirmar((select count(*) = 2 and count(*) filter (where fecha_revocacion is null) = 1
  from cuidared.vinculo where envejeciente_id = :'a_fam' and usuario_id = :'fam_cuid'), 'reasignar abre otro periodo');

-- Dos cuidadoras asignadas están al mismo nivel (V2: no hay cuidador principal).
select pruebas.como(:'fam_coord');
set local role authenticated;
select cuidared_api.api_asignar(:cta_fam, :'a_fam', 'cuidador_asignado', :'fam_cuid2');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')->'cuidadores') = 2, 'varias cuidadoras asignadas');
reset role;

-- Una baja de membresía revoca el acceso y la lista no la muestra, aunque el vínculo persista.
update cuidared.membresia set estado = 'inactiva', fecha_fin = cuidared_interno.hoy()
 where usuario_id = :'fam_cuid2' and cuenta_id = :cta_fam;
select pruebas.afirmar(not cuidared_interno.alcanza_envejeciente(:cta_fam, :'a_fam', :'fam_cuid2'), 'la baja de la membresía anula el alcance');
select pruebas.como(:'fam_coord');
set local role authenticated;
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_asignaciones_listar(:cta_fam, :'a_fam')->'cuidadores') = 1, 'la lista omite a quien ya no es miembro activo');
reset role;

/* ───────────── Organización: voluntarios y reparto de facultades ───────────── */
select pruebas.como(:'org_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_asignar(:cta_org, :'a_org', 'voluntario_asignado', :'org_vol')->>'tipo') = 'voluntario_asignado', 'el coordinador asigna voluntarios');
select pruebas.afirmar((cuidared_api.api_asignar(:cta_org, :'a_org', 'cuidador_asignado', :'org_cuid')->>'tipo') = 'cuidador_asignado', 'el coordinador asigna cuidadores');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_org, :'a_org', 'voluntario_asignado', :'org_cuid'), 'P0001', 'CR_ROL_NO_COMPATIBLE');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_org, :'a_org', 'cuidador_asignado', :'org_vol'), 'P0001', 'CR_ROL_NO_COMPATIBLE');
-- En Organización solo el Administrador autoriza familiares.
select pruebas.error(format('select cuidared_api.api_familiar_autorizar(%s, %L, %L)', :cta_org, :'a_org', :'org_fami'), '42501');
reset role;
select pruebas.como(:'org_adm');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_familiar_autorizar(:cta_org, :'a_org', :'org_fami')->>'tipo') = 'familiar_responsable', 'el administrador autoriza familiares');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_asignaciones_listar(:cta_org, :'a_org')->'voluntarios') = 1, 'el administrador ve a los voluntarios');
reset role;
select pruebas.como(:'org_vol');
set local role authenticated;
select cuidared_api.api_asignaciones_listar(:cta_org, :'a_org')::text as lista_vol \gset
select pruebas.afirmar(jsonb_array_length(:'lista_vol'::jsonb->'voluntarios') = 1 and not (:'lista_vol'::jsonb ? 'familiares')
  and not (:'lista_vol'::jsonb->'voluntarios'->0 ? 'usuario_id'), 'la voluntaria asignada solo ve nombres');
select pruebas.error(format('select cuidared_api.api_asignar(%s, %L, %L, %L)', :cta_org, :'a_org', 'voluntario_asignado', :'org_vol'), '42501');
reset role;
-- Sin asignar, la voluntaria no ve a otro adulto de la misma cuenta.
select pruebas.adulto_3b(:cta_org, '93000000006') as a_org2 \gset
select pruebas.como(:'org_vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_org, :'a_org2'), '42501');
reset role;

/* ───────────── Sesión, vigencia y exposición ───────────── */
select pruebas.como(:'externo');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_vencida, :'a_vencida'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
reset role;
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_fam, :'a_fam'), '28000');
reset role;
set local role anon;
select pruebas.error(format('select cuidared_api.api_asignaciones_listar(%s, %L)', :cta_fam, :'a_fam'), '42501');
reset role;

-- Restricciones del modelo: un motivo exige fecha de revocación.
select pruebas.error(format('update cuidared.vinculo set motivo_revocacion = %L where envejeciente_id = %L and usuario_id = %L',
  'x', :'a_fam', :'fam_cuid'), '23514');
rollback;
