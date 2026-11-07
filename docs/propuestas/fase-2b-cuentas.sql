-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 2 · bloque 2b — Alta de cuenta, cuenta activa, configuración, suscripción/vigencia y catálogos (ID02).
-- RF-11, RF-19, RF-20 · CR-157, CR-164, CR-165 · Reglas de Negocio V2.
-- Depende de docs/propuestas/fase-2a-base.sql (esquema cuidared_interno, matriz rol_permiso, api_contexto_cuenta y
-- api_mis_cuentas). Validada en un PostgreSQL local con `node scripts/validar-propuestas-local.js --solo=2b`
-- (esquema auth simulado; no certifica RLS ni Auth de Supabase). Contrato HTTP: docs/contratos/cuentas.md.
-- © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (propuestas técnicas, ver docs/contratos/cuentas.md):
--   · Autorregistro del titular (confirmado por el usuario el 2026-11-06): api_registrar_cuenta hace titular a auth.uid().
--   · Prueba gratuita única de 7 días fijos, sin plan; anti-abuso: un titular no tiene dos pruebas vigentes a la vez.
--   · Las lecturas de la propia cuenta (cuenta, configuración, suscripción) son para cualquier miembro activo y NO exigen
--     acceso operativo: con la cuenta vencida solo se conserva el acceso a la cuenta y a la suscripción (D07).
--   · Parámetros (D14): configuracion_cuenta.valor > parametro.valor; `null` en la API borra la fila propia.
--   · La auditoría de datos (cuidared.auditoria) la hacen los triggers existentes de la base; esta propuesta NO crea
--     triggers. Antes de aplicar, comprobar que cubren cuidared.cuenta y cuidared.configuracion_cuenta:
--       select tgrelid::regclass, tgname from pg_trigger
--       where not tgisinternal and tgrelid in ('cuidared.cuenta'::regclass, 'cuidared.configuracion_cuenta'::regclass);
--   · Territorio (D14 pendiente): NO se siembran provincias ni municipios. La base remota debe tenerlos cargados antes
--     de que alguien pueda registrar una cuenta (municipio_cod es obligatorio y se valida contra cuidared.municipio).
begin;

/* ───────────── 1. Ayudas internas (esquema cuidared_interno, NO expuesto) ───────────── */

-- Variante de exigir() para leer la propia cuenta: cualquier miembro activo, sin acción concreta y sin exigir acceso
-- operativo (V2: vencida, la cuenta sigue accesible junto con su suscripción). 28000 sin sesión; 42501 sin membresía.
create function cuidared_interno.exigir_miembro(p_cuenta_id bigint) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_m record;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_uid);
  if not found then raise insufficient_privilege; end if;
  return jsonb_build_object('usuario_id', v_uid, 'membresia_id', v_m.membresia_id, 'rol', v_m.rol, 'tipo', v_m.tipo,
                            'rol_id', v_m.rol_id, 'tipo_cuenta_id', v_m.tipo_cuenta_id);
end;
$$;

-- Uso frente a los límites. `usuarios` cuenta a los miembros activos que no son voluntarios (incluye familiares, igual
-- que el frontend); `familiares` y `voluntarios` se informan aparte. Las invitaciones pendientes no consumen cupo.
create function cuidared_interno.uso_de_cuenta(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  with miembros as (
    select m.usuario_id, r.codigo::text as rol
    from cuidared.membresia m
    join cuidared.rol r on r.rol_id = m.rol_id
    join cuidared.usuario u on u.usuario_id = m.usuario_id and u.estado::text = 'activo'
    -- Las invitaciones pendientes reservan cupo (mismo criterio que fase-2c al invitar y aceptar).
    where m.cuenta_id = p_cuenta_id
      and (m.estado::text = 'pendiente'
        or (m.estado::text = 'activa' and m.fecha_inicio <= cuidared_interno.hoy()
            and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())))
  )
  select jsonb_build_object(
    'envejecientes', (select count(*) from cuidared.envejeciente e
                      where e.cuenta_id = p_cuenta_id and e.estado::text = 'activo'),
    'usuarios', (select count(distinct usuario_id) from miembros where rol <> 'voluntario'),
    'familiares', (select count(distinct usuario_id) from miembros where rol = 'familiar'),
    'voluntarios', (select count(distinct usuario_id) from miembros where rol = 'voluntario'))
$$;

