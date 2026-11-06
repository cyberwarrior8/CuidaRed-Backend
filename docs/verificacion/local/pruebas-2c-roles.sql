-- pruebas-2c-roles.sql — Cambio de rol, baja/reactivación, protecciones y titularidad (fase 2, bloque 2c).
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
-- Organización A: administrador titular (adm1), segundo administrador (adm2), coordinador, cuidador, familiar y voluntario.
select pruebas.usuario('adm1@x.test', '00100000201', 'Andrea', 'Uno') as adm1 \gset
select pruebas.usuario('adm2@x.test', '00100000202', 'Bruno', 'Dos') as adm2 \gset
select pruebas.usuario('coord@x.test', '00100000203', 'Carla', 'Coord') as coord \gset
select pruebas.usuario('cuid@x.test', '00100000204', 'Diego', 'Cuidador') as cuid \gset
select pruebas.usuario('fami@x.test', '00100000205', 'Elisa', 'Familiar') as fami \gset
select pruebas.usuario('volu@x.test', '00100000206', 'Felipe', 'Voluntario') as volu \gset
select pruebas.cuenta('organizacion', :'adm1', 'activa', 'Operación Base') as cta_a \gset
select pruebas.miembro(:cta_a, :'adm2', 'administrador') as m_adm2 \gset
select pruebas.miembro(:cta_a, :'coord', 'coordinador') as m_coord \gset
select pruebas.miembro(:cta_a, :'cuid', 'cuidador') as m_cuid \gset
select pruebas.miembro(:cta_a, :'fami', 'familiar') as m_fami \gset
select pruebas.miembro(:cta_a, :'volu', 'voluntario') as m_volu \gset
select pruebas.escalar_2c(format('select membresia_id from cuidared.membresia where cuenta_id = %s and usuario_id = %L', :cta_a, :'adm1')) as m_adm1 \gset
-- Organización B: el cuidador también trabaja ahí (una identidad, varias cuentas).
select pruebas.cuenta('organizacion', :'adm2', 'activa', 'Operación Base') as cta_b \gset
select pruebas.miembro(:cta_b, :'cuid', 'cuidador') as m_cuid_b \gset
-- Familia con su coordinador titular y un segundo coordinador.
select pruebas.usuario('ftit@x.test', '00100000211', 'Patricia', 'Titular') as ftit \gset
select pruebas.usuario('fcoo@x.test', '00100000212', 'Rosa', 'Coord') as fcoo \gset
select pruebas.usuario('fcui@x.test', '00100000213', 'Sergio', 'Cuidador') as fcui \gset
select pruebas.cuenta('familia', :'ftit', 'activa', 'Cuidado Integral') as cta_f \gset
select pruebas.miembro(:cta_f, :'fcoo', 'coordinador') as m_fcoo \gset
select pruebas.miembro(:cta_f, :'fcui', 'cuidador') as m_fcui \gset
select pruebas.escalar_2c(format('select membresia_id from cuidared.membresia where cuenta_id = %s and usuario_id = %L', :cta_f, :'ftit')) as m_ftit \gset

-- Adultos y vínculos de acceso del cuidador: dos en la cuenta A (uno con «referente») y uno en la cuenta B.
reset role;
-- Ayuda común: cédula única y consentimiento (si el bloque 3a está cargado).
select pruebas.envejeciente(:cta_a, 'Abuela', 'Uno', 'F');
select pruebas.envejeciente(:cta_a, 'Abuelo', 'Dos', 'M');
select pruebas.envejeciente(:cta_b, 'Abuela', 'Tres', 'F');
insert into cuidared.vinculo (envejeciente_id, usuario_id, tipo_vinculo_id)
select e.envejeciente_id, :'cuid',
       (select tipo_vinculo_id from cuidared.tipo_vinculo where codigo = case when e.nombres = 'Abuelo' then 'referente' else 'cuidador_asignado' end)
from cuidared.envejeciente e where e.cuenta_id in (:cta_a, :cta_b);
select pruebas.afirmar((select count(*) from cuidared.vinculo where usuario_id = :'cuid') = 3, 'vínculos preparados');
-- Perfil Cuidador de la persona en ambas cuentas.
insert into cuidared.cuidador (usuario_id, cuenta_id, tipo_cuidado_id, cuidador_independiente, usuario_empleador_id)
select :'cuid', c, (select tipo_cuidado_id from cuidared.tipo_cuidado order by 1 limit 1), false, :'adm1' from unnest(array[:cta_a::bigint, :cta_b::bigint]) as c;
set local role authenticated;

