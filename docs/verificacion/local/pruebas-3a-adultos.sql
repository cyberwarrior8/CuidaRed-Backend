-- pruebas-3a-adultos.sql — Alta, listado, consulta y edición de perfiles (fase 3, bloque 3a).
-- Cubre autorización por rol, alcance (cuidador, voluntario y familiar solo ven a los suyos), datos mínimos del
-- Voluntario, aislamiento entre cuentas, consentimiento, contactos, límite del plan y cédula única global.
-- Las asignaciones se insertan en cuidared.vinculo como superusuario (las construye el bloque 3b). © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('ad.coord@x.test', '00100000201', 'Patricia') as f_coord \gset
select pruebas.usuario('ad.cuid@x.test', '00100000202') as f_cuid \gset
select pruebas.usuario('ad.fami@x.test', '00100000203') as f_fami \gset
select pruebas.usuario('ad.fami2@x.test', '00100000204') as f_fami2 \gset
select pruebas.usuario('ad.admin@x.test', '00100000205', 'Andrea') as o_adm \gset
select pruebas.usuario('ad.ocoord@x.test', '00100000206') as o_coord \gset
select pruebas.usuario('ad.ocuid@x.test', '00100000207') as o_cuid \gset
select pruebas.usuario('ad.ovol@x.test', '00100000208') as o_vol \gset
select pruebas.usuario('ad.ovol2@x.test', '00100000209') as o_vol2 \gset
select pruebas.usuario('ad.otra@x.test', '00100000210') as otra \gset
select pruebas.cuenta('familia', :'f_coord') as cta_fam \gset
select pruebas.miembro(:cta_fam, :'f_cuid', 'cuidador');
select pruebas.miembro(:cta_fam, :'f_fami', 'familiar');
select pruebas.miembro(:cta_fam, :'f_fami2', 'familiar');
-- Organización con un plan sin tope de adultos (Gestión Comunitaria Avanzada).
select pruebas.cuenta('organizacion', :'o_adm', 'activa', 'Gestión Comunitaria Avanzada') as cta_org \gset
select pruebas.miembro(:cta_org, :'o_coord', 'coordinador');
select pruebas.miembro(:cta_org, :'o_cuid', 'cuidador');
select pruebas.miembro(:cta_org, :'o_vol', 'voluntario');
select pruebas.miembro(:cta_org, :'o_vol2', 'voluntario');
select pruebas.cuenta('familia', :'otra') as cta_otra \gset
insert into cuidared.municipio values ('0102', 'Boca Chica', '01');

-- Datos base de un alta válida y atajo para invocar la RPC con cambios o claves quitadas.
create function pruebas.datos_base() returns jsonb language sql as $$
  select '{"nombres":"Rosa Maria","apellidos":"Pena Diaz","cedula":"001-1234567-8","fecha_nacimiento":"1950-03-15",
    "sexo":"F","telefono":"809 555 0100","municipio_cod":"0101","zona":"Centro","direccion":"Calle 1 #2",
    "autonomia":"parcial","condiciones":["cronica","movilidad"],"nota_condicion":"Usa baston",
    "consentimiento":{"otorgado":true,"otorgado_por":"adulto"},
    "contactos":[{"nombres":"Luis","apellidos":"Pena","parentesco":"Hijo/a","telefono":"829-555-0101","es_principal":true}]}'::jsonb
$$;
create function pruebas.crear(p_cuenta bigint, p_cambios jsonb default '{}', p_quitar text[] default '{}')
returns jsonb language sql as $$
  select cuidared_api.api_crear_envejeciente(p_cuenta, (pruebas.datos_base() || p_cambios) - p_quitar)
$$;
create function pruebas.vincular(p_adulto uuid, p_usuario uuid, p_tipo text) returns void
language sql security definer set search_path = '' as $$
  insert into cuidared.vinculo(envejeciente_id, usuario_id, tipo_vinculo_id)
  select p_adulto, p_usuario, tipo_vinculo_id from cuidared.tipo_vinculo where codigo = p_tipo
$$;

