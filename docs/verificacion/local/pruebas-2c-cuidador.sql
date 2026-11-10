-- pruebas-2c-cuidador.sql — Perfil Cuidador por cuenta, RF-12 (fase 2, bloque 2c).
-- Requiere docs/propuestas/fase-2c-miembros.sql. Todo dentro de una transacción con ROLLBACK.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

create function pruebas.escalar_2c(p_sql text) returns text
language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  execute p_sql into v;
  return v;
end $$;
grant execute on function pruebas.escalar_2c(text) to authenticated;

select cuidared_interno.hoy() as hoy \gset
select tipo_cuidado_id as tipo1 from cuidared.tipo_cuidado order by tipo_cuidado_id limit 1 \gset
select tipo_cuidado_id as tipo2 from cuidared.tipo_cuidado order by tipo_cuidado_id desc limit 1 \gset
-- Organización A: administrador titular, coordinador, cuidador, familiar. Organización B: el mismo cuidador.
select pruebas.usuario('adm@x.test', '00100000301', 'Andrea', 'Admin') as adm \gset
select pruebas.usuario('coo@x.test', '00100000302', 'Carla', 'Coord') as coo \gset
select pruebas.usuario('cui@x.test', '00100000303', 'Diego', 'Cuidador') as cui \gset
select pruebas.usuario('fam@x.test', '00100000304', 'Elisa', 'Familiar') as fam \gset
select pruebas.usuario('admb@x.test', '00100000305', 'Beto', 'AdminB') as admb \gset
select pruebas.cuenta('organizacion', :'adm', 'activa', 'Operación Base') as cta_a \gset
select pruebas.miembro(:cta_a, :'coo', 'coordinador') as m_coo \gset
select pruebas.miembro(:cta_a, :'cui', 'cuidador') as m_cui \gset
select pruebas.miembro(:cta_a, :'fam', 'familiar') as m_fam \gset
select pruebas.cuenta('organizacion', :'admb', 'activa', 'Operación Base') as cta_b \gset
select pruebas.miembro(:cta_b, :'cui', 'cuidador') as m_cui_b \gset
-- Familia: coordinador titular, segundo coordinador y cuidador.
select pruebas.usuario('ftit@x.test', '00100000311', 'Patricia', 'Titular') as ftit \gset
select pruebas.usuario('fcoo@x.test', '00100000312', 'Rosa', 'Coord') as fcoo \gset
select pruebas.usuario('fcui@x.test', '00100000313', 'Sergio', 'Cuidador') as fcui \gset
select pruebas.cuenta('familia', :'ftit', 'activa', 'Cuidado Integral') as cta_f \gset
select pruebas.miembro(:cta_f, :'fcoo', 'coordinador') as m_fcoo \gset
select pruebas.miembro(:cta_f, :'fcui', 'cuidador') as m_fcui \gset

set local role authenticated;

/* ───── Permiso cuidadores:gestionar: Administrador (Organización) y Coordinador (Familia) ───── */
select pruebas.como(:'coo');
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_a, :m_cui), '42501');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, false)', :cta_a, :m_cui, :tipo1), '42501');
select pruebas.error(format('select cuidared_api.api_finalizar_cuidador_miembro(%s, %s)', :cta_a, :m_cui), '42501');
select pruebas.como(:'cui');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, true)', :cta_a, :m_cui, :tipo1), '42501');
select pruebas.como(:'fam');
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_a, :m_cui), '42501');
select set_config('request.jwt.claims', '', true);
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_a, :m_cui), '28000');