/* ───── Cambiar rol ───── */
select pruebas.como(:'adm1');
-- Protecciones.
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_adm1, 'coordinador'), 'P0001', 'CR_MEMBRESIA_PROPIA');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_cuid, 'voluntaria'), 'P0001', 'CR_ROL_NO_PERMITIDO');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_cuid, 'cuidador'), 'P0001', 'CR_ESTADO_INVALIDO');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_cuid, null), '22023');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, 0, %L)', :cta_a, 'familiar'), '22023');
-- La membresía de otra cuenta no existe en esta (aislamiento por cuenta).
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_cuid_b, 'familiar'), 'P0002');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_b, :m_cuid, 'familiar'), '42501'); -- adm1 no es miembro de B
-- El titular conserva un rol gestor: lo intenta otro administrador.
select pruebas.como(:'adm2');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_adm1, 'coordinador'), 'P0001', 'CR_TITULAR_PROTEGIDO');
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, %s)', :cta_a, :m_adm1), 'P0001', 'CR_TITULAR_PROTEGIDO');
-- Un administrador que no es titular sí puede pasar a otro rol mientras haya otro gestor.
select pruebas.como(:'adm1');
select cuidared_api.api_cambiar_rol_miembro(:cta_a, :m_adm2, 'coordinador') as adm2_nuevo \gset
select pruebas.afirmar((:'adm2_nuevo'::jsonb)->>'rol' = 'coordinador' and (:'adm2_nuevo'::jsonb)->>'estado' = 'activa', 'gestor no titular cambia de rol');
select pruebas.como(:'adm2');
select pruebas.error(format('select cuidared_api.api_listar_miembros(%s)', :cta_a), '42501');
select pruebas.afirmar(not ((cuidared_api.api_contexto_cuenta(:cta_a)->'permisos') ? 'usuarios:gestionar'), 'el permiso cambió con el rol');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_b)->>'rol' = 'administrador', 'sin cambios en la otra cuenta');
select pruebas.como(:'adm1');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.membresia where cuenta_id = %s and usuario_id = %L', :cta_a, :'adm2')) = '2', 'historial: membresía anterior + nueva');
select pruebas.afirmar(pruebas.escalar_2c(format('select estado || fecha_fin::text from cuidared.membresia where membresia_id = %s', :m_adm2)) = 'inactiva' || :'hoy', 'la anterior queda inactiva con fecha_fin');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_a)->>'total')::int = 6, 'el listado muestra una fila por persona');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_a, 'coordinador')->>'total' = '2', 'dos coordinadores (filtro por rol vigente)');
-- Vuelve a administrador (otro cambio sobre la membresía vigente, no sobre la histórica).
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_adm2, 'administrador'), 'P0001', 'CR_ESTADO_INVALIDO');
select ((:'adm2_nuevo'::jsonb)->>'membresia_id')::bigint as m_adm2b \gset
select cuidared_api.api_cambiar_rol_miembro(:cta_a, :m_adm2b, 'administrador')->>'membresia_id' as m_adm2c \gset
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.membresia where cuenta_id = %s and usuario_id = %L', :cta_a, :'adm2')) = '3', 'tres filas de historial');

