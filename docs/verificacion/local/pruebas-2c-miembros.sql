-- pruebas-2c-miembros.sql — Lectura, invitación, aceptar/rechazar y límites del plan (fase 2, bloque 2c).
-- Requiere docs/propuestas/fase-2c-miembros.sql. Todo dentro de una transacción con ROLLBACK.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

-- Ayuda local: lee un escalar con privilegios del dueño (las tablas no son accesibles para authenticated).
create function pruebas.escalar_2c(p_sql text) returns text
language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  execute p_sql into v;
  return v;
end $$;
grant execute on function pruebas.escalar_2c(text) to authenticated;

select cuidared_interno.hoy() as hoy \gset
select pruebas.usuario('fam.tit@x.test', '00100000101', 'Patricia', 'Titular') as fam_tit \gset
select pruebas.usuario('org.adm@x.test', '00100000102', 'Andrea', 'Admin') as org_adm \gset
select pruebas.usuario('org.coord@x.test', '00100000103', 'Laura', 'Coord') as org_coord \gset
select pruebas.usuario('ext.uno@x.test', '00100000111', 'Eva', 'Externa') as ext1 \gset
select pruebas.usuario('ext.dos@x.test', '00100000112', 'Raul', 'Externo') as ext2 \gset
select pruebas.usuario('ext.tres@x.test', '00100000113', 'Tania', 'Tres') as ext3 \gset
select pruebas.usuario('ext.cuatro@x.test', '00100000114', 'Mario', 'Cuatro') as ext4 \gset
select pruebas.usuario('ext.cinco@x.test', '00100000115', 'Nora', 'Cinco') as ext5 \gset
select pruebas.usuario('ext.seis@x.test', '00100000116', 'Omar', 'Seis') as ext6 \gset
select pruebas.cuenta('familia', :'fam_tit') as cta_fam \gset
select pruebas.cuenta('organizacion', :'org_adm') as cta_org \gset
select pruebas.miembro(:cta_org, :'org_coord', 'coordinador') as m_org_coord \gset
select pruebas.usuario('otra.adm@x.test', '00100000104', 'Olga', 'Otra') as otra_adm \gset
select pruebas.cuenta('organizacion', :'otra_adm') as cta_otra \gset
select pruebas.escalar_2c(format('select membresia_id from cuidared.membresia where cuenta_id = %s and usuario_id = %L', :cta_otra, :'otra_adm')) as m_otra_adm \gset

set local role authenticated;

/* ───── Permisos: en Organización solo el Administrador gestiona miembros; en Familia, el Coordinador ───── */
select pruebas.como(:'org_coord');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s)', :cta_org), '42501');
select pruebas.error(format('select cuidared_api.api_detalle_miembro(%s, %s)', :cta_org, :m_org_coord), '42501');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_org, 'nuevo@x.test', '00100000199', 'cuidador'), '42501');
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_org, 'ext.uno@x.test', '00100000111', 'cuidador'), '42501');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_org, :m_org_coord, 'cuidador'), '42501');
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, %s)', :cta_org, :m_org_coord), '42501');

-- Sin sesión: 28000 (401).
select set_config('request.jwt.claims', '', true);
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s)', :cta_fam), '28000');
select pruebas.error('select cuidared_api.api_aceptar_membresia(1)', '28000');

/* ───── Listado y detalle ───── */
select pruebas.como(:'fam_tit');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam)->>'total')::int = 1, 'solo el titular');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_fam)->'items'->0->>'rol' = 'coordinador', 'rol del titular');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam)->'items'->0->>'es_titular')::boolean, 'es_titular');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_fam)->'items'->0->'usuario'->>'correo' = 'fam.tit@x.test', 'correo en la fila');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_fam)->'items'->0->'cuidador' = 'null'::jsonb, 'sin perfil cuidador');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_fam)->'items'->0 ?& array['membresia_id', 'rol', 'estado', 'fecha_inicio', 'fecha_fin', 'es_titular', 'usuario', 'cuidador'], 'forma del DTO');
select pruebas.afirmar(not (cuidared_api.api_listar_miembros(:cta_fam)->'items'->0->'usuario' ? 'cedula'), 'la cédula no se expone en el listado');

