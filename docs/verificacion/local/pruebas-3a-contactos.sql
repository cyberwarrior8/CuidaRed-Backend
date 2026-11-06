-- pruebas-3a-contactos.sql — Contactos de emergencia (fase 3, bloque 3a, RF-17).
-- Exactamente un principal por adulto, hasta 5 contactos, cambio atómico del principal, eliminación que no deja al
-- adulto sin contactos ni sin principal, alcance de lectura por rol y aislamiento entre cuentas.
-- Las asignaciones se insertan en cuidared.vinculo como superusuario (las construye el bloque 3b). © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('co.coord@x.test', '00100000401', 'Patricia') as coord \gset
select pruebas.usuario('co.cuid@x.test', '00100000402') as cuid \gset
select pruebas.usuario('co.cuid2@x.test', '00100000403') as cuid2 \gset
select pruebas.usuario('co.fami@x.test', '00100000404') as fami \gset
select pruebas.usuario('co.adm@x.test', '00100000405', 'Andrea') as adm \gset
select pruebas.usuario('co.vol@x.test', '00100000406') as vol \gset
select pruebas.usuario('co.otra@x.test', '00100000407') as otra \gset
select pruebas.cuenta('familia', :'coord') as cta \gset
select pruebas.miembro(:cta, :'cuid', 'cuidador');
select pruebas.miembro(:cta, :'cuid2', 'cuidador');
select pruebas.miembro(:cta, :'fami', 'familiar');
select pruebas.cuenta('organizacion', :'adm', 'activa', 'Gestión Comunitaria Avanzada') as cta_org \gset
select pruebas.miembro(:cta_org, :'vol', 'voluntario');
select pruebas.cuenta('familia', :'otra') as cta_otra \gset

create function pruebas.datos(p_cedula text) returns jsonb language sql as $$
  select jsonb_build_object('nombres', 'Rosa', 'apellidos', 'Pena', 'cedula', p_cedula, 'fecha_nacimiento', '1950-03-15',
    'sexo', 'F', 'municipio_cod', '0101', 'zona', 'Centro', 'autonomia', 'parcial',
    'consentimiento', jsonb_build_object('otorgado', true, 'otorgado_por', 'adulto'),
    'contactos', jsonb_build_array(jsonb_build_object('nombres', 'Luis', 'apellidos', 'Pena', 'parentesco', 'Hijo/a',
                                                      'telefono', '8295550101', 'es_principal', true)))
$$;
create function pruebas.contacto(p_nombres text, p_principal boolean default false) returns jsonb language sql as $$
  select jsonb_build_object('nombres', p_nombres, 'apellidos', 'Abreu', 'parentesco', 'Amigo/a', 'telefono', '809 555 0199',
                            'es_principal', p_principal)
$$;
-- Número de principales y de contactos de un adulto (como superusuario).
create function pruebas.principales(p_adulto uuid) returns integer language sql security definer set search_path = '' as $$
  select count(*)::integer from cuidared.contacto_emergencia where envejeciente_id = p_adulto and es_principal
$$;
create function pruebas.total(p_adulto uuid) returns integer language sql security definer set search_path = '' as $$
  select count(*)::integer from cuidared.contacto_emergencia where envejeciente_id = p_adulto
$$;