-- Cuidador → Voluntario: se revocan los vínculos de cuidador de los adultos DE ESA CUENTA; se conservan el
-- «referente» y los de la otra cuenta. El perfil Cuidador de esa cuenta se finaliza.
select cuidared_api.api_cambiar_rol_miembro(:cta_a, :m_cuid, 'voluntario') as cuid_nuevo \gset
select pruebas.afirmar((:'cuid_nuevo'::jsonb)->>'rol' = 'voluntario', 'ahora voluntario');
select pruebas.afirmar((:'cuid_nuevo'::jsonb)->'cuidador' = 'null'::jsonb, 'sin perfil cuidador vigente en esa cuenta');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.vinculo v join cuidared.envejeciente e using (envejeciente_id) where v.usuario_id = %L and e.cuenta_id = %s', :'cuid', :cta_a)) = '1', 'solo queda el referente en la cuenta A');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.vinculo v join cuidared.envejeciente e using (envejeciente_id) where v.usuario_id = %L and e.cuenta_id = %s', :'cuid', :cta_b)) = '1', 'la cuenta B no se toca');
select pruebas.afirmar(pruebas.escalar_2c(format('select count(*) from cuidared.cuidador where usuario_id = %L and cuenta_id = %s and fecha_fin is null', :'cuid', :cta_b)) = '1', 'perfil vigente en B');
select pruebas.afirmar(pruebas.escalar_2c(format('select fecha_fin::text from cuidared.cuidador where usuario_id = %L and cuenta_id = %s', :'cuid', :cta_a)) = :'hoy', 'perfil finalizado en A');
select pruebas.como(:'cuid');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_a)->>'rol' = 'voluntario', 'el acceso usa el rol nuevo');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_b)->>'rol' = 'cuidador', 'y sigue siendo cuidador en B');
-- Rol nuevo hacia un gestor: pasa a administrador (cualquier otro rol que no sea del tipo se rechaza).
select pruebas.como(:'adm1');
select ((:'cuid_nuevo'::jsonb)->>'membresia_id')::bigint as m_cuid2 \gset
select pruebas.afirmar(cuidared_api.api_cambiar_rol_miembro(:cta_a, :m_cuid2, 'familiar')->>'rol' = 'familiar', 'voluntario → familiar');
-- Un miembro inactivo no cambia de rol: primero se reactiva.
select cuidared_api.api_desactivar_miembro(:cta_a, :m_fami);
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_fami, 'cuidador'), 'P0001', 'CR_ESTADO_INVALIDO');

-- Familia: el Coordinador gestiona miembros y el rol gestor del tipo es Coordinador.
select pruebas.como(:'fcoo');
select cuidared_api.api_cambiar_rol_miembro(:cta_f, :m_fcui, 'familiar') as fcui_nuevo \gset
select pruebas.afirmar((:'fcui_nuevo'::jsonb)->>'rol' = 'familiar', 'Familia: el Coordinador cambia roles');
select ((:'fcui_nuevo'::jsonb)->>'membresia_id')::bigint as m_fcui2 \gset
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_f, :m_fcui2, 'administrador'), 'P0001', 'CR_ROL_NO_PERMITIDO');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_f, :m_fcui, 'cuidador'), 'P0001', 'CR_ESTADO_INVALIDO'); -- membresía histórica
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_f, :m_ftit, 'cuidador'), 'P0001', 'CR_TITULAR_PROTEGIDO');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_f, :m_ftit, 'voluntario'), 'P0001', 'CR_ROL_NO_PERMITIDO');
select pruebas.como(:'ftit');
select pruebas.afirmar(cuidared_api.api_cambiar_rol_miembro(:cta_f, :m_fcoo, 'cuidador')->>'rol' = 'cuidador', 'Familia: un coordinador no titular pasa a cuidador');