/* ───── Invitar a una persona que ya existe: preparar + agregar ───── */
-- Correo en otro formato: se resuelve sin distinguir mayúsculas.
select pruebas.afirmar((cuidared_api.api_preparar_invitacion(:cta_fam, 'EXT.UNO@x.test', '00100000111', 'cuidador')->>'usuario_existe')::boolean, 'la persona existe');
select pruebas.afirmar(not (cuidared_api.api_preparar_invitacion(:cta_fam, 'nueva@x.test', '00100000199', 'cuidador')->>'usuario_existe')::boolean, 'persona nueva');
-- Entradas inválidas (422) y reglas (409/422).
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '123', 'cuidador'), '22023');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'sin-arroba', '00100000111', 'cuidador'), '22023');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000111', null), '22023');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(0, %L, %L, %L)', 'ext.uno@x.test', '00100000111', 'cuidador'), '42501');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000999', 'cuidador'), 'P0001', 'CR_IDENTIDAD_NO_COINCIDE');
-- Cédula ya registrada con otro correo: mismo error genérico.
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'otro.correo@x.test', '00100000111', 'cuidador'), 'P0001', 'CR_IDENTIDAD_NO_COINCIDE');
-- En Familia no existen Voluntario ni Administrador.
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000111', 'voluntario'), 'P0001', 'CR_ROL_NO_PERMITIDO');
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000111', 'administrador'), 'P0001', 'CR_ROL_NO_PERMITIDO');
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000111', 'superusuario'), 'P0001', 'CR_ROL_NO_PERMITIDO');
-- Agregar exige que la identidad exista (la invitación Auth aún no se completó): P0002.
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_fam, 'nueva@x.test', '00100000199', 'cuidador'), 'P0002');

select cuidared_api.api_agregar_miembro(:cta_fam, 'EXT.UNO@x.test', '00100000111', 'cuidador') as inv1 \gset
select pruebas.afirmar((:'inv1'::jsonb)->>'estado' = 'pendiente', 'queda pendiente');
select pruebas.afirmar((:'inv1'::jsonb)->>'rol' = 'cuidador', 'con el rol indicado');
select pruebas.afirmar((:'inv1'::jsonb)->>'fecha_inicio' = :'hoy', 'fecha_inicio = hoy de negocio');
select pruebas.afirmar((:'inv1'::jsonb)->'fecha_fin' = 'null'::jsonb, 'sin fecha_fin');
select pruebas.afirmar((:'inv1'::jsonb)->'usuario'->>'id' = :'ext1', 'identidad resuelta por correo y cédula');
select ((:'inv1'::jsonb)->>'membresia_id')::bigint as m_ext1 \gset
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.notificacion where usuario_id = %L and cuenta_id = %s', :'ext1', :cta_fam)) = '1', 'notificación personal al invitado');
select pruebas.afirmar(pruebas.escalar_2c(format('select mensaje from cuidared.notificacion where usuario_id = %L', :'ext1')) like '%Cuidador%', 'la notificación nombra el rol');
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000111', 'familiar'), 'P0001', 'CR_YA_ES_MIEMBRO');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam, 'ext.uno@x.test', '00100000111', 'familiar'), 'P0001', 'CR_YA_ES_MIEMBRO');
-- Una invitación pendiente no concede acceso.
select pruebas.afirmar(pruebas.como(:'ext1') is not null, 'sesión de la persona invitada');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_fam) is null, 'pendiente: sin acceso a la cuenta');
select pruebas.afirmar(cuidared_api.api_mis_cuentas()->'pendientes'->0->>'membresia_id' = :'m_ext1', 'aparece en mis pendientes');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s)', :cta_fam), '42501');

