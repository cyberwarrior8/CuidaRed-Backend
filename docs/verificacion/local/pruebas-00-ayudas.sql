-- pruebas-00-ayudas.sql — Ayudas para las pruebas SQL locales (solo en la base desechable de validación).
-- Uso típico dentro de una prueba (siempre en transacción con ROLLBACK):
--   begin;
--   select pruebas.usuario('ana@x.test', '00100000001') as ana \gset
--   select pruebas.cuenta('familia', :'ana') as cuenta \gset
--   select pruebas.como(:'ana');  set local role authenticated;
--   select pruebas.afirmar((cuidared_api.api_contexto_cuenta(:cuenta)->>'rol') = 'coordinador', 'rol del titular');
--   select pruebas.error('select cuidared_api.api_contexto_cuenta(0)', '22023');
--   reset role;
--   rollback;
-- © 2026 Equipo CuidaRed – INTEC.
create schema pruebas;
grant usage on schema pruebas to authenticated, anon;

-- Identidad confirmada + perfil (lo crea el trigger de perfil). Devuelve el id.
create function pruebas.usuario(p_email text, p_cedula text, p_nombres text default 'Persona', p_apellidos text default 'Prueba')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into auth.users(email, email_confirmed_at, raw_user_meta_data)
  values (p_email, now(), jsonb_build_object('cedula', p_cedula, 'nombres', p_nombres, 'apellidos', p_apellidos))
  returning id into v_id;
  return v_id;
end $$;

-- Cuenta con su titular como miembro activo (rol del titular según tipo). Estado 'prueba' vigente por defecto.
create function pruebas.cuenta(p_tipo text, p_titular uuid, p_estado text default 'prueba', p_plan text default null,
                               p_fin_prueba date default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_tipo smallint; v_cat smallint; v_hoy date := cuidared_interno.hoy();
begin
  select tipo_cuenta_id into v_tipo from cuidared.tipo_cuenta where codigo = p_tipo;
  select categoria_cuenta_id into v_cat from cuidared.categoria_cuenta where tipo_cuenta_id = v_tipo order by 1 limit 1;
  insert into cuidared.provincia values ('01', 'Distrito Nacional') on conflict do nothing;
  insert into cuidared.municipio values ('0101', 'Santo Domingo de Guzmán', '01') on conflict do nothing;
  insert into cuidared.cuenta(nombre, tipo_cuenta_id, categoria_cuenta_id, municipio_cod, suscripcion_estado, prueba_gratuita,
                              fecha_inicio_prueba, fecha_fin_prueba, plan_id, usuario_titular_id)
  values ('Cuenta ' || p_tipo, v_tipo, v_cat, '0101', p_estado, p_estado = 'prueba',
          case when p_estado = 'prueba' then coalesce(p_fin_prueba, v_hoy + 7) - 7 end,
          case when p_estado = 'prueba' then coalesce(p_fin_prueba, v_hoy + 7) end,
          (select plan_id from cuidared.plan where nombre = p_plan), p_titular)
  returning cuenta_id into v_id;
  perform pruebas.miembro(v_id, p_titular, case p_tipo when 'familia' then 'coordinador' else 'administrador' end);
  return v_id;
end $$;

create function pruebas.miembro(p_cuenta bigint, p_usuario uuid, p_rol text, p_estado text default 'activa')
returns bigint language sql security definer set search_path = '' as $$
  insert into cuidared.membresia(usuario_id, cuenta_id, rol_id, estado)
  select p_usuario, p_cuenta, r.rol_id, p_estado from cuidared.rol r where r.codigo = p_rol
  returning membresia_id
$$;

-- Actúa como el usuario: crea su sesión Auth y publica los claims del JWT (como PostgREST). Luego: set local role authenticated.
create function pruebas.como(p_usuario uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_sid uuid;
begin
  insert into auth.sessions(user_id) values (p_usuario) returning id into v_sid;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_usuario, 'session_id', v_sid, 'role', 'authenticated')::text, true);
  return v_sid;
end $$;

create function pruebas.afirmar(p_condicion boolean, p_mensaje text) returns void
language plpgsql as $$
begin
  if p_condicion is distinct from true then raise exception 'FALLA: %', p_mensaje; end if;
end $$;

-- Ejecuta la sentencia y exige que falle con el SQLSTATE indicado (y, si se da, con ese mensaje CR_*).
create function pruebas.error(p_sql text, p_sqlstate text, p_mensaje text default null) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FALLA: se esperaba % en: %', p_sqlstate, p_sql;
exception when others then
  if sqlerrm like 'FALLA:%' then raise; end if;
  if sqlstate <> p_sqlstate or (p_mensaje is not null and sqlerrm <> p_mensaje) then
    raise exception 'FALLA: % (%) en lugar de % % en: %', sqlstate, sqlerrm, p_sqlstate, coalesce(p_mensaje, ''), p_sql;
  end if;
end $$;

grant execute on all functions in schema pruebas to authenticated, anon;

-- Adulto mayor válido con o sin el bloque 3a cargado (cédula única generada y consentimiento si existe la columna).
create sequence pruebas.secuencia_cedula start 90000000001;
create function pruebas.envejeciente(p_cuenta bigint, p_nombres text default 'Adulto', p_apellidos text default 'Prueba',
                                     p_sexo text default 'F', p_estado text default 'activo')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_registrador uuid; v_cedula text := lpad(nextval('pruebas.secuencia_cedula')::text, 11, '0');
begin
  select c.usuario_titular_id into v_registrador from cuidared.cuenta c where c.cuenta_id = p_cuenta;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cuidared' and table_name = 'envejeciente' and column_name = 'consentimiento_otorgado') then
    execute $q$
      insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
                                         municipio_cod, direccion, estado, consentimiento_otorgado, consentimiento_otorgado_por,
                                         consentimiento_fecha, consentimiento_registrado_por)
      values ($1, $2, $3, $4, $5, date '1945-05-05', $6, '0101', 'Calle 1', $7, true, 'adulto', now(), $2)
      returning envejeciente_id$q$
      into v_id using p_cuenta, v_registrador, p_nombres, p_apellidos, v_cedula, p_sexo, p_estado;
  else
    insert into cuidared.envejeciente (cuenta_id, usuario_registrador_id, nombres, apellidos, cedula, fecha_nacimiento, sexo,
                                       municipio_cod, direccion, estado)
    values (p_cuenta, v_registrador, p_nombres, p_apellidos, v_cedula, date '1945-05-05', p_sexo, '0101', 'Calle 1', p_estado)
    returning envejeciente_id into v_id;
  end if;
  return v_id;
end $$;
grant usage on sequence pruebas.secuencia_cedula to authenticated, anon;
grant execute on function pruebas.envejeciente(bigint, text, text, text, text) to authenticated, anon;
