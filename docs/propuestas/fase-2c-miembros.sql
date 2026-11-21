-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 2 · bloque 2c — Miembros, invitaciones, roles, titularidad y perfiles de Cuidador (ID02).
-- RF-09, RF-11, RF-12 · Reglas de Negocio V2. Depende de docs/propuestas/fase-2a-base.sql (cuidared_interno.exigir,
-- limites, hoy, membresia_activa, uq_membresia_vigente, cuidador.cuenta_id, uq_cuidador_vigente).
-- Validada en un PostgreSQL local con `node scripts/validar-propuestas-local.js --solo=2c` (esquema auth simulado;
-- no certifica RLS ni Auth de Supabase). Contrato HTTP: docs/contratos/miembros.md.
-- © 2026 Equipo CuidaRed – INTEC.
--
-- No crea tablas nuevas. Todas las RPC viven en cuidared_api (security definer, search_path vacío), autorizan SIEMPRE
-- con cuidared_interno.exigir (o exigir_sesion en las acciones sobre la membresía propia) y sacan la identidad solo de
-- auth.uid(). Errores: 28000 sin sesión · 42501 sin permiso · P0002 no existe (o es de otra cuenta) · 22023 entrada
-- inválida · P0001 + CR_* regla de negocio (CR_LIMITE_PLAN, CR_ROL_NO_PERMITIDO y CR_ESTADO_INVALIDO vienen de 2a).
--
-- Propuestas técnicas pendientes de aprobación (los Dxx son las preguntas abiertas de CONTEXTO-BACKEND.md §15.2):
--   · D07  Límites: el Voluntario no cuenta para limites.usuarios (no paga plan propio); el Familiar cuenta para
--          limites.usuarios y limites.familiares. Una invitación pendiente reserva cupo; aceptar lo recomprueba.
--   · D09  Duplicados: una membresía vigente (pendiente/activa) por usuario y cuenta, y un perfil Cuidador vigente por
--          usuario y cuenta (índices de 2a). Toda operación que cambia membresías de una cuenta se serializa con un
--          advisory lock por cuenta: así los límites del plan y el «último gestor» no se rompen por concurrencia.
--   · D04  Al cambiar de rol se eliminan los vínculos cuidador_asignado / voluntario_asignado / familiar_responsable de
--          los adultos DE ESA CUENTA que no correspondan al nuevo rol, y se finaliza el perfil Cuidador si el nuevo
--          rol no es cuidador. Al desactivar se conservan (el acceso se corta porque membresia_activa deja de devolver
--          la membresía); no se arrastra ningún permiso al reactivar porque el rol se vuelve a comprobar.
--   · D14  La invitación genera una notificación personal (fan-out personal) para la persona invitada, con el nombre
--          de la cuenta y el rol, sin datos de adultos. El catálogo TipoCuidado es el de 2a.
--   · D15  Desactivar y cambiar de rol conservan el historial: se cierra la membresía (inactiva + fecha_fin) y, si hay
--          cambio de rol, se abre otra. Nada se borra salvo los vínculos de acceso del rol anterior.
--   · Un Cuidador que no es independiente tiene como empleador al titular de la cuenta (siempre es un gestor).
--   · Reactivar exige que la membresía indicada sea la más reciente de la persona en la cuenta (mayor membresia_id);
--     conserva su rol. El listado muestra una fila por persona: su membresía vigente o, si no tiene, la más reciente.
begin;

/* ───────────── 1. Defensa en profundidad e índice ───────────── */

-- Las tablas ya no se tocan directamente: solo a través de las RPC (security definer, dueño de las tablas).
alter table cuidared.membresia enable row level security;
alter table cuidared.cuidador enable row level security;
revoke all on cuidared.membresia, cuidared.cuidador from public, anon, authenticated;

-- Listado y recuentos por cuenta (uq_membresia_vigente arranca por usuario_id y es parcial).
create index ix_membresia_cuenta on cuidared.membresia (cuenta_id, usuario_id);

/* ───────────── 2. Funciones internas (NO expuestas) ───────────── */

-- Serializa los cambios de membresías de una cuenta (límites del plan, último gestor, titularidad).
create function cuidared_interno.bloquear_miembros(p_cuenta_id bigint) returns void
language plpgsql set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cuidared.miembros:' || p_cuenta_id::text, 0));
end;
$$;

/*
 * exigir() + bloqueo de la cuenta + exigir() otra vez: tras esperar el bloqueo, otra operación pudo haber dado de baja
 * o cambiado de rol a quien llama; la segunda comprobación ve el estado ya confirmado (cada sentencia toma su
 * propia instantánea en READ COMMITTED).
 */
create function cuidared_interno.exigir_miembros(p_cuenta_id bigint, p_accion text) returns jsonb
language plpgsql set search_path = '' as $$
begin
  perform cuidared_interno.exigir(p_cuenta_id, p_accion);
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);
  return cuidared_interno.exigir(p_cuenta_id, p_accion);
end;
$$;