select pruebas.como(:'coord');
set local role authenticated;
select (cuidared_api.api_crear_envejeciente(:cta, pruebas.datos('00100000011'))->>'envejeciente_id')::uuid as a1 \gset
select (cuidared_api.api_crear_envejeciente(:cta, pruebas.datos('00100000012'))->>'envejeciente_id')::uuid as a2 \gset
select (cuidared_api.api_listar_contactos(:cta, :'a1')->0->>'contacto_id')::bigint as c_luis \gset
reset role;
select pruebas.como(:'otra');
set local role authenticated;
select (cuidared_api.api_crear_envejeciente(:cta_otra, pruebas.datos('00100000013'))->>'envejeciente_id')::uuid as a_otra \gset
select (cuidared_api.api_listar_contactos(:cta_otra, :'a_otra')->0->>'contacto_id')::bigint as c_otra \gset
reset role;
select pruebas.como(:'adm');
set local role authenticated;
select (cuidared_api.api_crear_envejeciente(:cta_org, pruebas.datos('00100000014'))->>'envejeciente_id')::uuid as o1 \gset
reset role;
-- Asignaciones: el cuidador 1 a a1; el voluntario al adulto de la organización; el familiar a a1.
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'a1', :'cuid', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'cuidador_asignado';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'a1', :'fami', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'familiar_responsable';
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
  select :'o1', :'vol', tipo_vinculo_id from cuidared.tipo_vinculo where codigo = 'voluntario_asignado';