/* ───── Desactivar y reactivar ───── */
select pruebas.como(:'adm1');
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, %s)', :cta_a, :m_adm1), 'P0001', 'CR_MEMBRESIA_PROPIA');
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, %s)', :cta_a, :m_cuid_b), 'P0002');
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, %s)', :cta_a, :m_fami), 'P0001', 'CR_ESTADO_INVALIDO'); -- ya inactiva
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, 0)', :cta_a), '22023');
-- Elisa estaba desactivada arriba: la baja conservó el historial y revocó el acceso.
select pruebas.afirmar(pruebas.escalar_2c(format('select estado from cuidared.membresia where membresia_id = %s', :m_fami)) = 'inactiva', 'baja = inactiva');
select pruebas.afirmar(pruebas.escalar_2c(format('select fecha_fin::text from cuidared.membresia where membresia_id = %s', :m_fami)) = :'hoy', 'baja con fecha_fin');
select pruebas.como(:'fami');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_a) is null, 'la baja revoca el acceso');
select pruebas.afirmar(jsonb_array_length(cuidared_api.api_mis_cuentas()->'activas') = 0, 'sin cuentas activas');
select pruebas.como(:'adm1');
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_a, null, 'inactiva')->>'total')::int = 1, 'aparece como inactiva en el listado');
-- Reactivar: otra membresía activa con el mismo rol; la histórica no se reutiliza.
select cuidared_api.api_reactivar_miembro(:cta_a, :m_fami) as fami_nuevo \gset
select ((:'fami_nuevo'::jsonb)->>'membresia_id')::bigint as m_fami2 \gset
select pruebas.afirmar((:'fami_nuevo'::jsonb)->>'estado' = 'activa' and (:'fami_nuevo'::jsonb)->>'rol' = 'familiar', 'reactivada con el mismo rol');
select pruebas.afirmar(:m_fami2 <> :m_fami, 'es una membresía nueva');
select pruebas.afirmar(pruebas.escalar_2c(format('select estado from cuidared.membresia where membresia_id = %s', :m_fami)) = 'inactiva', 'el historial se conserva');
select pruebas.como(:'fami');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_a)->>'rol' = 'familiar', 'recupera el acceso');
select pruebas.como(:'adm1');
select pruebas.error(format('select cuidared_api.api_reactivar_miembro(%s, %s)', :cta_a, :m_fami), 'P0001', 'CR_ESTADO_INVALIDO'); -- ya hay una vigente
select pruebas.error(format('select cuidared_api.api_reactivar_miembro(%s, %s)', :cta_a, :m_fami2), 'P0001', 'CR_ESTADO_INVALIDO'); -- activa
select pruebas.error(format('select cuidared_api.api_reactivar_miembro(%s, %s)', :cta_a, :m_adm1), 'P0001', 'CR_MEMBRESIA_PROPIA');
select pruebas.error(format('select cuidared_api.api_reactivar_miembro(%s, %s)', :cta_a, :m_cuid_b), 'P0002');
-- Cancelar una invitación pendiente = desactivarla.
select pruebas.usuario('pend@x.test', '00100000207', 'Pablo', 'Pendiente') as pend \gset
select cuidared_api.api_agregar_miembro(:cta_a, 'pend@x.test', '00100000207', 'cuidador')->>'membresia_id' as m_pend \gset
select pruebas.afirmar(cuidared_api.api_desactivar_miembro(:cta_a, :m_pend)->>'estado' = 'inactiva', 'invitación cancelada');
select pruebas.como(:'pend');
select pruebas.error(format('select cuidared_api.api_aceptar_membresia(%s)', :m_pend), 'P0001', 'CR_ESTADO_INVALIDO');
/* ───── Titularidad: solo el titular actual; el destino es otro gestor activo del tipo de cuenta ───── */
select pruebas.como(:'adm2');
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_a, :m_adm1), '42501'); -- adm2 no es el titular de A
select pruebas.como(:'adm1');
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_a, :m_adm1), 'P0001', 'CR_ESTADO_INVALIDO'); -- ya es el titular
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_a, :m_coord), 'P0001', 'CR_DESTINO_NO_GESTOR');
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_a, :m_fami), 'P0001', 'CR_ESTADO_INVALIDO'); -- membresía histórica
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_a, :m_cuid_b), 'P0002'); -- miembro de otra cuenta
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, 0)', :cta_a), '22023');
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_b, :m_cuid_b), '42501'); -- adm1 no es miembro de B
select cuidared_api.api_transferir_titularidad(:cta_a, :m_adm2c) as transf \gset
select pruebas.afirmar((:'transf'::jsonb)->>'usuario_titular_id' = :'adm2', 'titularidad transferida');
select pruebas.afirmar(pruebas.escalar_2c(format('select usuario_titular_id::text from cuidared.cuenta where cuenta_id = %s', :cta_a)) = :'adm2', 'cuenta.usuario_titular_id actualizado');
select pruebas.afirmar(cuidared_api.api_contexto_cuenta(:cta_a)->>'es_titular' = 'false', 'quien cedió ya no es titular');
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_a, :m_adm2c), '42501'); -- solo el titular actual
-- Con otro titular, quien la cedió ya puede darse de baja (antes estaba protegido) y el nuevo titular queda protegido.
select pruebas.como(:'adm2');
select pruebas.afirmar(cuidared_api.api_listar_miembros(:cta_a, 'administrador')->'items' @> jsonb_build_array(jsonb_build_object('es_titular', true)), 'el listado marca al nuevo titular');
select pruebas.afirmar(cuidared_api.api_desactivar_miembro(:cta_a, :m_adm1)->>'estado' = 'inactiva', 'el titular anterior puede desactivarse');
select pruebas.afirmar(cuidared_api.api_reactivar_miembro(:cta_a, :m_adm1)->>'estado' = 'activa', 'y reactivarse');
select pruebas.como(:'adm1');
select pruebas.error(format('select cuidared_api.api_desactivar_miembro(%s, %s)', :cta_a, :m_adm2c), 'P0001', 'CR_TITULAR_PROTEGIDO');
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_adm2c, 'coordinador'), 'P0001', 'CR_TITULAR_PROTEGIDO');
-- Familia: el destino debe ser Coordinador activo (Sergio es Familiar).
select pruebas.como(:'ftit');
select pruebas.error(format('select cuidared_api.api_transferir_titularidad(%s, %s)', :cta_f, :m_fcui2), 'P0001', 'CR_DESTINO_NO_GESTOR');
select pruebas.afirmar(pruebas.escalar_2c(format('select usuario_titular_id::text from cuidared.cuenta where cuenta_id = %s', :cta_f)) = :'ftit', 'sin cambios por los rechazos');

