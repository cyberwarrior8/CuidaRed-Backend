-- pruebas-3b-00-ayudas.sql — Ayudas de las pruebas del bloque 3b (solo en la base desechable de validación).
-- Los adultos de prueba se insertan directamente en cuidared.envejeciente (como superusuario): el CRUD de adultos es
-- de otro bloque (3a). Siempre con cédulas de 11 dígitos únicas (prefijo 93…) para no chocar con la unicidad global.
-- © 2026 Equipo CuidaRed – INTEC.

create function pruebas.adulto_3b(p_cuenta bigint, p_cedula text, p_estado text default 'activo')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_registrador uuid;
begin
  select c.usuario_titular_id into v_registrador from cuidared.cuenta c where c.cuenta_id = p_cuenta;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cuidared' and table_name = 'envejeciente' and column_name = 'consentimiento_otorgado') then
    -- Con el bloque 3a cargado, sin consentimiento informado no se guarda un perfil (ck_envejeciente_consentimiento).
    execute $q$
      insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
                                         municipio_cod, direccion, estado, consentimiento_otorgado, consentimiento_otorgado_por,
                                         consentimiento_fecha, consentimiento_registrado_por)
      values ($1, $2, 'Adulto', 'Prueba ' || $3, $3, date '1945-05-05', 'F', '0101', 'Calle 1', $4, true, 'adulto', now(), $2)
      returning envejeciente_id$q$
      into v_id using p_cuenta, v_registrador, p_cedula, p_estado;
  else
    insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
                                       municipio_cod, direccion, estado)
    values (p_cuenta, v_registrador, 'Adulto', 'Prueba ' || p_cedula, p_cedula, date '1945-05-05', 'F', '0101', 'Calle 1', p_estado)
    returning envejeciente_id into v_id;
  end if;
  return v_id;
end $$;

-- Visita con su detalle para el adulto (columnas de DB.sql).
create function pruebas.visita_3b(p_adulto uuid, p_estado text, p_fecha date, p_razon text, p_observacion text,
                                  p_estado_general text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_cuenta bigint; v_usuario uuid;
begin
  select e.cuenta_id, e.usuario_registrador_id into v_cuenta, v_usuario
    from cuidared.envejeciente e where e.envejeciente_id = p_adulto;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cuidared' and table_name = 'visita' and column_name = 'cuenta_id') then
    -- Con el bloque 4a cargado, la visita lleva su cuenta y cancelar exige motivo y autor.
    execute $q$
      insert into cuidared.visita (fecha, hora_inicio, razon, estado, cuenta_id, motivo_cancelacion, cancelada_por)
      values ($1, time '10:00', $2, $3, $4, case when $3 = 'cancelada' then 'Motivo de prueba' end,
              case when $3 = 'cancelada' then $5 end)
      returning visita_id$q$
      into v_id using p_fecha, p_razon, p_estado, v_cuenta, v_usuario;
  else
    insert into cuidared.visita (fecha, hora_inicio, razon, estado) values (p_fecha, time '10:00', p_razon, p_estado)
    returning visita_id into v_id;
  end if;
  insert into cuidared.detalle_visita (visita_id, envejeciente_id, estado_general, observacion)
  values (v_id, p_adulto, p_estado_general, p_observacion);
  return v_id;
end $$;

-- Necesidad y alerta mínimas (con sus catálogos) para el historial.
create function pruebas.necesidad_3b(p_adulto uuid, p_descripcion text, p_resuelta boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_tipo smallint; v_nec smallint; v_prio smallint;
begin
  insert into cuidared.tipo_necesidad (nombre) values ('Tipo 3b') on conflict (nombre) do nothing;
  select tipo_necesidad_id into v_tipo from cuidared.tipo_necesidad where nombre = 'Tipo 3b';
  insert into cuidared.necesidad (nombre, tipo_necesidad_id) values ('Medicamentos 3b', v_tipo) on conflict (nombre) do nothing;
  select necesidad_id into v_nec from cuidared.necesidad where nombre = 'Medicamentos 3b';
  insert into cuidared.prioridad (nombre, orden) values ('Alta 3b', 91) on conflict (nombre) do nothing;
  select prioridad_id into v_prio from cuidared.prioridad where nombre = 'Alta 3b';
  insert into cuidared.envejeciente_necesidad (envejeciente_id, necesidad_id, prioridad_id, descripcion, estado,
                                               fecha_resolucion, motivo_resolucion)
  values (p_adulto, v_nec, v_prio, p_descripcion, case when p_resuelta then 'resuelta' else 'pendiente' end,
          case when p_resuelta then now() + interval '1 hour' end, case when p_resuelta then 'Se entregó el medicamento' end)
  returning envejeciente_necesidad_id into v_id;
  return v_id;
end $$;

create function pruebas.alerta_3b(p_adulto uuid, p_descripcion text, p_atendida boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_tipo smallint; v_prio smallint;
begin
  insert into cuidared.tipo_alerta (codigo, nombre) values ('riesgo_alto_prueba', 'Riesgo alto 3b') on conflict (codigo) do nothing;
  select tipo_alerta_id into v_tipo from cuidared.tipo_alerta where codigo = 'riesgo_alto_prueba';
  insert into cuidared.prioridad (nombre, orden) values ('Alta 3b', 91) on conflict (nombre) do nothing;
  select prioridad_id into v_prio from cuidared.prioridad where nombre = 'Alta 3b';
  insert into cuidared.alerta_envejeciente (envejeciente_id, tipo_alerta_id, prioridad_id, descripcion, estado,
                                            fecha_atencion, accion_tomada)
  values (p_adulto, v_tipo, v_prio, p_descripcion, case when p_atendida then 'resuelta' else 'pendiente' end,
          case when p_atendida then now() + interval '2 hours' end, case when p_atendida then 'Se llamó al contacto' end)
  returning alerta_envejeciente_id into v_id;
  return v_id;
end $$;

grant execute on function pruebas.adulto_3b(bigint, text, text),
  pruebas.visita_3b(uuid, text, date, text, text, text),
  pruebas.necesidad_3b(uuid, text, boolean),
  pruebas.alerta_3b(uuid, text, boolean) to authenticated, anon;