/* ───── Crear y actualizar el perfil vigente ───── */
select pruebas.como(:'adm');
select pruebas.afirmar(cuidared_api.api_obtener_cuidador_miembro(:cta_a, :m_cui) is null, 'sin perfil todavía (null)');
select cuidared_api.api_guardar_cuidador_miembro(:cta_a, :m_cui, :tipo1::smallint, false) as perfil \gset
select pruebas.afirmar((:'perfil'::jsonb)->>'tipo_cuidado_id' = :'tipo1', 'tipo de cuidado');
select pruebas.afirmar(not ((:'perfil'::jsonb)->>'cuidador_independiente')::boolean, 'no independiente');
select pruebas.afirmar((:'perfil'::jsonb)->>'usuario_empleador_id' = :'adm', 'el empleador es el titular de la cuenta');
select pruebas.afirmar((:'perfil'::jsonb)->>'fecha_inicio' = :'hoy', 'fecha_inicio = hoy de negocio');
select pruebas.afirmar((:'perfil'::jsonb) ?& array['cuidador_id', 'tipo_cuidado', 'tipo_cuidado_id', 'cuidador_independiente', 'usuario_empleador_id', 'fecha_inicio'], 'forma del perfil');
select pruebas.afirmar(cuidared_api.api_obtener_cuidador_miembro(:cta_a, :m_cui) = (:'perfil'::jsonb), 'GET devuelve el perfil vigente');
select pruebas.afirmar(cuidared_api.api_detalle_miembro(:cta_a, :m_cui)->'cuidador' = (:'perfil'::jsonb), 'el detalle de miembro incluye el perfil');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_a, 'cuidador')->'items'->0->'cuidador' = (:'perfil'::jsonb), 'el listado incluye el perfil');
-- Upsert: no se duplica el perfil vigente.
select cuidared_api.api_guardar_cuidador_miembro(:cta_a, :m_cui, :tipo2::smallint, true) as perfil2 \gset
select pruebas.afirmar((:'perfil2'::jsonb)->>'cuidador_id' = (:'perfil'::jsonb)->>'cuidador_id', 'mismo perfil (upsert)');
select pruebas.afirmar((:'perfil2'::jsonb)->>'tipo_cuidado_id' = :'tipo2', 'tipo actualizado');
select pruebas.afirmar((:'perfil2'::jsonb)->>'cuidador_independiente' = 'true' and (:'perfil2'::jsonb)->'usuario_empleador_id' = 'null'::jsonb, 'independiente: sin empleador');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.cuidador where usuario_id = %L and cuenta_id = %s', :'cui', :cta_a)) = '1', 'un solo perfil');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.cuidador where usuario_id = %L and cuenta_id = %s', :'cui', :cta_b)) = '0', 'sin perfil en la otra cuenta');

/* ───── Validaciones ───── */
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, false)', :cta_a, :m_fam, :tipo1), 'P0001', 'CR_NO_ES_CUIDADOR');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, false)', :cta_a, :m_coo, :tipo1), 'P0001', 'CR_NO_ES_CUIDADOR');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, 9999::smallint, false)', :cta_a, :m_cui), '22023');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, null, false)', :cta_a, :m_cui), '22023');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, null)', :cta_a, :m_cui, :tipo1), '22023');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, 0, %s::smallint, false)', :cta_a, :tipo1), '22023');
-- Aislamiento: la membresía de otra cuenta no existe en esta, y una cuenta ajena no se gestiona.
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, false)', :cta_a, :m_cui_b, :tipo1), 'P0002');
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_a, :m_cui_b), 'P0002');
select pruebas.error(format('select cuidared_api.api_finalizar_cuidador_miembro(%s, %s)', :cta_a, :m_cui_b), 'P0002');
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, false)', :cta_b, :m_cui_b, :tipo1), '42501');

/* ───── Un perfil por persona y cuenta ───── */
select pruebas.como(:'admb');
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_b, :m_cui), 'P0002');
select cuidared_api.api_guardar_cuidador_miembro(:cta_b, :m_cui_b, :tipo1::smallint, false) as perfil_b \gset
select pruebas.afirmar((:'perfil_b'::jsonb)->>'cuidador_id' <> (:'perfil2'::jsonb)->>'cuidador_id', 'perfil propio en la cuenta B');
select pruebas.afirmar((:'perfil_b'::jsonb)->>'usuario_empleador_id' = :'admb', 'el empleador de B es el titular de B');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.cuidador where usuario_id = %L and fecha_fin is null', :'cui')) = '2', 'vigente en dos cuentas a la vez');
reset role;
select pruebas.error(format('insert into cuidared.cuidador (usuario_id, cuenta_id, tipo_cuidado_id) values (%L, %s, %s)', :'cui', :cta_a, :tipo1), '23505');
set local role authenticated;