/* ───── Siempre queda al menos un gestor activo (comprobación interna; la API ya lo evita con el titular) ───── */
reset role;
select pruebas.error(format('select cuidared_interno.exigir_otro_gestor(%s, %L)', :cta_b, :'adm2'), 'P0001', 'CR_ULTIMO_GESTOR');
select cuidared_interno.exigir_otro_gestor(:cta_b, :'cuid');   -- adm2 sigue siendo gestor activo de B
select pruebas.error(format('select cuidared_interno.exigir_otro_gestor(%s, %L)', :cta_f, :'ftit'), 'P0001', 'CR_ULTIMO_GESTOR'); -- fcoo ya es cuidador
set local role authenticated;

/* ───── Cuenta sin plan vigente: la gestión de miembros se conserva (V2) y los límites se vuelven a comprobar ───── */
reset role;
-- Se simula la prueba de 5 usuarios y que el equipo ya la supera (rebaja de plan o de prueba).
update cuidared.cuenta set suscripcion_estado = 'prueba', plan_id = null, prueba_gratuita = true,
  fecha_inicio_prueba = :'hoy'::date, fecha_fin_prueba = :'hoy'::date + 7 where cuenta_id = :cta_a;
set local role authenticated;
select pruebas.como(:'adm2');
select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cta_a)->'limites'->>'usuarios')::int = 5, 'límite de prueba');
select pruebas.usuario('r1@x.test', '00100000221', 'R', 'Uno') as r1 \gset
select pruebas.usuario('r2@x.test', '00100000222', 'R', 'Dos') as r2 \gset
select pruebas.usuario('r3@x.test', '00100000223', 'R', 'Tres') as r3 \gset
select pruebas.miembro(:cta_a, :'r1', 'cuidador');
select pruebas.miembro(:cta_a, :'r2', 'cuidador');
select pruebas.miembro(:cta_a, :'r3', 'cuidador');
select pruebas.error(format('select cuidared_api.api_reactivar_miembro(%s, %s)', :cta_a, :m_fami2), 'P0001', 'CR_ESTADO_INVALIDO'); -- ya activa
select cuidared_api.api_desactivar_miembro(:cta_a, :m_fami2);
select pruebas.error(format('select cuidared_api.api_reactivar_miembro(%s, %s)', :cta_a, :m_fami2), 'P0001', 'CR_LIMITE_PLAN');
-- Voluntario → usuario necesita cupo; Coordinador → Cuidador no aumenta el uso y se permite aunque la cuenta esté llena.
select pruebas.error(format('select cuidared_api.api_cambiar_rol_miembro(%s, %s, %L)', :cta_a, :m_volu, 'cuidador'), 'P0001', 'CR_LIMITE_PLAN');
select pruebas.afirmar(cuidared_api.api_cambiar_rol_miembro(:cta_a, :m_coord, 'cuidador')->>'rol' = 'cuidador', 'coordinador → cuidador no aumenta el uso');
-- Con la cuenta vencida (sin prueba ni plan) solo se conserva cuenta y suscripción: miembros sí, perfiles Cuidador no.
reset role;
update cuidared.cuenta set fecha_inicio_prueba = :'hoy'::date - 8, fecha_fin_prueba = :'hoy'::date - 1 where cuenta_id = :cta_a;
set local role authenticated;
select pruebas.afirmar((cuidared_api.api_listar_miembros(:cta_a)->>'total')::int > 0, 'vencida: se siguen gestionando los miembros');
select pruebas.error(format('select cuidared_api.api_obtener_cuidador_miembro(%s, %s)', :cta_a, :m_coord), 'P0001', 'CR_CUENTA_SIN_ACCESO');
rollback;
