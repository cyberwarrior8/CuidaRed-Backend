-- PROPUESTA SIN APLICAR. Requiere revisión y aprobación expresa antes de generar la migración.
-- Fase 2 · Organización (ID02) — base compartida que reutilizan las RPC de las fases 2, 3 y 4.
-- RF-09, RF-11, RF-12, RF-19, RF-20 · CR-157 (funcionalidades por plan) · Reglas de Negocio V2.
-- Basada en docs/DB.sql y la migración 20261025041944_fase_1_acceso. Validada en un PostgreSQL local con
-- `node scripts/validar-propuestas-local.js` (esquema auth simulado; no certifica RLS ni Auth de Supabase).
-- © 2026 Equipo CuidaRed – INTEC.
--
-- Decisiones aplicadas (registro en docs/FASE-2-ORGANIZACION.md):
--   · Autorregistro del titular (confirmado por el usuario el 2026-11-06): api_sesion deja de exigir invited_at.
--   · Prueba gratuita única de 7 días fijos (confirmado 2026-11-06), sin plan; se marca con cuenta.prueba_gratuita.
--   · Matriz de permisos V2 (propuesta, D04) en cuidared.rol_permiso, generada desde src/modules/cuentas/permisos.js.
--   · Una membresía vigente por usuario y cuenta; un perfil global de Cuidador por usuario.
begin;

/* ───────────── 1. Catálogos de cuenta con código estable ───────────── */

alter table cuidared.tipo_cuenta
  add column codigo character varying unique check (codigo::text ~ '^[a-z_]+$'),
  -- Alcance de la prueba gratuita por tipo de cuenta (propuesta del equipo de front; V2 no fija límites de prueba).
  add column prueba_limite_envejecientes integer check (prueba_limite_envejecientes is null or prueba_limite_envejecientes > 0),
  add column prueba_limite_usuarios integer check (prueba_limite_usuarios is null or prueba_limite_usuarios > 0),
  add column prueba_limite_familiares integer check (prueba_limite_familiares is null or prueba_limite_familiares > 0);

insert into cuidared.tipo_cuenta (nombre, codigo, prueba_limite_envejecientes, prueba_limite_usuarios, prueba_limite_familiares)
values ('Familia', 'familia', 2, null, 3), ('Organización', 'organizacion', 15, 20, null)
on conflict (nombre) do update set
  codigo = excluded.codigo,
  prueba_limite_envejecientes = excluded.prueba_limite_envejecientes,
  prueba_limite_usuarios = excluded.prueba_limite_usuarios,
  prueba_limite_familiares = excluded.prueba_limite_familiares;

-- V2 §Cuenta: cada categoría pertenece a un tipo de cuenta.
alter table cuidared.categoria_cuenta add column tipo_cuenta_id smallint references cuidared.tipo_cuenta(tipo_cuenta_id);
insert into cuidared.categoria_cuenta (nombre, tipo_cuenta_id)
select v.nombre, t.tipo_cuenta_id
from (values
  ('Monitoreo a distancia', 'familia'), ('Cuidado domiciliario', 'familia'), ('Cuidado temporal', 'familia'),
  ('Asilo', 'organizacion'), ('Iglesia', 'organizacion'), ('Universidad', 'organizacion'), ('Fundación', 'organizacion')
) as v(nombre, tipo)
join cuidared.tipo_cuenta t on t.codigo = v.tipo
on conflict (nombre) do update set tipo_cuenta_id = excluded.tipo_cuenta_id;

insert into cuidared.rol (codigo, nombre, descripcion) values
  ('administrador', 'Administrador', 'Solo Organización: miembros, familiares autorizados, configuración y suscripción.'),
  ('coordinador', 'Coordinador', 'Seguimiento, asignaciones, tareas, autorización de visitas y alertas. En Familia gestiona accesos.'),
  ('cuidador', 'Cuidador', 'Visitas, necesidades, indicaciones, tareas y evidencias de sus adultos asignados.'),
  ('familiar', 'Familiar responsable', 'Consulta lo autorizado explícitamente.'),
  ('voluntario', 'Voluntario', 'Solo Organización: registra la visita y su observación.')
on conflict (codigo) do nothing;

-- D14: tres tipos de cuidado aprobados para el MVP.
insert into cuidared.tipo_cuidado (nombre) values ('Cuidador remunerado'), ('Familiar cuidador'), ('Voluntario comunitario')
on conflict (nombre) do nothing;

-- Prioridad compartida por necesidades, alertas y tareas (DB.sql no la siembra), con código estable.
alter table cuidared.prioridad add column codigo character varying unique check (codigo::text ~ '^[a-z_]+$');
insert into cuidared.prioridad (nombre, orden, codigo) values ('Alta', 1, 'alta'), ('Media', 2, 'media'), ('Baja', 3, 'baja')
on conflict (nombre) do update set codigo = excluded.codigo;

insert into cuidared.tipo_vinculo (codigo, nombre) values
  ('cuidador_asignado', 'Cuidador asignado'),
  ('voluntario_asignado', 'Voluntario asignado'),
  ('familiar_responsable', 'Familiar autorizado'),
  ('referente', 'Referente comunitario')
on conflict (codigo) do nothing;

