-- pruebas-2b-cuentas.sql — Alta de cuenta, cuenta activa, configuración, suscripción/vigencia y catálogos (fase 2, 2b).
-- Se ejecuta con `node scripts/validar-propuestas-local.js --solo=2b` sobre la base local desechable.
-- © 2026 Equipo CuidaRed – INTEC.
begin;
select cuidared_interno.hoy() as hoy \gset

-- Ayudas locales de esta prueba (se descartan con el ROLLBACK).
create function pruebas.datos(p_tipo text, p_categoria int, p_cambios jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('tipo', p_tipo, 'nombre', 'Cuenta de prueba', 'categoria_cuenta_id', p_categoria,
                            'municipio_cod', '0101') || p_cambios
$$;
create function pruebas.param(p_config jsonb, p_nombre text) returns jsonb
language sql as $$ select e from jsonb_array_elements(p_config) e where e->>'nombre' = p_nombre $$;

select pruebas.usuario('fam2b@x.test', '00200000001', 'Rita') as u_fam \gset
select pruebas.usuario('org2b@x.test', '00200000002', 'Omar') as u_org \gset
select pruebas.usuario('adm2b@x.test', '00200000003', 'Ada') as u_adm \gset
select pruebas.usuario('coord2b@x.test', '00200000004', 'Carla') as u_coord \gset
select pruebas.usuario('cuid2b@x.test', '00200000005', 'Cris') as u_cuid \gset
select pruebas.usuario('vol2b@x.test', '00200000006', 'Vera') as u_vol \gset
select pruebas.usuario('famil2b@x.test', '00200000007', 'Fabio') as u_famil \gset
select pruebas.usuario('venc2b@x.test', '00200000008', 'Vero') as u_venc \gset

-- Territorio de prueba (en la base real lo carga el equipo; D14).
insert into cuidared.provincia values ('01', 'Distrito Nacional'), ('02', 'Azua') on conflict do nothing;
insert into cuidared.municipio values ('0101', 'Santo Domingo de Guzmán', '01'), ('0201', 'Azua de Compostela', '02'),
  ('0202', 'Las Charcas', '02') on conflict do nothing;
select min(c.categoria_cuenta_id) as cat_fam, max(c.categoria_cuenta_id) as cat_fam2
  from cuidared.categoria_cuenta c join cuidared.tipo_cuenta t using (tipo_cuenta_id) where t.codigo = 'familia' \gset
select min(c.categoria_cuenta_id) as cat_org, max(c.categoria_cuenta_id) as cat_org2
  from cuidared.categoria_cuenta c join cuidared.tipo_cuenta t using (tipo_cuenta_id) where t.codigo = 'organizacion' \gset
select pruebas.afirmar(:cat_fam <> :cat_fam2 and :cat_org <> :cat_org2, 'categorías sembradas por tipo');

-- Cuentas creadas fuera de la API (la cuenta org no pasa por el alta).
select pruebas.cuenta('organizacion', :'u_adm', 'activa', 'Operación Base') as cta_org \gset
select pruebas.miembro(:cta_org, :'u_coord', 'coordinador');
select pruebas.miembro(:cta_org, :'u_cuid', 'cuidador');
select pruebas.miembro(:cta_org, :'u_vol', 'voluntario');
select pruebas.miembro(:cta_org, :'u_famil', 'familiar');
select pruebas.cuenta('familia', :'u_venc', 'prueba', null, :'hoy'::date - 1) as cta_venc \gset
select pruebas.cuenta('organizacion', :'u_adm', 'activa', 'Gestión Comunitaria Avanzada') as cta_pago \gset
update cuidared.cuenta set fecha_fin_vigencia = :'hoy'::date - 1 where cuenta_id = :cta_pago;
select pruebas.cuenta('organizacion', :'u_adm', 'activa', 'Operación Base') as cta_futura \gset
update cuidared.cuenta set fecha_fin_vigencia = :'hoy'::date + 5 where cuenta_id = :cta_futura;

/* ───────────── Alta de cuenta (autorregistro del titular) ───────────── */

select pruebas.como(:'u_fam');
set local role authenticated;
select cuidared_api.api_registrar_cuenta(pruebas.datos('familia', :cat_fam,
  '{"nombre":"  Familia Pérez  ","telefono":"+18095551234","correo":"familia@x.test","direccion":"Calle 1"}'))::text as reg_fam \gset
select (:'reg_fam'::jsonb ->> 'cuenta_id')::bigint as cta_fam \gset
select pruebas.afirmar((:'reg_fam'::jsonb ->> 'rol') = 'coordinador'
  and (:'reg_fam'::jsonb ->> 'es_titular')::boolean
  and (:'reg_fam'::jsonb ->> 'acceso_operativo')::boolean
  and (:'reg_fam'::jsonb ->> 'suscripcion_estado') = 'prueba'
  and (:'reg_fam'::jsonb ->> 'tipo') = 'familia', 'alta Familia: titular coordinador con prueba vigente');
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_fam)->'permisos') ? 'usuarios:gestionar', 'el titular gestiona accesos (Familia)');
reset role;
select pruebas.afirmar((select count(*) from cuidared.cuenta
  where cuenta_id = :cta_fam and prueba_gratuita and suscripcion_estado = 'prueba' and plan_id is null
    and fecha_inicio_prueba = :'hoy'::date and fecha_fin_prueba = :'hoy'::date + 7
    and usuario_titular_id = :'u_fam' and nombre = 'Familia Pérez' and telefono = '+18095551234'
    and correo = 'familia@x.test' and direccion = 'Calle 1') = 1, 'cuenta creada: prueba de 7 días fijos, sin plan y datos normalizados');
