-- Verificación negativa de permisos/sesiones, sin crear usuarios ni datos de negocio.
-- Ejecutar como postgres en el proyecto aprobado. Todos los ajustes son locales a la transacción.
-- No valida el recorrido de una identidad real, que sigue pendiente de aprobación aparte.
-- © 2026 Equipo CuidaRed – INTEC.
begin;

do $$
declare v_fn regprocedure;
begin
  if not exists (select 1 from pg_class where oid='cuidared.usuario'::regclass and relrowsecurity)
    or not exists (select 1 from pg_class where oid='cuidared.sesion_acceso'::regclass and relrowsecurity) then
    raise exception 'Falta RLS en tablas de fase 1';
  end if;
  if has_schema_privilege('anon','cuidared_api','USAGE')
    or not has_schema_privilege('authenticated','cuidared_api','USAGE') then
    raise exception 'Permisos de esquema incorrectos';
  end if;
  if has_table_privilege('anon','cuidared.usuario','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('authenticated','cuidared.usuario','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('anon','cuidared.sesion_acceso','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('authenticated','cuidared.sesion_acceso','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
    raise exception 'Hay privilegios directos sobre tablas privadas';
  end if;
  foreach v_fn in array array[
    'cuidared_api.api_sesion(text)'::regprocedure,
    'cuidared_api.api_mi_perfil()'::regprocedure,
    'cuidared_api.api_actualizar_mi_perfil(jsonb)'::regprocedure
  ] loop
    if has_function_privilege('anon',v_fn,'EXECUTE')
      or not has_function_privilege('authenticated',v_fn,'EXECUTE') then
      raise exception 'Permisos incorrectos en RPC %',v_fn;
    end if;
    if not exists (select 1 from pg_proc where oid=v_fn and prosecdef and proconfig @> array['search_path=""']) then
      raise exception 'RPC sin contexto seguro %',v_fn;
    end if;
  end loop;
  if md5(pg_get_functiondef('cuidared.fn_trg_auth_nuevo_usuario()'::regprocedure))
    <> '83fe36f5284de5ce0df6fc3f621ce6c3' then
    raise exception 'Cambió el trigger de invitaciones';
  end if;
  if exists (select 1 from auth.users where id='ffffffff-ffff-4fff-8fff-fffffffffff1'::uuid) then
    raise exception 'El identificador reservado para prueba está ocupado; no ejecutar la prueba';
  end if;
end;
$$;

set local role anon;
do $$
declare v_rejected boolean := false;
begin
  begin
    perform cuidared_api.api_sesion('validar');
  exception when insufficient_privilege then v_rejected := true;
  end;
  if not v_rejected then raise exception 'anon ejecutó una RPC protegida'; end if;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims','{}',true);
do $$
declare v_rejected boolean := false;
begin
  begin
    perform cuidared_api.api_sesion('validar');
  exception when insufficient_privilege then v_rejected := true;
  end;
  if not v_rejected then raise exception 'Se aceptó una petición sin identidad'; end if;
end;
$$;

-- Claims sintéticos solo dentro de esta conexión SQL: no son tokens ni usuarios creados.
select set_config('request.jwt.claims',
  '{"sub":"ffffffff-ffff-4fff-8fff-fffffffffff1","role":"authenticated","session_id":"ffffffff-ffff-4fff-8fff-fffffffffff2"}',true);
do $$
declare v_action text; v_rejected boolean;
begin
  foreach v_action in array array['validar','actividad','cerrar'] loop
    if (cuidared_api.api_sesion(v_action)->>'vigente')::boolean is distinct from false then
      raise exception 'Se aceptó sesión inexistente para %', v_action;
    end if;
  end loop;
  v_rejected := false;
  begin
    perform cuidared_api.api_mi_perfil();
  exception when insufficient_privilege then v_rejected := true;
  end;
  if not v_rejected then raise exception 'Se consultó perfil sin sesión válida'; end if;
  v_rejected := false;
  begin
    perform cuidared_api.api_actualizar_mi_perfil('{"nombres":"No persistir"}'::jsonb);
  exception when insufficient_privilege then v_rejected := true;
  end;
  if not v_rejected then raise exception 'Se modificó perfil sin sesión válida'; end if;
end;
$$;

rollback;
select true as security_boundaries_verified, false as real_users_created;