/* ───── Finalizar ───── */
select pruebas.como(:'adm');
select cuidared_api.api_finalizar_cuidador_miembro(:cta_a, :m_cui) as fin \gset
select pruebas.afirmar((:'fin'::jsonb)->'cuidador' = 'null'::jsonb and (:'fin'::jsonb)->>'rol' = 'cuidador', 'ya no hay perfil vigente');
select pruebas.afirmar(pruebas.escalar_2c(format('select fecha_fin::text from cuidared.cuidador where cuidador_id = %s', (:'perfil'::jsonb)->>'cuidador_id')) = :'hoy', 'fecha_fin = hoy');
select pruebas.afirmar(cuidared_api.api_obtener_cuidador_miembro(:cta_a, :m_cui) is null, 'GET sin perfil vigente');
select pruebas.error(format('select cuidared_api.api_finalizar_cuidador_miembro(%s, %s)', :cta_a, :m_cui), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_finalizar_cuidador_miembro(%s, %s)', :cta_a, :m_fam), 'P0001', 'CR_ESTADO_INVALIDO');
-- El perfil de la otra cuenta sigue vigente. Se puede registrar uno nuevo y el historial se conserva.
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.cuidador where usuario_id = %L and cuenta_id = %s and fecha_fin is null', :'cui', :cta_b)) = '1', 'B sigue vigente');
select cuidared_api.api_guardar_cuidador_miembro(:cta_a, :m_cui, :tipo1::smallint, false) as perfil3 \gset
select pruebas.afirmar((:'perfil3'::jsonb)->>'cuidador_id' <> (:'perfil'::jsonb)->>'cuidador_id', 'perfil nuevo tras finalizar');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.cuidador where usuario_id = %L and cuenta_id = %s', :'cui', :cta_a)) = '2', 'historial: perfil anterior + nuevo');

/* ───── Una membresía inactiva no recibe perfil; una pendiente sí ───── */
select cuidared_api.api_desactivar_miembro(:cta_a, :m_cui);
select pruebas.error(format('select cuidared_api.api_guardar_cuidador_miembro(%s, %s, %s::smallint, false)', :cta_a, :m_cui, :tipo1), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.usuario('pend@x.test', '00100000306', 'Pablo', 'Pendiente') as pend \gset
select cuidared_api.api_agregar_miembro(:cta_a, 'pend@x.test', '00100000306', 'cuidador')->>'membresia_id' as m_pend \gset
select pruebas.afirmar(cuidared_api.api_guardar_cuidador_miembro(:cta_a, :m_pend, :tipo1::smallint, true)->>'cuidador_independiente' = 'true', 'perfil para un cuidador pendiente');

/* ───── Familia: el Coordinador (no el Administrador) gestiona cuidadores; el empleador es el titular ───── */
select pruebas.como(:'fcoo');
select cuidared_api.api_guardar_cuidador_miembro(:cta_f, :m_fcui, :tipo1::smallint, false) as perfil_f \gset
select pruebas.afirmar((:'perfil_f'::jsonb)->>'usuario_empleador_id' = :'ftit', 'Familia: empleador = titular aunque lo registre otro coordinador');
select pruebas.como(:'fcui');
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_f, :m_fcui), '42501');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_f)->>'rol' = 'cuidador', 'rol cuidador en Familia');
select pruebas.como(:'ftit');
select pruebas.afirmar(cuidared_api.api_finalizar_cuidador_miembro(:cta_f, :m_fcui)->'cuidador' = 'null'::jsonb, 'Familia: el titular finaliza el perfil');
rollback;