/* ───────────── Alta (Coordinador de Familia) ───────────── */
select pruebas.como(:'f_coord');
set local role authenticated;
select (pruebas.crear(:cta_fam)->>'envejeciente_id')::uuid as a1 \gset
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'cedula') = '00112345678', 'cédula normalizada sin guiones');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'telefono') = '8095550100', 'teléfono normalizado');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'estado') = 'activo', 'estado inicial activo');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'condicion_general'->>'autonomia') = 'parcial', 'condición general');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'condicion_general'->'condiciones') = '["cronica","movilidad"]'::jsonb, 'condiciones');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'consentimiento'->>'registrado_por') = :'f_coord', 'consentimiento registrado por el actor');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'consentimiento'->>'otorgado_por') = 'adulto', 'consentimiento del adulto');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'contacto_principal'->>'telefono') = '8295550101', 'contacto principal normalizado');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'contactos') = 1, 'un contacto');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'municipio_nombre') = 'Santo Domingo de Guzmán', 'municipio resuelto');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'fecha_creacion') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$', 'marca temporal UTC ISO 8601');

-- Segundo adulto, con representante y varios contactos (el principal no es el primero).
select (pruebas.crear(:cta_fam, jsonb_build_object('cedula', '00198765432', 'nombres', 'Ana', 'apellidos', 'Abreu', 'zona', 'Los Mina',
  'municipio_cod', '0102', 'sexo', 'M', 'telefono', null,
  'consentimiento', '{"otorgado":true,"otorgado_por":"representante","representante":"Maria Perez"}'::jsonb,
  'contactos', '[{"nombres":"Eva","apellidos":"Abreu","parentesco":"Nieto/a","telefono":"8095550111"},
                 {"nombres":"Raul","apellidos":"Abreu","parentesco":"Hijo/a","telefono":"+18095550112","es_principal":true}]'::jsonb))
  ->>'envejeciente_id')::uuid as a2 \gset
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a2')->'consentimiento'->>'representante') = 'Maria Perez', 'representante registrado');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a2')->'contacto_principal'->>'nombres') = 'Raul', 'principal designado');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a2')->'contactos'->0->>'es_principal') = 'true', 'principal primero en la lista');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a2')->>'telefono') is null, 'teléfono opcional');

-- Límite de la prueba de Familia (2 adultos activos): el tercero se rechaza con CR_LIMITE_PLAN.
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00177777777"}'), 'P0001', 'CR_LIMITE_PLAN');

-- Cédula única en toda la plataforma: duplicada en la misma cuenta o en otra, sin revelar nada más.
select pruebas.error(format('select pruebas.crear(%s)', :cta_fam), 'P0001', 'CR_LIMITE_PLAN');
reset role;
-- Con cupo liberado, la duplicada se rechaza por cédula (no por límite). Se libera inactivando a2 como superusuario.
update cuidared.envejeciente set estado = 'inactivo', motivo_estado = 'prueba' where envejeciente_id = :'a2';
select pruebas.como(:'f_coord');
set local role authenticated;
select pruebas.error(format('select pruebas.crear(%s)', :cta_fam), 'P0001', 'CR_CEDULA_DUPLICADA');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00198765432"}'), 'P0001', 'CR_CEDULA_DUPLICADA');
reset role;
select pruebas.como(:'otra');
set local role authenticated;
select pruebas.error(format('select pruebas.crear(%s)', :cta_otra), 'P0001', 'CR_CEDULA_DUPLICADA');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_otra, '{"cedula":"001-1234567-8"}'), 'P0001', 'CR_CEDULA_DUPLICADA');
-- Una cédula nueva sí se acepta en otra cuenta, y aquí no se ve nada de las demás cuentas.
select (pruebas.crear(:cta_otra, '{"cedula":"00155555550"}')->>'envejeciente_id')::uuid as a_otra \gset
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_otra)->>'total')::int = 1, 'otra cuenta: solo su adulto');
reset role;
-- Un alta fallida no deja filas parciales (perfil ni contactos).
select pruebas.afirmar((select count(*) from cuidared.envejeciente where cuenta_id = :cta_fam) = 2, 'sin perfiles parciales');
select pruebas.afirmar((select count(*) from cuidared.contacto_emergencia c join cuidared.envejeciente e using (envejeciente_id)
  where e.cuenta_id = :cta_fam) = 3, 'sin contactos parciales');