select pruebas.afirmar((select count(*) from cuidared.membresia m join cuidared.rol r using (rol_id)
  where m.cuenta_id = :cta_fam and m.usuario_id = :'u_fam' and m.estado = 'activa' and r.codigo = 'coordinador'
    and m.fecha_inicio = :'hoy'::date) = 1, 'membresía activa del titular desde hoy');

-- Anti-abuso: una sola prueba vigente por titular (de cualquier tipo).
select pruebas.como(:'u_fam');
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s))', 'familia', :cat_fam), 'P0001', 'CR_PRUEBA_EN_CURSO');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s))', 'organizacion', :cat_org), 'P0001', 'CR_PRUEBA_EN_CURSO');

-- Validación: 22023 con datos inválidos; CR_CATEGORIA_INVALIDA si la categoría no es del tipo.
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s))', 'organizacion', :cat_fam), 'P0001', 'CR_CATEGORIA_INVALIDA');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s))', 'familia', 30000), 'P0001', 'CR_CATEGORIA_INVALIDA');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s))', 'club', :cat_fam), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) - %L)', 'familia', :cat_fam, 'nombre'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"nombre":" "}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"telefono":"123"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"telefono":"809-555-1234"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"correo":"sin-arroba"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"municipio_cod":"9999"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"municipio_cod":"ab"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"categoria_cuenta_id":"1"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"categoria_cuenta_id":1.5}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"usuario_titular_id":"x"}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam, '{"plan_id":1}'), '22023');
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s) || %L)', 'familia', :cat_fam,
  jsonb_build_object('direccion', repeat('x', 151))::text), '22023');
select pruebas.error($$select cuidared_api.api_registrar_cuenta('[]'::jsonb)$$, '22023');
select pruebas.error('select cuidared_api.api_registrar_cuenta(null)', '22023');
reset role;
select pruebas.afirmar((select count(*) from cuidared.cuenta where usuario_titular_id = :'u_fam') = 1,
  'los intentos rechazados no crean cuentas');

-- Organización: el titular es administrador.
select pruebas.como(:'u_org');
set local role authenticated;
select cuidared_api.api_registrar_cuenta(pruebas.datos('organizacion', :cat_org, '{"nombre":"Fundación Esperanza"}'))::text as reg_org \gset
select (:'reg_org'::jsonb ->> 'cuenta_id')::bigint as cta_reg_org \gset
select pruebas.afirmar((:'reg_org'::jsonb ->> 'rol') = 'administrador' and (:'reg_org'::jsonb ->> 'tipo') = 'organizacion'
  and (:'reg_org'::jsonb -> 'permisos') ? 'adultos:anonimizar', 'alta Organización: titular administrador');