/* ───────────── Alta, lectura y principal ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_contactos(:cta, :'a1')) = 1, 'un contacto inicial');
select pruebas.afirmar((cuidared_api.api_listar_contactos(:cta, :'a1')->0->>'es_principal') = 'true', 'el inicial es el principal');
-- Alta de un contacto no principal: normaliza el teléfono y conserva al principal.
select cuidared_api.api_crear_contacto(:cta, :'a1', pruebas.contacto('Eva')) as c2 \gset
select pruebas.afirmar((:'c2'::jsonb->>'telefono') = '8095550199', 'teléfono sin espacios');
select pruebas.afirmar((:'c2'::jsonb->>'es_principal') = 'false', 'no principal');
select pruebas.afirmar((:'c2'::jsonb->>'envejeciente_id') = :'a1', 'pertenece al adulto');
select pruebas.afirmar(pruebas.principales(:'a1') = 1 and pruebas.total(:'a1') = 2, 'sigue habiendo un solo principal');
-- Alta de un contacto principal: reemplaza al anterior de forma atómica.
select cuidared_api.api_crear_contacto(:cta, :'a1', pruebas.contacto('Raul', true)) as c3 \gset
select pruebas.afirmar((:'c3'::jsonb->>'es_principal') = 'true', 'nuevo principal');
select pruebas.afirmar(pruebas.principales(:'a1') = 1 and pruebas.total(:'a1') = 3, 'un único principal tras el reemplazo');
select pruebas.afirmar((cuidared_api.api_listar_contactos(:cta, :'a1')->0->>'nombres') = 'Raul', 'el principal va primero');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta, :'a1')->'contacto_principal'->>'nombres') = 'Raul', 'el perfil expone el nuevo principal');
-- Cambiar el principal a otro contacto existente.
select pruebas.afirmar((cuidared_api.api_principal_contacto(:cta, :c_luis)->>'es_principal') = 'true', 'Luis vuelve a ser principal');
select pruebas.afirmar(pruebas.principales(:'a1') = 1, 'un único principal tras el cambio');
select pruebas.afirmar((cuidared_api.api_ver_envejeciente(:cta, :'a1')->'contacto_principal'->>'nombres') = 'Luis', 'principal cambiado');
-- Idempotente si ya es el principal.
select pruebas.afirmar((cuidared_api.api_principal_contacto(:cta, :c_luis)->>'es_principal') = 'true', 'idempotente');
select pruebas.afirmar(pruebas.principales(:'a1') = 1, 'idempotente: un solo principal');

-- Tope de 5 contactos por adulto.
select cuidared_api.api_crear_contacto(:cta, :'a1', pruebas.contacto('Cuarto'));
select cuidared_api.api_crear_contacto(:cta, :'a1', pruebas.contacto('Quinto'));
select pruebas.afirmar(pruebas.total(:'a1') = 5, 'cinco contactos');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a1', pruebas.contacto('Sexto')), 'P0001', 'CR_LIMITE_CONTACTOS');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a1', pruebas.contacto('Sexto', true)), 'P0001', 'CR_LIMITE_CONTACTOS');
select pruebas.afirmar(pruebas.total(:'a1') = 5 and pruebas.principales(:'a1') = 1, 'el rechazo no cambia nada');

-- Entradas inválidas (22023).
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2', '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2', '{"nombres":"Eva"}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2',
  '{"nombres":"Eva","apellidos":"Abreu","parentesco":"Amigo/a","telefono":"123"}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2',
  '{"nombres":"Eva 2","apellidos":"Abreu","parentesco":"Amigo/a","telefono":"8095550199"}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2',
  '{"nombres":"Eva","apellidos":"Abreu","parentesco":"","telefono":"8095550199"}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2',
  '{"nombres":"Eva","apellidos":"Abreu","parentesco":"Amigo/a","telefono":"8095550199","es_principal":"si"}'), '22023');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a2',
  '{"nombres":"Eva","apellidos":"Abreu","parentesco":"Amigo/a","telefono":"8095550199","envejeciente_id":"x"}'), '22023');
select pruebas.afirmar(pruebas.total(:'a2') = 1, 'las altas inválidas no crean contactos');

-- Edición parcial; el principal no se cambia por aquí.
select pruebas.afirmar((cuidared_api.api_editar_contacto(:cta, :c_luis, '{"telefono":"829-555-0102","parentesco":"Esposo/a"}')->>'telefono') = '8295550102', 'edita teléfono');
select pruebas.afirmar((cuidared_api.api_editar_contacto(:cta, :c_luis, '{"nombres":"Luis Alberto"}')->>'parentesco') = 'Esposo/a', 'lo no enviado no cambia');
select pruebas.afirmar((cuidared_api.api_editar_contacto(:cta, :c_luis, '{"nombres":"Luis"}')->>'es_principal') = 'true', 'sigue siendo el principal');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, :c_luis, '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, :c_luis, '{"es_principal":false}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, :c_luis, '{"telefono":"12"}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, :c_luis, '{"envejeciente_id":"x"}'), '22023');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, 999999, '{"nombres":"Eva"}'), 'P0002');
select pruebas.error(format('select cuidared_api.api_principal_contacto(%s, %L)', :cta, 999999), 'P0002');
select pruebas.error(format('select cuidared_api.api_eliminar_contacto(%s, %L)', :cta, 999999), 'P0002');

/* ───────────── Eliminación ───────────── */
-- No se elimina el principal mientras haya otros: hay que designar antes otro.
select pruebas.error(format('select cuidared_api.api_eliminar_contacto(%s, %L)', :cta, :c_luis), 'P0001', 'CR_CONTACTO_PRINCIPAL');
select pruebas.afirmar(pruebas.total(:'a1') = 5 and pruebas.principales(:'a1') = 1, 'el principal sigue ahí');
select (cuidared_api.api_listar_contactos(:cta, :'a1')->1->>'contacto_id')::bigint as c_otro \gset
select pruebas.afirmar((cuidared_api.api_eliminar_contacto(:cta, :c_otro)->>'eliminado') = 'true', 'elimina un contacto no principal');
select pruebas.afirmar(pruebas.total(:'a1') = 4 and pruebas.principales(:'a1') = 1, 'cuatro contactos y un principal');
-- Se puede eliminar al principal anterior después de designar otro.
select cuidared_api.api_listar_contactos(:cta, :'a1') as lista \gset
select (:'lista'::jsonb->1->>'contacto_id')::bigint as c_nuevo \gset
select cuidared_api.api_principal_contacto(:cta, :c_nuevo);
select pruebas.afirmar((cuidared_api.api_eliminar_contacto(:cta, :c_luis)->>'eliminado') = 'true', 'elimina al principal anterior');
select pruebas.afirmar(pruebas.total(:'a1') = 3 and pruebas.principales(:'a1') = 1, 'tres contactos y un principal');
-- Un adulto nunca queda sin contactos: el último no se elimina.
select (cuidared_api.api_listar_contactos(:cta, :'a2')->0->>'contacto_id')::bigint as c_unico \gset
select pruebas.error(format('select cuidared_api.api_eliminar_contacto(%s, %L)', :cta, :c_unico), 'P0001', 'CR_ULTIMO_CONTACTO');
select pruebas.afirmar(pruebas.total(:'a2') = 1 and pruebas.principales(:'a2') = 1, 'el último contacto sigue ahí');
reset role;