update cuidared.envejeciente set estado = 'activo', motivo_estado = null where envejeciente_id = :'a2';
select pruebas.como(:'f_coord');
set local role authenticated;

-- Consentimiento (CR-158): sin consentimiento no se guarda el perfil.
select pruebas.error(format('select pruebas.crear(%s, %L, %L)', :cta_fam, '{"cedula":"00166666666"}', '{consentimiento}'), 'P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","consentimiento":{"otorgado":false,"otorgado_por":"adulto"}}'), 'P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","consentimiento":{"otorgado":true,"otorgado_por":"representante"}}'), 'P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","consentimiento":null}'), 'P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","consentimiento":{"otorgado":true,"otorgado_por":"adulto","representante":"Maria Perez"}}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","consentimiento":{"otorgado":true,"otorgado_por":"tutor"}}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","consentimiento":{"otorgado":"si","otorgado_por":"adulto"}}'), '22023');

-- Contactos: de 1 a 5 y exactamente un principal (CR_CONTACTO_PRINCIPAL).
select pruebas.error(format('select pruebas.crear(%s, %L, %L)', :cta_fam, '{"cedula":"00166666666"}', '{contactos}'), 'P0001', 'CR_CONTACTO_PRINCIPAL');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","contactos":[]}'), 'P0001', 'CR_CONTACTO_PRINCIPAL');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","contactos":[{"nombres":"Luis","apellidos":"Pena","parentesco":"Hijo/a","telefono":"8295550101"}]}'), 'P0001', 'CR_CONTACTO_PRINCIPAL');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","contactos":[
  {"nombres":"Luis","apellidos":"Pena","parentesco":"Hijo/a","telefono":"8295550101","es_principal":true},
  {"nombres":"Eva","apellidos":"Pena","parentesco":"Hijo/a","telefono":"8295550102","es_principal":true}]}'), 'P0001', 'CR_CONTACTO_PRINCIPAL');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, (
  select jsonb_build_object('cedula', '00166666666', 'contactos', jsonb_agg(jsonb_build_object('nombres', 'Luis', 'apellidos', 'Pena',
    'parentesco', 'Hijo/a', 'telefono', '8295550101', 'es_principal', n = 1)))::text from generate_series(1, 6) n)), 'P0001', 'CR_CONTACTO_PRINCIPAL');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","contactos":[{"nombres":"Luis","apellidos":"Pena","parentesco":"Hijo/a","telefono":"123","es_principal":true}]}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","contactos":[{"nombres":"Luis","apellidos":"Pena","parentesco":"Hijo/a","telefono":"8295550101","es_principal":"si"}]}'), '22023');

-- Entradas inválidas (22023): formato, dominio y claves desconocidas.
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"1234"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"0011234567a"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","sexo":"X"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","sexo":"Femenino"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","nombres":"Rosa 2"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","nombres":"R"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","apellidos":"<b>x</b>"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","fecha_nacimiento":"1990-01-01"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","fecha_nacimiento":"1850-01-01"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","fecha_nacimiento":"2999-01-01"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","fecha_nacimiento":"1950-02-31"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","fecha_nacimiento":"15/03/1950"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","municipio_cod":"9999"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","municipio_cod":"ab"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","telefono":"12345"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","zona":""}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","autonomia":"total"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","condiciones":["diabetes"]}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","condiciones":"cronica"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","condiciones":[1]}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, jsonb_build_object('cedula', '00166666666', 'nota_condicion', repeat('a', 501))::text), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","estado":"inactivo"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","cuenta_id":999}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666","usuario_registrador_id":"x"}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L, %L)', :cta_fam, '{"cedula":"00166666666"}', '{zona}'), '22023');
select pruebas.error(format('select pruebas.crear(%s, %L, %L)', :cta_fam, '{"cedula":"00166666666"}', '{autonomia}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_envejeciente(%s, %L)', :cta_fam, '[]'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_envejeciente(%s, null)', :cta_fam), '22023');
reset role;

/* ───────────── Autorización por rol en el alta ───────────── */
select pruebas.como(:'f_cuid');
set local role authenticated;
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666"}'), '42501');
reset role;
select pruebas.como(:'f_fami');
set local role authenticated;
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666"}'), '42501');
reset role;
select pruebas.como(:'o_vol');
set local role authenticated;
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_org, '{"cedula":"00166666666"}'), '42501');
-- Sin membresía en la cuenta, 42501 (y nunca datos).
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666"}'), '42501');
reset role;
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_fam, '{"cedula":"00166666666"}'), '28000');
reset role;

