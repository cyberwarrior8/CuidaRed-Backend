-- ID05/RF-10: extender el contrato de sincronización aplicado en 4c.
-- Propuesta local; ejecutar después de fase-5-necesidades.sql.
begin;

create function cuidared_interno.sync_necesidad(
  p_cuenta_id bigint, p_usuario_id uuid, p_id_cliente uuid, p_tipo text, p_registro_id uuid,
  p_datos jsonb, p_cliente timestamptz, p_base timestamptz,
  out o_resultado text, out o_motivo text, out o_gana text, out o_servidor timestamptz
) returns record
language plpgsql set search_path = '' as $$
declare
  v_adulto uuid;
  v_actual cuidared.envejeciente_necesidad;
  v_productor uuid;
  v_marca_productor timestamptz;
  v_marca_servidor timestamptz;
  v_base_cambio boolean;
  v_gana_local boolean := false;
begin
  -- Mismo orden de bloqueos que las escrituras en línea y los cambios de membresía.
  perform cuidared_interno.bloquear_miembros(p_cuenta_id);

  if p_tipo = 'registrar' then
    if p_base is not null then raise invalid_parameter_value; end if;
    v_adulto := cuidared_interno.v_uuid(p_datos->'envejeciente_id');
    perform cuidared_interno.necesidad_crear(p_cuenta_id, v_adulto, p_registro_id, p_datos - 'envejeciente_id');
    o_resultado := 'aplicada';
    select n.fecha_actualizacion into o_servidor
      from cuidared.envejeciente_necesidad n where n.envejeciente_necesidad_id = p_registro_id;
    return;
  end if;

  perform cuidared_interno.necesidad_exigir(p_cuenta_id, p_registro_id, 'necesidades:actualizar');
  perform 1 from cuidared.envejeciente e join cuidared.envejeciente_necesidad n using (envejeciente_id)
    where n.envejeciente_necesidad_id = p_registro_id and e.cuenta_id = p_cuenta_id
      and e.estado = 'activo' and e.consentimiento_retirado_en is null for share of e;
  if not found then raise exception 'CR_ADULTO_INACTIVO' using errcode = 'P0001'; end if;
  select * into strict v_actual from cuidared.envejeciente_necesidad n
    where n.envejeciente_necesidad_id = p_registro_id for update;
  o_servidor := v_actual.fecha_actualizacion;

  if exists (select from cuidared.operacion_sync o
    where o.cuenta_id = p_cuenta_id and o.usuario_id = p_usuario_id and o.entidad = 'necesidad'
      and o.tipo = p_tipo and o.registro_id = p_registro_id and o.actualizado_en_cliente = p_cliente
      and o.id_cliente <> p_id_cliente and o.resultado <> 'rechazada') then
    o_resultado := 'duplicada';
    return;
  end if;

  -- La versión producida por sync se compara con el instante original de la captura.
  select o.usuario_id, o.actualizado_en_cliente into v_productor, v_marca_productor
    from cuidared.operacion_sync o
    where o.cuenta_id = p_cuenta_id and o.entidad = 'necesidad' and o.registro_id = p_registro_id
      and (o.resultado = 'aplicada' or (o.resultado = 'conflicto' and o.gana = 'local'))
      and o.actualizado_en_servidor = v_actual.fecha_actualizacion
    order by o.procesada_en desc, o.id_cliente
    limit 1;
  v_marca_servidor := cuidared_interno.sync_ms(coalesce(v_marca_productor, v_actual.fecha_actualizacion));
  v_base_cambio := p_base is null or cuidared_interno.sync_ms(o_servidor) > cuidared_interno.sync_ms(p_base);

  if v_actual.estado in ('resuelta','cancelada') then
    if not v_base_cambio then raise exception 'CR_NECESIDAD_CERRADA' using errcode = 'P0001'; end if;
    o_resultado := 'conflicto'; o_gana := 'servidor'; o_motivo := 'NEED_CLOSED';
    return;
  end if;
  if v_base_cambio and not (v_productor is not distinct from p_usuario_id and v_marca_servidor <= cuidared_interno.sync_ms(p_cliente)) then
    if v_marca_servidor >= cuidared_interno.sync_ms(p_cliente) then
      o_resultado := 'conflicto'; o_gana := 'servidor'; o_motivo := 'SERVIDOR_MAS_RECIENTE';
      return;
    end if;
    v_gana_local := true;
  end if;

  perform cuidared_interno.necesidad_cambiar_estado(p_cuenta_id, p_registro_id, p_datos);
  o_resultado := case when v_gana_local then 'conflicto' else 'aplicada' end;
  o_gana := case when v_gana_local then 'local' end;
  select n.fecha_actualizacion into o_servidor
    from cuidared.envejeciente_necesidad n where n.envejeciente_necesidad_id = p_registro_id;
