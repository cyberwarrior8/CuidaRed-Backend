-- Catálogo referencial del producto para validación de CuidaRed. No ejecuta cobros.
-- Fuente: CuidaRed-Frontend/src/domain/datosMaestros.ts y el contrato de cuentas de la V2.
-- Sustituir por los valores comerciales aprobados antes de ofrecer estos planes a clientes.
begin;
do $$
declare
  planes jsonb := '[
    {"nombre":"Básico Familiar","tipo":"familia","categoria":"Básico","precio":650,
     "adultos":2,"usuarios":null,"familiares":3,"funcionalidades":["registro_visitas","necesidades_diarias","visitas_recurrentes"]},
    {"nombre":"Cuidado Integral","tipo":"familia","categoria":"Premium","precio":1450,
     "adultos":6,"usuarios":null,"familiares":null,"funcionalidades":["registro_visitas","necesidades_diarias","visitas_recurrentes","alertas_tiempo_real","historial_inmutable","dashboard_metricas"]},
    {"nombre":"Operación Base","tipo":"organizacion","categoria":"Básico","precio":3500,
     "adultos":15,"usuarios":20,"familiares":null,"funcionalidades":["registro_visitas","necesidades_diarias","tablon_notificaciones","dashboard_metricas"]},
    {"nombre":"Gestión Comunitaria Avanzada","tipo":"organizacion","categoria":"Premium","precio":8500,
     "adultos":null,"usuarios":null,"familiares":null,"funcionalidades":["registro_visitas","necesidades_diarias","tablon_notificaciones","dashboard_metricas","visitas_recurrentes","alertas_tiempo_real","riesgo_completo","org_necesidad","reportes_avanzados"]}
  ]';
  metodos text[] := array['Transferencia bancaria','Tarjeta de crédito o débito','Efectivo'];
  item record;
  v_tipo smallint;
  v_categoria smallint;
  v_plan smallint;
begin
  if jsonb_array_length(planes)=0 or cardinality(metodos)=0 then
    raise exception 'Completa los planes y métodos de pago aprobados';
  end if;
  for item in select * from jsonb_to_recordset(planes) as p(nombre text,tipo text,categoria text,
    precio numeric,adultos integer,usuarios integer,familiares integer,funcionalidades text[])
  loop
    if item.precio is null or item.precio<=0 or cardinality(item.funcionalidades) is null or cardinality(item.funcionalidades)=0
      then raise exception 'Se requiere precio positivo y al menos una funcionalidad por plan'; end if;
    select tipo_cuenta_id into strict v_tipo from cuidared.tipo_cuenta where codigo=item.tipo and activo;
    insert into cuidared.plan_categoria(nombre) values(item.categoria) on conflict(nombre) do nothing;
    select plan_categoria_id into strict v_categoria from cuidared.plan_categoria where nombre=item.categoria;
    insert into cuidared.plan(nombre,plan_categoria_id,tipo_cuenta_id,precio,periodicidad,duracion_dias,
      estado,limite_envejecientes,limite_usuarios,limite_familiares)
    values(item.nombre,v_categoria,v_tipo,item.precio,'mensual',30,'activo',item.adultos,item.usuarios,item.familiares)
    on conflict(nombre) do nothing;
    select plan_id into strict v_plan from cuidared.plan where nombre=item.nombre and tipo_cuenta_id=v_tipo and not bo_gratuito;
    insert into cuidared.plan_funcionalidad(plan_id,funcionalidad)
    select v_plan,f from unnest(item.funcionalidades) f on conflict do nothing;
  end loop;
  insert into cuidared.metodo_pago(nombre) select distinct trim(metodo) from unnest(metodos) metodo
  where trim(metodo)<>'' on conflict(nombre) do nothing;
end $$;
commit;