/* ───── Aceptar y rechazar solo la membresía propia pendiente ───── */
select pruebas.como(:'ext2');
select pruebas.error(format('select cuidared_api.api_aceptar_membresia(%s)', :m_ext1), 'P0002');   -- de otra persona
select pruebas.error(format('select cuidared_api.api_rechazar_membresia(%s)', :m_ext1), 'P0002');
select pruebas.error('select cuidared_api.api_aceptar_membresia(0)', '22023');
select pruebas.error('select cuidared_api.api_aceptar_membresia(99999999)', 'P0002');
select pruebas.como(:'ext1');
select cuidared_api.api_aceptar_membresia(:m_ext1) as acept \gset
select pruebas.afirmar((:'acept'::jsonb)->>'estado' = 'activa' and (:'acept'::jsonb)->>'rol' = 'cuidador', 'aceptada');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_fam)->>'rol' = 'cuidador', 'ahora tiene acceso con su rol');
select pruebas.afirmar(not ((cuidared_api.api_contexto_cuenta(:cta_fam)->'permisos') ? 'usuarios:gestionar'), 'el cuidador no gestiona miembros');
select pruebas.error(format('select cuidared_api.api_aceptar_membresia(%s)', :m_ext1), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_rechazar_membresia(%s)', :m_ext1), 'P0001', 'CR_ESTADO_INVALIDO');

-- Rechazar: la membresía queda inactiva con fecha_fin y no concede acceso.
select pruebas.como(:'fam_tit');
select cuidared_api.api_agregar_miembro(:cta_fam, 'ext.dos@x.test', '00100000112', 'familiar')->>'membresia_id' as m_ext2 \gset
select pruebas.como(:'ext2');
select cuidared_api.api_rechazar_membresia(:m_ext2);
select pruebas.afirmar(pruebas.escalar_2c(format('select estado from cuidared.membresia where membresia_id = %s', :m_ext2)) = 'inactiva', 'rechazada = inactiva');
select pruebas.afirmar(pruebas.escalar_2c(format('select fecha_fin::text from cuidared.membresia where membresia_id = %s', :m_ext2)) = :'hoy', 'rechazada con fecha_fin');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_fam) is null, 'rechazada: sin acceso');
-- Tras rechazar se puede volver a invitar (la vigente única ya no existe).
select pruebas.como(:'fam_tit');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_fam, 'ext.dos@x.test', '00100000112', 'familiar')->>'estado' = 'pendiente', 'reinvitación tras rechazo');

/* ───── Filtros, orden y paginación ───── */
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam)->>'total')::int = 3, 'tres personas: titular, cuidador y familiar pendiente');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam, 'cuidador')->>'total')::int = 1, 'filtro por rol');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam, null, 'pendiente')->>'total')::int = 1, 'filtro por estado');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam, 'voluntario')->>'total')::int = 0, 'filtro sin resultados');
-- Orden por nombres (Eva, Patricia, Raul) y descendente.
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_fam)->'items'->0->'usuario'->>'nombres' = 'Eva', 'orden por nombres');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_fam, null, null, '["-nombres","membresia_id"]')->'items'->0->'usuario'->>'nombres' = 'Raul', 'orden descendente');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_miembros(:cta_fam, null, null, '["nombres","membresia_id"]', 2, 0)->'items') = 2, 'primera página');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_miembros(:cta_fam, null, null, '["nombres","membresia_id"]', 2, 2)->'items') = 1, 'segunda página');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_fam, null, null, '["nombres","membresia_id"]', 2, 2)->>'total')::int = 3, 'el total no depende de la página');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_miembros(:cta_fam, null, null, '["nombres","membresia_id"]', 2, 40)->'items') = 0, 'página fuera de rango');
-- La orden del cliente nunca es SQL.
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, null, %L)', :cta_fam, '["nombres; drop table cuidared.membresia"]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, null, %L)', :cta_fam, '["cedula"]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, null, %L)', :cta_fam, '"nombres"'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, ''inexistente'')', :cta_fam), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, null, null, 0)', :cta_fam), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, null, null, 101)', :cta_fam), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s, null, null, null, 20, -1)', :cta_fam), '22023');
-- Detalle: de ESTA cuenta; el de otra cuenta no existe para quien consulta.
select pruebas.afirmar(cuidared_api.api_detalle_miembro(:cta_fam, :m_ext1)->>'rol' = 'cuidador', 'detalle');
select pruebas.error(format('select cuidared_api.api_detalle_miembro(%s, %s)', :cta_fam, :m_otra_adm), 'P0002');
select pruebas.error(format('select cuidared_api.api_detalle_miembro(%s, 0)', :cta_fam), '22023');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s)', :cta_otra), '42501');
select pruebas.error(format('select cuidared_api.api_detalle_miembro(%s, %s)', :cta_otra, :m_otra_adm), '42501');