/* ───────────── 2. Planes V2 y funcionalidades por plan (CR-157) ───────────── */

alter table cuidared.plan
  add column limite_familiares integer check (limite_familiares is null or limite_familiares > 0),
  add column resumen character varying;

-- El catálogo comercial y sus precios se cargarán en fase 8.
create table cuidared.plan_funcionalidad (
  plan_id smallint not null references cuidared.plan(plan_id),
  funcionalidad character varying not null check (funcionalidad::text ~ '^[a-z_]+$'),
  constraint plan_funcionalidad_pkey primary key (plan_id, funcionalidad)
);
-- Funcionalidades del nivel básico durante la prueba gratuita, por tipo de cuenta.
create table cuidared.prueba_funcionalidad (
  tipo_cuenta_id smallint not null references cuidared.tipo_cuenta(tipo_cuenta_id),
  funcionalidad character varying not null check (funcionalidad::text ~ '^[a-z_]+$'),
  constraint prueba_funcionalidad_pkey primary key (tipo_cuenta_id, funcionalidad)
);
insert into cuidared.prueba_funcionalidad (tipo_cuenta_id, funcionalidad)
select t.tipo_cuenta_id, f.funcionalidad
from (values ('familia', 'registro_visitas'), ('familia', 'necesidades_diarias'), ('familia', 'visitas_recurrentes'),
             ('organizacion', 'registro_visitas'), ('organizacion', 'necesidades_diarias'),
             ('organizacion', 'tablon_notificaciones'), ('organizacion', 'dashboard_metricas')) as f(tipo, funcionalidad)
join cuidared.tipo_cuenta t on t.codigo = f.tipo
on conflict do nothing;

/* ───────────── 3. Cuenta: prueba sin plan y vigencia pagada ───────────── */

-- V2: la prueba no es un plan del catálogo. La cuenta en prueba no tiene plan; una suscripción activa sí.
alter table cuidared.cuenta alter column plan_id drop not null;
alter table cuidared.cuenta enable row level security;
revoke all on cuidared.cuenta from public, anon, authenticated;
alter table cuidared.cuenta alter column suscripcion_estado set default 'prueba';
alter table cuidared.cuenta add column fecha_fin_vigencia date;
alter table cuidared.cuenta add constraint ck_cuenta_plan_activa
  check (suscripcion_estado::text <> 'activa' or plan_id is not null);
-- Conservar las fechas de calendario originales. Solo los instantes verificables pueden dar acceso por prueba.
-- La regla previa del proyecto exigiría fechas de calendario a las nuevas pruebas con prueba_gratuita = true.
alter table cuidared.cuenta drop constraint if exists ck_cuenta_prueba;
alter table cuidared.cuenta rename column fecha_inicio_prueba to fecha_inicio_prueba_historica;
alter table cuidared.cuenta rename column fecha_fin_prueba to fecha_fin_prueba_historica;
alter table cuidared.cuenta
  add column fecha_inicio_prueba timestamptz,
  add column fecha_fin_prueba timestamptz,
  add column prueba_historica boolean not null default false;
update cuidared.cuenta set prueba_historica = true
 where fecha_inicio_prueba_historica is not null or fecha_fin_prueba_historica is not null
    or prueba_gratuita or suscripcion_estado = 'prueba';

-- Ventana automática de 168 horas transcurridas, independiente de la zona horaria.
alter table cuidared.cuenta add constraint ck_cuenta_prueba_7_dias
  check (case when prueba_historica then fecha_inicio_prueba is null and fecha_fin_prueba is null
    else (fecha_inicio_prueba is null and fecha_fin_prueba is null and not prueba_gratuita and suscripcion_estado <> 'prueba')
      or (prueba_gratuita and fecha_inicio_prueba is not null and fecha_fin_prueba is not null
          and fecha_fin_prueba - fecha_inicio_prueba = interval '168 hours') end);

-- La base real ya usa esta función en el trigger de cuenta. Conservar la validación de plan cuando exista.
create or replace function cuidared.fn_trg_cuenta_valida_plan() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.plan_id is null and new.suscripcion_estado <> 'activa' then return new; end if;
  if not exists (select 1 from cuidared.plan p where p.plan_id = new.plan_id
                 and p.tipo_cuenta_id = new.tipo_cuenta_id and p.estado = 'activo') then
    raise check_violation;
  end if;
  return new;
end $$;
revoke all on function cuidared.fn_trg_cuenta_valida_plan() from public, anon, authenticated;
create or replace trigger trg_cuenta_valida_plan before insert or update of plan_id, tipo_cuenta_id
on cuidared.cuenta for each row execute function cuidared.fn_trg_cuenta_valida_plan();

create function cuidared.fn_prueba_inmutable() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.prueba_historica or new.fecha_inicio_prueba_historica is not null or new.fecha_fin_prueba_historica is not null then
      raise check_violation;
    end if;
    return new;
  end if;
  if new.fecha_inicio_prueba is distinct from old.fecha_inicio_prueba
     or new.fecha_fin_prueba is distinct from old.fecha_fin_prueba
     or new.fecha_inicio_prueba_historica is distinct from old.fecha_inicio_prueba_historica
     or new.fecha_fin_prueba_historica is distinct from old.fecha_fin_prueba_historica
     or new.prueba_historica is distinct from old.prueba_historica
     or new.prueba_gratuita is distinct from old.prueba_gratuita then
    raise check_violation;
  end if;
  return new;
