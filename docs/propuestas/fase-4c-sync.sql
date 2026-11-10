-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 4 · Visitas y Seguimiento, bloque 4c (ID04) — sincronización de visitas registradas sin conexión.
-- RF-10, RF-4.5, RNF-4.2 · CU-14 · Reglas de Negocio V2 (D07: una cuenta vencida no admite escrituras operativas).
-- Depende de docs/propuestas/fase-2a-base.sql (exigir_sesion, exigir, acceso_operativo, permisos, v_uuid) y de
-- docs/propuestas/fase-4a-visitas.sql (registrar_visita_realizada, iniciar_visita, bloquear_visita, exigir_operar_visita,
-- tiene_permiso, v_texto, visita.fecha_actualizacion). Validada en un PostgreSQL local con
-- `node scripts/validar-propuestas-local.js --solo=3a,3b,4a,4c` (esquema auth simulado; no certifica RLS ni Auth de Supabase).
-- © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (registro y razones en docs/contratos/sync.md). D16 sigue ABIERTA en CONTEXTO-BACKEND.md §15.2: todo lo
-- marcado «Propuesta técnica (D16)» sirve para discutir y puede cambiar sin tocar el contrato de visitas.
--   · Confirmado (V2/SRS): marcas UTC, Last-Write-Wins, sin duplicados al reintentar, permisos revalidados al sincronizar y
--     cuenta vencida sin escrituras operativas.
--   · Propuesta técnica (D16): cada operación es su propia transacción (una RPC por operación): una operación rechazada no
--     revierte las demás del lote.
--   · Propuesta técnica (D16): idempotencia por `id_cliente` (UUID de la operación) persistida en cuidared.operacion_sync. El
--     reintento de una operación ya resuelta (aplicada, conflicto o duplicada) devuelve su resultado como `duplicada` sin
--     aplicar nada; una `rechazada` se vuelve a evaluar al reintentar (puede haberse corregido el permiso, la suscripción o el
--     reloj) y los efectos siguen siendo idempotentes por visita_id (4a).
--   · Propuesta técnica (D16): el reloj del dispositivo es la marca de escritura; se rechaza una marca más de 5 minutos en el
--     futuro (RELOJ_INVALIDO). No hay límite inferior: un reloj atrasado solo hace perder los conflictos.
--   · Propuesta técnica (D16): conflicto = el servidor cambió la visita después de la versión base del cliente. Gana la escritura
--     más reciente; en empate gana el servidor. La marca del servidor es la de su escritura efectiva: la `fecha_actualizacion`
--     de la visita o, si esa versión la produjo una operación sincronizada, la marca del dispositivo de esa operación (así el
--     orden de llegada del lote no decide). Una visita completada o cancelada es terminal (D10): nunca se modifica.
--   · Propuesta técnica (D16): la comparación se hace en milisegundos (el cliente JavaScript solo guarda milisegundos).
--   · Extensible por entidad: solo `visita` en este bloque; cualquier otra devuelve `rechazada` / ENTIDAD_NO_SOPORTADA.
begin;

/* ───────────── 1. Operaciones sincronizadas (idempotencia y trazabilidad) ───────────── */

