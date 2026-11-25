-- Acuse al visitante y aviso al equipo que recibe la solicitud. © 2026 Equipo CuidaRed – INTEC.
begin;
alter table cuidared.aviso_visita add column destinatario_usuario_id uuid references cuidared.usuario(usuario_id);
alter table cuidared.aviso_visita drop constraint aviso_visita_evento_check;
alter table cuidared.aviso_visita add constraint aviso_visita_evento_check
  check (evento in ('autorizada','rechazada','reprogramada','cancelada','recordatorio','recibida','nueva_solicitud'));
alter table cuidared.aviso_visita add constraint aviso_visita_destinatario_check
  check ((evento = 'nueva_solicitud') = (destinatario_usuario_id is not null));
create unique index ix_aviso_visita_acuse on cuidared.aviso_visita(solicitud_id) where evento = 'recibida';
create unique index ix_aviso_visita_equipo on cuidared.aviso_visita(solicitud_id, destinatario_usuario_id)
  where evento = 'nueva_solicitud';
create index ix_aviso_visita_destinatario on cuidared.aviso_visita(destinatario_usuario_id)
  where destinatario_usuario_id is not null;

create function cuidared_interno.trg_correo_nueva_solicitud() returns trigger
language plpgsql set search_path = '' as $$
declare v_cita timestamptz := (new.fecha_propuesta + new.hora_propuesta) at time zone 'America/Santo_Domingo';
begin
  if new.visitante_correo is not null then
    insert into cuidared.aviso_visita(solicitud_id, evento, cita)
      values(new.solicitud_visita_id, 'recibida', v_cita);
  end if;
  insert into cuidared.aviso_visita(solicitud_id, evento, cita, destinatario_usuario_id)
    select new.solicitud_visita_id, 'nueva_solicitud', v_cita, g.usuario_id
    from cuidared_interno.gestores_cuenta(new.cuenta_id) g(usuario_id)
    join auth.users u on u.id = g.usuario_id
    where u.email_confirmed_at is not null and u.email is not null and u.deleted_at is null
      and (u.banned_until is null or u.banned_until <= now()) and not u.is_anonymous;
  return new;
end $$;
create trigger solicitud_correo_recepcion after insert on cuidared.solicitud_visita
  for each row execute function cuidared_interno.trg_correo_nueva_solicitud();
revoke all on function cuidared_interno.trg_correo_nueva_solicitud() from public, anon, authenticated;

create or replace function cuidared_api.api_visita_reclamar_avisos() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_reclamo uuid := gen_random_uuid(); v_avisos jsonb;
begin
  update cuidared.aviso_visita set cierre = 'omitido', reclamo = null
    where cierre is null and evento = 'recordatorio' and cita <= now() and disponible_en <= now();
  -- La membresía y el correo confirmado se revisan de nuevo antes de cada intento.
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
      'evento', a.evento,
      'correo', case when a.destinatario_usuario_id is null then s.visitante_correo else u.email end,
      'destinatario', case when a.destinatario_usuario_id is null then 'visitante' else 'organizacion' end,
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
-- La tabla conserva su RLS y sus privilegios privados. No se generan avisos retroactivos.
commit;