end $$;
create trigger trg_cuenta_prueba_inmutable before insert or update of fecha_inicio_prueba, fecha_fin_prueba,
  fecha_inicio_prueba_historica, fecha_fin_prueba_historica, prueba_historica, prueba_gratuita
on cuidared.cuenta for each row execute function cuidared.fn_prueba_inmutable();
revoke all on function cuidared.fn_prueba_inmutable() from public, anon, authenticated;

/* ───────────── 4. Membresías y cuidadores ───────────── */

-- Una membresía vigente por usuario y cuenta; el historial (inactivas) se conserva.
create unique index uq_membresia_vigente on cuidared.membresia (usuario_id, cuenta_id)
  where estado::text in ('pendiente', 'activa');

-- Un perfil global por identidad, con alcance derivado de la membresía de cada cuenta.
create unique index uq_cuidador_usuario on cuidared.cuidador (usuario_id);

-- Una fila por periodo de asignación. Las revocaciones de fase 2c ya pueden conservar la fila original.
alter table cuidared.vinculo
  add column vinculo_id bigint generated always as identity,
  add column autorizado_por_usuario_id uuid references cuidared.usuario(usuario_id),
  add column fecha_autorizacion timestamptz,
  add column fecha_revocacion timestamptz,
  add column motivo_revocacion character varying,
  drop constraint if exists pk_vinculo,
  drop constraint if exists vinculo_pkey,
  add constraint vinculo_pkey primary key (vinculo_id),
  add constraint ck_vinculo_autorizacion check ((autorizado_por_usuario_id is null) = (fecha_autorizacion is null)),
  add constraint ck_vinculo_motivo_revocacion check (motivo_revocacion is null or fecha_revocacion is not null),
  add constraint ck_vinculo_revocacion_posterior
    check (fecha_revocacion is null or fecha_revocacion >= coalesce(fecha_autorizacion, fecha_creacion));
create unique index uq_vinculo_vigente on cuidared.vinculo (envejeciente_id, usuario_id) where fecha_revocacion is null;
create index ix_vinculo_usuario_vigente on cuidared.vinculo (usuario_id, tipo_vinculo_id) where fecha_revocacion is null;
alter table cuidared.vinculo enable row level security;
revoke all on cuidared.vinculo from public, anon, authenticated;

/* ───────────── 5. Parámetros (RF-19) ───────────── */
-- Regla propuesta (D14): configuracion_cuenta.valor > parametro.valor (valor global efectivo); valor_defecto es la
-- referencia de fábrica para restablecer.
insert into cuidared.parametro (nombre, valor, valor_defecto, descripcion, tipo_dato) values
  ('dias_sin_visita_alerta', '15', '15', 'Días calendario sin visita realizada para la alerta de seguimiento (RF-05).', 'entero'),
  ('dias_escalar_necesidad', '7', '7', 'Días sin resolver tras los que una necesidad se marca como atrasada.', 'entero'),
  ('notificar_casos_prioritarios', 'true', 'true', 'Notificar a coordinación cuando se genere una alerta.', 'booleano'),
  ('notificar_nuevos_voluntarios', 'true', 'true', 'Avisar cuando un voluntario active su cuenta.', 'booleano'),
  ('contacto_institucional_nombre', '', '', 'Persona o institución de contacto que se muestra en la ayuda.', 'texto'),
  ('contacto_institucional_telefono', '', '', 'Teléfono de contacto que se muestra en la ayuda.', 'texto')
on conflict (nombre) do nothing;

/* ───────────── 6. Matriz de permisos (D04, propuesta) ───────────── */

