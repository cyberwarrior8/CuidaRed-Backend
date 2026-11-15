-- Ejecutar en el proyecto aprobado después de la migración. Crear y confirmar las identidades en Supabase Auth.
begin;
do $$
declare
  v_nombre text;
  v_rol text;
  v_id uuid;
begin
  for v_nombre,v_rol in select * from (values
    ('REEMPLAZAR-SUPER-ADMIN','super_admin'),
    ('REEMPLAZAR-SOPORTE','soporte'),
    ('REEMPLAZAR-AUDITOR','auditor')
  ) as usuarios(email,rol)
  loop
    if v_nombre like 'REEMPLAZAR-%' then continue; end if;
    select id into strict v_id from auth.users where lower(email)=lower(v_nombre) and email_confirmed_at is not null;
    if exists(select 1 from cuidared.membresia where usuario_id=v_id) then
      raise exception 'El backoffice requiere una identidad institucional sin membresía de PWA';
    end if;
    insert into cuidared.usuario_backoffice(usuario_id,rol,activo) values(v_id,v_rol,true)
    on conflict(usuario_id) do update set rol=excluded.rol,activo=true;
  end loop;
  if not exists(select 1 from cuidared.usuario_backoffice where rol='super_admin' and activo) then
    raise exception 'Registra al menos un super administrador confirmado antes de aplicar este script';
  end if;
end $$;
commit;