/* ───── Límites del plan (D07) ───── */
-- Plan Básico Familiar: familiares 3 y cuidadores sin límite. Los familiares cuentan aparte.
select pruebas.usuario('fam2.tit@x.test', '00100000105', 'Fabio', 'Dos') as fam2_tit \gset
select pruebas.cuenta('familia', :'fam2_tit', 'activa', 'Básico Familiar') as cta_fam2 \gset
select pruebas.como(:'fam2_tit');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_fam2, 'ext.tres@x.test', '00100000113', 'familiar')->>'estado' = 'pendiente', 'familiar 1');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_fam2, 'ext.cuatro@x.test', '00100000114', 'familiar')->>'estado' = 'pendiente', 'familiar 2');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_fam2, 'ext.cinco@x.test', '00100000115', 'familiar')->>'estado' = 'pendiente', 'familiar 3 (pendientes reservan cupo)');
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_fam2, 'ext.seis@x.test', '00100000116', 'familiar'), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_fam2, 'ext.seis@x.test', '00100000116', 'familiar'), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_fam2, 'ext.seis@x.test', '00100000116', 'cuidador')->>'estado' = 'pendiente', 'los cuidadores no tienen límite en este plan');

-- Organización en prueba: 5 usuarios (Administrador, Coordinador, ...). El Voluntario no cuenta.
select pruebas.como(:'org_adm');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_org, 'ext.tres@x.test', '00100000113', 'cuidador')->>'estado' = 'pendiente', 'usuario 3');
select pruebas.afirmar(cuidared_api.api_agregar_miembro(:cta_org, 'ext.cuatro@x.test', '00100000114', 'familiar')->>'estado' = 'pendiente', 'usuario 4');
select cuidared_api.api_agregar_miembro(:cta_org, 'ext.cinco@x.test', '00100000115', 'cuidador')->>'membresia_id' as m_ext5 \gset
select pruebas.error(format('select cuidared_api.api_agregar_miembro(%s, %L, %L, %L)', :cta_org, 'ext.seis@x.test', '00100000116', 'cuidador'), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.error(format('select cuidared_api.api_preparar_invitacion(%s, %L, %L, %L)', :cta_org, 'persona.nueva@x.test', '00100000198', 'coordinador'), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.afirmar(not (cuidared_api.api_preparar_invitacion(:cta_org, 'persona.nueva@x.test', '00100000198', 'voluntario')->>'usuario_existe')::boolean, 'el voluntario no necesita cupo');
select cuidared_api.api_agregar_miembro(:cta_org, 'ext.seis@x.test', '00100000116', 'voluntario')->>'membresia_id' as m_ext6 \gset
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_org)->>'total')::int = 6, 'cinco usuarios y un voluntario');

-- Aceptar vuelve a comprobar el plan (pudo cambiar desde la invitación): se simula con un miembro extra.
select pruebas.usuario('extra@x.test', '00100000117', 'Elena', 'Extra') as extra \gset
select pruebas.miembro(:cta_org, :'extra', 'cuidador');
select pruebas.como(:'ext5');
select pruebas.error(format('select cuidared_api.api_aceptar_membresia(%s)', :m_ext5), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.afirmar(pruebas.escalar_2c(format('select estado from cuidared.membresia where membresia_id = %s', :m_ext5)) = 'pendiente', 'sigue pendiente tras el rechazo por límite');
-- El voluntario acepta aunque la cuenta esté llena: no consume cupo.
select pruebas.como(:'ext6');
select pruebas.afirmar(cuidared_api.api_aceptar_membresia(:m_ext6)->>'estado' = 'activa', 'el voluntario acepta sin cupo');

-- Una persona puede tener membresías en varias cuentas con permisos propios de cada una.
select pruebas.como(:'ext1');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_fam)->>'rol' = 'cuidador', 'rol en la cuenta Familia');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_org) is null, 'sin acceso a la otra cuenta');
rollback;