create table cuidared.rol_permiso (
  rol_id smallint not null references cuidared.rol(rol_id),
  tipo_cuenta_id smallint not null references cuidared.tipo_cuenta(tipo_cuenta_id),
  accion character varying not null check (accion::text ~ '^[a-z]+:[a-z-]+$'),
  constraint rol_permiso_pkey primary key (rol_id, tipo_cuenta_id, accion)
);
-- Generado con `node scripts/generar-permisos-sql.js` (no editar a mano).
-- @@PERMISOS:INICIO@@
insert into cuidared.rol_permiso (rol_id, tipo_cuenta_id, accion)
select r.rol_id, t.tipo_cuenta_id, v.accion
from (values
  ('coordinador', 'familia', 'adultos:ver'),
  ('coordinador', 'familia', 'adultos:crear'),
  ('coordinador', 'familia', 'adultos:editar'),
  ('coordinador', 'familia', 'adultos:desactivar'),
  ('coordinador', 'familia', 'adultos:asignar'),
  ('coordinador', 'familia', 'adultos:evaluar'),
  ('coordinador', 'familia', 'adultos:ver-sensible'),
  ('coordinador', 'familia', 'visitas:ver'),
  ('coordinador', 'familia', 'visitas:registrar'),
  ('coordinador', 'familia', 'visitas:programar'),
  ('coordinador', 'familia', 'visitas:autorizar'),
  ('coordinador', 'familia', 'necesidades:ver'),
  ('coordinador', 'familia', 'necesidades:registrar'),
  ('coordinador', 'familia', 'necesidades:actualizar'),
  ('coordinador', 'familia', 'alertas:ver'),
  ('coordinador', 'familia', 'alertas:gestionar'),
  ('coordinador', 'familia', 'resumen:ver'),
  ('coordinador', 'familia', 'reportes:ver'),
  ('coordinador', 'familia', 'informe:exportar'),
  ('coordinador', 'familia', 'sync:usar'),
  ('coordinador', 'familia', 'indicaciones:ver'),
  ('coordinador', 'familia', 'indicaciones:gestionar'),
  ('coordinador', 'familia', 'agenda:ver'),
  ('coordinador', 'familia', 'agenda:gestionar'),
  ('coordinador', 'familia', 'evidencias:validar'),
  ('coordinador', 'familia', 'usuarios:gestionar'),
  ('coordinador', 'familia', 'familiares:autorizar'),
  ('coordinador', 'familia', 'organizacion:configurar'),
  ('coordinador', 'familia', 'cuenta:suscripcion'),
  ('coordinador', 'familia', 'cuidadores:gestionar'),
  ('coordinador', 'familia', 'auditoria:ver'),
  ('coordinador', 'familia', 'catalogos:ver'),
  ('cuidador', 'familia', 'adultos:ver'),
  ('cuidador', 'familia', 'adultos:ver-sensible'),
  ('cuidador', 'familia', 'visitas:ver'),
  ('cuidador', 'familia', 'visitas:registrar'),
  ('cuidador', 'familia', 'necesidades:ver'),
  ('cuidador', 'familia', 'necesidades:registrar'),
  ('cuidador', 'familia', 'necesidades:actualizar'),
  ('cuidador', 'familia', 'alertas:ver'),
  ('cuidador', 'familia', 'alertas:cerrar'),
  ('cuidador', 'familia', 'informe:exportar'),
  ('cuidador', 'familia', 'sync:usar'),
  ('cuidador', 'familia', 'indicaciones:ver'),
  ('cuidador', 'familia', 'indicaciones:gestionar'),
  ('cuidador', 'familia', 'agenda:ver'),
  ('cuidador', 'familia', 'agenda:ejecutar'),
  ('familiar', 'familia', 'adultos:ver'),
  ('familiar', 'familia', 'visitas:ver'),
  ('familiar', 'familia', 'necesidades:ver'),
  ('familiar', 'familia', 'indicaciones:ver'),
  ('administrador', 'organizacion', 'adultos:ver'),
  ('administrador', 'organizacion', 'adultos:crear'),
  ('administrador', 'organizacion', 'adultos:editar'),
  ('administrador', 'organizacion', 'adultos:desactivar'),
  ('administrador', 'organizacion', 'adultos:asignar'),
  ('administrador', 'organizacion', 'adultos:evaluar'),
  ('administrador', 'organizacion', 'adultos:anonimizar'),
  ('administrador', 'organizacion', 'adultos:ver-sensible'),
  ('administrador', 'organizacion', 'visitas:ver'),
  ('administrador', 'organizacion', 'visitas:programar'),
  ('administrador', 'organizacion', 'visitas:autorizar'),
  ('administrador', 'organizacion', 'necesidades:ver'),
  ('administrador', 'organizacion', 'necesidades:registrar'),
  ('administrador', 'organizacion', 'necesidades:actualizar'),
  ('administrador', 'organizacion', 'alertas:ver'),
  ('administrador', 'organizacion', 'alertas:gestionar'),
  ('administrador', 'organizacion', 'resumen:ver'),
  ('administrador', 'organizacion', 'reportes:ver'),
  ('administrador', 'organizacion', 'usuarios:gestionar'),
  ('administrador', 'organizacion', 'familiares:autorizar'),
  ('administrador', 'organizacion', 'organizacion:configurar'),
  ('administrador', 'organizacion', 'auditoria:ver'),
  ('administrador', 'organizacion', 'indicaciones:ver'),
  ('administrador', 'organizacion', 'agenda:ver'),
  ('administrador', 'organizacion', 'agenda:gestionar'),
  ('administrador', 'organizacion', 'evidencias:validar'),
  ('administrador', 'organizacion', 'cuenta:suscripcion'),
  ('administrador', 'organizacion', 'cuidadores:gestionar'),
  ('administrador', 'organizacion', 'catalogos:ver'),
  ('coordinador', 'organizacion', 'adultos:ver'),
  ('coordinador', 'organizacion', 'adultos:crear'),
  ('coordinador', 'organizacion', 'adultos:editar'),
  ('coordinador', 'organizacion', 'adultos:desactivar'),
  ('coordinador', 'organizacion', 'adultos:asignar'),
  ('coordinador', 'organizacion', 'adultos:evaluar'),
  ('coordinador', 'organizacion', 'adultos:ver-sensible'),
  ('coordinador', 'organizacion', 'visitas:ver'),
  ('coordinador', 'organizacion', 'visitas:registrar'),
  ('coordinador', 'organizacion', 'visitas:programar'),
  ('coordinador', 'organizacion', 'visitas:autorizar'),
  ('coordinador', 'organizacion', 'necesidades:ver'),
  ('coordinador', 'organizacion', 'necesidades:registrar'),
  ('coordinador', 'organizacion', 'necesidades:actualizar'),
  ('coordinador', 'organizacion', 'alertas:ver'),
  ('coordinador', 'organizacion', 'alertas:gestionar'),
  ('coordinador', 'organizacion', 'resumen:ver'),
  ('coordinador', 'organizacion', 'reportes:ver'),
  ('coordinador', 'organizacion', 'informe:exportar'),
  ('coordinador', 'organizacion', 'sync:usar'),
  ('coordinador', 'organizacion', 'indicaciones:ver'),
  ('coordinador', 'organizacion', 'indicaciones:gestionar'),
  ('coordinador', 'organizacion', 'agenda:ver'),
  ('coordinador', 'organizacion', 'agenda:gestionar'),
  ('coordinador', 'organizacion', 'evidencias:validar'),
  ('coordinador', 'organizacion', 'cuidadores:gestionar'),
  ('cuidador', 'organizacion', 'adultos:ver'),
  ('cuidador', 'organizacion', 'adultos:ver-sensible'),
  ('cuidador', 'organizacion', 'visitas:ver'),
  ('cuidador', 'organizacion', 'visitas:registrar'),
  ('cuidador', 'organizacion', 'necesidades:ver'),
  ('cuidador', 'organizacion', 'necesidades:registrar'),
  ('cuidador', 'organizacion', 'necesidades:actualizar'),
  ('cuidador', 'organizacion', 'alertas:ver'),
  ('cuidador', 'organizacion', 'alertas:cerrar'),
  ('cuidador', 'organizacion', 'informe:exportar'),
  ('cuidador', 'organizacion', 'sync:usar'),
  ('cuidador', 'organizacion', 'indicaciones:ver'),
  ('cuidador', 'organizacion', 'indicaciones:gestionar'),
  ('cuidador', 'organizacion', 'agenda:ver'),
  ('cuidador', 'organizacion', 'agenda:ejecutar'),
  ('familiar', 'organizacion', 'adultos:ver'),
  ('familiar', 'organizacion', 'visitas:ver'),
  ('familiar', 'organizacion', 'necesidades:ver'),
  ('familiar', 'organizacion', 'indicaciones:ver'),
  ('voluntario', 'organizacion', 'adultos:ver'),
  ('voluntario', 'organizacion', 'visitas:ver'),
  ('voluntario', 'organizacion', 'visitas:registrar'),
  ('voluntario', 'organizacion', 'sync:usar')
) as v(rol, tipo, accion)
join cuidared.rol r on r.codigo = v.rol
join cuidared.tipo_cuenta t on t.codigo = v.tipo
on conflict do nothing;
-- @@PERMISOS:FIN@@