-- rol_id del rol si existe, está activo y es válido para el tipo de cuenta (tiene permisos sembrados); si no, null.
create function cuidared_interno.rol_del_tipo(p_rol text, p_tipo_cuenta_id smallint) returns smallint
language sql stable set search_path = '' as $$
  select r.rol_id
  from cuidared.rol r
  where r.codigo::text = p_rol and r.activo
    and exists (select 1 from cuidared.rol_permiso rp where rp.rol_id = r.rol_id and rp.tipo_cuenta_id = p_tipo_cuenta_id)
$$;

-- ¿Es un rol gestor de miembros en ese tipo de cuenta? (Administrador en Organización, Coordinador en Familia.)
create function cuidared_interno.rol_gestor(p_rol_id smallint, p_tipo_cuenta_id smallint) returns boolean
language sql stable set search_path = '' as $$
  select 'usuarios:gestionar' = any (cuidared_interno.permisos(p_rol_id, p_tipo_cuenta_id))
$$;

-- CR_ULTIMO_GESTOR si, sin la persona indicada, la cuenta se quedara sin un gestor activo.
create function cuidared_interno.exigir_otro_gestor(p_cuenta_id bigint, p_usuario_excluido uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not exists (
    select 1
    from cuidared.membresia m
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    join cuidared.rol r on r.rol_id = m.rol_id and r.activo
    join cuidared.usuario u on u.usuario_id = m.usuario_id and u.estado::text = 'activo'
    where m.cuenta_id = p_cuenta_id and m.usuario_id <> p_usuario_excluido and m.estado::text = 'activa'
      and m.fecha_inicio <= cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
      and cuidared_interno.rol_gestor(m.rol_id, c.tipo_cuenta_id)
  ) then
    raise exception 'CR_ULTIMO_GESTOR' using errcode = 'P0001';
  end if;
end;
$$;

-- Los pendientes no reservan plaza. Familiares y voluntarios quedan fuera del cupo de staff.
create function cuidared_interno.uso_miembros(p_cuenta_id bigint, p_excluir_membresia_id bigint default null) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'usuarios', count(*) filter (where r.codigo::text in ('administrador','coordinador','cuidador')),
    'familiares', count(*) filter (where r.codigo::text = 'familiar'))
  from cuidared.membresia m
  join cuidared.rol r on r.rol_id = m.rol_id
  where m.cuenta_id = p_cuenta_id and m.estado::text = 'activa'
    and m.fecha_inicio <= cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
    and m.membresia_id is distinct from p_excluir_membresia_id
$$;

/*
 * CR_LIMITE_PLAN si sumar la membresía supera el plan (o la prueba). Solo se exige cupo cuando el cambio AUMENTA el
 * uso: p_rol_actual es el rol que la persona ya tiene (cambio de rol; null si es una membresía nueva) y
 * p_excluir_membresia_id la membresía pendiente que ya cuenta y se está aceptando.
 */
create function cuidared_interno.exigir_cupo_miembro(p_cuenta_id bigint, p_rol_nuevo text, p_rol_actual text default null,
                                                     p_excluir_membresia_id bigint default null) returns void
language plpgsql stable set search_path = '' as $$
declare
  v_lim jsonb := cuidared_interno.limites(p_cuenta_id);
  v_uso jsonb := cuidared_interno.uso_miembros(p_cuenta_id, p_excluir_membresia_id);
  v_cuenta_usuario_nuevo boolean := p_rol_nuevo in ('administrador','coordinador','cuidador');
  v_cuenta_usuario_actual boolean := coalesce(p_rol_actual in ('administrador','coordinador','cuidador'), false);
begin
  if v_cuenta_usuario_nuevo and not v_cuenta_usuario_actual and (v_lim->>'usuarios') is not null
     and (v_uso->>'usuarios')::integer + 1 > (v_lim->>'usuarios')::integer then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
  if p_rol_nuevo = 'familiar' and p_rol_actual is distinct from 'familiar' and (v_lim->>'familiares') is not null
     and (v_uso->>'familiares')::integer + 1 > (v_lim->>'familiares')::integer then
    raise exception 'CR_LIMITE_PLAN' using errcode = 'P0001';
  end if;
end;
$$;

-- Reemplaza el validador histórico de la base real, que contaba pendientes y todos los roles.
create or replace function cuidared.fn_trg_membresia_limite() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_rol text; v_rol_anterior text; v_id bigint;
begin
  if new.estado <> 'activa' then return new; end if;
  perform cuidared_interno.bloquear_miembros(new.cuenta_id);
  select codigo::text into v_rol from cuidared.rol where rol_id = new.rol_id;
  if tg_op = 'UPDATE' then
    v_id := old.membresia_id;
    if old.cuenta_id = new.cuenta_id and old.estado = 'activa' then
      select codigo::text into v_rol_anterior from cuidared.rol where rol_id = old.rol_id;
    end if;
  end if;
  perform cuidared_interno.exigir_cupo_miembro(new.cuenta_id, v_rol, v_rol_anterior, v_id);
  return new;
end $$;
revoke all on function cuidared.fn_trg_membresia_limite() from public, anon, authenticated;
create or replace trigger trg_membresia_limite before insert or update of estado, rol_id, cuenta_id
on cuidared.membresia for each row execute function cuidared.fn_trg_membresia_limite();