/* ───────────── Alcance y datos mínimos ───────────── */
-- Familia: el cuidador está asignado a a1 y el familiar autorizado a a1; nadie más tiene vínculo con a2.
select pruebas.vincular(:'a1', :'f_cuid', 'cuidador_asignado');
select pruebas.vincular(:'a1', :'f_fami', 'familiar_responsable');
-- Organización: dos adultos; el voluntario 1 está asignado al primero.
select pruebas.como(:'o_adm');
set local role authenticated;
select (pruebas.crear(:cta_org, '{"cedula":"00111000001","nombres":"Carlos","apellidos":"Zapata"}')->>'envejeciente_id')::uuid as o1 \gset
select (pruebas.crear(:cta_org, '{"cedula":"00111000002","nombres":"Berta","apellidos":"Almonte"}')->>'envejeciente_id')::uuid as o2 \gset
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->>'total')::int = 2, 'administrador ve todos');
reset role;
select pruebas.vincular(:'o1', :'o_vol', 'voluntario_asignado');
select pruebas.vincular(:'o1', :'o_cuid', 'cuidador_asignado');
-- El vínculo de otro tipo no concede el alcance de este rol (un voluntario no es cuidador asignado).
select pruebas.vincular(:'o2', :'o_vol2', 'cuidador_asignado');

-- Gestores: todos los de la cuenta, ordenados por apellidos, nombres y fecha de creación.
select pruebas.como(:'o_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->>'total')::int = 2, 'coordinador ve todos');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->'items'->0->>'apellidos') = 'Almonte', 'orden por apellidos');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, null, null, '["-apellidos"]')->'items'->0->>'apellidos') = 'Zapata', 'orden descendente');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, p_limite => 1, p_desplazamiento => 1)->'items'->0->>'apellidos') = 'Zapata', 'paginación');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, p_limite => 1, p_desplazamiento => 1)->>'total')::int = 2, 'total antes de paginar');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_envejecientes(:cta_org, p_desplazamiento => 40)->'items') = 0, 'página fuera de rango vacía');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, p_desplazamiento => 40)->>'total')::int = 2, 'total fuera de rango');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->'items'->0->>'autonomia') = 'parcial', 'gestor ve la autonomía en el listado');
-- Filtros por estado y municipio.
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, 'inactivo')->>'total')::int = 0, 'filtro estado inactivo vacío');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, 'activo')->>'total')::int = 2, 'filtro estado activo');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, null, '0102')->>'total')::int = 0, 'filtro municipio sin coincidencias');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org, null, '0101')->>'total')::int = 2, 'filtro municipio');
-- Parámetros inválidos.
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, %L)', :cta_org, 'borrado'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, null, %L)', :cta_org, 'x1'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, null, null, %L)', :cta_org, '["cedula"]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, null, null, %L)', :cta_org, '["apellidos; drop table x"]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, null, null, %L)', :cta_org, '[]'), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, p_limite => 0)', :cta_org), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, p_limite => 101)', :cta_org), '22023');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s, p_desplazamiento => -1)', :cta_org), '22023');
reset role;

-- Cuidador de Familia: solo el asignado. El otro adulto de la misma cuenta responde como si no existiera.
select pruebas.como(:'f_cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_fam)->>'total')::int = 2 - 1, 'cuidador: solo asignados');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_fam)->'items'->0->>'envejeciente_id') = :'a1', 'cuidador: el asignado');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'condicion_general'->>'autonomia') = 'parcial', 'cuidador ve la condición general (sensible)');
select pruebas.afirmar(cuidared_api.api_ver_envejeciente(:cta_fam, :'a1') ? 'consentimiento', 'cuidador ve el consentimiento');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_fam, :'a2'), 'P0002');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_fam, gen_random_uuid()), 'P0002');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_fam, :'a_otra'), 'P0002');
reset role;