-- Una fila por operación del cliente. `id_cliente` es la clave de idempotencia: la genera el dispositivo (UUID) y es única en
-- toda la plataforma; no se admite reutilizarla por otro usuario, en otra cuenta ni para otra operación. No guarda el contenido
-- de la operación (observaciones, adultos): solo qué se pidió, qué se resolvió y con qué marcas.
create table cuidared.operacion_sync (
  id_cliente uuid not null,
  usuario_id uuid not null,
  cuenta_id bigint not null,
  entidad character varying not null check (entidad::text ~ '^[a-z][a-z_]{0,29}$'),
  tipo character varying not null check (tipo::text ~ '^[a-z][a-z_]{0,29}$'),
  registro_id uuid not null,
  resultado character varying not null check (resultado::text in ('aplicada', 'duplicada', 'conflicto', 'rechazada')),
  motivo character varying check (motivo is null or motivo::text ~ '^[A-Z][A-Z0-9_]{0,59}$'),
  -- Solo en un conflicto: qué versión se conservó.
  gana character varying check (gana is null or gana::text in ('local', 'servidor')),
  actualizado_en_cliente timestamp with time zone not null,
  base_actualizado_en timestamp with time zone,
  -- Versión de la visita en el servidor tras resolver (null si no hay nada que informar, p. ej. un rechazo).
  actualizado_en_servidor timestamp with time zone,
  procesada_en timestamp with time zone not null default now(),
  constraint operacion_sync_pkey primary key (id_cliente),
  constraint fk_operacion_sync_usuario foreign key (usuario_id) references cuidared.usuario(usuario_id),
  constraint fk_operacion_sync_cuenta foreign key (cuenta_id) references cuidared.cuenta(cuenta_id),
  -- Coherencia del resultado: un rechazo explica su motivo; solo un conflicto dice quién gana.
  constraint ck_operacion_sync_resultado check (
    (resultado::text <> 'rechazada' or motivo is not null) and ((resultado::text = 'conflicto') = (gana is not null)))
);
-- Segunda barrera de duplicados y versión efectiva: operaciones de una visita.
create index ix_operacion_sync_registro on cuidared.operacion_sync (cuenta_id, entidad, registro_id, usuario_id);
create index ix_operacion_sync_usuario on cuidared.operacion_sync (cuenta_id, usuario_id, procesada_en desc);

-- Sin acceso directo: solo a través de las RPC. La retención de estas filas es una decisión pendiente (D15).
alter table cuidared.operacion_sync enable row level security;
revoke all on cuidared.operacion_sync from public, anon, authenticated;

/* ───────────── 2. Utilidades internas ───────────── */

-- Marca UTC en el formato que usa el cliente: ISO 8601 con milisegundos y «Z» (el cliente devuelve esta cadena como base).
create function cuidared_interno.sync_iso(p_marca timestamp with time zone) returns text
language sql immutable set search_path = '' as $$
  select pg_catalog.to_char(p_marca at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;

-- Las marcas se comparan en milisegundos: el cliente JavaScript no conserva los microsegundos de la base.
create function cuidared_interno.sync_ms(p_marca timestamp with time zone) returns timestamp with time zone
language sql stable set search_path = '' as $$
  select pg_catalog.date_trunc('milliseconds', p_marca)
$$;

-- Marca UTC de entrada: texto ISO 8601 con «Z» (no se aceptan desfases ni fechas sin zona). Toda entrada inválida es 22023.
create function cuidared_interno.v_marca(p_valor jsonb, p_requerido boolean default true)
returns timestamp with time zone language plpgsql stable set search_path = '' as $$
declare v_texto text;
begin
  if p_valor is null or jsonb_typeof(p_valor) = 'null' then
    if p_requerido then raise invalid_parameter_value; end if;
    return null;
  end if;
  if jsonb_typeof(p_valor) <> 'string' then raise invalid_parameter_value; end if;
  v_texto := p_valor #>> '{}';
  if v_texto !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$' then
    raise invalid_parameter_value;
  end if;
  begin
    return v_texto::timestamp with time zone;
  exception when data_exception then
    raise invalid_parameter_value;
  end;
end $$;

-- Elemento de la respuesta de una operación (el mismo para el lote y para la consulta posterior).
create function cuidared_interno.sync_item(
  p_id_cliente uuid, p_registro_id uuid, p_resultado text, p_motivo text, p_gana text, p_original text,
  p_servidor timestamp with time zone
) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id_cliente', p_id_cliente,
    'resultado', p_resultado,
    'registro_id', p_registro_id,
    'motivo', p_motivo,
    'gana', p_gana,
    'resultado_original', p_original,
    'actualizado_en_servidor', cuidared_interno.sync_iso(p_servidor))
$$;