-- Tablas nuevas: sin acceso directo (solo a través de las RPC).
alter table cuidared.rol_permiso enable row level security;
alter table cuidared.plan_funcionalidad enable row level security;
alter table cuidared.prueba_funcionalidad enable row level security;
revoke all on cuidared.rol_permiso, cuidared.plan_funcionalidad, cuidared.prueba_funcionalidad
  from public, anon, authenticated;

/* ───────────── 7. Esquema interno de autorización (NO expuesto) ───────────── */

create schema cuidared_interno;
revoke all on schema cuidared_interno from public, anon, authenticated;

-- Fecha de negocio (República Dominicana, sin horario de verano).
create function cuidared_interno.hoy() returns date
language sql stable set search_path = '' as $$
  select (pg_catalog.now() at time zone 'America/Santo_Domingo')::date
$$;

-- Sesión vigente y usuario activo; si no, 28000 (401 en la API, CR-162).
create function cuidared_interno.exigir_sesion() returns uuid
language plpgsql set search_path = '' as $$
declare v_sesion jsonb;
begin
  if auth.uid() is null then
    raise exception 'sin sesion' using errcode = '28000';
  end if;
  v_sesion := cuidared_api.api_sesion('validar');
  if not coalesce((v_sesion->>'vigente')::boolean, false) then
    raise exception 'sesion no vigente' using errcode = '28000';
  end if;
  return auth.uid();
end;
$$;

-- ¿La cuenta tiene prueba vigente o una suscripción activa y vigente? (D07: al vencer se bloquea lo operativo).
create function cuidared_interno.acceso_operativo(p_cuenta_id bigint) returns boolean
language sql stable set search_path = '' as $$
  select coalesce((
    select case c.suscripcion_estado::text
      when 'prueba' then pg_catalog.now() >= c.fecha_inicio_prueba and pg_catalog.now() < c.fecha_fin_prueba
      when 'activa' then c.fecha_fin_vigencia is not null and c.fecha_fin_vigencia >= cuidared_interno.hoy()
      else false end
    from cuidared.cuenta c where c.cuenta_id = p_cuenta_id), false)
$$;