-- Familiar: solo el autorizado; ve la identificación pero no la condición general ni el consentimiento.
select pruebas.como(:'f_fami');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_fam)->>'total')::int = 1, 'familiar: solo el autorizado');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_fam)->'items'->0) ? 'fecha_nacimiento', 'familiar ve la identificación');
select pruebas.afirmar(not ((cuidared_api.api_listar_envejecientes(:cta_fam)->'items'->0) ? 'autonomia'), 'familiar no ve la autonomía en el listado');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'cedula') = '00112345678', 'familiar ve la cédula');
select pruebas.afirmar(not (cuidared_api.api_ver_envejeciente(:cta_fam, :'a1') ? 'condicion_general'), 'familiar sin condición general');
select pruebas.afirmar(not (cuidared_api.api_ver_envejeciente(:cta_fam, :'a1') ? 'consentimiento'), 'familiar sin consentimiento');
select pruebas.afirmar(not (cuidared_api.api_ver_envejeciente(:cta_fam, :'a1') ? 'motivo_estado'), 'familiar sin motivo de estado');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_fam, :'a2'), 'P0002');
reset role;
-- Familiar sin autorización: lista vacía y 404 para todos.
select pruebas.como(:'f_fami2');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_fam)->>'total')::int = 0, 'familiar sin autorización: lista vacía');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_envejecientes(:cta_fam)->'items') = 0, 'familiar sin autorización: sin filas');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_fam, :'a1'), 'P0002');
reset role;

-- Voluntario: solo el asignado y solo datos mínimos.
select pruebas.como(:'o_vol');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->>'total')::int = 1, 'voluntario: solo el asignado');
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->'items'->0->>'apellidos') = 'Zapata', 'voluntario: su adulto');
select pruebas.afirmar(not ((cuidared_api.api_listar_envejecientes(:cta_org)->'items'->0) ?| array['fecha_nacimiento', 'sexo', 'autonomia', 'cedula']),
  'voluntario: listado mínimo');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_org, :'o1')->>'nombres') = 'Carlos', 'voluntario ve nombres');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_org, :'o1')->>'direccion') = 'Calle 1 #2', 'voluntario ve la dirección');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_org, :'o1')->>'zona') = 'Centro', 'voluntario ve la zona');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_org, :'o1')->>'municipio_cod') = '0101', 'voluntario ve el municipio');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_org, :'o1')->'contacto_principal'->>'es_principal') = 'true', 'voluntario ve el contacto principal');
select pruebas.afirmar(not (cuidared_api.api_ver_envejeciente(:cta_org, :'o1') ?| array['cedula', 'fecha_nacimiento', 'sexo', 'telefono',
  'condicion_general', 'consentimiento', 'contactos', 'motivo_estado']), 'voluntario sin cédula, nacimiento, condición ni consentimiento');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_org, :'o2'), 'P0002');
reset role;
-- Un voluntario sin vínculo propio no ve nada; el cuidador de Organización solo ve el suyo.
select pruebas.como(:'o_vol2');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->>'total')::int = 0, 'voluntario con vínculo de otro tipo: nada');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_org, :'o2'), 'P0002');
reset role;
select pruebas.como(:'o_cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_envejecientes(:cta_org)->>'total')::int = 1, 'cuidador de organización: solo el asignado');
reset role;

/* ───────────── Aislamiento entre cuentas ───────────── */
select pruebas.como(:'otra');
set local role authenticated;
-- Un adulto de otra cuenta responde igual que uno inexistente (P0002), tanto en lectura como en escritura.
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_otra, :'a1'), 'P0002');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_otra, :'a1', '{"zona":"Hack"}'), 'P0002');
select pruebas.error(format('select cuidared_api.api_estado_envejeciente(%s, %L, %L, %L)', :cta_otra, :'a1', 'inactivo', 'prueba'), 'P0002');
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta_otra, :'a1'), 'P0002');
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_otra, gen_random_uuid()), 'P0002');
-- Y la cuenta ajena misma responde 42501 (sin membresía), sin revelar si el adulto existe.
select pruebas.error(format('select cuidared_api.api_ver_envejeciente(%s, %L)', :cta_fam, :'a1'), '42501');
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s)', :cta_fam), '42501');
reset role;
select pruebas.afirmar((select zona from cuidared.envejeciente where envejeciente_id = :'a1') = 'Centro', 'el adulto ajeno no cambió');

