-- Reintentos idempotentes de solicitudes públicas. © 2026 Equipo CuidaRed – INTEC.
begin;
CREATE OR REPLACE FUNCTION cuidared_api.api_publico_crear_solicitud(p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cuenta bigint;
  v_nombres text;
  v_apellidos text;
  v_cedula text;
  v_telefono text;
  v_correo text;
  v_persona text;
  v_fecha date;
  v_hora time;
  v_motivo text;
  v_hash text;
  v_org text;
  v_id uuid;
  v_existente cuidared.solicitud_visita;
  v_tipo text;
  v_entidad text;
  v_tipo_entidad text;
  v_cantidad integer;
  v_aporte text;
begin
  if jsonb_typeof(p_datos) is distinct from 'object'
     or p_datos - array['cuenta_id', 'nombres', 'apellidos', 'cedula', 'telefono', 'correo', 'persona_a_visitar',
                        'fecha_propuesta', 'hora_propuesta', 'motivo', 'codigo_hash', 'tipo_visita', 'entidad_visitante', 'tipo_entidad', 'cantidad_visitantes', 'aporte_previsto'] <> '{}'::jsonb
     or jsonb_typeof(p_datos->'cuenta_id') is distinct from 'number'
     or (p_datos->>'cuenta_id') !~ '^[1-9][0-9]{0,17}$' then
    raise invalid_parameter_value;
  end if;
  v_cuenta := (p_datos->>'cuenta_id')::bigint;
  v_nombres := cuidared_interno.v_texto(p_datos->'nombres', 2, 60);
  v_apellidos := cuidared_interno.v_texto(p_datos->'apellidos', 2, 60);
  v_cedula := cuidared_interno.v_texto(p_datos->'cedula', 11, 11);
  v_telefono := cuidared_interno.v_texto(p_datos->'telefono', 10, 16);
  v_correo := cuidared_interno.v_texto(p_datos->'correo', 5, 254, false);
  v_tipo := coalesce(cuidared_interno.v_texto(p_datos->'tipo_visita', 1, 20, false), 'personal');
  if v_tipo not in ('personal','institucional') then raise invalid_parameter_value; end if;
  v_persona := cuidared_interno.v_texto(p_datos->'persona_a_visitar', 3, 120, v_tipo = 'personal');
  v_entidad := cuidared_interno.v_texto(p_datos->'entidad_visitante', 2, 160, v_tipo = 'institucional');
  v_tipo_entidad := cuidared_interno.v_texto(p_datos->'tipo_entidad', 1, 30, v_tipo = 'institucional');
  v_aporte := cuidared_interno.v_texto(p_datos->'aporte_previsto', 1, 300, false);
  if p_datos ? 'cantidad_visitantes' and (
    jsonb_typeof(p_datos->'cantidad_visitantes') <> 'number' or p_datos->>'cantidad_visitantes' !~ '^[1-9][0-9]{0,9}$'
  ) then raise invalid_parameter_value; end if;
  v_cantidad := coalesce((p_datos->>'cantidad_visitantes')::integer, 1);
  if v_cantidad < 1
     or (v_tipo = 'institucional' and (v_persona is not null or v_tipo_entidad not in ('fundacion','iglesia','universidad','centro_educativo','empresa','grupo_comunitario','otro')))
     or (v_tipo = 'personal' and (v_entidad is not null or v_tipo_entidad is not null or v_aporte is not null)) then
    raise invalid_parameter_value;
  end if;
  v_fecha := cuidared_interno.v_fecha(p_datos->'fecha_propuesta');
  v_hora := cuidared_interno.v_hora(p_datos->'hora_propuesta');
  v_motivo := cuidared_interno.v_texto(p_datos->'motivo', 3, 300);
  v_hash := cuidared_interno.v_texto(p_datos->'codigo_hash', 64, 64);
  if v_cedula !~ '^[0-9]{11}$' or v_telefono !~ '^\+?[0-9]{10,15}$' or v_hash !~ '^[0-9a-f]{64}$'
     or (v_correo is not null and v_correo !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
     or v_fecha < cuidared_interno.hoy() then
    raise invalid_parameter_value;
  end if;
  -- Serializa los reintentos con la misma huella antes de evaluar cupos o notificar.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_hash, 1979));
  select * into v_existente from cuidared.solicitud_visita where codigo_hash = v_hash;
  if found then
    if row(v_existente.cuenta_id, v_existente.visitante_nombres, v_existente.visitante_apellidos,
           v_existente.visitante_cedula, v_existente.visitante_telefono, v_existente.visitante_correo,
           v_existente.persona_a_visitar, v_existente.fecha_propuesta, v_existente.hora_propuesta,
           v_existente.motivo, v_existente.tipo_visita, v_existente.entidad_visitante,
           v_existente.tipo_entidad, v_existente.cantidad_visitantes, v_existente.aporte_previsto)
       is distinct from
       row(v_cuenta, v_nombres, v_apellidos, v_cedula, v_telefono, lower(v_correo),
           v_persona, v_fecha, v_hora, v_motivo, v_tipo, v_entidad, v_tipo_entidad, v_cantidad, v_aporte) then
      raise exception 'CR_CONFLICTO' using errcode = 'P0001';
    end if;
    select nombre into v_org from cuidared.cuenta where cuenta_id = v_cuenta;
    return jsonb_build_object('organizacion', v_org, 'estado', 'pendiente',
      'fecha_propuesta', v_existente.fecha_propuesta,
      'hora_propuesta', cuidared_interno.hhmm(v_existente.hora_propuesta));
  end if;
  select c.nombre into v_org
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id and t.codigo::text = 'organizacion'
  where c.cuenta_id = v_cuenta and cuidared_interno.acceso_operativo(c.cuenta_id);
  if not found then raise invalid_parameter_value; end if;
  -- Frenos contra inundación: pendientes por visitante, pendientes por cuenta y creaciones por hora.
  if (select count(*) from cuidared.solicitud_visita s
      where s.cuenta_id = v_cuenta and s.visitante_cedula = v_cedula and s.estado::text = 'pendiente') >= 3 then
    raise exception 'CR_CONFLICTO' using errcode = 'P0001';
  end if;
  -- Las RPC públicas pueden llamarse directo (sin pasar por el límite de Express): estos topes acotan el daño por cuenta.
  if (select count(*) from cuidared.solicitud_visita s where s.cuenta_id = v_cuenta and s.estado::text = 'pendiente') >= 500
     or (select count(*) from cuidared.solicitud_visita s
         where s.cuenta_id = v_cuenta and s.fecha_creacion > now() - interval '1 hour') >= 60 then
    raise exception 'CR_SOLICITUD_NO_DISPONIBLE' using errcode = 'P0001';
  end if;
  insert into cuidared.solicitud_visita (cuenta_id, visitante_nombres, visitante_apellidos, visitante_cedula, visitante_telefono,
                                        visitante_correo, persona_a_visitar, fecha_propuesta, hora_propuesta, motivo, codigo_hash, tipo_visita, entidad_visitante, tipo_entidad, cantidad_visitantes, aporte_previsto)
    values (v_cuenta, v_nombres, v_apellidos, v_cedula, v_telefono, lower(v_correo), v_persona, v_fecha, v_hora, v_motivo, v_hash, v_tipo, v_entidad, v_tipo_entidad, v_cantidad, v_aporte)
    returning solicitud_visita_id into v_id;
  -- Aviso a los usuarios principales de la cuenta (sin datos del adulto: aún no está confirmado ni identificado).
  insert into cuidared.notificacion (usuario_id, cuenta_id, mensaje)
    select g, v_cuenta, format('Nueva solicitud de visita de %s %s para el %s.', v_nombres, v_apellidos, to_char(v_fecha, 'DD/MM/YYYY'))
    from cuidared_interno.gestores_cuenta(v_cuenta) g;
  return jsonb_build_object('organizacion', v_org, 'estado', 'pendiente', 'fecha_propuesta', v_fecha,
                            'hora_propuesta', cuidared_interno.hhmm(v_hora));
end $function$;
commit;