select pruebas.afirmar((:'reg_org'::jsonb -> 'permisos') ? 'usuarios:gestionar', 'el administrador gestiona miembros');
select pruebas.afirmar((:'reg_org'::jsonb #>> '{limites,envejecientes}')::int = 5, 'límites de prueba de Organización');
reset role;

-- Sin sesión: 28000.
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error(format('select cuidared_api.api_registrar_cuenta(pruebas.datos(%L, %s))', 'familia', :cat_fam), '28000');
reset role;

/* ───────────── Cuenta activa: lectura y actualización ───────────── */

select pruebas.como(:'u_fam');
set local role authenticated;
select cuidared_api.api_obtener_cuenta(:cta_fam)::text as det_fam \gset
select pruebas.afirmar((:'det_fam'::jsonb #>> '{cuenta,nombre}') = 'Familia Pérez'
  and (:'det_fam'::jsonb #>> '{cuenta,tipo}') = 'familia'
  and (:'det_fam'::jsonb #>> '{cuenta,municipio,provincia}') = 'Distrito Nacional'
  and (:'det_fam'::jsonb #>> '{cuenta,categoria,categoria_cuenta_id}')::int = :cat_fam
  and (:'det_fam'::jsonb #>> '{contexto,rol}') = 'coordinador'
  and (:'det_fam'::jsonb #>> '{uso,usuarios}')::int = 1
  and (:'det_fam'::jsonb #>> '{uso,envejecientes}')::int = 0
  and (:'det_fam'::jsonb #>> '{uso,familiares}')::int = 0
  and (:'det_fam'::jsonb #>> '{contexto,limites,envejecientes}')::int = 2, 'detalle: cuenta, contexto y uso');
-- Una cuenta ajena no es visible ni editable; ids inválidos.
select pruebas.error(format('select cuidared_api.api_obtener_cuenta(%s)', :cta_org), '42501');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_org, '{"nombre":"Intrusa"}'), '42501');
select pruebas.error(format('select cuidared_api.api_obtener_configuracion(%s)', :cta_org), '42501');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"20"}'), '42501');
select pruebas.error(format('select cuidared_api.api_obtener_suscripcion(%s)', :cta_org), '42501');
select pruebas.error('select cuidared_api.api_obtener_cuenta(0)', '22023');
select pruebas.error('select cuidared_api.api_obtener_cuenta(null)', '22023');
-- El coordinador de Familia (titular) edita la cuenta: categoría del mismo tipo, municipio, vaciar campos.
select cuidared_api.api_actualizar_cuenta(:cta_fam, format('{"nombre":"Casa Pérez","municipio_cod":"0201","categoria_cuenta_id":%s,"telefono":null,"direccion":"Calle 2"}', :cat_fam2)::jsonb)::text as upd_fam \gset
select pruebas.afirmar((:'upd_fam'::jsonb #>> '{cuenta,nombre}') = 'Casa Pérez'
  and (:'upd_fam'::jsonb #>> '{cuenta,municipio,provincia}') = 'Azua'
  and (:'upd_fam'::jsonb #>> '{cuenta,categoria,categoria_cuenta_id}')::int = :cat_fam2
  and (:'upd_fam'::jsonb #>> '{cuenta,telefono}') is null
  and (:'upd_fam'::jsonb #>> '{cuenta,correo}') = 'familia@x.test'
  and (:'upd_fam'::jsonb #>> '{cuenta,direccion}') = 'Calle 2', 'actualización parcial de la cuenta');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, format('{"categoria_cuenta_id":%s}', :cat_org)), 'P0001', 'CR_CATEGORIA_INVALIDA');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"categoria_cuenta_id":30000}'), 'P0001', 'CR_CATEGORIA_INVALIDA');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"tipo":"organizacion"}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"usuario_titular_id":"00000000-0000-0000-0000-000000000000"}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"suscripcion_estado":"activa"}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"plan_id":1}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"nombre":null}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"nombre":"a"}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"municipio_cod":"9999"}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"telefono":"12"}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_fam, '{"correo":"mal"}'), '22023');
select pruebas.error('select cuidared_api.api_actualizar_cuenta(999999999, ''{"nombre":"Nada"}'')', '42501');
reset role;
select pruebas.afirmar((select count(*) from cuidared.cuenta where cuenta_id = :cta_fam and usuario_titular_id = :'u_fam'
  and plan_id is null and suscripcion_estado = 'prueba' and tipo_cuenta_id = (select tipo_cuenta_id from cuidared.tipo_cuenta where codigo = 'familia')) = 1,
  'la edición no cambia tipo, titular ni suscripción');

-- Administrador de la Organización: edita; coordinador, cuidador, voluntario y familiar solo leen.
select pruebas.como(:'u_adm');
set local role authenticated;
select cuidared_api.api_actualizar_cuenta(:cta_org, '{"nombre":"Fundación Esperanza","telefono":"8095551234"}')::text as upd_org \gset
select pruebas.afirmar((:'upd_org'::jsonb #>> '{cuenta,nombre}') = 'Fundación Esperanza' and (:'upd_org'::jsonb #>> '{contexto,rol}') = 'administrador', 'el administrador edita la organización');
reset role;
select pruebas.como(:'u_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_obtener_cuenta(:cta_org) #>> '{contexto,rol}') = 'coordinador', 'coordinador (Org) lee la cuenta');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_org, '{"nombre":"X"}'), '42501');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"20"}'), '42501');
reset role;
select pruebas.como(:'u_cuid');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_obtener_cuenta(:cta_org) #>> '{contexto,rol}') = 'cuidador', 'cuidador lee la cuenta');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_org, '{"nombre":"X"}'), '42501');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"20"}'), '42501');
reset role;
select pruebas.como(:'u_vol');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_obtener_cuenta(:cta_org) #>> '{contexto,rol}') = 'voluntario', 'voluntario lee la cuenta');
select pruebas.afirmar(jsonb_typeof(cuidared_api.api_obtener_configuracion(:cta_org)) = 'array', 'voluntario lee la configuración');
select pruebas.afirmar(jsonb_typeof(cuidared_api.api_obtener_suscripcion(:cta_org) -> 'planes') = 'null', 'voluntario no ve los planes');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_org, '{"nombre":"X"}'), '42501');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"20"}'), '42501');
reset role;
select pruebas.como(:'u_famil');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_obtener_cuenta(:cta_org) #>> '{contexto,rol}') = 'familiar', 'familiar lee la cuenta');
select pruebas.afirmar((cuidared_api.api_obtener_cuenta(:cta_org) #>> '{uso,voluntarios}')::int = 1
  and (cuidared_api.api_obtener_cuenta(:cta_org) #>> '{uso,usuarios}')::int = 4, 'el uso no cuenta voluntarios entre los usuarios');
select pruebas.error(format('select cuidared_api.api_actualizar_cuenta(%s, %L)', :cta_org, '{"nombre":"X"}'), '42501');
reset role;

/* ───────────── Configuración (RF-19) ───────────── */

select pruebas.como(:'u_adm');
set local role authenticated;
select cuidared_api.api_obtener_configuracion(:cta_org)::text as cfg0 \gset
select pruebas.afirmar(jsonb_array_length(:'cfg0'::jsonb) = 6
  and pruebas.param(:'cfg0'::jsonb, 'dias_sin_visita_alerta') ->> 'valor' = '15'
  and pruebas.param(:'cfg0'::jsonb, 'dias_sin_visita_alerta') ->> 'tipo_dato' = 'entero'
  and not (pruebas.param(:'cfg0'::jsonb, 'dias_sin_visita_alerta') ->> 'es_propio')::boolean, 'configuración efectiva: valores generales');
select cuidared_api.api_actualizar_configuracion(:cta_org,
  '{"dias_sin_visita_alerta":"30","notificar_casos_prioritarios":"false","contacto_institucional_nombre":"  Hogar Esperanza  "}')::text as cfg1 \gset
select pruebas.afirmar(pruebas.param(:'cfg1'::jsonb, 'dias_sin_visita_alerta') ->> 'valor' = '30'
  and (pruebas.param(:'cfg1'::jsonb, 'dias_sin_visita_alerta') ->> 'es_propio')::boolean
  and pruebas.param(:'cfg1'::jsonb, 'dias_sin_visita_alerta') ->> 'valor_general' = '15'
  and pruebas.param(:'cfg1'::jsonb, 'notificar_casos_prioritarios') ->> 'valor' = 'false'
  and pruebas.param(:'cfg1'::jsonb, 'contacto_institucional_nombre') ->> 'valor' = 'Hogar Esperanza'
  and not (pruebas.param(:'cfg1'::jsonb, 'dias_escalar_necesidad') ->> 'es_propio')::boolean, 'valores propios de la cuenta');
-- Dominio por tipo de dato y nombres existentes (todo o nada).
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"91"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"0"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"abc"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"1.5"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"-3"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":30}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"notificar_casos_prioritarios":"si"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"notificar_casos_prioritarios":true}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org,
  jsonb_build_object('contacto_institucional_nombre', repeat('x', 121))::text), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"parametro_inexistente":"1"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{"dias_sin_visita_alerta":"10","parametro_inexistente":"1"}'), 'P0001', 'CR_PARAMETRO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '{}'), '22023');
select pruebas.error(format('select cuidared_api.api_actualizar_configuracion(%s, %L)', :cta_org, '[]'), '22023');
select pruebas.afirmar(pruebas.param(cuidared_api.api_obtener_configuracion(:cta_org), 'dias_sin_visita_alerta') ->> 'valor' = '30',
  'un lote con error no aplica ningún valor');
-- null devuelve el valor general.
select cuidared_api.api_actualizar_configuracion(:cta_org, '{"dias_sin_visita_alerta":null}')::text as cfg2 \gset
select pruebas.afirmar(pruebas.param(:'cfg2'::jsonb, 'dias_sin_visita_alerta') ->> 'valor' = '15'
  and not (pruebas.param(:'cfg2'::jsonb, 'dias_sin_visita_alerta') ->> 'es_propio')::boolean
  and (pruebas.param(:'cfg2'::jsonb, 'notificar_casos_prioritarios') ->> 'es_propio')::boolean, 'null restablece el valor general');
reset role;
-- Aislamiento entre cuentas: lo configurado en una no cambia la otra.
select pruebas.como(:'u_fam');
set local role authenticated;
select pruebas.afirmar(pruebas.param(cuidared_api.api_obtener_configuracion(:cta_fam), 'notificar_casos_prioritarios') ->> 'valor' = 'true'
  and not (pruebas.param(cuidared_api.api_obtener_configuracion(:cta_fam), 'notificar_casos_prioritarios') ->> 'es_propio')::boolean,
  'la configuración de otra cuenta no se mezcla');
-- El coordinador de Familia (titular) también configura su cuenta.
select pruebas.afirmar(pruebas.param(cuidared_api.api_actualizar_configuracion(:cta_fam, '{"dias_escalar_necesidad":"3"}'), 'dias_escalar_necesidad') ->> 'valor' = '3',
  'el coordinador de Familia configura su cuenta');
reset role;
select pruebas.afirmar((select count(*) from cuidared.configuracion_cuenta where cuenta_id = :cta_org) = 2
  and (select count(*) from cuidared.configuracion_cuenta where cuenta_id = :cta_fam) = 1, 'filas propias por cuenta');

/* ───────────── Suscripción y vigencia (RF-20) ───────────── */

-- Prueba vigente: 7 días restantes, sin plan; el coordinador de Familia ve los planes de Familia.
select pruebas.como(:'u_fam');
set local role authenticated;
select cuidared_api.api_obtener_suscripcion(:cta_fam)::text as sus_fam \gset
select pruebas.afirmar((:'sus_fam'::jsonb ->> 'estado') = 'prueba'
  and (:'sus_fam'::jsonb ->> 'acceso_operativo')::boolean
  and (:'sus_fam'::jsonb #>> '{prueba,gratuita}')::boolean
  and (:'sus_fam'::jsonb #>> '{prueba,vigente}')::boolean
  and (:'sus_fam'::jsonb #>> '{prueba,fecha_inicio}')::date = :'hoy'::date
  and (:'sus_fam'::jsonb #>> '{prueba,fecha_fin}')::date = :'hoy'::date + 7
  and (:'sus_fam'::jsonb #>> '{prueba,dias_restantes}')::int = 7
  and jsonb_typeof(:'sus_fam'::jsonb -> 'plan') = 'null'
  and jsonb_typeof(:'sus_fam'::jsonb -> 'fecha_fin_vigencia') = 'null'
  and (:'sus_fam'::jsonb #>> '{limites,envejecientes}')::int = 2
  and (:'sus_fam'::jsonb -> 'funcionalidades') ? 'registro_visitas', 'suscripción en prueba vigente');
select pruebas.afirmar(jsonb_array_length(:'sus_fam'::jsonb -> 'planes') = 2
  and (select bool_and(p ->> 'plan_id' is not null and not (p ->> 'es_actual')::boolean and jsonb_array_length(p -> 'funcionalidades') > 0)
       from jsonb_array_elements(:'sus_fam'::jsonb -> 'planes') p), 'planes compatibles con Familia, ninguno actual');
select pruebas.afirmar(not exists (select 1 from jsonb_array_elements(:'sus_fam'::jsonb -> 'planes') p where p ->> 'nombre' in ('Operación Base', 'Gestión Comunitaria Avanzada')),
  'un plan de Organización no se ofrece a Familia');
reset role;
-- Plan activo: plan actual, límites del plan, planes de Organización; sin planes para quien no gestiona la suscripción.
select pruebas.como(:'u_adm');
set local role authenticated;
select cuidared_api.api_obtener_suscripcion(:cta_org)::text as sus_org \gset
select pruebas.afirmar((:'sus_org'::jsonb ->> 'estado') = 'activa'
  and (:'sus_org'::jsonb #>> '{plan,nombre}') = 'Operación Base'
  and not (:'sus_org'::jsonb #>> '{prueba,vigente}')::boolean
  and (:'sus_org'::jsonb #>> '{prueba,dias_restantes}')::int = 0
  and (:'sus_org'::jsonb #>> '{limites,envejecientes}')::int = 15
  and (:'sus_org'::jsonb -> 'funcionalidades') ? 'tablon_notificaciones'
  and jsonb_array_length(:'sus_org'::jsonb -> 'planes') = 2
  and (select count(*) from jsonb_array_elements(:'sus_org'::jsonb -> 'planes') p
       where (p ->> 'es_actual')::boolean and p ->> 'nombre' = 'Operación Base') = 1, 'suscripción con plan activo');
reset role;
select pruebas.como(:'u_coord');
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_obtener_suscripcion(:cta_org) ->> 'estado') = 'activa'
  and jsonb_typeof(cuidared_api.api_obtener_suscripcion(:cta_org) -> 'planes') = 'null', 'sin cuenta:suscripcion no se listan los planes');
reset role;
-- Cuenta con la prueba vencida: sin acceso operativo, pero conserva cuenta, configuración y suscripción (D07).
select pruebas.como(:'u_venc');
set local role authenticated;
select cuidared_api.api_obtener_suscripcion(:cta_venc)::text as sus_venc \gset
select pruebas.afirmar(not (:'sus_venc'::jsonb ->> 'acceso_operativo')::boolean
  and not (:'sus_venc'::jsonb #>> '{prueba,vigente}')::boolean
  and (:'sus_venc'::jsonb #>> '{prueba,dias_restantes}')::int = 0
  and jsonb_array_length(:'sus_venc'::jsonb -> 'funcionalidades') = 0
  and jsonb_array_length(:'sus_venc'::jsonb -> 'planes') = 2, 'vencida: suscripción visible y sin funcionalidades');
select pruebas.afirmar(not (cuidared_api.api_obtener_cuenta(:cta_venc) #>> '{contexto,acceso_operativo}')::boolean, 'vencida: la cuenta sigue accesible');
select pruebas.afirmar(jsonb_typeof(cuidared_api.api_obtener_configuracion(:cta_venc)) = 'array', 'vencida: la configuración sigue accesible');
select pruebas.afirmar((cuidared_api.api_actualizar_cuenta(:cta_venc, '{"direccion":"Calle 9"}') #>> '{cuenta,direccion}') = 'Calle 9', 'vencida: gestión de la cuenta permitida');
select pruebas.afirmar(pruebas.param(cuidared_api.api_actualizar_configuracion(:cta_venc, '{"dias_escalar_necesidad":"5"}'), 'dias_escalar_necesidad') ->> 'valor' = '5', 'vencida: configuración permitida');
reset role;

-- Control de vigencia: pasa a vencida lo caducado y no toca lo vigente. Idempotente y no expuesto a la API.
select pruebas.afirmar((select count(*) from cuidared.cuenta where suscripcion_estado = 'prueba' and fecha_fin_prueba < :'hoy'::date) = 1
  and (select count(*) from cuidared.cuenta where suscripcion_estado = 'activa' and fecha_fin_vigencia < :'hoy'::date) = 1,
  'hay una prueba y una suscripción caducadas sin normalizar');
select cuidared_interno.actualizar_vencimientos() as venc1 \gset
select pruebas.afirmar(:venc1 = 2, 'actualizar_vencimientos cambia solo lo caducado');
select pruebas.afirmar((select suscripcion_estado from cuidared.cuenta where cuenta_id = :cta_venc) = 'vencida'
  and (select suscripcion_estado from cuidared.cuenta where cuenta_id = :cta_pago) = 'vencida'
  and (select plan_id from cuidared.cuenta where cuenta_id = :cta_pago) is not null, 'caducadas: vencida, conservando el plan');
select pruebas.afirmar((select suscripcion_estado from cuidared.cuenta where cuenta_id = :cta_fam) = 'prueba'
  and (select suscripcion_estado from cuidared.cuenta where cuenta_id = :cta_org) = 'activa'
  and (select suscripcion_estado from cuidared.cuenta where cuenta_id = :cta_futura) = 'activa', 'las vigentes no cambian');
select pruebas.afirmar(cuidared_interno.actualizar_vencimientos() = 0, 'actualizar_vencimientos es idempotente');
select pruebas.como(:'u_venc');
set local role authenticated;
select pruebas.error('select cuidared_interno.actualizar_vencimientos()', '42501');
select pruebas.afirmar(not (cuidared_api.api_obtener_cuenta(:cta_venc) #>> '{contexto,acceso_operativo}')::boolean
  and (cuidared_api.api_obtener_suscripcion(:cta_venc) ->> 'estado') = 'vencida', 'vencida: sigue sin acceso operativo y accesible');
reset role;

/* ───────────── Catálogos (CR-165) ───────────── */

select pruebas.como(:'u_vol');
set local role authenticated;
select pruebas.afirmar((select bool_and(jsonb_typeof(cuidared_api.api_catalogo(n) -> 'items') = 'array'
                                        and (cuidared_api.api_catalogo(n) ->> 'total')::int = jsonb_array_length(cuidared_api.api_catalogo(n) -> 'items'))
  from unnest(array['provincias', 'municipios', 'tipos-cuenta', 'categorias-cuenta', 'roles', 'planes', 'tipos-cuidado',
                    'tipos-vinculo', 'prioridades', 'niveles-riesgo', 'riesgos', 'tipos-necesidad', 'necesidades',
                    'tipos-alerta', 'tipos-indicacion', 'metodos-pago']) n), 'los 16 catálogos responden con {items, total}');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('provincias') -> 'items') = 2
  and (cuidared_api.api_catalogo('provincias') #>> '{items,0,provincia_cod}') = '01', 'provincias');
select pruebas.afirmar((cuidared_api.api_catalogo('municipios') ->> 'total')::int = 3
  and (cuidared_api.api_catalogo('municipios', '{"provincia_cod":"02"}') ->> 'total')::int = 2, 'municipios filtrados por provincia');
select pruebas.afirmar((cuidared_api.api_catalogo('municipios', '{"provincia_cod":"02","limit":1,"offset":1,"sort":[{"field":"nombre","direction":"asc"}]}') #>> '{items,0,nombre}') = 'Las Charcas'
  and jsonb_array_length(cuidared_api.api_catalogo('municipios', '{"provincia_cod":"02","limit":1,"offset":1}') -> 'items') = 1
  and (cuidared_api.api_catalogo('municipios', '{"provincia_cod":"02","limit":1,"offset":1}') ->> 'total')::int = 2, 'municipios paginados con total');
select pruebas.afirmar((cuidared_api.api_catalogo('municipios', '{"sort":[{"field":"nombre","direction":"desc"}]}') #>> '{items,0,nombre}') = 'Santo Domingo de Guzmán', 'municipios en orden descendente');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('municipios', '{"offset":50}') -> 'items') = 0
  and (cuidared_api.api_catalogo('municipios', '{"offset":50}') ->> 'total')::int = 3, 'página fuera de rango: vacía con el total');
select pruebas.afirmar((select bool_and(i ->> 'tipo' = 'familia') from jsonb_array_elements(cuidared_api.api_catalogo('categorias-cuenta', '{"tipo":"familia"}') -> 'items') i)
  and jsonb_array_length(cuidared_api.api_catalogo('categorias-cuenta', '{"tipo":"familia"}') -> 'items') = 3
  and jsonb_array_length(cuidared_api.api_catalogo('categorias-cuenta') -> 'items') = 7, 'categorías por tipo de cuenta');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('tipos-cuenta') -> 'items') = 2
  and (cuidared_api.api_catalogo('tipos-cuenta') #>> '{items,0,codigo}') = 'familia', 'tipos de cuenta con código estable');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('planes', '{"tipo":"organizacion"}') -> 'items') = 2
  and jsonb_array_length(cuidared_api.api_catalogo('planes', '{"tipo":"familia"}') -> 'items') = 2
  and jsonb_array_length(cuidared_api.api_catalogo('planes') -> 'items') = 4
  and (select bool_and(jsonb_array_length(i -> 'funcionalidades') > 0 and i ? 'limites') from jsonb_array_elements(cuidared_api.api_catalogo('planes') -> 'items') i), 'planes con funcionalidades y límites');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('roles') -> 'items') = 5
  and (select i -> 'tipos' from jsonb_array_elements(cuidared_api.api_catalogo('roles') -> 'items') i where i ->> 'codigo' = 'voluntario') = '["organizacion"]'::jsonb
  and (select i -> 'tipos' from jsonb_array_elements(cuidared_api.api_catalogo('roles') -> 'items') i where i ->> 'codigo' = 'coordinador') = '["familia", "organizacion"]'::jsonb, 'roles con los tipos de cuenta que los admiten');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('tipos-vinculo') -> 'items') >= 4
  and jsonb_array_length(cuidared_api.api_catalogo('tipos-cuidado') -> 'items') >= 3, 'tipos de vínculo y de cuidado sembrados');
-- Filtros y nombres: lista cerrada.
select pruebas.error($$select cuidared_api.api_catalogo('usuarios')$$, 'P0002');
select pruebas.error($$select cuidared_api.api_catalogo('cuenta')$$, 'P0002');
select pruebas.error($$select cuidared_api.api_catalogo(null)$$, 'P0002');
select pruebas.error($$select cuidared_api.api_catalogo('planes', '{"tipo":"hogar"}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('planes', '{"foo":"x"}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('provincias', '{"limit":5}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('municipios', '{"limit":101}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('municipios', '{"limit":0}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('municipios', '{"offset":-1}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('municipios', '{"provincia_cod":"2"}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('municipios', '{"sort":[{"field":"provincia_cod","direction":"asc"}]}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('municipios', '{"sort":[{"field":"nombre; drop table x","direction":"asc"}]}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('necesidades', '{"tipo_necesidad_id":"1"}')$$, '22023');
select pruebas.error($$select cuidared_api.api_catalogo('provincias', '[]')$$, '22023');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_catalogo('necesidades', '{"tipo_necesidad_id":9999}') -> 'items') = 0, 'necesidades de un tipo sin registros');
reset role;
-- Sin sesión (401) y como anónimo (sin acceso al esquema).
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select pruebas.error($$select cuidared_api.api_catalogo('provincias')$$, '28000');
reset role;
set local role anon;
select pruebas.error($$select cuidared_api.api_catalogo('provincias')$$, '42501');
reset role;

/* ───────────── Permisos y endurecimiento de las funciones ───────────── */

select pruebas.afirmar((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
  from unnest(array[
    'cuidared_api.api_registrar_cuenta(jsonb)', 'cuidared_api.api_obtener_cuenta(bigint)',
    'cuidared_api.api_actualizar_cuenta(bigint, jsonb)', 'cuidared_api.api_obtener_configuracion(bigint)',
    'cuidared_api.api_actualizar_configuracion(bigint, jsonb)', 'cuidared_api.api_obtener_suscripcion(bigint)',
    'cuidared_api.api_catalogo(text, jsonb)']) f), 'las RPC 2b solo las ejecuta authenticated');
select pruebas.afirmar((select bool_and(not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
  from unnest(array[
    'cuidared_interno.exigir_miembro(bigint)', 'cuidared_interno.uso_de_cuenta(bigint)',
    'cuidared_interno.cuenta_detalle(bigint, uuid)', 'cuidared_interno.configuracion_efectiva(bigint)',
    'cuidared_interno.valor_parametro_valido(text, text)', 'cuidared_interno.actualizar_vencimientos()']) f), 'las ayudas internas 2b no son ejecutables por la API');
select pruebas.afirmar((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'cuidared_api'
    and p.proname in ('api_registrar_cuenta', 'api_obtener_cuenta', 'api_actualizar_cuenta', 'api_obtener_configuracion',
                      'api_actualizar_configuracion', 'api_obtener_suscripcion', 'api_catalogo')
    and p.prosecdef and p.proconfig @> array['search_path=""']) = 7, 'RPC 2b: security definer con search_path vacío');
rollback;
