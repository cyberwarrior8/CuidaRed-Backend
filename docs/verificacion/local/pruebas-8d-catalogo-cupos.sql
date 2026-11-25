-- Datos sintéticos para verificar el catálogo de planes y el cupo de cuidadores.
begin;
do $$
declare
  v_titular uuid := pruebas.usuario('catalogo-titular@example.test', '00885100001');
  v_admin uuid := pruebas.usuario('catalogo-admin@example.test', '00885100002');
  v_sesion uuid := pruebas.como(v_admin);
  v_cuenta bigint := pruebas.cuenta('familia', v_titular);
  v_plan smallint := (select plan_id from cuidared.plan where nombre = 'Básico Familiar');
  v_pendiente bigint;
  v_cuidador uuid;
  v_catalogo jsonb;
  v_limites jsonb;
begin
  perform pruebas.como(v_titular);
  v_catalogo := cuidared_api.api_stripe_catalogo_cuenta(v_cuenta);
  perform pruebas.afirmar(v_catalogo @> '[{"codigo":"basico_familiar","limites":{"cuidadores":5},"precios_referencia":{"mensual":900,"anual":9000}}]',
    'el catálogo de Familia incluye el cupo y las referencias sin precio publicado');
  perform pruebas.afirmar(v_catalogo @> '[{"codigo":"cuidado_integral","limites":{"cuidadores":null}}]',
    'Cuidado Integral conserva cuidadores ilimitados');
  perform pruebas.afirmar(not (v_catalogo @> '[{"codigo":"operacion_base"}]'),
    'el catálogo se limita al tipo de la cuenta');
  perform pruebas.afirmar(not (v_catalogo @> '[{"funcionalidades":["visitas_recurrentes"]}]'),
    'el catálogo familiar respeta la restricción del módulo de Visitas');
  perform pruebas.como(v_admin);
  perform pruebas.error(format('select cuidared_api.api_stripe_catalogo_cuenta(%s)',v_cuenta),'42501');
  insert into cuidared.usuario_backoffice(usuario_id, rol) values (v_admin,'super_admin');
  perform cuidared_api.api_bo_admitir(v_admin,v_sesion,null,null);
  perform cuidared_api.api_bo_sesion(v_admin,v_sesion,'aal2','ingreso',null,null);
  perform pruebas.afirmar(cuidared_api.api_bo_leer(v_admin,v_sesion,'aal2','planes','{}') @>
    jsonb_build_array(jsonb_build_object('plan_id',v_plan,'limite_cuidadores',5,'cuidadores_editable',true)),
    'Backoffice carga el cupo efectivo y distingue el plan que se puede editar');

  for i in 1..5 loop
    v_cuidador := pruebas.usuario('catalogo-cuidador-'||i||'@example.test','0088511000'||i);
    perform pruebas.miembro(v_cuenta,v_cuidador,'cuidador');
  end loop;
  v_cuidador := pruebas.usuario('catalogo-cuidador-6@example.test','00885110006');
  v_pendiente := pruebas.miembro(v_cuenta,v_cuidador,'cuidador','pendiente');
  perform pruebas.error(format('update cuidared.membresia set estado=%L where membresia_id=%s','activa',v_pendiente),
    'P0001','CR_LIMITE_PLAN');
  perform pruebas.afirmar((cuidared_interno.uso_miembros(v_cuenta)->>'cuidadores')::int = 5,
    'la invitación pendiente y el coordinador no consumen el cupo de cuidadores');

  v_limites := jsonb_build_object('id',v_plan,'adultos',2,'usuarios',null,'cuidadores',4);
  perform pruebas.error(format('select cuidared_api.api_bo_mutar(%L,%L,%L,%L,%L,%L,null,null)',
    v_admin,v_sesion,'aal1','plan.limites',v_limites,'Prueba de límites'),'42501');
  perform cuidared_api.api_bo_mutar(v_admin,v_sesion,'aal2','plan.limites',v_limites,'Prueba de límites',null,null);
  perform pruebas.afirmar((select valor_nuevo->>'cuidadores' = '4' from cuidared.auditoria_backoffice
    where accion = 'plan.limites' and entidad_id = v_plan::text), 'el cambio de cupo queda auditado');
  perform pruebas.error(format('select cuidared_interno.stripe_exigir_capacidad(%s,%s::smallint)',v_cuenta,v_plan),
    'P0001','CR_STRIPE_SUPERA_LIMITE');
  perform pruebas.como(v_titular);
  perform pruebas.afirmar(cuidared_api.api_stripe_catalogo_cuenta(v_cuenta) @>
    '[{"codigo":"basico_familiar","limites":{"cuidadores":4}}]', 'la PWA recibe el cupo publicado en Backoffice');
  perform pruebas.afirmar((cuidared_interno.limites(v_cuenta)->>'cuidadores')::int = 4
    and (cuidared_interno.uso_miembros(v_cuenta)->>'cuidadores')::int = 5,
    'bajar el cupo conserva las membresías existentes');
  update cuidared.cuenta set plan_id = v_plan, suscripcion_estado = 'activa' where cuenta_id = v_cuenta;
  perform pruebas.error(format('update cuidared.membresia set estado=%L where membresia_id=%s','activa',v_pendiente),
    'P0001','CR_LIMITE_PLAN');
end $$;
rollback;