/*
 * Valida una invitación y resuelve a la persona por correo. Devuelve {usuario_id (null si no existe), rol_id}.
 * La comparten api_preparar_invitacion (sin escribir) y api_agregar_miembro (bajo bloqueo).
 *   22023 entrada inválida · CR_ROL_NO_PERMITIDO · CR_IDENTIDAD_NO_COINCIDE (cédula distinta, persona inactiva o cédula
 *   ya registrada con otro correo: mismo error para no revelar cuál) · CR_YA_ES_MIEMBRO · CR_LIMITE_PLAN
 */
create function cuidared_interno.resolver_invitacion(p_cuenta_id bigint, p_correo text, p_cedula text, p_rol text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_tipo smallint;
  v_rol_id smallint;
  v_usuario record;
begin
  if p_correo is null or length(p_correo) > 254 or p_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     or p_cedula is null or p_cedula !~ '^[0-9]{11}$' or p_rol is null then
    raise invalid_parameter_value;
  end if;
  select c.tipo_cuenta_id into v_tipo from cuidared.cuenta c where c.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  v_rol_id := cuidared_interno.rol_del_tipo(p_rol, v_tipo);
  if v_rol_id is null then
    raise exception 'CR_ROL_NO_PERMITIDO' using errcode = 'P0001';
  end if;

  select u.usuario_id, u.cedula::text as cedula, u.estado::text as estado
    into v_usuario
    from cuidared.usuario u
    where lower(u.correo::text) = lower(btrim(p_correo))
    order by u.usuario_id
    limit 1;
  if found then
    if v_usuario.cedula <> p_cedula or v_usuario.estado <> 'activo' then
      raise exception 'CR_IDENTIDAD_NO_COINCIDE' using errcode = 'P0001';
    end if;
    if exists (select 1 from cuidared.membresia m
               where m.cuenta_id = p_cuenta_id and m.usuario_id = v_usuario.usuario_id
                 and m.estado::text in ('pendiente', 'activa')) then
      raise exception 'CR_YA_ES_MIEMBRO' using errcode = 'P0001';
    end if;
  elsif exists (select 1 from cuidared.usuario u where u.cedula::text = p_cedula) then
    raise exception 'CR_IDENTIDAD_NO_COINCIDE' using errcode = 'P0001';
  end if;

  return jsonb_build_object('usuario_id', v_usuario.usuario_id, 'rol_id', v_rol_id);
end;
$$;

-- Perfil global, visible solo mediante una membresía activa de Cuidador en la cuenta consultada.
create function cuidared_interno.cuidador_json(p_usuario_id uuid, p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'cuidador_id', cd.cuidador_id::text,
    'tipo_cuidado_id', cd.tipo_cuidado_id,
    'tipo_cuidado', tc.nombre,
    'cuidador_independiente', cd.cuidador_independiente,
    'usuario_empleador_id', case when exists (
      select 1 from cuidared_interno.membresia_activa(p_cuenta_id, cd.usuario_empleador_id)
    ) then cd.usuario_empleador_id end,
    'fecha_inicio', cd.fecha_inicio)
  from cuidared.cuidador cd
  join cuidared.tipo_cuidado tc on tc.tipo_cuidado_id = cd.tipo_cuidado_id
  where cd.usuario_id = p_usuario_id and cd.fecha_fin is null
    and exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m where m.rol = 'cuidador')
$$;

-- Fila de miembro (DTO). Solo datos de la persona que ve quien gestiona la cuenta.
create function cuidared_interno.miembro_json(p_membresia_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'membresia_id', m.membresia_id::text,
    'rol', r.codigo,
    'estado', m.estado,
    'fecha_inicio', m.fecha_inicio,
    'fecha_fin', m.fecha_fin,
    'es_titular', c.usuario_titular_id = m.usuario_id,
    'usuario', jsonb_build_object('id', u.usuario_id, 'nombres', u.nombres, 'apellidos', u.apellidos,
                                  'correo', u.correo, 'telefono', u.telefono),
    'cuidador', cuidared_interno.cuidador_json(m.usuario_id, m.cuenta_id))
  from cuidared.membresia m
  join cuidared.rol r on r.rol_id = m.rol_id
  join cuidared.usuario u on u.usuario_id = m.usuario_id
  join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
  where m.membresia_id = p_membresia_id
$$;

revoke all on all functions in schema cuidared_interno from public, anon, authenticated;

/* ───────────── 3. Lectura de miembros (usuarios:gestionar) ───────────── */

/*
 * Una fila por persona: su membresía vigente o, si no tiene, la más reciente (historial). Filtros por rol y estado de
 * esa fila. p_orden: arreglo JSON de campos permitidos con «-» para descendente (lista cerrada, nunca SQL del cliente).
 * Devuelve {total, items}; total y datos salen del mismo conjunto autorizado y filtrado.
 */