-- Guarda el resultado de una operación. Una fila ya resuelta (no rechazada) no se sobrescribe nunca: solo un rechazo puede
-- reevaluarse en un reintento y solo por el mismo usuario y cuenta que lo envió.
create function cuidared_interno.sync_registrar(
  p_id_cliente uuid, p_usuario_id uuid, p_cuenta_id bigint, p_entidad text, p_tipo text, p_registro_id uuid,
  p_resultado text, p_motivo text, p_gana text, p_cliente timestamp with time zone, p_base timestamp with time zone,
  p_servidor timestamp with time zone
) returns void language sql set search_path = '' as $$
  insert into cuidared.operacion_sync (id_cliente, usuario_id, cuenta_id, entidad, tipo, registro_id, resultado, motivo, gana,
                                       actualizado_en_cliente, base_actualizado_en, actualizado_en_servidor)
  values (p_id_cliente, p_usuario_id, p_cuenta_id, p_entidad, p_tipo, p_registro_id, p_resultado, p_motivo, p_gana,
          p_cliente, p_base, p_servidor)
  on conflict (id_cliente) do update
    set resultado = excluded.resultado, motivo = excluded.motivo, gana = excluded.gana,
        actualizado_en_cliente = excluded.actualizado_en_cliente, base_actualizado_en = excluded.base_actualizado_en,
        actualizado_en_servidor = excluded.actualizado_en_servidor, procesada_en = now()
    where cuidared.operacion_sync.resultado::text = 'rechazada'
      and cuidared.operacion_sync.usuario_id = excluded.usuario_id and cuidared.operacion_sync.cuenta_id = excluded.cuenta_id
$$;

/* ───────────── 3. Aplicación de una operación sobre una visita ───────────── */

/*
 * Aplica una operación de visita (`registrar` o `iniciar`) con Last-Write-Wins. Devuelve el resultado en los parámetros OUT:
 *   o_resultado  aplicada | duplicada | conflicto
 *   o_motivo     motivo informativo (VISIT_CLOSED, SERVIDOR_MAS_RECIENTE, YA_REGISTRADA, YA_INICIADA) o null
 *   o_gana       en un conflicto: 'servidor' o 'local'
 *   o_servidor   versión de la visita (fecha_actualizacion) tras resolver
 * Cualquier incumplimiento de permisos o reglas se señala con una excepción (42501, P0002, 22023, 23514 o CR_*); el llamador
 * la convierte en un resultado `rechazada` y, al ser una subtransacción, nada de lo escrito aquí sobrevive.
 *
 * Orden de bloqueos idéntico al de 4a (bloqueo asesor por visita → solicitud → visita) para no crear interbloqueos con
 * api_registrar_visita_realizada, api_cancelar_visita ni la observación del visitante. La comparación de versiones ocurre con la
 * visita bloqueada: no hay carrera entre leer su versión y escribir.
 *
 * Una visita ajena (otra cuenta, o la que el usuario no ve) no se distingue de una inexistente salvo por el motivo más genérico
 * posible, y la versión del servidor solo se calcula después de revalidar membresía, permiso, alcance y participación.
 */
create function cuidared_interno.sync_visita(
  p_cuenta_id bigint, p_usuario_id uuid, p_id_cliente uuid, p_tipo text, p_visita_id uuid, p_datos jsonb,
  p_cliente timestamp with time zone, p_base timestamp with time zone,
  out o_resultado text, out o_motivo text, out o_gana text, out o_servidor timestamp with time zone
) returns record language plpgsql set search_path = '' as $$
declare
  v_v cuidared.visita;
  v_s timestamp with time zone;
  v_w timestamp with time zone;
  v_productor boolean;
  v_prod_usuario uuid;
  v_prod_cliente timestamp with time zone;
  v_cambio boolean;
  v_local boolean := false;