/* ───────────── Edición ───────────── */
select pruebas.como(:'f_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_editar_envejeciente(:cta_fam, :'a1', '{"zona":"Gazcue","telefono":null,"nota_condicion":null,"condiciones":["cognitivo","cognitivo","vive_solo"]}')->>'zona') = 'Gazcue', 'edita la zona');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'telefono') is null, 'telefono null lo borra');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'condicion_general'->>'nota') is null, 'nota null la borra');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->'condicion_general'->'condiciones') = '["cognitivo","vive_solo"]'::jsonb, 'condiciones únicas y ordenadas');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'nombres') = 'Rosa Maria', 'lo no enviado no cambia');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'fecha_actualizacion') >= (cuidared_api.api_ver_envejeciente(:cta_fam, :'a1')->>'fecha_creacion'), 'fecha de actualización no retrocede');
-- Cédula: puede cambiar mientras siga siendo única en la plataforma.
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"cedula":"00198765432"}'), 'P0001', 'CR_CEDULA_DUPLICADA');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"cedula":"00155555550"}'), 'P0001', 'CR_CEDULA_DUPLICADA');
select pruebas.afirmar((cuidared_api.api_editar_envejeciente(:cta_fam, :'a1', '{"cedula":"001-1234567-8"}')->>'cedula') = '00112345678', 'misma cédula no choca consigo misma');
select pruebas.afirmar((cuidared_api.api_editar_envejeciente(:cta_fam, :'a1', '{"cedula":"00112345600"}')->>'cedula') = '00112345600', 'cédula libre');
select pruebas.afirmar((cuidared_api.api_editar_envejeciente(:cta_fam, :'a1', '{"cedula":"00112345678"}')->>'cedula') = '00112345678', 'restablece la cédula');
-- Consentimiento: se vuelve a registrar con fecha y usuario actuales; no se puede retirar.
select pruebas.afirmar((cuidared_api.api_editar_envejeciente(:cta_fam, :'a1',
  '{"consentimiento":{"otorgado":true,"otorgado_por":"representante","representante":"Maria Perez"}}')->'consentimiento'->>'otorgado_por') = 'representante', 'cambia el otorgante');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"consentimiento":{"otorgado":false,"otorgado_por":"adulto"}}'), 'P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"consentimiento":null}'), 'P0001', 'CR_CONSENTIMIENTO_REQUERIDO');
-- Entradas inválidas y campos no editables.
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"estado":"inactivo"}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"cuenta_id":999}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"contactos":[]}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"sexo":"Z"}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"zona":null}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"municipio_cod":"9999"}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"fecha_nacimiento":"2000-01-01"}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '[]'), '22023');
reset role;
-- Solo gestores editan: cuidador y familiar con alcance sobre el adulto reciben 42501.
select pruebas.como(:'f_cuid');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"zona":"Hack"}'), '42501');
reset role;
select pruebas.como(:'f_fami');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_fam, :'a1', '{"zona":"Hack"}'), '42501');
reset role;
select pruebas.como(:'o_vol');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_editar_envejeciente(%s, %L, %L)', :cta_org, :'o1', '{"zona":"Hack"}'), '42501');
reset role;
select pruebas.afirmar((select zona from cuidared.envejeciente where envejeciente_id = :'a1') = 'Gazcue', 'las ediciones denegadas no cambian nada');

-- Cuenta vencida: se bloquea también la consulta de los módulos operativos (D07).
select pruebas.usuario('ad.venc@x.test', '00100000211') as venc \gset
select pruebas.cuenta('familia', :'venc', 'prueba', null, cuidared_interno.hoy() - 1) as cta_venc \gset
select pruebas.como(:'venc');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_envejecientes(%s)', :cta_venc), 'P0001', 'CR_CUENTA_SIN_ACCESO');
select pruebas.error(format('select pruebas.crear(%s, %L)', :cta_venc, '{"cedula":"00166666667"}'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
reset role;
rollback;