-- Funcionalidades efectivas (plan activo vigente, o las de la prueba) · CR-157.
create function cuidared_interno.funcionalidades(p_cuenta_id bigint) returns text[]
language sql stable set search_path = '' as $$
  select coalesce(case
    when not cuidared_interno.acceso_operativo(c.cuenta_id) then array[]::text[]
    when c.suscripcion_estado::text = 'activa' then
      (select array_agg(pf.funcionalidad::text order by pf.funcionalidad) from cuidared.plan_funcionalidad pf where pf.plan_id = c.plan_id)
    else
      (select array_agg(pr.funcionalidad::text order by pr.funcionalidad) from cuidared.prueba_funcionalidad pr where pr.tipo_cuenta_id = c.tipo_cuenta_id)
  end, array[]::text[])
  from cuidared.cuenta c where c.cuenta_id = p_cuenta_id
$$;

create function cuidared_interno.cuenta_tiene_funcionalidad(p_cuenta_id bigint, p_funcionalidad text) returns boolean
language sql stable set search_path = '' as $$
  select p_funcionalidad = any (cuidared_interno.funcionalidades(p_cuenta_id))
$$;

-- Límites efectivos (null = ilimitado): del plan activo o de la prueba del tipo de cuenta.
create function cuidared_interno.limites(p_cuenta_id bigint) returns jsonb
language sql stable set search_path = '' as $$
  select case when c.suscripcion_estado::text = 'activa' then
      jsonb_build_object('envejecientes', p.limite_envejecientes, 'usuarios', p.limite_usuarios, 'familiares', p.limite_familiares)
    else
      jsonb_build_object('envejecientes', t.prueba_limite_envejecientes, 'usuarios', t.prueba_limite_usuarios,
                         'familiares', t.prueba_limite_familiares)
    end
  from cuidared.cuenta c
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id
  left join cuidared.plan p on p.plan_id = c.plan_id
  where c.cuenta_id = p_cuenta_id
$$;

-- Membresía activa del usuario en la cuenta (rol y tipo), o ninguna fila.
create function cuidared_interno.membresia_activa(p_cuenta_id bigint, p_usuario_id uuid)
returns table (membresia_id bigint, rol text, tipo text, tipo_cuenta_id smallint, rol_id smallint)
language sql stable set search_path = '' as $$
  select m.membresia_id, r.codigo::text, t.codigo::text, t.tipo_cuenta_id, r.rol_id
  from cuidared.membresia m
  join cuidared.rol r on r.rol_id = m.rol_id and r.activo
  join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
  join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id
  join cuidared.usuario u on u.usuario_id = m.usuario_id and u.estado::text = 'activo'
  where m.cuenta_id = p_cuenta_id and m.usuario_id = p_usuario_id and m.estado::text = 'activa'
    and m.fecha_inicio <= cuidared_interno.hoy() and (m.fecha_fin is null or m.fecha_fin >= cuidared_interno.hoy())
  limit 1
$$;

create function cuidared_interno.permisos(p_rol_id smallint, p_tipo_cuenta_id smallint) returns text[]
language sql stable set search_path = '' as $$
  select coalesce(array_agg(rp.accion::text order by rp.accion), array[]::text[])
  from cuidared.rol_permiso rp where rp.rol_id = p_rol_id and rp.tipo_cuenta_id = p_tipo_cuenta_id
$$;

-- Acciones permitidas sin acceso operativo (cuenta vencida): solo gestionar cuenta y suscripción.
create function cuidared_interno.accion_sin_acceso_operativo(p_accion text) returns boolean
language sql immutable set search_path = '' as $$
  select p_accion = 'cuenta:suscripcion'
$$;

/*
 * Punto único de autorización de las RPC de cuenta. Devuelve {usuario_id, membresia_id, rol, tipo}.
 *   28000  sin sesión vigente               → 401
 *   42501  sin membresía activa o sin permiso → 403
 *   CR_CUENTA_SIN_ACCESO (P0001) cuenta sin prueba/plan vigente para una acción operativa → 403
 */