begin
  if p_tipo = 'iniciar' and p_datos <> '{}'::jsonb then raise invalid_parameter_value; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_visita_id::text, 0));
  v_v := cuidared_interno.bloquear_visita(p_visita_id);

  -- La cola solo puede operar sobre visitas que el servidor ya programó.
  if v_v.visita_id is null then
    raise no_data_found;
  end if;

  if v_v.cuenta_id is distinct from p_cuenta_id then
    if p_tipo = 'iniciar' then raise no_data_found; end if;
    raise insufficient_privilege;
  end if;

  -- Revalida membresía activa, visitas:registrar, acceso operativo, visibilidad y participación (o gestión) antes de revelar
  -- nada de la visita. Registrar sobre una visita que no ve se responde como falta de permiso, no como inexistente.
  begin
    perform cuidared_interno.exigir_operar_visita(p_cuenta_id, p_visita_id, p_usuario_id);
  exception when no_data_found then
    if p_tipo = 'registrar' then raise insufficient_privilege; end if;
    raise;
  end;

  v_s := cuidared_interno.sync_ms(v_v.fecha_actualizacion);
  o_servidor := v_v.fecha_actualizacion;

  -- Segunda barrera: la misma captura (misma marca del dispositivo) reenviada con otra clave ya se resolvió.
  if exists (
       select 1 from cuidared.operacion_sync o
       where o.cuenta_id = p_cuenta_id and o.usuario_id = p_usuario_id and o.entidad::text = 'visita'
         and o.tipo::text = p_tipo and o.registro_id = p_visita_id and o.actualizado_en_cliente = p_cliente
         and o.id_cliente <> p_id_cliente and o.resultado::text <> 'rechazada') then
    o_resultado := 'duplicada';
    o_motivo := case p_tipo when 'registrar' then 'YA_REGISTRADA' else 'YA_INICIADA' end;
    return;
  end if;

  -- Marca de escritura efectiva de la versión actual: la del dispositivo si la produjo una operación sincronizada; si no, la
  -- del servidor (escritura en línea). Así el orden de llegada de un lote no decide quién escribió después.
  select o.usuario_id, o.actualizado_en_cliente into v_prod_usuario, v_prod_cliente
  from cuidared.operacion_sync o
  where o.cuenta_id = p_cuenta_id and o.entidad::text = 'visita' and o.registro_id = p_visita_id
    and (o.resultado::text = 'aplicada' or (o.resultado::text = 'conflicto' and o.gana::text = 'local'))
    and cuidared_interno.sync_ms(o.actualizado_en_servidor) = v_s
  order by o.procesada_en desc, o.actualizado_en_cliente desc
  limit 1;
  v_productor := found;
  v_w := case when v_productor then cuidared_interno.sync_ms(v_prod_cliente) else v_s end;

  -- ¿Cambió la visita en el servidor desde la versión que tenía el cliente?
  v_cambio := p_base is null or v_s > cuidared_interno.sync_ms(p_base);

  -- Visita cerrada (D10: terminal). Si cambió en el servidor es un conflicto y gana el servidor; si no, la operación no es
  -- válida (igual que en línea: CR_VISITA_CERRADA).
  if v_v.estado::text in ('completada', 'cancelada') then
    if v_cambio then
      o_resultado := 'conflicto'; o_gana := 'servidor'; o_motivo := 'VISIT_CLOSED';
      return;
    end if;
    raise exception 'CR_VISITA_CERRADA' using errcode = 'P0001';
  end if;

  -- Iniciar una visita que ya está en curso no cambia nada.
  if p_tipo = 'iniciar' and v_v.estado::text = 'en_curso' then
    o_resultado := 'duplicada'; o_motivo := 'YA_INICIADA';
    return;
  end if;

  -- Last-Write-Wins entre cambios que el dominio permite (visita programada o en curso).
  if v_cambio
     and not (v_productor and v_prod_usuario = p_usuario_id and v_w <= cuidared_interno.sync_ms(p_cliente)) then
    -- Hubo otra escritura. Gana la más reciente; en empate, el servidor.
    if v_w >= cuidared_interno.sync_ms(p_cliente) then
      o_resultado := 'conflicto'; o_gana := 'servidor'; o_motivo := 'SERVIDOR_MAS_RECIENTE';
      return;
    end if;
    v_local := true;
  end if;

  if p_tipo = 'registrar' then
    perform cuidared_interno.registrar_visita_realizada(p_cuenta_id, p_usuario_id, p_visita_id, p_datos);
  else
    perform cuidared_interno.iniciar_visita(p_cuenta_id, p_usuario_id, p_visita_id);
  end if;
  o_resultado := case when v_local then 'conflicto' else 'aplicada' end;
  o_gana := case when v_local then 'local' end;
  select v.fecha_actualizacion into o_servidor from cuidared.visita v where v.visita_id = p_visita_id;
end $$;

/* ───────────── 4. RPC de sincronización (cuidared_api) ───────────── */