-- Datos de la cuenta, contexto del usuario y uso (lo usan api_obtener_cuenta y api_actualizar_cuenta).
create function cuidared_interno.cuenta_detalle(p_cuenta_id bigint, p_usuario_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'cuenta', jsonb_build_object(
      'cuenta_id', c.cuenta_id,
      'nombre', c.nombre,
      'tipo', t.codigo,
      'categoria', jsonb_build_object('categoria_cuenta_id', cc.categoria_cuenta_id, 'nombre', cc.nombre),
      'municipio', jsonb_build_object('municipio_cod', mu.municipio_cod, 'nombre', mu.nombre,
                                      'provincia_cod', pr.provincia_cod, 'provincia', pr.nombre),
      'direccion', c.direccion,
      'telefono', c.telefono,
      'correo', c.correo,
      'fecha_creacion', c.fecha_creacion),
    'contexto', cuidared_interno.contexto(c.cuenta_id, p_usuario_id),
    'uso', cuidared_interno.uso_de_cuenta(c.cuenta_id))
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id
  join cuidared.categoria_cuenta cc on cc.categoria_cuenta_id = c.categoria_cuenta_id
  join cuidared.municipio mu on mu.municipio_cod = c.municipio_cod
  join cuidared.provincia pr on pr.provincia_cod = mu.provincia_cod
  where c.cuenta_id = p_cuenta_id
$$;

-- Parámetros efectivos de la cuenta (D14): valor propio de la cuenta, o el valor general del parámetro.
create function cuidared_interno.configuracion_efectiva(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'nombre', p.nombre,
      'valor', coalesce(cc.valor, p.valor),
      'tipo_dato', p.tipo_dato,
      'es_propio', cc.parametro_id is not null,
      'valor_general', p.valor,
      'descripcion', p.descripcion) order by p.nombre), '[]'::jsonb)
  from cuidared.parametro p
  left join cuidared.configuracion_cuenta cc on cc.parametro_id = p.parametro_id and cc.cuenta_id = p_cuenta_id
$$;