exception when unique_violation then
  -- Un registro ya existente con otro id_cliente no constituye un alta nueva.
  if p_tipo = 'registrar' then raise no_data_found; end if;
  raise;
end;
$$;
revoke all on function cuidared_interno.sync_necesidad(bigint,uuid,uuid,text,uuid,jsonb,timestamptz,timestamptz)
  from public, anon, authenticated;

create or replace function cuidared_api.api_sync_aplicar_operacion(p_cuenta_id bigint, p_operacion jsonb) returns jsonb
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
      if v_entidad = 'necesidad' then
        perform cuidared_interno.necesidad_exigir(p_cuenta_id, v_registro,
          case v_tipo when 'registrar' then 'necesidades:registrar' else 'necesidades:actualizar' end);
      else
        perform cuidared_interno.exigir_operar_visita(p_cuenta_id, v_registro, v_uid);
      end if;
      v_resultado := 'duplicada'; v_original := v_previa.resultado::text; v_motivo := v_previa.motivo::text;
      v_gana := v_previa.gana::text; v_servidor := v_previa.actualizado_en_servidor;
    elsif v_entidad not in ('visita', 'necesidad') then
      v_resultado := 'rechazada'; v_motivo := 'ENTIDAD_NO_SOPORTADA';
    elsif (v_entidad = 'visita' and v_tipo not in ('registrar', 'iniciar'))
       or (v_entidad = 'necesidad' and v_tipo not in ('registrar', 'cambiar_estado')) then
      v_resultado := 'rechazada'; v_motivo := 'TIPO_NO_SOPORTADO';
    elsif v_cliente > v_ahora + interval '5 minutes' or v_base > v_ahora + interval '5 minutes' then
      v_resultado := 'rechazada'; v_motivo := 'RELOJ_INVALIDO';
    else
      if v_entidad = 'necesidad' then
        select * into v_res from cuidared_interno.sync_necesidad(
          p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      else
        select * into v_res from cuidared_interno.sync_visita(
          p_cuenta_id, v_uid, v_id, v_tipo, v_registro, v_datos, v_cliente, v_base);
      end if;
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
        when 'CR_LIMITE_PLAN' then v_resultado := 'rechazada'; v_motivo := 'PLAN_LIMIT_REACHED';
        when 'CR_VISITA_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'VISIT_CLOSED';
        when 'CR_ESTADO_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_ADULTO_INACTIVO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_STATE';
        when 'CR_NECESIDAD_CERRADA' then v_resultado := 'rechazada'; v_motivo := 'NEED_CLOSED';
        when 'CR_RESPONSABLE_NECESIDAD_INVALIDO' then v_resultado := 'rechazada'; v_motivo := 'INVALID_NEED_ASSIGNEE';
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
create or replace function cuidared_api.api_sync_obtener_operacion(p_cuenta_id bigint, p_id_cliente uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_ctx jsonb; v_uid uuid; v_o cuidared.operacion_sync; v_permiso text;
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 or p_id_cliente is null then raise invalid_parameter_value; end if;
  v_ctx := cuidared_interno.exigir(p_cuenta_id, 'sync:usar');
  v_uid := (v_ctx->>'usuario_id')::uuid;
  select * into v_o from cuidared.operacion_sync o
    where o.id_cliente = p_id_cliente and o.usuario_id = v_uid and o.cuenta_id = p_cuenta_id;
  if not found then raise no_data_found; end if;
  if v_o.entidad = 'necesidad' then
    v_permiso := case v_o.tipo when 'registrar' then 'necesidades:registrar' else 'necesidades:actualizar' end;
    if v_o.resultado = 'rechazada' and v_o.actualizado_en_servidor is null then
      -- Un rechazo sin versión solo informa del intento propio, aunque el registro nunca se haya creado.
      perform cuidared_interno.exigir(p_cuenta_id, v_permiso);
    else
      perform cuidared_interno.necesidad_exigir(p_cuenta_id, v_o.registro_id, v_permiso);
    end if;
  end if;
  return cuidared_interno.sync_item(v_o.id_cliente, v_o.registro_id, v_o.resultado::text, v_o.motivo::text, v_o.gana::text, null,
                                    v_o.actualizado_en_servidor)
    || jsonb_build_object('entidad', v_o.entidad, 'tipo', v_o.tipo, 'procesada_en', cuidared_interno.sync_iso(v_o.procesada_en));
end $$;

commit;