/*
 * Resuelve UNA operación del lote. Express llama a esta RPC una vez por operación, en el orden recibido, de modo que cada una
 * es su propia transacción: lo que una rechaza o revierte no afecta a las demás.
 *
 *   p_cuenta_id  cuenta de la ruta.
 *   p_operacion  {id_cliente, entidad, tipo, registro_id, datos, actualizado_en, base_actualizado_en?}.
 *
 * Devuelve {id_cliente, resultado, registro_id, motivo, gana, resultado_original, actualizado_en_servidor}.
 *   28000  sin sesión vigente                                          → 401
 *   42501  sin membresía activa o sin sync:usar                        → 403 (nada se guarda)
 *   22023  operación mal formada (el contrato la valida antes)         → 422
 * Todo lo demás es un resultado de la operación (HTTP 200): aplicada | duplicada | conflicto | rechazada, con su motivo.
 * Una operación que no se puede responder por una falla de la base (excepción no clasificada) se propaga: Express responde 503
 * y el cliente reintenta con la misma clave sin perder nada.
 */
create function cuidared_api.api_sync_aplicar_operacion(p_cuenta_id bigint, p_operacion jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_id uuid;
  v_registro uuid;
  v_entidad text;
  v_tipo text;
  v_datos jsonb;
  v_cliente timestamp with time zone;
  v_base timestamp with time zone;
  v_ahora timestamp with time zone := pg_catalog.now();
  v_previa cuidared.operacion_sync;
  v_hay_previa boolean;
  v_res record;
  v_resultado text;
  v_motivo text;
  v_gana text;
  v_servidor timestamp with time zone;
  v_original text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or jsonb_typeof(p_operacion) is distinct from 'object'
     or length(p_operacion::text) > 65536
     or p_operacion - array['id_cliente', 'entidad', 'tipo', 'registro_id', 'datos', 'actualizado_en', 'base_actualizado_en']
        <> '{}'::jsonb then
    raise invalid_parameter_value;
  end if;
  -- Sin membresía activa o sin sync:usar no hay nada que registrar: 403 y no se guarda nada.
  if not cuidared_interno.tiene_permiso(p_cuenta_id, v_uid, 'sync:usar') then
    raise insufficient_privilege;
  end if;

  v_id := cuidared_interno.v_uuid(p_operacion->'id_cliente');
  v_registro := cuidared_interno.v_uuid(p_operacion->'registro_id');
  v_entidad := cuidared_interno.v_texto(p_operacion->'entidad', 1, 30);
  v_tipo := cuidared_interno.v_texto(p_operacion->'tipo', 1, 30);
  if v_entidad !~ '^[a-z][a-z_]{0,29}$' or v_tipo !~ '^[a-z][a-z_]{0,29}$'
     or jsonb_typeof(p_operacion->'datos') is distinct from 'object' then
    raise invalid_parameter_value;
  end if;
  v_datos := p_operacion->'datos';
  v_cliente := cuidared_interno.v_marca(p_operacion->'actualizado_en');
  v_base := cuidared_interno.v_marca(p_operacion->'base_actualizado_en', false);

  -- Serializa los reintentos con la misma clave: el segundo espera y ve la fila ya escrita.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id::text, 1));
  select * into v_previa from cuidared.operacion_sync o where o.id_cliente = v_id;
  v_hay_previa := found;

  -- La clave es de una sola operación de una sola persona en una sola cuenta: cualquier otro uso se rechaza sin revelar nada
  -- de la fila existente ni modificarla.
  if v_hay_previa and (v_previa.usuario_id <> v_uid or v_previa.cuenta_id <> p_cuenta_id or v_previa.entidad::text <> v_entidad
                       or v_previa.tipo::text <> v_tipo or v_previa.registro_id <> v_registro) then
    return cuidared_interno.sync_item(v_id, v_registro, 'rechazada', 'ID_CLIENTE_EN_USO', null, null, null);
  end if;

  begin
    if not cuidared_interno.acceso_operativo(p_cuenta_id) then
      -- D07: sin escrituras operativas. Es transitorio: al renovar la cuenta el mismo reintento se resuelve.
      v_resultado := 'rechazada'; v_motivo := 'SUBSCRIPTION_INACTIVE';
    elsif v_hay_previa and v_previa.resultado::text <> 'rechazada' then
      -- Reintento de una operación ya resuelta: se devuelve lo resuelto, sin aplicar nada.
      perform cuidared_interno.exigir_operar_visita(p_cuenta_id, v_registro, v_uid);
      v_resultado := 'duplicada'; v_original := v_previa.resultado::text; v_motivo := v_previa.motivo::text;
      v_gana := v_previa.gana::text; v_servidor := v_previa.actualizado_en_servidor;
    elsif v_entidad <> 'visita' then
      v_resultado := 'rechazada'; v_motivo := 'ENTIDAD_NO_SOPORTADA';
    elsif v_tipo not in ('registrar', 'iniciar') then
      v_resultado := 'rechazada'; v_motivo := 'TIPO_NO_SOPORTADO';
    elsif v_cliente > v_ahora + interval '5 minutes' or v_base > v_ahora + interval '5 minutes' then
      v_resultado := 'rechazada'; v_motivo := 'RELOJ_INVALIDO';
    else
      select * into v_res from cuidared_interno.sync_visita(p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      v_resultado := v_res.o_resultado; v_motivo := v_res.o_motivo; v_gana := v_res.o_gana; v_servidor := v_res.o_servidor;
    end if;
  exception
    -- Las reglas incumplidas son el resultado de ESTA operación; la subtransacción deshace lo que haya escrito.
    when insufficient_privilege then
      v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN'; v_gana := null; v_servidor := null;
    when no_data_found then
      v_resultado := 'rechazada'; v_motivo := 'NOT_FOUND'; v_gana := null; v_servidor := null;
    when data_exception or check_violation then
      v_resultado := 'rechazada'; v_motivo := 'INVALID_INPUT'; v_gana := null; v_servidor := null;
    when raise_exception then
      v_gana := null; v_servidor := null;
      case sqlerrm
        when 'CR_CUENTA_SIN_ACCESO' then v_resultado := 'rechazada'; v_motivo := 'SUBSCRIPTION_INACTIVE';
        when 'CR_VISITA_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'VISIT_CLOSED';
        when 'CR_ESTADO_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_NO_PARTICIPA' then v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN';
        when 'CR_CONFLICTO' then v_resultado := 'rechazada'; v_motivo := 'FORBIDDEN';
        else raise;
      end case;
  end;

  -- Un reintento de una operación ya resuelta no escribe nada (la fila original se conserva).
  if v_original is null then
    perform cuidared_interno.sync_registrar(v_id, v_uid, p_cuenta_id, v_entidad, v_tipo, v_registro, v_resultado, v_motivo,
                                            v_gana, v_cliente, v_base, v_servidor);
  end if;
  return cuidared_interno.sync_item(v_id, v_registro, v_resultado, v_motivo, v_gana, v_original, v_servidor);
end $$;

-- Resultado de una operación propia (para el cliente que reintenta después de perder la respuesta). Otra persona, otra cuenta o
-- una clave inexistente: P0002 (404), sin distinguir cuál. Como toda lectura operativa, se bloquea en una cuenta vencida.
create function cuidared_api.api_sync_obtener_operacion(p_cuenta_id bigint, p_id_cliente uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid; v_o cuidared.operacion_sync;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_id_cliente is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'sync:usar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  select * into v_o from cuidared.operacion_sync o
    where o.id_cliente = p_id_cliente and o.usuario_id = v_uid and o.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  return cuidared_interno.sync_item(v_o.id_cliente, v_o.registro_id, v_o.resultado::text, v_o.motivo::text, v_o.gana::text, null,
                                    v_o.actualizado_en_servidor)
    || jsonb_build_object('entidad', v_o.entidad, 'tipo', v_o.tipo, 'procesada_en', cuidared_interno.sync_iso(v_o.procesada_en));
end $$;

/* ───────────── 5. Privilegios ───────────── */

revoke all on all functions in schema cuidared_interno from public, anon, authenticated;

revoke all on function
  cuidared_api.api_sync_aplicar_operacion(bigint, jsonb),
  cuidared_api.api_sync_obtener_operacion(bigint, uuid)
  from public, anon;

grant execute on function
  cuidared_api.api_sync_aplicar_operacion(bigint, jsonb),
  cuidared_api.api_sync_obtener_operacion(bigint, uuid)
  to authenticated;

commit;