create function cuidared_api.api_listar_miembros(
  p_cuenta_id bigint,
  p_rol text default null,
  p_estado text default null,
  p_orden jsonb default '["nombres","apellidos","fecha_inicio","membresia_id"]'::jsonb,
  p_limite integer default 20,
  p_desplazamiento integer default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_orden text := '';
  v_token text;
  v_campo text;
  v_expr text;
  v_total bigint;
  v_items jsonb;
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'usuarios:gestionar');
  if p_limite is null or p_limite not between 1 and 100 or p_desplazamiento is null or p_desplazamiento < 0
     or (p_estado is not null and p_estado not in ('pendiente', 'activa', 'inactiva'))
     or (p_rol is not null and p_rol !~ '^[a-z_]{1,32}$')
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) not between 1 and 8 then
    raise invalid_parameter_value;
  end if;
  for v_token in select jsonb_array_elements_text(p_orden) loop
    v_campo := case when left(v_token, 1) = '-' then substr(v_token, 2) else v_token end;
    v_expr := case v_campo
      when 'nombres' then 'lower(f.nombres)'
      when 'apellidos' then 'lower(f.apellidos)'
      when 'fecha_inicio' then 'f.fecha_inicio'
      when 'rol' then 'f.rol'
      when 'estado' then 'f.estado'
      when 'membresia_id' then 'f.membresia_id'
    end;
    if v_expr is null then raise invalid_parameter_value; end if;
    v_orden := v_orden || case when v_orden = '' then '' else ', ' end || v_expr
               || case when left(v_token, 1) = '-' then ' desc' else ' asc' end;
  end loop;

  -- Las expresiones de orden salen de la lista cerrada de arriba; los valores del cliente van como parámetros.
  execute format($q$
    with base as (
      select distinct on (m.usuario_id) m.membresia_id, m.usuario_id, m.rol_id, m.estado, m.fecha_inicio
      from cuidared.membresia m
      where m.cuenta_id = $1
      order by m.usuario_id, (m.estado::text in ('pendiente', 'activa')) desc, m.membresia_id desc
    ), filtrada as (
      select b.membresia_id, b.fecha_inicio, b.estado::text as estado, u.nombres, u.apellidos, r.codigo::text as rol
      from base b
      join cuidared.usuario u on u.usuario_id = b.usuario_id
      join cuidared.rol r on r.rol_id = b.rol_id
      where ($2::text is null or r.codigo::text = $2) and ($3::text is null or b.estado::text = $3)
    )
    select (select count(*) from filtrada),
           coalesce((select jsonb_agg(cuidared_interno.miembro_json(pag.membresia_id) order by pag.ord)
                     from (select f.membresia_id, row_number() over (order by %s) as ord
                           from filtrada f order by ord limit $4 offset $5) pag), '[]'::jsonb)
  $q$, v_orden)
  into v_total, v_items
  using p_cuenta_id, p_rol, p_estado, p_limite, p_desplazamiento;
  return jsonb_build_object('total', v_total, 'items', v_items);
end;
$$;

