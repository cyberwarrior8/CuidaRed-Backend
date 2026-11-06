-- pruebas-2a-base.sql — Contexto de cuenta, permisos por tipo, vigencia y autorregistro (fase 2, base).
-- © 2026 Equipo CuidaRed – INTEC.
begin;
select pruebas.usuario('titular.familia@x.test', '00100000001', 'Patricia') as fam_tit \gset
select pruebas.usuario('admin.org@x.test', '00100000002', 'Andrea') as org_adm \gset
select pruebas.usuario('coord.org@x.test', '00100000003', 'Laura') as org_coord \gset
select pruebas.usuario('externa@x.test', '00100000004', 'Ana') as externa \gset
select pruebas.cuenta('familia', :'fam_tit') as cta_fam \gset
select pruebas.cuenta('organizacion', :'org_adm', 'activa', 'Operación Base') as cta_org \gset
select pruebas.miembro(:cta_org, :'org_coord', 'coordinador');
select pruebas.cuenta('organizacion', :'externa', 'prueba', null, cuidared_interno.hoy() - 1) as cta_vencida \gset

-- Catálogos y matriz sembrados.
select pruebas.afirmar((select count(*) from cuidared.tipo_cuenta where codigo in ('familia', 'organizacion')) = 2, 'tipos de cuenta');
select pruebas.afirmar((select count(*) from cuidared.plan where nombre like '%Familiar' or nombre = 'Cuidado Integral') = 2, 'planes familia');
select pruebas.afirmar((select count(*) from cuidared.rol_permiso) > 100, 'matriz sembrada');

-- Autorregistro: una identidad no invitada pero confirmada tiene sesión vigente.
select pruebas.como(:'fam_tit');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_sesion('validar')->>'vigente')::boolean, 'sesión de autorregistro vigente');

-- Coordinadora de Familia: gestiona accesos (ajuste por tipo de cuenta) y está en prueba vigente.
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_fam)->>'rol') = 'coordinador', 'rol titular familia');
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_fam)->'permisos') ? 'usuarios:gestionar', 'familia: coordinador gestiona accesos');
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_fam)->>'acceso_operativo')::boolean, 'prueba vigente');
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_fam)->'funcionalidades') ? 'registro_visitas', 'funcionalidades de prueba');
select pruebas.afirmar(not ((cuidared_api.api_contexto_cuenta(:cta_fam)->'funcionalidades') ? 'reportes_avanzados'), 'sin reportes avanzados en prueba');
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_fam)->'limites'->>'envejecientes')::int = 2, 'límite de prueba familia');
-- Sin membresía en otra cuenta: null (no revela la cuenta).
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_org) is null, 'cuenta ajena oculta');
select pruebas.error('select cuidared_api.api_contexto_cuenta(0)', '22023');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_mis_cuentas()->'activas') = 1, 'mis cuentas');
reset role;

-- Coordinador de Organización: NO gestiona miembros; el administrador sí.
select pruebas.como(:'org_coord');
set local role authenticated;
select pruebas.afirmar(not ((cuidared_api.api_contexto_cuenta(:cta_org)->'permisos') ? 'usuarios:gestionar'), 'org: coordinador sin gestión de miembros');
select pruebas.error(format('select cuidared_interno.exigir(%s, %L)', :cta_org, 'usuarios:gestionar'), '42501');
reset role;
select pruebas.como(:'org_adm');
select pruebas.afirmar((cuidared_interno.exigir(:cta_org, 'usuarios:gestionar')->>'rol') = 'administrador', 'org: administrador gestiona miembros');
select pruebas.afirmar(cuidared_interno.cuenta_tiene_funcionalidad(:cta_org, 'tablon_notificaciones'), 'plan Operación Base: tablón');
select pruebas.afirmar(not cuidared_interno.cuenta_tiene_funcionalidad(:cta_org, 'org_necesidad'), 'plan Operación Base: sin Org_Necesidad');

-- Cuenta vencida: se bloquea lo operativo y se conserva la gestión de cuenta/suscripción (D07).
select pruebas.como(:'externa');
select pruebas.afirmar(not (cuidared_api.api_contexto_cuenta(:cta_vencida)->>'acceso_operativo')::boolean, 'prueba vencida sin acceso');
select pruebas.error(format('select cuidared_interno.exigir(%s, %L)', :cta_vencida, 'adultos:ver'), 'P0001', 'CR_CUENTA_SIN_ACCESO');
select pruebas.afirmar((cuidared_interno.exigir(:cta_vencida, 'cuenta:suscripcion')->>'rol') = 'administrador', 'vencida: gestiona suscripción');

-- Sin sesión: 28000.
select set_config('request.jwt.claims', '', true);
select pruebas.error(format('select cuidared_api.api_contexto_cuenta(%s)', :cta_fam), '28000');

-- Restricciones del modelo.
select pruebas.error(format('update cuidared.cuenta set suscripcion_estado = %L, plan_id = null where cuenta_id = %s', 'activa', :cta_fam), '23514');
select pruebas.error(format('update cuidared.cuenta set fecha_fin_prueba = fecha_inicio_prueba + 14 where cuenta_id = %s', :cta_fam), '23514');
select pruebas.error(format('select pruebas.miembro(%s, %L, %L)', :cta_fam, :'fam_tit', 'familiar'), '23505');
rollback;
