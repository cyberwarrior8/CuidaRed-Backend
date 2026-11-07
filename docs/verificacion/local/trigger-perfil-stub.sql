-- trigger-perfil-stub.sql — Equivalente local del trigger remoto fn_trg_auth_nuevo_usuario (no está en DB.sql):
-- crea cuidared.usuario con la cédula, nombres y apellidos que trae la identidad. Solo para pruebas locales.
-- © 2026 Equipo CuidaRed – INTEC.
create function cuidared.fn_trg_auth_nuevo_usuario() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(new.raw_user_meta_data->>'cedula', '') = '' or coalesce(new.raw_user_meta_data->>'nombres', '') = ''
     or coalesce(new.raw_user_meta_data->>'apellidos', '') = '' then
    raise exception 'Faltan datos del perfil' using errcode = '23514';
  end if;
  insert into cuidared.usuario(usuario_id, cedula, nombres, apellidos, correo)
  values (new.id, new.raw_user_meta_data->>'cedula', new.raw_user_meta_data->>'nombres',
          new.raw_user_meta_data->>'apellidos', new.email);
  return new;
end $$;
create trigger trg_auth_nuevo_usuario after insert on auth.users for each row execute function cuidared.fn_trg_auth_nuevo_usuario();