-- Dominio de cada tipo de dato de parámetro. Enteros: días entre 1 y 90 (los parámetros actuales son plazos en días);
-- decimales: 0 a 100000; booleanos: 'true'/'false'; texto: hasta 120 caracteres sin caracteres de control.
create function cuidared_interno.valor_parametro_valido(p_tipo_dato text, p_valor text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(case p_tipo_dato
    when 'entero' then case when p_valor ~ '^[1-9][0-9]?$' then p_valor::integer <= 90 else false end
    when 'decimal' then case when p_valor ~ '^(0|[1-9][0-9]{0,5})(\.[0-9]{1,4})?$' then p_valor::numeric <= 100000 else false end
    when 'booleano' then p_valor in ('true', 'false')
    when 'texto' then char_length(p_valor) <= 120 and p_valor !~ '[[:cntrl:]]'
    else false end, false)
$$;

/*
 * Control de vigencia (RF-20): pasa a 'vencida' las pruebas y suscripciones caducadas. Devuelve cuántas cuentas cambió.
 * Idempotente. NO es lo que bloquea el acceso: acceso_operativo() ya compara las fechas con hoy() en cada llamada; esto
 * solo normaliza el estado para que la interfaz y los reportes lo muestren. Conserva plan_id (permite renovar).
 * La ejecuta pg_cron (ver el bloque comentado del final) como propietario: no se otorga a ningún rol de la API.
 */
create function cuidared_interno.actualizar_vencimientos() returns integer
language plpgsql set search_path = '' as $$
declare v_filas integer;
begin
  update cuidared.cuenta c
  set suscripcion_estado = 'vencida', fecha_actualizacion = pg_catalog.now()
  where (c.suscripcion_estado::text = 'prueba' and c.fecha_fin_prueba is not null
         and c.fecha_fin_prueba < cuidared_interno.hoy())
     or (c.suscripcion_estado::text = 'activa' and c.fecha_fin_vigencia is not null
         and c.fecha_fin_vigencia < cuidared_interno.hoy());
  get diagnostics v_filas = row_count;
  return v_filas;
end;
$$;

revoke all on function
  cuidared_interno.exigir_miembro(bigint),
  cuidared_interno.uso_de_cuenta(bigint),
  cuidared_interno.cuenta_detalle(bigint, uuid),
  cuidared_interno.configuracion_efectiva(bigint),
  cuidared_interno.valor_parametro_valido(text, text),
  cuidared_interno.actualizar_vencimientos()
  from public, anon, authenticated;

/* ───────────── 2. Alta de cuenta (autorregistro del titular) ───────────── */

/*
 * Crea la cuenta con prueba gratuita de 7 días y hace titular a auth.uid() con su membresía activa (coordinador en
 * Familia, administrador en Organización). La identidad sale solo del JWT. p_datos:
 *   { tipo, nombre, categoria_cuenta_id, municipio_cod, direccion?, telefono?, correo? }
 * Errores: 28000 sin sesión · 42501 usuario inactivo · 22023 datos inválidos (incluye municipio inexistente) ·
 * CR_CATEGORIA_INVALIDA si la categoría no existe o no es del tipo de cuenta · CR_PRUEBA_EN_CURSO si el titular ya
 * tiene otra cuenta con prueba vigente (se serializa por usuario con un lock de asesoría: no hay carrera entre dos
 * solicitudes simultáneas).
 */
create function cuidared_api.api_registrar_cuenta(p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_hoy date := cuidared_interno.hoy();
  v_tipo_cod text;
  v_tipo smallint;
  v_categoria integer;
  v_nombre text;
  v_municipio text;
  v_direccion text;
  v_telefono text;
  v_correo text;
  v_cuenta_id bigint;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['tipo', 'nombre', 'categoria_cuenta_id', 'municipio_cod', 'direccion', 'telefono', 'correo'] <> '{}'::jsonb
     or jsonb_typeof(p_datos->'tipo') is distinct from 'string'
     or jsonb_typeof(p_datos->'nombre') is distinct from 'string'
     or jsonb_typeof(p_datos->'categoria_cuenta_id') is distinct from 'number'
     or jsonb_typeof(p_datos->'municipio_cod') is distinct from 'string'
     or coalesce(jsonb_typeof(p_datos->'direccion'), 'null') not in ('string', 'null')
     or coalesce(jsonb_typeof(p_datos->'telefono'), 'null') not in ('string', 'null')
     or coalesce(jsonb_typeof(p_datos->'correo'), 'null') not in ('string', 'null') then
    raise invalid_parameter_value;
  end if;
  v_tipo_cod := p_datos->>'tipo';
  v_nombre := btrim(p_datos->>'nombre');
  v_municipio := p_datos->>'municipio_cod';
  v_direccion := nullif(btrim(p_datos->>'direccion'), '');
  v_telefono := nullif(btrim(p_datos->>'telefono'), '');
  v_correo := nullif(btrim(p_datos->>'correo'), '');
  if v_tipo_cod not in ('familia', 'organizacion')
     or char_length(v_nombre) not between 2 and 120
     or (p_datos->>'categoria_cuenta_id') !~ '^[1-9][0-9]{0,4}$'
     or v_municipio !~ '^[0-9]{4,6}$'
     or char_length(v_direccion) > 150
     or v_telefono !~ '^\+?[0-9]{10,15}$'
     or (v_correo is not null and (char_length(v_correo) > 254 or v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')) then
    raise invalid_parameter_value;
  end if;
  v_categoria := (p_datos->>'categoria_cuenta_id')::integer;
  select t.tipo_cuenta_id into v_tipo from cuidared.tipo_cuenta t where t.codigo = v_tipo_cod and t.activo;
  if not found or not exists (select 1 from cuidared.municipio m where m.municipio_cod = v_municipio) then
    raise invalid_parameter_value;
  end if;
  if not exists (select 1 from cuidared.categoria_cuenta c
                 where c.categoria_cuenta_id = v_categoria and c.activo and c.tipo_cuenta_id = v_tipo) then
    raise exception 'CR_CATEGORIA_INVALIDA' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared.usuario u where u.usuario_id = v_uid and u.estado::text = 'activo') then
    raise insufficient_privilege;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cuidared.registrar_cuenta:' || v_uid::text, 0));
  if exists (select 1 from cuidared.cuenta c
             where c.usuario_titular_id = v_uid and c.suscripcion_estado::text = 'prueba'
               and c.fecha_fin_prueba is not null and c.fecha_fin_prueba >= v_hoy) then
    raise exception 'CR_PRUEBA_EN_CURSO' using errcode = 'P0001';
  end if;

  insert into cuidared.cuenta (nombre, tipo_cuenta_id, categoria_cuenta_id, municipio_cod, direccion, telefono, correo,
                               suscripcion_estado, prueba_gratuita, fecha_inicio_prueba, fecha_fin_prueba, plan_id,
                               usuario_titular_id)
  values (v_nombre, v_tipo, v_categoria::smallint, v_municipio, v_direccion, v_telefono, v_correo,
          'prueba', true, v_hoy, v_hoy + 7, null, v_uid)
  returning cuenta_id into v_cuenta_id;

  -- fecha_inicio explícita: el valor por defecto usa CURRENT_DATE (UTC) y no la fecha de negocio de hoy().
  insert into cuidared.membresia (usuario_id, cuenta_id, rol_id, estado, fecha_inicio)
  select v_uid, v_cuenta_id, r.rol_id, 'activa', v_hoy
  from cuidared.rol r
  where r.activo and r.codigo = case v_tipo_cod when 'familia' then 'coordinador' else 'administrador' end;
  if not found then
    -- Catálogo de roles incompleto: fallo de configuración (503 en la API), no un error del usuario.
    raise exception 'rol de titular no disponible' using errcode = 'P0001';
  end if;

  return cuidared_interno.contexto(v_cuenta_id, v_uid);
end;
$$;

/* ───────────── 3. Cuenta activa: lectura y actualización ───────────── */

-- Cualquier miembro activo (aun con la cuenta vencida). {cuenta, contexto, uso}.
create function cuidared_api.api_obtener_cuenta(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir_miembro(p_cuenta_id);
begin
  return cuidared_interno.cuenta_detalle(p_cuenta_id, (v_ctx->>'usuario_id')::uuid);
end;
$$;

/*
 * Actualiza los datos de la cuenta (organizacion:configurar; permitido aun vencida, es gestión de cuenta). No cambia el
 * tipo, el titular ni la suscripción: cualquier otra clave es 22023. Campos: nombre, categoria_cuenta_id, municipio_cod,
 * direccion, telefono, correo (los tres últimos admiten null para vaciarlos). La categoría debe ser del mismo tipo.
 */
create function cuidared_api.api_actualizar_cuenta(p_cuenta_id bigint, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'organizacion:configurar');
  v_tipo smallint;
  v_categoria integer;
  v_nombre text;
  v_municipio text;
  v_direccion text;
  v_telefono text;
  v_correo text;
begin
  if jsonb_typeof(p_datos) is distinct from 'object' or p_datos = '{}'::jsonb
     or p_datos - array['nombre', 'categoria_cuenta_id', 'municipio_cod', 'direccion', 'telefono', 'correo'] <> '{}'::jsonb
     or (p_datos ? 'nombre' and jsonb_typeof(p_datos->'nombre') is distinct from 'string')
     or (p_datos ? 'categoria_cuenta_id' and jsonb_typeof(p_datos->'categoria_cuenta_id') is distinct from 'number')
     or (p_datos ? 'municipio_cod' and jsonb_typeof(p_datos->'municipio_cod') is distinct from 'string')
     or (p_datos ? 'direccion' and jsonb_typeof(p_datos->'direccion') not in ('string', 'null'))
     or (p_datos ? 'telefono' and jsonb_typeof(p_datos->'telefono') not in ('string', 'null'))
     or (p_datos ? 'correo' and jsonb_typeof(p_datos->'correo') not in ('string', 'null')) then
    raise invalid_parameter_value;
  end if;

  -- Serializa las ediciones de la misma cuenta y fija su tipo para validar la categoría.
  select c.tipo_cuenta_id into v_tipo from cuidared.cuenta c where c.cuenta_id = p_cuenta_id for no key update;
  if not found then raise no_data_found; end if;

  if p_datos ? 'nombre' then
    v_nombre := btrim(p_datos->>'nombre');
    if char_length(v_nombre) not between 2 and 120 then raise invalid_parameter_value; end if;
  end if;
  if p_datos ? 'municipio_cod' then
    v_municipio := p_datos->>'municipio_cod';
    if v_municipio !~ '^[0-9]{4,6}$'
       or not exists (select 1 from cuidared.municipio m where m.municipio_cod = v_municipio) then
      raise invalid_parameter_value;
    end if;
  end if;
  if p_datos ? 'direccion' then
    v_direccion := nullif(btrim(p_datos->>'direccion'), '');
    if char_length(v_direccion) > 150 then raise invalid_parameter_value; end if;
  end if;
  if p_datos ? 'telefono' then
    v_telefono := nullif(btrim(p_datos->>'telefono'), '');
    if v_telefono !~ '^\+?[0-9]{10,15}$' then raise invalid_parameter_value; end if;
  end if;
  if p_datos ? 'correo' then
    v_correo := nullif(btrim(p_datos->>'correo'), '');
    if v_correo is not null and (char_length(v_correo) > 254 or v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
      raise invalid_parameter_value;
    end if;
  end if;
  if p_datos ? 'categoria_cuenta_id' then
    if (p_datos->>'categoria_cuenta_id') !~ '^[1-9][0-9]{0,4}$' then raise invalid_parameter_value; end if;
    v_categoria := (p_datos->>'categoria_cuenta_id')::integer;
    if not exists (select 1 from cuidared.categoria_cuenta cc
                   where cc.categoria_cuenta_id = v_categoria and cc.activo and cc.tipo_cuenta_id = v_tipo) then
      raise exception 'CR_CATEGORIA_INVALIDA' using errcode = 'P0001';
    end if;
  end if;

  update cuidared.cuenta c set
    nombre = case when p_datos ? 'nombre' then v_nombre else c.nombre end,
    categoria_cuenta_id = case when p_datos ? 'categoria_cuenta_id' then v_categoria::smallint else c.categoria_cuenta_id end,
    municipio_cod = case when p_datos ? 'municipio_cod' then v_municipio else c.municipio_cod end,
    direccion = case when p_datos ? 'direccion' then v_direccion else c.direccion end,
    telefono = case when p_datos ? 'telefono' then v_telefono else c.telefono end,
    correo = case when p_datos ? 'correo' then v_correo else c.correo end,
    fecha_actualizacion = pg_catalog.now()
  where c.cuenta_id = p_cuenta_id;

  return cuidared_interno.cuenta_detalle(p_cuenta_id, (v_ctx->>'usuario_id')::uuid);
end;
$$;

/* ───────────── 4. Configuración de la cuenta (RF-19) ───────────── */

-- Cualquier miembro activo. Arreglo de {nombre, valor, tipo_dato, es_propio, valor_general, descripcion}.
create function cuidared_api.api_obtener_configuracion(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir_miembro(p_cuenta_id);
begin
  return cuidared_interno.configuracion_efectiva(p_cuenta_id);
end;
$$;

/*
 * Cambia parámetros de la cuenta (organizacion:configurar). p_valores = {nombre: valor_texto | null}. Todo o nada: un
 * nombre inexistente o un valor fuera de dominio es CR_PARAMETRO_INVALIDO y no se aplica ninguno. `null` borra el valor
 * propio y la cuenta vuelve al valor general. Devuelve la configuración efectiva completa.
 */
create function cuidared_api.api_actualizar_configuracion(p_cuenta_id bigint, p_valores jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, 'organizacion:configurar');
  v_nombre text;
  v_valor jsonb;
  v_param record;
  v_texto text;
begin
  if jsonb_typeof(p_valores) is distinct from 'object' or p_valores = '{}'::jsonb
     or (select count(*) from jsonb_object_keys(p_valores)) > 50 then
    raise invalid_parameter_value;
  end if;
  -- Serializa los cambios de configuración de la misma cuenta.
  perform 1 from cuidared.cuenta c where c.cuenta_id = p_cuenta_id for no key update;
  if not found then raise no_data_found; end if;

  for v_nombre, v_valor in select e.key, e.value from jsonb_each(p_valores) e loop
    select p.parametro_id, p.tipo_dato::text as tipo_dato into v_param
    from cuidared.parametro p where p.nombre = v_nombre;
    if not found or jsonb_typeof(v_valor) not in ('string', 'null') then
      raise exception 'CR_PARAMETRO_INVALIDO' using errcode = 'P0001';
    end if;
    if jsonb_typeof(v_valor) = 'null' then
      delete from cuidared.configuracion_cuenta cc
      where cc.cuenta_id = p_cuenta_id and cc.parametro_id = v_param.parametro_id;
    else
      v_texto := btrim(v_valor #>> '{}');
      if not cuidared_interno.valor_parametro_valido(v_param.tipo_dato, v_texto) then
        raise exception 'CR_PARAMETRO_INVALIDO' using errcode = 'P0001';
      end if;
      insert into cuidared.configuracion_cuenta (cuenta_id, parametro_id, valor)
      values (p_cuenta_id, v_param.parametro_id, v_texto)
      on conflict (cuenta_id, parametro_id)
      do update set valor = excluded.valor, fecha_actualizacion = pg_catalog.now();
    end if;
  end loop;

  return cuidared_interno.configuracion_efectiva(p_cuenta_id);
end;
$$;

/* ───────────── 5. Suscripción y vigencia (RF-20, sin pagos: Stripe llega en la fase 8) ───────────── */

/*
 * Cualquier miembro activo, aun vencida. Estado, prueba, acceso operativo, plan, vigencia, límites, uso y
 * funcionalidades. `planes` (compatibles con el tipo de cuenta, con precio, límites y funcionalidades) solo se
 * incluye si el rol tiene cuenta:suscripcion; si no, es null.
 */
create function cuidared_api.api_obtener_suscripcion(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb := cuidared_interno.exigir_miembro(p_cuenta_id);
  v_hoy date := cuidared_interno.hoy();
  v_planes boolean := 'cuenta:suscripcion' = any (
    cuidared_interno.permisos((v_ctx->>'rol_id')::smallint, (v_ctx->>'tipo_cuenta_id')::smallint));
begin
  return (
    select jsonb_build_object(
      'estado', c.suscripcion_estado,
      'acceso_operativo', cuidared_interno.acceso_operativo(c.cuenta_id),
      'prueba', jsonb_build_object(
        'gratuita', c.prueba_gratuita,
        'vigente', c.suscripcion_estado::text = 'prueba' and c.fecha_fin_prueba is not null and c.fecha_fin_prueba >= v_hoy,
        'fecha_inicio', c.fecha_inicio_prueba,
        'fecha_fin', c.fecha_fin_prueba,
        'dias_restantes', case when c.suscripcion_estado::text = 'prueba' and c.fecha_fin_prueba is not null
                               then greatest(0, c.fecha_fin_prueba - v_hoy) else 0 end),
      'plan', case when p.plan_id is null then null else jsonb_build_object(
        'plan_id', p.plan_id, 'nombre', p.nombre, 'categoria', pc.nombre, 'precio', p.precio,
        'periodicidad', p.periodicidad, 'duracion_dias', p.duracion_dias, 'resumen', p.resumen) end,
      'fecha_fin_vigencia', c.fecha_fin_vigencia,
      'limites', cuidared_interno.limites(c.cuenta_id),
      'uso', cuidared_interno.uso_de_cuenta(c.cuenta_id),
      'funcionalidades', to_jsonb(cuidared_interno.funcionalidades(c.cuenta_id)),
      'planes', case when v_planes then (
        select coalesce(jsonb_agg(jsonb_build_object(
            'plan_id', pl.plan_id, 'nombre', pl.nombre, 'categoria', plc.nombre, 'precio', pl.precio,
            'periodicidad', pl.periodicidad, 'duracion_dias', pl.duracion_dias, 'resumen', pl.resumen,
            'limites', jsonb_build_object('envejecientes', pl.limite_envejecientes, 'usuarios', pl.limite_usuarios,
                                          'familiares', pl.limite_familiares),
            'funcionalidades', coalesce((select jsonb_agg(pf.funcionalidad order by pf.funcionalidad)
                                         from cuidared.plan_funcionalidad pf where pf.plan_id = pl.plan_id), '[]'::jsonb),
            'es_actual', pl.plan_id is not distinct from c.plan_id and c.suscripcion_estado::text = 'activa')
          order by pl.precio, pl.plan_id), '[]'::jsonb)
        from cuidared.plan pl
        join cuidared.plan_categoria plc on plc.plan_categoria_id = pl.plan_categoria_id
        where pl.tipo_cuenta_id = c.tipo_cuenta_id and pl.estado::text = 'activo') end)
    from cuidared.cuenta c
    left join cuidared.plan p on p.plan_id = c.plan_id
    left join cuidared.plan_categoria pc on pc.plan_categoria_id = p.plan_categoria_id
    where c.cuenta_id = p_cuenta_id);
end;
$$;

/* ───────────── 6. Catálogos (CR-165) ───────────── */

/*
 * Catálogo de lista cerrada para formularios; solo exige sesión (no cuenta): son datos de referencia comunes, sin
 * datos personales. p_nombre usa los mismos nombres que la ruta. Devuelve {items, total}. p_filtro admite solo las
 * claves del catálogo, o 22023:
 *   municipios: provincia_cod, limit (1-100), offset (>=0), sort ([{field: nombre|municipio_cod, direction: asc|desc}])
 *   categorias-cuenta, planes: tipo (familia|organizacion) · necesidades: tipo_necesidad_id
 * Nombre desconocido: P0002. Solo se publican registros activos de los catálogos que tienen estado.
 */
create function cuidared_api.api_catalogo(p_nombre text, p_filtro jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_filtro jsonb := coalesce(p_filtro, '{}'::jsonb);
  v_permitidas text[];
  v_items jsonb;
  v_total integer;
  v_tipo text;
  v_provincia text;
  v_tipo_necesidad integer;
  v_limit integer := 100;
  v_offset integer := 0;
  v_orden text;
  v_campo jsonb;
  v_partes text[] := array[]::text[];
begin
  perform cuidared_interno.exigir_sesion();
  if jsonb_typeof(v_filtro) is distinct from 'object' then raise invalid_parameter_value; end if;
  v_permitidas := case p_nombre
    when 'municipios' then array['provincia_cod', 'limit', 'offset', 'sort']
    when 'categorias-cuenta' then array['tipo']
    when 'planes' then array['tipo']
    when 'necesidades' then array['tipo_necesidad_id']
    when 'provincias' then array[]::text[]
    when 'tipos-cuenta' then array[]::text[]
    when 'roles' then array[]::text[]
    when 'tipos-cuidado' then array[]::text[]
    when 'tipos-vinculo' then array[]::text[]
    when 'prioridades' then array[]::text[]
    when 'niveles-riesgo' then array[]::text[]
    when 'riesgos' then array[]::text[]
    when 'tipos-necesidad' then array[]::text[]
    when 'tipos-alerta' then array[]::text[]
    when 'tipos-indicacion' then array[]::text[]
    when 'metodos-pago' then array[]::text[]
    else null end;
  if v_permitidas is null then raise no_data_found; end if;
  if exists (select 1 from jsonb_object_keys(v_filtro) k where k <> all (v_permitidas)) then
    raise invalid_parameter_value;
  end if;

  if v_filtro ? 'tipo' then
    if jsonb_typeof(v_filtro->'tipo') is distinct from 'string' or (v_filtro->>'tipo') not in ('familia', 'organizacion') then
      raise invalid_parameter_value;
    end if;
    v_tipo := v_filtro->>'tipo';
  end if;
  if v_filtro ? 'provincia_cod' then
    if jsonb_typeof(v_filtro->'provincia_cod') is distinct from 'string' or (v_filtro->>'provincia_cod') !~ '^[0-9]{2}$' then
      raise invalid_parameter_value;
    end if;
    v_provincia := v_filtro->>'provincia_cod';
  end if;
  if v_filtro ? 'tipo_necesidad_id' then
    if jsonb_typeof(v_filtro->'tipo_necesidad_id') is distinct from 'number' or (v_filtro->>'tipo_necesidad_id') !~ '^[1-9][0-9]{0,4}$' then
      raise invalid_parameter_value;
    end if;
    v_tipo_necesidad := (v_filtro->>'tipo_necesidad_id')::integer;
  end if;
  if v_filtro ? 'limit' then
    if jsonb_typeof(v_filtro->'limit') is distinct from 'number' or (v_filtro->>'limit') !~ '^[1-9][0-9]{0,2}$'
       or (v_filtro->>'limit')::integer > 100 then
      raise invalid_parameter_value;
    end if;
    v_limit := (v_filtro->>'limit')::integer;
  end if;
  if v_filtro ? 'offset' then
    if jsonb_typeof(v_filtro->'offset') is distinct from 'number' or (v_filtro->>'offset') !~ '^(0|[1-9][0-9]{0,8})$' then
      raise invalid_parameter_value;
    end if;
    v_offset := (v_filtro->>'offset')::integer;
  end if;
  if v_filtro ? 'sort' then
    if jsonb_typeof(v_filtro->'sort') is distinct from 'array' or jsonb_array_length(v_filtro->'sort') not between 1 and 2 then
      raise invalid_parameter_value;
    end if;
    for v_campo in select s.value from jsonb_array_elements(v_filtro->'sort') s loop
      if jsonb_typeof(v_campo) is distinct from 'object'
         or coalesce(v_campo->>'field', '') not in ('nombre', 'municipio_cod')
         or coalesce(v_campo->>'direction', '') not in ('asc', 'desc') then
        raise invalid_parameter_value;
      end if;
      v_partes := v_partes || ('m.' || (v_campo->>'field') || ' ' || (v_campo->>'direction'));
    end loop;
  end if;
  -- Desempate estable por el código (clave primaria).
  v_orden := array_to_string(v_partes || array['m.municipio_cod asc'], ', ');

  if p_nombre = 'provincias' then
    select coalesce(jsonb_agg(jsonb_build_object('provincia_cod', p.provincia_cod, 'nombre', p.nombre)
                              order by p.provincia_cod), '[]'::jsonb) into v_items from cuidared.provincia p;
  elsif p_nombre = 'municipios' then
    select count(*) into v_total from cuidared.municipio m where v_provincia is null or m.provincia_cod = v_provincia;
    execute format($q$
      with pagina as (
        select m.* from cuidared.municipio m
        where $1 is null or m.provincia_cod = $1
        order by %1$s limit $2 offset $3)
      select coalesce(jsonb_agg(jsonb_build_object('municipio_cod', m.municipio_cod, 'nombre', m.nombre,
                                                   'provincia_cod', m.provincia_cod) order by %1$s), '[]'::jsonb)
      from pagina m $q$, v_orden)
      into v_items using v_provincia, v_limit, v_offset;
  elsif p_nombre = 'tipos-cuenta' then
    select coalesce(jsonb_agg(jsonb_build_object('tipo_cuenta_id', t.tipo_cuenta_id, 'codigo', t.codigo, 'nombre', t.nombre)
                              order by t.tipo_cuenta_id), '[]'::jsonb)
    into v_items from cuidared.tipo_cuenta t where t.activo and t.codigo is not null;
  elsif p_nombre = 'categorias-cuenta' then
    select coalesce(jsonb_agg(jsonb_build_object('categoria_cuenta_id', c.categoria_cuenta_id, 'nombre', c.nombre,
                                                 'tipo_cuenta_id', t.tipo_cuenta_id, 'tipo', t.codigo)
                              order by c.categoria_cuenta_id), '[]'::jsonb)
    into v_items
    from cuidared.categoria_cuenta c
    join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id
    where c.activo and t.activo and (v_tipo is null or t.codigo = v_tipo);
  elsif p_nombre = 'roles' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'rol_id', r.rol_id, 'codigo', r.codigo, 'nombre', r.nombre, 'descripcion', r.descripcion,
        'tipos', coalesce((select jsonb_agg(distinct t.codigo order by t.codigo)
                           from cuidared.rol_permiso rp
                           join cuidared.tipo_cuenta t on t.tipo_cuenta_id = rp.tipo_cuenta_id
                           where rp.rol_id = r.rol_id), '[]'::jsonb)) order by r.rol_id), '[]'::jsonb)
    into v_items from cuidared.rol r where r.activo;
  elsif p_nombre = 'planes' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'plan_id', p.plan_id, 'nombre', p.nombre, 'categoria', pc.nombre, 'tipo', t.codigo, 'precio', p.precio,
        'periodicidad', p.periodicidad, 'duracion_dias', p.duracion_dias, 'resumen', p.resumen,
        'limites', jsonb_build_object('envejecientes', p.limite_envejecientes, 'usuarios', p.limite_usuarios,
                                      'familiares', p.limite_familiares),
        'funcionalidades', coalesce((select jsonb_agg(pf.funcionalidad order by pf.funcionalidad)
                                     from cuidared.plan_funcionalidad pf where pf.plan_id = p.plan_id), '[]'::jsonb))
      order by t.tipo_cuenta_id, p.precio, p.plan_id), '[]'::jsonb)
    into v_items
    from cuidared.plan p
    join cuidared.plan_categoria pc on pc.plan_categoria_id = p.plan_categoria_id
    join cuidared.tipo_cuenta t on t.tipo_cuenta_id = p.tipo_cuenta_id
    where p.estado::text = 'activo' and t.codigo is not null and (v_tipo is null or t.codigo = v_tipo);
  elsif p_nombre = 'tipos-cuidado' then
    select coalesce(jsonb_agg(jsonb_build_object('tipo_cuidado_id', x.tipo_cuidado_id, 'nombre', x.nombre)
                              order by x.tipo_cuidado_id), '[]'::jsonb) into v_items from cuidared.tipo_cuidado x;
  elsif p_nombre = 'tipos-vinculo' then
    select coalesce(jsonb_agg(jsonb_build_object('tipo_vinculo_id', x.tipo_vinculo_id, 'codigo', x.codigo, 'nombre', x.nombre)
                              order by x.tipo_vinculo_id), '[]'::jsonb) into v_items from cuidared.tipo_vinculo x;
  elsif p_nombre = 'prioridades' then
    select coalesce(jsonb_agg(jsonb_build_object('prioridad_id', x.prioridad_id, 'nombre', x.nombre, 'orden', x.orden)
                              order by x.orden), '[]'::jsonb) into v_items from cuidared.prioridad x;
  elsif p_nombre = 'niveles-riesgo' then
    select coalesce(jsonb_agg(jsonb_build_object('nivel_riesgo_id', x.nivel_riesgo_id, 'nombre', x.nombre, 'orden', x.orden)
                              order by x.orden), '[]'::jsonb) into v_items from cuidared.nivel_riesgo x;
  elsif p_nombre = 'riesgos' then
    select coalesce(jsonb_agg(jsonb_build_object('riesgo_id', x.riesgo_id, 'nombre', x.nombre, 'descripcion', x.descripcion)
                              order by x.riesgo_id), '[]'::jsonb) into v_items from cuidared.riesgo x;
  elsif p_nombre = 'tipos-necesidad' then
    select coalesce(jsonb_agg(jsonb_build_object('tipo_necesidad_id', x.tipo_necesidad_id, 'nombre', x.nombre)
                              order by x.tipo_necesidad_id), '[]'::jsonb) into v_items from cuidared.tipo_necesidad x;
  elsif p_nombre = 'necesidades' then
    select coalesce(jsonb_agg(jsonb_build_object('necesidad_id', x.necesidad_id, 'nombre', x.nombre,
                                                 'tipo_necesidad_id', x.tipo_necesidad_id, 'descripcion', x.descripcion)
                              order by x.necesidad_id), '[]'::jsonb)
    into v_items from cuidared.necesidad x
    where x.activo and (v_tipo_necesidad is null or x.tipo_necesidad_id = v_tipo_necesidad);
  elsif p_nombre = 'tipos-alerta' then
    select coalesce(jsonb_agg(jsonb_build_object('tipo_alerta_id', x.tipo_alerta_id, 'codigo', x.codigo, 'nombre', x.nombre)
                              order by x.tipo_alerta_id), '[]'::jsonb) into v_items from cuidared.tipo_alerta x;
  elsif p_nombre = 'tipos-indicacion' then
    select coalesce(jsonb_agg(jsonb_build_object('tipo_indicacion_id', x.tipo_indicacion_id, 'nombre', x.nombre)
                              order by x.tipo_indicacion_id), '[]'::jsonb) into v_items from cuidared.tipo_indicacion x;
  elsif p_nombre = 'metodos-pago' then
    select coalesce(jsonb_agg(jsonb_build_object('metodo_pago_id', x.metodo_pago_id, 'nombre', x.nombre)
                              order by x.metodo_pago_id), '[]'::jsonb) into v_items from cuidared.metodo_pago x where x.activo;
  end if;

  return jsonb_build_object('items', v_items, 'total', coalesce(v_total, jsonb_array_length(v_items)));
end;
$$;

/* ───────────── 7. Permisos de las RPC ───────────── */

revoke all on function
  cuidared_api.api_registrar_cuenta(jsonb),
  cuidared_api.api_obtener_cuenta(bigint),
  cuidared_api.api_actualizar_cuenta(bigint, jsonb),
  cuidared_api.api_obtener_configuracion(bigint),
  cuidared_api.api_actualizar_configuracion(bigint, jsonb),
  cuidared_api.api_obtener_suscripcion(bigint),
  cuidared_api.api_catalogo(text, jsonb)
  from public, anon;
grant execute on function
  cuidared_api.api_registrar_cuenta(jsonb),
  cuidared_api.api_obtener_cuenta(bigint),
  cuidared_api.api_actualizar_cuenta(bigint, jsonb),
  cuidared_api.api_obtener_configuracion(bigint),
  cuidared_api.api_actualizar_configuracion(bigint, jsonb),
  cuidared_api.api_obtener_suscripcion(bigint),
  cuidared_api.api_catalogo(text, jsonb)
  to authenticated;

/* ───────────── 8. Programación del control de vigencia (requiere aprobación) ───────────── */
-- pg_cron necesita la extensión habilitada en el proyecto (Database > Extensions) y aprobación expresa. Se propone una
-- vez al día a las 04:05 UTC (00:05 en República Dominicana, justo después del cambio de fecha de negocio):
--
--   create extension if not exists pg_cron;
--   select cron.schedule('cuidared-actualizar-vencimientos', '5 4 * * *', $$select cuidared_interno.actualizar_vencimientos()$$);
--
-- Para retirarla: select cron.unschedule('cuidared-actualizar-vencimientos');

commit;