/* ───────────── Alcance de lectura y permisos de escritura ───────────── */
-- Cuidador asignado: consulta los contactos de su adulto, no los de otro, y no edita.
select pruebas.como(:'cuid');
set local role authenticated;
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_contactos(:cta, :'a1')) = 3, 'cuidador asignado ve los contactos');
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta, :'a2'), 'P0002');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a1', pruebas.contacto('Intruso')), '42501');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, :c_nuevo, '{"nombres":"Hack"}'), '42501');
select pruebas.error(format('select cuidared_api.api_principal_contacto(%s, %L)', :cta, :c_nuevo), '42501');
select pruebas.error(format('select cuidared_api.api_eliminar_contacto(%s, %L)', :cta, :c_nuevo), '42501');
reset role;
-- Cuidador sin asignación: no ve a nadie.
select pruebas.como(:'cuid2');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta, :'a1'), 'P0002');
reset role;
-- Familiar autorizado: consulta los contactos, no los modifica.
select pruebas.como(:'fami');
set local role authenticated;
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_contactos(:cta, :'a1')) = 3, 'familiar autorizado ve los contactos');
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta, :'a2'), 'P0002');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a1', pruebas.contacto('Intruso')), '42501');
select pruebas.error(format('select cuidared_api.api_eliminar_contacto(%s, %L)', :cta, :c_nuevo), '42501');
reset role;
-- Voluntario: solo el contacto principal de su adulto (datos mínimos), sin escribir.
select pruebas.como(:'adm');
set local role authenticated;
select cuidared_api.api_crear_contacto(:cta_org, :'o1', pruebas.contacto('Segundo'));
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_contactos(:cta_org, :'o1')) = 2, 'el administrador ve los dos contactos');
reset role;
select pruebas.como(:'vol');
set local role authenticated;
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_listar_contactos(:cta_org, :'o1')) = 1, 'voluntario: solo un contacto');
select pruebas.afirmar((cuidared_api.api_listar_contactos(:cta_org, :'o1')->0->>'es_principal') = 'true', 'voluntario: el principal');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta_org, :'o1', pruebas.contacto('Intruso')), '42501');
reset role;

/* ───────────── Aislamiento entre cuentas ───────────── */
select pruebas.como(:'coord');
set local role authenticated;
-- Contactos de un adulto de otra cuenta, a través de la propia cuenta: igual que inexistentes.
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta, :'a_otra'), 'P0002');
select pruebas.error(format('select cuidared_api.api_crear_contacto(%s, %L, %L)', :cta, :'a_otra', pruebas.contacto('Intruso')), 'P0002');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta, :c_otra, '{"nombres":"Hack"}'), 'P0002');
select pruebas.error(format('select cuidared_api.api_principal_contacto(%s, %L)', :cta, :c_otra), 'P0002');
select pruebas.error(format('select cuidared_api.api_eliminar_contacto(%s, %L)', :cta, :c_otra), 'P0002');
-- Y a través de la cuenta ajena, sin membresía: 42501.
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta_otra, :'a_otra'), '42501');
select pruebas.error(format('select cuidared_api.api_editar_contacto(%s, %L, %L)', :cta_otra, :c_otra, '{"nombres":"Hack"}'), '42501');
reset role;
select pruebas.afirmar(pruebas.total(:'a_otra') = 1, 'los contactos ajenos no cambiaron');
select pruebas.afirmar((select nombres from cuidared.contacto_emergencia where contacto_emergencia_id = :c_otra) = 'Luis', 'el contacto ajeno no cambió');
-- Sin sesión.
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_listar_contactos(%s, %L)', :cta, :'a1'), '28000');
reset role;
rollback;
