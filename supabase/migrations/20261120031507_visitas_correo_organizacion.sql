-- Buzón de recepción configurable por organización, sin crear identidades. © 2026 Equipo CuidaRed – INTEC.
begin;
alter table cuidared.aviso_visita drop constraint aviso_visita_destinatario_check;
alter table cuidared.aviso_visita add constraint aviso_visita_destinatario_check
  check (destinatario_usuario_id is null or evento = 'nueva_solicitud');
create unique index ix_aviso_visita_correo_cuenta on cuidared.aviso_visita(solicitud_id)
  where evento = 'nueva_solicitud' and destinatario_usuario_id is null;

create or replace function cuidared_interno.trg_correo_nueva_solicitud() returns trigger
language plpgsql set search_path = '' as $$
declare v_cita timestamptz := (new.fecha_propuesta + new.hora_propuesta) at time zone 'America/Santo_Domingo';
begin
  if new.visitante_correo is not null then
    insert into cuidared.aviso_visita(solicitud_id, evento, cita)
      values(new.solicitud_visita_id, 'recibida', v_cita);
  end if;
  if exists(select from cuidared.cuenta where cuenta_id = new.cuenta_id and correo is not null) then
    insert into cuidared.aviso_visita(solicitud_id, evento, cita)
      values(new.solicitud_visita_id, 'nueva_solicitud', v_cita);
  else
    insert into cuidared.aviso_visita(solicitud_id, evento, cita, destinatario_usuario_id)
      select new.solicitud_visita_id, 'nueva_solicitud', v_cita, g.usuario_id
      from cuidared_interno.gestores_cuenta(new.cuenta_id) g(usuario_id)
      join auth.users u on u.id = g.usuario_id
      where u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= now()) and not u.is_anonymous;
  end if;
  return new;
end $$;
revoke all on function cuidared_interno.trg_correo_nueva_solicitud() from public, anon, authenticated;

create or replace function cuidared_api.api_visita_reclamar_avisos() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_reclamo uuid := gen_random_uuid(); v_avisos jsonb;
begin
  update cuidared.aviso_visita set cierre = 'omitido', reclamo = null
    where cierre is null and evento = 'recordatorio' and cita <= now() and disponible_en <= now();
  update cuidared.aviso_visita a set cierre = 'omitido', reclamo = null
    where a.cierre is null and a.evento = 'nueva_solicitud' and a.destinatario_usuario_id is null
      and not exists(select from cuidared.solicitud_visita s join cuidared.cuenta c using(cuenta_id)
        where s.solicitud_visita_id = a.solicitud_id and c.correo is not null);
  update cuidared.aviso_visita a set cierre = 'omitido', reclamo = null
    where a.cierre is null and a.destinatario_usuario_id is not null and not exists (
      select from cuidared.solicitud_visita s
      cross join lateral cuidared_interno.gestores_cuenta(s.cuenta_id) g(usuario_id)
      join auth.users u on u.id = g.usuario_id
      where s.solicitud_visita_id = a.solicitud_id and g.usuario_id = a.destinatario_usuario_id
        and u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null
        and (u.banned_until is null or u.banned_until <= now()) and not u.is_anonymous
    );
  with elegidos as (
      select a.aviso_id, a.disponible_en from cuidared.aviso_visita a
      where a.cierre is null and a.disponible_en <= now()
      order by a.disponible_en, a.aviso_id limit 10 for update skip locked
    ), tomados as (
      update cuidared.aviso_visita a set intentos = a.intentos + 1,
        reclamo = v_reclamo, disponible_en = now() + interval '5 minutes'
      from elegidos e where e.aviso_id = a.aviso_id returning a.*
    )
    select coalesce(jsonb_agg(jsonb_build_object('id', a.aviso_id, 'reclamo', a.reclamo,
      'evento', a.evento, 'correo', case
        when a.evento = 'nueva_solicitud' and a.destinatario_usuario_id is null then c.correo
        when a.destinatario_usuario_id is not null then u.email else s.visitante_correo end,
      'destinatario', case when a.evento = 'nueva_solicitud' then 'organizacion' else 'visitante' end,
      'organizacion', c.nombre, 'cita', a.cita, 'fin', cuidared_interno.hhmm(a.fin))
      order by e.disponible_en, a.aviso_id), '[]'::jsonb) into v_avisos
    from tomados a join cuidared.solicitud_visita s on s.solicitud_visita_id = a.solicitud_id
    join elegidos e on e.aviso_id = a.aviso_id
    join cuidared.cuenta c on c.cuenta_id = s.cuenta_id
    left join auth.users u on u.id = a.destinatario_usuario_id;
  return v_avisos;
end $$;
revoke all on function cuidared_api.api_visita_reclamar_avisos() from public, anon, authenticated;
grant execute on function cuidared_api.api_visita_reclamar_avisos() to service_role;
commit;