-- Una membresía de la cuenta (vigente o histórica). P0002 si no existe en ESTA cuenta.
create function cuidared_api.api_detalle_miembro(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'usuarios:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  if not exists (select 1 from cuidared.membresia m where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id) then
    raise no_data_found;
  end if;
  return cuidared_interno.miembro_json(p_membresia_id);
end;
$$;

/* ───────────── 4. Invitar ───────────── */

-- Paso 1 (sin escribir): autoriza, valida rol y límites y dice si la persona ya existe. Si no existe, la API crea la
-- identidad Auth (el trigger crea el perfil) y llama a api_agregar_miembro, que vuelve a comprobar todo.
create function cuidared_api.api_preparar_invitacion(p_cuenta_id bigint, p_correo text, p_cedula text, p_rol text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_res jsonb;
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'usuarios:gestionar');
  v_res := cuidared_interno.resolver_invitacion(p_cuenta_id, p_correo, p_cedula, p_rol);
  return jsonb_build_object('usuario_existe', (v_res->>'usuario_id') is not null);
end;
$$;

-- Paso 2: crea la membresía pendiente (y avisa a la persona). La identidad sale de correo + cédula, nunca de un id del cliente.
create function cuidared_api.api_agregar_miembro(p_cuenta_id bigint, p_correo text, p_cedula text, p_rol text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_res jsonb;
  v_id bigint;
begin
  perform cuidared_interno.exigir_miembros(p_cuenta_id, 'usuarios:gestionar');
  v_res := cuidared_interno.resolver_invitacion(p_cuenta_id, p_correo, p_cedula, p_rol);
  -- La identidad aún no está disponible (la invitación Auth no se completó): no hay a quién agregar.
  if (v_res->>'usuario_id') is null then raise no_data_found; end if;
  insert into cuidared.membresia (usuario_id, cuenta_id, rol_id, estado, fecha_inicio)
  values ((v_res->>'usuario_id')::uuid, p_cuenta_id, (v_res->>'rol_id')::smallint, 'pendiente', cuidared_interno.hoy())
  returning membresia_id into v_id;
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
  select m.usuario_id, m.cuenta_id,
         format('Te invitaron a la cuenta "%s" como %s. Acepta o rechaza la invitación desde tus cuentas.', c.nombre, r.nombre)
  from cuidared.membresia m
  join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
  join cuidared.rol r on r.rol_id = m.rol_id
  where m.membresia_id = v_id;
  return cuidared_interno.miembro_json(v_id);
end;
$$;

/* ───────────── 5. Membresías propias: aceptar y rechazar ───────────── */

-- Solo la persona invitada y solo sobre su membresía pendiente. No usa exigir(): aún no tiene membresía activa.
create function cuidared_api.api_aceptar_membresia(p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_cuenta bigint;
  v_m record;
begin
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  select m.cuenta_id into v_cuenta from cuidared.membresia m where m.membresia_id = p_membresia_id and m.usuario_id = v_uid;
  if not found then raise no_data_found; end if;
  perform cuidared_interno.bloquear_miembros(v_cuenta);
  if not cuidared_interno.acceso_operativo(v_cuenta) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;
  select m.membresia_id, m.cuenta_id, m.estado::text as estado, r.codigo::text as rol
    into v_m
    from cuidared.membresia m join cuidared.rol r on r.rol_id = m.rol_id
    where m.membresia_id = p_membresia_id and m.usuario_id = v_uid
    for update of m;
  if v_m.estado <> 'pendiente' then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  -- La invitación no reserva plaza. El cupo se comprueba al activar la membresía.
  perform cuidared_interno.exigir_cupo_miembro(v_m.cuenta_id, v_m.rol, null, v_m.membresia_id);
  update cuidared.membresia
     set estado = 'activa', fecha_inicio = cuidared_interno.hoy(), fecha_fin = null, fecha_actualizacion = now()
   where membresia_id = v_m.membresia_id;
  return jsonb_build_object('membresia_id', v_m.membresia_id::text, 'cuenta_id', v_m.cuenta_id::text, 'rol', v_m.rol, 'estado', 'activa');
end;
$$;

create function cuidared_api.api_rechazar_membresia(p_membresia_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_cuenta bigint;
  v_estado text;
begin
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  select m.cuenta_id into v_cuenta from cuidared.membresia m where m.membresia_id = p_membresia_id and m.usuario_id = v_uid;
  if not found then raise no_data_found; end if;
  perform cuidared_interno.bloquear_miembros(v_cuenta);
  if not cuidared_interno.acceso_operativo(v_cuenta) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;
  select m.estado::text into v_estado from cuidared.membresia m
    where m.membresia_id = p_membresia_id and m.usuario_id = v_uid for update;
  if v_estado <> 'pendiente' then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  update cuidared.membresia
     set estado = 'inactiva', fecha_fin = cuidared_interno.hoy(), fecha_actualizacion = now()
   where membresia_id = p_membresia_id;
end;
$$;

/* ───────────── 6. Cambiar rol, desactivar y reactivar ───────────── */

-- Cierra la membresía actual (historial) y abre otra con el rol nuevo. Devuelve la membresía nueva.
create function cuidared_api.api_cambiar_rol_miembro(p_cuenta_id bigint, p_membresia_id bigint, p_rol text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_m record;
  v_rol_id smallint;
  v_nueva bigint;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'usuarios:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 or p_rol is null then raise invalid_parameter_value; end if;
  select m.membresia_id, m.usuario_id, m.rol_id, m.estado::text as estado, r.codigo::text as rol,
         c.tipo_cuenta_id, c.usuario_titular_id
    into v_m
    from cuidared.membresia m
    join cuidared.rol r on r.rol_id = m.rol_id
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id
    for update of m;
  if not found then raise no_data_found; end if;
  if v_m.usuario_id = (v_ctx->>'usuario_id')::uuid then
    raise exception 'CR_MEMBRESIA_PROPIA' using errcode = 'P0001';
  end if;
  if v_m.estado <> 'activa' then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  v_rol_id := cuidared_interno.rol_del_tipo(p_rol, v_m.tipo_cuenta_id);
  if v_rol_id is null then
    raise exception 'CR_ROL_NO_PERMITIDO' using errcode = 'P0001';
  end if;
  if v_rol_id = v_m.rol_id then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001'; -- ya tiene ese rol: nada que cambiar
  end if;
  if cuidared_interno.rol_gestor(v_m.rol_id, v_m.tipo_cuenta_id) and not cuidared_interno.rol_gestor(v_rol_id, v_m.tipo_cuenta_id) then
    if v_m.usuario_id = v_m.usuario_titular_id then
      raise exception 'CR_TITULAR_PROTEGIDO' using errcode = 'P0001';
    end if;
    perform cuidared_interno.exigir_otro_gestor(p_cuenta_id, v_m.usuario_id);
  end if;
  perform cuidared_interno.exigir_cupo_miembro(p_cuenta_id, p_rol, v_m.rol);

  update cuidared.membresia
     set estado = 'inactiva', fecha_fin = cuidared_interno.hoy(), fecha_actualizacion = now()
   where membresia_id = v_m.membresia_id;
  insert into cuidared.membresia (usuario_id, cuenta_id, rol_id, estado, fecha_inicio)
  values (v_m.usuario_id, p_cuenta_id, v_rol_id, 'activa', cuidared_interno.hoy())
  returning membresia_id into v_nueva;

  -- D04: conservar el historial y revocar solo accesos incompatibles de esta cuenta.
  update cuidared.vinculo v
     set fecha_revocacion = clock_timestamp(), motivo_revocacion = 'Cambio de rol'
    from cuidared.envejeciente e, cuidared.tipo_vinculo tv
   where v.envejeciente_id = e.envejeciente_id and e.cuenta_id = p_cuenta_id and v.usuario_id = v_m.usuario_id
     and tv.tipo_vinculo_id = v.tipo_vinculo_id
     and v.fecha_revocacion is null
     and tv.codigo::text in ('cuidador_asignado', 'voluntario_asignado', 'familiar_responsable')
     and tv.codigo::text is distinct from case p_rol when 'cuidador' then 'cuidador_asignado'
                                                     when 'voluntario' then 'voluntario_asignado'
                                                     when 'familiar' then 'familiar_responsable' end;
  return cuidared_interno.miembro_json(v_nueva);
end;
$$;

-- Baja: la membresía queda inactiva con fecha_fin (también cancela una invitación pendiente). El acceso se revoca
-- porque membresia_activa deja de devolverla.
create function cuidared_api.api_desactivar_miembro(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_m record;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'usuarios:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  select m.membresia_id, m.usuario_id, m.rol_id, m.estado::text as estado, c.tipo_cuenta_id, c.usuario_titular_id
    into v_m
    from cuidared.membresia m
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id
    for update of m;
  if not found then raise no_data_found; end if;
  if v_m.usuario_id = (v_ctx->>'usuario_id')::uuid then
    raise exception 'CR_MEMBRESIA_PROPIA' using errcode = 'P0001';
  end if;
  if v_m.estado not in ('pendiente', 'activa') then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if v_m.usuario_id = v_m.usuario_titular_id then
    raise exception 'CR_TITULAR_PROTEGIDO' using errcode = 'P0001';
  end if;
  if v_m.estado = 'activa' and cuidared_interno.rol_gestor(v_m.rol_id, v_m.tipo_cuenta_id) then
    perform cuidared_interno.exigir_otro_gestor(p_cuenta_id, v_m.usuario_id);
  end if;
  update cuidared.membresia
     set estado = 'inactiva', fecha_fin = cuidared_interno.hoy(), fecha_actualizacion = now()
   where membresia_id = v_m.membresia_id;
  return cuidared_interno.miembro_json(v_m.membresia_id);
end;
$$;

-- Reactiva: abre una membresía activa nueva con el mismo rol (la indicada debe ser la más reciente de la persona).
create function cuidared_api.api_reactivar_miembro(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_m record;
  v_nueva bigint;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'usuarios:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  select m.membresia_id, m.usuario_id, m.estado::text as estado, r.codigo::text as rol,
         c.tipo_cuenta_id, u.estado::text as usuario_estado
    into v_m
    from cuidared.membresia m
    join cuidared.rol r on r.rol_id = m.rol_id
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    join cuidared.usuario u on u.usuario_id = m.usuario_id
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id
    for update of m;
  if not found then raise no_data_found; end if;
  if v_m.usuario_id = (v_ctx->>'usuario_id')::uuid then
    raise exception 'CR_MEMBRESIA_PROPIA' using errcode = 'P0001';
  end if;
  if v_m.estado <> 'inactiva' or v_m.usuario_estado <> 'activo'
     or exists (select 1 from cuidared.membresia o
                where o.cuenta_id = p_cuenta_id and o.usuario_id = v_m.usuario_id and o.membresia_id > v_m.membresia_id) then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if cuidared_interno.rol_del_tipo(v_m.rol, v_m.tipo_cuenta_id) is null then
    raise exception 'CR_ROL_NO_PERMITIDO' using errcode = 'P0001';
  end if;
  perform cuidared_interno.exigir_cupo_miembro(p_cuenta_id, v_m.rol);
  insert into cuidared.membresia (usuario_id, cuenta_id, rol_id, estado, fecha_inicio)
  select v_m.usuario_id, p_cuenta_id, m.rol_id, 'activa', cuidared_interno.hoy()
    from cuidared.membresia m where m.membresia_id = v_m.membresia_id
  returning membresia_id into v_nueva;
  return cuidared_interno.miembro_json(v_nueva);
end;
$$;

/* ───────────── 7. Titularidad ───────────── */

-- Solo el titular actual. El destino: miembro activo con rol gestor del tipo de cuenta (otra persona).
create function cuidared_api.api_transferir_titularidad(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ctx jsonb;
  v_m record;
begin
  v_ctx := cuidared_interno.exigir_miembros(p_cuenta_id, 'usuarios:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  if not exists (select 1 from cuidared.cuenta c
                 where c.cuenta_id = p_cuenta_id and c.usuario_titular_id = (v_ctx->>'usuario_id')::uuid) then
    raise insufficient_privilege;
  end if;
  select m.usuario_id, m.rol_id, m.estado::text as estado, c.tipo_cuenta_id, u.estado::text as usuario_estado
    into v_m
    from cuidared.membresia m
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    join cuidared.usuario u on u.usuario_id = m.usuario_id
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if v_m.usuario_id = (v_ctx->>'usuario_id')::uuid or v_m.estado <> 'activa' or v_m.usuario_estado <> 'activo' then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, v_m.usuario_id) m
                 where cuidared_interno.rol_gestor(m.rol_id, m.tipo_cuenta_id)) then
    raise exception 'CR_DESTINO_NO_GESTOR' using errcode = 'P0001';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cuidared.registrar_cuenta:' || v_m.usuario_id::text, 0));
  if exists (select 1 from cuidared.cuenta c where c.cuenta_id = p_cuenta_id and c.suscripcion_estado = 'prueba'
             and cuidared_interno.acceso_operativo(c.cuenta_id))
     and exists (select 1 from cuidared.cuenta c where c.usuario_titular_id = v_m.usuario_id
                 and c.suscripcion_estado = 'prueba' and cuidared_interno.acceso_operativo(c.cuenta_id)) then
    raise exception 'CR_PRUEBA_EN_CURSO' using errcode = 'P0001';
  end if;
  update cuidared.cuenta set usuario_titular_id = v_m.usuario_id, fecha_actualizacion = now() where cuenta_id = p_cuenta_id;
  return jsonb_build_object('cuenta_id', p_cuenta_id::text, 'usuario_titular_id', v_m.usuario_id, 'membresia_id', p_membresia_id::text);
end;
$$;

/* ───────────── 8. Perfil Cuidador (RF-12, cuidadores:gestionar) ───────────── */

create function cuidared_api.api_obtener_cuidador_miembro(p_cuenta_id bigint, p_membresia_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_usuario uuid;
begin
  perform cuidared_interno.exigir(p_cuenta_id, 'cuidadores:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 then raise invalid_parameter_value; end if;
  select m.usuario_id into v_usuario from cuidared.membresia m where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  return cuidared_interno.cuidador_json(v_usuario, p_cuenta_id);
end;
$$;

-- Crea o actualiza el perfil global. Solo para una membresía activa con rol Cuidador.
create function cuidared_api.api_guardar_cuidador_miembro(
  p_cuenta_id bigint, p_membresia_id bigint, p_tipo_cuidado_id smallint, p_cuidador_independiente boolean
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_m record;
begin
  perform cuidared_interno.exigir_miembros(p_cuenta_id, 'cuidadores:gestionar');
  if p_membresia_id is null or p_membresia_id <= 0 or p_tipo_cuidado_id is null or p_cuidador_independiente is null then
    raise invalid_parameter_value;
  end if;
  select m.usuario_id, m.estado::text as estado, r.codigo::text as rol, c.usuario_titular_id
    into v_m
    from cuidared.membresia m
    join cuidared.rol r on r.rol_id = m.rol_id
    join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
    where m.membresia_id = p_membresia_id and m.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if v_m.rol <> 'cuidador' then
    raise exception 'CR_NO_ES_CUIDADOR' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared_interno.membresia_activa(p_cuenta_id, v_m.usuario_id) m
                 where m.membresia_id = p_membresia_id and m.rol = 'cuidador') then
    raise exception 'CR_ESTADO_INVALIDO' using errcode = 'P0001';
  end if;
  if not exists (select 1 from cuidared.tipo_cuidado t where t.tipo_cuidado_id = p_tipo_cuidado_id) then
    raise invalid_parameter_value;
  end if;
  insert into cuidared.cuidador (usuario_id, tipo_cuidado_id, fecha_inicio, cuidador_independiente, usuario_empleador_id)
  values (v_m.usuario_id, p_tipo_cuidado_id, cuidared_interno.hoy(), p_cuidador_independiente,
          case when p_cuidador_independiente then null else v_m.usuario_titular_id end)
  on conflict (usuario_id) do update set
    tipo_cuidado_id = excluded.tipo_cuidado_id,
    cuidador_independiente = excluded.cuidador_independiente,
    usuario_empleador_id = excluded.usuario_empleador_id,
    fecha_fin = null;
  return cuidared_interno.cuidador_json(v_m.usuario_id, p_cuenta_id);
end;
$$;

-- Directorio mínimo y paginado para elegir participantes, asignaciones y cuidadores.
create function cuidared_api.api_candidatos_cuenta(
  p_cuenta_id bigint, p_uso text, p_offset bigint, p_limit integer, p_orden jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_permiso text;
  v_roles text[];
  v_item jsonb;
  v_campo text;
  v_direccion text;
  v_orden text := '';
  v_resultado jsonb;
begin
  case p_uso
    when 'visita' then v_permiso := 'visitas:programar'; v_roles := array['coordinador','cuidador','voluntario'];
    when 'asignacion' then v_permiso := 'adultos:asignar'; v_roles := array['cuidador','voluntario'];
    when 'familiar' then v_permiso := 'familiares:autorizar'; v_roles := array['familiar'];
    when 'agenda' then v_permiso := 'agenda:gestionar'; v_roles := array['cuidador'];
    when 'cuidado' then v_permiso := 'cuidadores:gestionar'; v_roles := array['cuidador'];
    when 'titularidad' then v_permiso := 'usuarios:gestionar'; v_roles := array['administrador','coordinador'];
    else raise invalid_parameter_value;
  end case;
  perform cuidared_interno.exigir(p_cuenta_id, v_permiso);
  if p_uso = 'visita' then perform cuidared_interno.exigir(p_cuenta_id, 'visitas:autorizar'); end if;
  if p_uso = 'titularidad' and not exists (
    select 1 from cuidared.cuenta where cuenta_id = p_cuenta_id and usuario_titular_id = auth.uid()
  ) then raise insufficient_privilege; end if;
  if p_offset is null or p_offset < 0 or p_limit is null or p_limit not between 1 and 100
     or jsonb_typeof(p_orden) is distinct from 'array' or jsonb_array_length(p_orden) > 2 then
    raise invalid_parameter_value;
  end if;
  for v_item in select value from jsonb_array_elements(p_orden) loop
    v_campo := v_item->>'field';
    v_direccion := v_item->>'direction';
    if v_campo is null or v_campo not in ('nombre','usuario_id') or
       v_direccion is null or v_direccion not in ('asc','desc') then raise invalid_parameter_value; end if;
    v_orden := v_orden || format('%I %s, ', v_campo, v_direccion);
  end loop;
  execute format($q$
    with candidatos as (
      select u.usuario_id, u.nombres || ' ' || u.apellidos as nombre, m.rol,
             m.membresia_id::text as membresia_id, c.cuidador_id::text as cuidador_id
      from cuidared.membresia x join cuidared.usuario u on u.usuario_id = x.usuario_id
      join lateral cuidared_interno.membresia_activa($1, u.usuario_id) m on m.membresia_id = x.membresia_id
      left join cuidared.cuidador c on c.usuario_id = u.usuario_id and c.fecha_fin is null
      where x.cuenta_id = $1 and m.rol = any($2) and ($3 <> 'agenda' or c.cuidador_id is not null)
        and ($3 <> 'titularidad' or (u.usuario_id <> auth.uid() and cuidared_interno.rol_gestor(m.rol_id,m.tipo_cuenta_id)))
    ), pagina as (
      select *, row_number() over (order by %1$s usuario_id) as rn
      from candidatos order by %1$s usuario_id limit $4 offset $5
    )
    select jsonb_build_object('items', coalesce((select jsonb_agg(to_jsonb(p) - 'rn' order by rn) from pagina p), '[]'::jsonb),
                              'total', (select count(*) from candidatos))
  $q$, v_orden) into v_resultado using p_cuenta_id, v_roles, p_uso, p_limit, p_offset;
  return v_resultado;
end $$;
revoke all on function cuidared_api.api_candidatos_cuenta(bigint,text,bigint,integer,jsonb) from public, anon;
grant execute on function cuidared_api.api_candidatos_cuenta(bigint,text,bigint,integer,jsonb) to authenticated;

/* ───────────── 9. Permisos de las RPC ───────────── */

revoke all on function
  cuidared_api.api_listar_miembros(bigint, text, text, jsonb, integer, integer),
  cuidared_api.api_detalle_miembro(bigint, bigint),
  cuidared_api.api_preparar_invitacion(bigint, text, text, text),
  cuidared_api.api_agregar_miembro(bigint, text, text, text),
  cuidared_api.api_aceptar_membresia(bigint),
  cuidared_api.api_rechazar_membresia(bigint),
  cuidared_api.api_cambiar_rol_miembro(bigint, bigint, text),
  cuidared_api.api_desactivar_miembro(bigint, bigint),
  cuidared_api.api_reactivar_miembro(bigint, bigint),
  cuidared_api.api_transferir_titularidad(bigint, bigint),
  cuidared_api.api_obtener_cuidador_miembro(bigint, bigint),
  cuidared_api.api_guardar_cuidador_miembro(bigint, bigint, smallint, boolean)
  from public, anon;
grant execute on function
  cuidared_api.api_listar_miembros(bigint, text, text, jsonb, integer, integer),
  cuidared_api.api_detalle_miembro(bigint, bigint),
  cuidared_api.api_preparar_invitacion(bigint, text, text, text),
  cuidared_api.api_agregar_miembro(bigint, text, text, text),
  cuidared_api.api_aceptar_membresia(bigint),
  cuidared_api.api_rechazar_membresia(bigint),
  cuidared_api.api_cambiar_rol_miembro(bigint, bigint, text),
  cuidared_api.api_desactivar_miembro(bigint, bigint),
  cuidared_api.api_reactivar_miembro(bigint, bigint),
  cuidared_api.api_transferir_titularidad(bigint, bigint),
  cuidared_api.api_obtener_cuidador_miembro(bigint, bigint),
  cuidared_api.api_guardar_cuidador_miembro(bigint, bigint, smallint, boolean)
  to authenticated;

commit;