create function cuidared_interno.exigir(p_cuenta_id bigint, p_accion text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_m record;
begin
  select * into v_m from cuidared_interno.membresia_activa(p_cuenta_id, v_uid);
  if not found or not (p_accion = any (cuidared_interno.permisos(v_m.rol_id, v_m.tipo_cuenta_id))) then
    raise insufficient_privilege;
  end if;
  if not cuidared_interno.acceso_operativo(p_cuenta_id) and not cuidared_interno.accion_sin_acceso_operativo(p_accion) then
    raise exception 'CR_CUENTA_SIN_ACCESO' using errcode = 'P0001';
  end if;
  return jsonb_build_object('usuario_id', v_uid, 'membresia_id', v_m.membresia_id, 'rol', v_m.rol, 'tipo', v_m.tipo);
end;
$$;

-- Contexto completo de la cuenta para un usuario (lo usan api_contexto_cuenta y api_mis_cuentas).
create function cuidared_interno.contexto(p_cuenta_id bigint, p_usuario_id uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'cuenta_id', c.cuenta_id::text,
    'nombre', c.nombre,
    'tipo', m.tipo,
    'rol', m.rol,
    'membresia_id', m.membresia_id::text,
    'permisos', to_jsonb(cuidared_interno.permisos(m.rol_id, m.tipo_cuenta_id)),
    'es_titular', c.usuario_titular_id = p_usuario_id,
    'suscripcion_estado', case when c.suscripcion_estado in ('prueba', 'activa')
          and not cuidared_interno.acceso_operativo(c.cuenta_id) then 'vencida' else c.suscripcion_estado end,
    'fecha_fin_prueba', c.fecha_fin_prueba,
    'fecha_fin_vigencia', c.fecha_fin_vigencia,
    'plan_id', c.plan_id,
    'acceso_operativo', cuidared_interno.acceso_operativo(c.cuenta_id),
    'funcionalidades', to_jsonb(cuidared_interno.funcionalidades(c.cuenta_id)),
    'limites', cuidared_interno.limites(c.cuenta_id))
  from cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m
  join cuidared.cuenta c on c.cuenta_id = p_cuenta_id
$$;

/*
 * Alcance sobre un adulto mayor (V2 §Vínculo): Administrador y Coordinador ven todos los de su cuenta; Cuidador y
 * Voluntario solo los asignados con su tipo de vínculo; Familiar solo los autorizados explícitamente. El adulto
 * debe pertenecer a la cuenta y el vínculo debe seguir vigente. Un vínculo familiar previo sin autorización
 * registrada conserva su historia, pero no concede acceso.
 */
create function cuidared_interno.alcanza_envejeciente(p_cuenta_id bigint, p_envejeciente_id uuid, p_usuario_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1
    from cuidared.envejeciente e
    join cuidared_interno.membresia_activa(p_cuenta_id, p_usuario_id) m on true
    where e.envejeciente_id = p_envejeciente_id and e.cuenta_id = p_cuenta_id
      and (m.rol in ('administrador', 'coordinador')
        or exists (
          select 1 from cuidared.vinculo v join cuidared.tipo_vinculo tv on tv.tipo_vinculo_id = v.tipo_vinculo_id
          where v.envejeciente_id = e.envejeciente_id and v.usuario_id = p_usuario_id
            and v.fecha_revocacion is null
            and (m.rol <> 'familiar' or v.autorizado_por_usuario_id is not null)
            and tv.codigo::text = case m.rol when 'cuidador' then 'cuidador_asignado'
                                             when 'voluntario' then 'voluntario_asignado'
                                             when 'familiar' then 'familiar_responsable' end)))
$$;

-- exigir() + alcance sobre el adulto. 42501 si la acción o el alcance no se cumplen (no revela si el adulto existe
-- en otra cuenta: el llamador debe responder 404/42501 de forma uniforme).
create function cuidared_interno.exigir_envejeciente(p_cuenta_id bigint, p_accion text, p_envejeciente_id uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare v_ctx jsonb := cuidared_interno.exigir(p_cuenta_id, p_accion);
begin
  if not cuidared_interno.alcanza_envejeciente(p_cuenta_id, p_envejeciente_id, (v_ctx->>'usuario_id')::uuid) then
    raise insufficient_privilege;
  end if;
  return v_ctx;
end;
$$;

revoke all on all functions in schema cuidared_interno from public, anon, authenticated;

/* ───────────── 8. RPC expuestas (cuidared_api) ───────────── */

-- Contexto de la cuenta activa (middleware requireCuenta). null si no hay membresía activa: no revela la cuenta.
create function cuidared_api.api_contexto_cuenta(p_cuenta_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := cuidared_interno.exigir_sesion();
begin
  if p_cuenta_id is null or p_cuenta_id <= 0 then raise invalid_parameter_value; end if;
  return cuidared_interno.contexto(p_cuenta_id, v_uid);
end;
$$;

-- Colección propia de cuentas activas (CR-162). Los nombres de columna y las direcciones salen de una lista cerrada.
create function cuidared_api.api_mis_cuentas(p_filtros jsonb, p_orden jsonb, p_offset bigint, p_limit integer)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_item jsonb;
  v_campo text;
  v_dir text;
  v_orden text := '';
  v_vistos text[] := '{}';
  v_res jsonb;
begin
  if jsonb_typeof(p_filtros) is distinct from 'object'
     or p_filtros - array['tipo_cuenta','suscripcion_estado'] <> '{}'::jsonb
     or (p_filtros ? 'tipo_cuenta' and not coalesce(p_filtros->>'tipo_cuenta' in ('familia','organizacion'), false))
     or (p_filtros ? 'suscripcion_estado' and not coalesce(p_filtros->>'suscripcion_estado' in ('prueba','activa','vencida','cancelada','suspendida'), false))
     or jsonb_typeof(p_orden) is distinct from 'array' or p_offset is null or p_offset < 0
     or p_limit is null or p_limit not between 1 and 100 then raise invalid_parameter_value; end if;

  for v_item in select value from jsonb_array_elements(p_orden) loop
    v_campo := v_item->>'field';
    v_dir := v_item->>'direction';
    if v_campo is null or v_campo not in ('nombre','fecha_creacion','cuenta_id')
       or v_campo = any(v_vistos) or v_dir is null or v_dir not in ('asc','desc') then
      raise invalid_parameter_value;
    end if;
    v_vistos := array_append(v_vistos, v_campo);
    v_orden := v_orden || format('%I %s, ', v_campo, v_dir);
  end loop;
  if not ('cuenta_id' = any(v_vistos)) then v_orden := v_orden || 'cuenta_id asc, '; end if;
  v_orden := left(v_orden, -2);
  execute format($q$
    with propias as (
      select c.cuenta_id, c.nombre, c.fecha_creacion, ctx.datos
      from cuidared.membresia m join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
      cross join lateral (select cuidared_interno.contexto(c.cuenta_id, $1) as datos) ctx
      where m.usuario_id = $1 and m.estado = 'activa' and ctx.datos is not null
        and ($2 is null or ctx.datos->>'tipo' = $2)
        and ($3 is null or ctx.datos->>'suscripcion_estado' = $3)
    ), pagina as (
      select datos, row_number() over (order by %1$s) as rn
      from propias order by %1$s limit $4 offset $5
    )
    select jsonb_build_object('items', coalesce((select jsonb_agg(datos order by rn) from pagina), '[]'::jsonb),
                              'total', (select count(*) from propias))
  $q$, v_orden) into v_res using v_uid, p_filtros->>'tipo_cuenta', p_filtros->>'suscripcion_estado', p_limit, p_offset;
  return v_res;
end $$;

create function cuidared_api.api_mis_invitaciones() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := cuidared_interno.exigir_sesion();
begin
  return coalesce((
      select jsonb_agg(jsonb_build_object('membresia_id', m.membresia_id::text, 'cuenta_id', c.cuenta_id::text, 'nombre', c.nombre,
                                          'tipo', t.codigo, 'rol', r.codigo) order by m.membresia_id desc)
      from cuidared.membresia m
      join cuidared.cuenta c on c.cuenta_id = m.cuenta_id
      join cuidared.tipo_cuenta t on t.tipo_cuenta_id = c.tipo_cuenta_id
      join cuidared.rol r on r.rol_id = m.rol_id
      where m.usuario_id = v_uid and m.estado::text = 'pendiente'), '[]'::jsonb);
end;
$$;

revoke all on function cuidared_api.api_contexto_cuenta(bigint),
  cuidared_api.api_mis_cuentas(jsonb,jsonb,bigint,integer), cuidared_api.api_mis_invitaciones() from public, anon;
grant execute on function cuidared_api.api_contexto_cuenta(bigint),
  cuidared_api.api_mis_cuentas(jsonb,jsonb,bigint,integer), cuidared_api.api_mis_invitaciones() to authenticated;

/* ───────────── 9. Autorregistro: api_sesion deja de exigir invitación ───────────── */
-- Único cambio respecto de fase 1: se elimina `u.invited_at is not null`. Sigue exigiendo correo confirmado, no
-- borrado ni bloqueado, sesión existente, 12 h máximas y 30 min de inactividad. La habilitación del registro en
-- Supabase Auth (signups + plantilla con código) es configuración aparte, también pendiente de aprobación.
create or replace function cuidared_api.api_sesion(p_accion text default 'validar')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_sid uuid;
  v_inicio timestamptz;
  v_not_after timestamptz;
  v_ahora timestamptz := clock_timestamp();
  v_actividad timestamptz;
  v_revocada timestamptz;
begin
  if v_uid is null or p_accion is null or p_accion not in ('validar', 'actividad', 'cerrar') then
    raise insufficient_privilege;
  end if;
  begin
    v_sid := nullif(auth.jwt()->>'session_id', '')::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object('vigente', false);
  end;
  if v_sid is null then return jsonb_build_object('vigente', false); end if;
  -- Excluye usuarios anónimos/no verificados, borrados y bloqueados (autorregistro permitido desde fase 2).
  if not exists (select 1 from auth.users u where u.id = v_uid
    and u.email_confirmed_at is not null
    and u.deleted_at is null and (u.banned_until is null or u.banned_until <= v_ahora)) then
    return jsonb_build_object('vigente', false);
  end if;
  select s.created_at, s.not_after into v_inicio, v_not_after
    from auth.sessions s where s.id = v_sid and s.user_id = v_uid;
  if not found then return jsonb_build_object('vigente', false); end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_sid::text, 0));
  v_ahora := clock_timestamp();
  select ultima_actividad, revocada_en into v_actividad, v_revocada
    from cuidared.sesion_acceso where sesion_id = v_sid;
  v_actividad := coalesce(v_actividad, v_inicio);
  if v_revocada is not null or v_ahora >= v_inicio + interval '12 hours'
     or v_ahora >= v_actividad + interval '30 minutes'
     or (v_not_after is not null and v_ahora >= v_not_after) then
    return jsonb_build_object('vigente', false);
  end if;
  if exists (select 1 from cuidared.usuario u where u.usuario_id = v_uid and u.estado <> 'activo') then
    return jsonb_build_object('vigente', false, 'motivo', 'usuario_inactivo');
  end if;
  if p_accion in ('actividad', 'cerrar') then
    insert into cuidared.sesion_acceso(sesion_id, ultima_actividad, revocada_en)
      values (v_sid, v_ahora, case when p_accion = 'cerrar' then v_ahora end)
      on conflict (sesion_id) do update set
        ultima_actividad = excluded.ultima_actividad,
        revocada_en = excluded.revocada_en;
  end if;
  return jsonb_build_object('vigente', true);
end;
$$;

commit;
