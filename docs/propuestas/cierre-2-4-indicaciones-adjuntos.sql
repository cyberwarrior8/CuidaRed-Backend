-- Adjuntos de indicaciones médicas en Storage privado. Aplicar después del consentimiento.
begin;

create table cuidared.evidencia_indicacion (
  evidencia_indicacion_id uuid primary key default gen_random_uuid(),
  indicacion_medica_id uuid not null references cuidared.indicacion_medica(indicacion_medica_id),
  registrada_por uuid not null references cuidared.usuario(usuario_id),
  ruta text not null unique,
  nombre_archivo text not null check (length(nombre_archivo) between 1 and 150),
  tipo_mime text not null check (tipo_mime in ('image/jpeg','image/png','image/webp','application/pdf')),
  tamano_bytes integer not null check (tamano_bytes between 1 and 5242880),
  fecha_registro timestamptz not null default now()
);
create index ix_evidencia_indicacion_indicacion on cuidared.evidencia_indicacion(indicacion_medica_id);
alter table cuidared.evidencia_indicacion enable row level security;
revoke all on cuidared.evidencia_indicacion from public, anon, authenticated;

create function cuidared_interno.evidencia_indicacion_acceso(p_cuenta bigint, p_indicacion uuid, p_uid uuid, p_subir boolean)
returns boolean language sql stable set search_path = '' as $$
  select cuidared_interno.acceso_operativo(p_cuenta)
    and cuidared_interno.tiene_permiso(p_cuenta, p_uid, case when p_subir then 'indicaciones:gestionar' else 'indicaciones:ver' end)
    and exists (select from cuidared.indicacion_medica i join cuidared.envejeciente e using (envejeciente_id)
      where i.indicacion_medica_id = p_indicacion and e.cuenta_id = p_cuenta
        and cuidared_interno.alcanza_envejeciente(p_cuenta, e.envejeciente_id, p_uid)
        and (not p_subir or (i.estado <> 'finalizada' and e.estado = 'activo')))
$$;
revoke all on function cuidared_interno.evidencia_indicacion_acceso(bigint,uuid,uuid,boolean) from public, anon, authenticated;

create function cuidared_api.api_indicacion_preparar_evidencia(p_cuenta_id bigint, p_indicacion_id uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := cuidared_interno.exigir_sesion(); v_archivo record;
begin
  if not cuidared_interno.evidencia_indicacion_acceso(p_cuenta_id, p_indicacion_id, v_uid, true) then raise insufficient_privilege; end if;
  select * into v_archivo from cuidared_interno.evidencia_validar_archivo(p_datos);
  return jsonb_build_object('ruta', format('cuenta/%s/indicacion/%s/%s/%s.%s',
    p_cuenta_id, p_indicacion_id, v_uid, gen_random_uuid(), v_archivo.o_ext), 'bucket', 'evidencias');
end $$;

create function cuidared_api.api_indicacion_registrar_evidencia(p_cuenta_id bigint, p_indicacion_id uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := cuidared_interno.exigir_sesion();
  v_ruta text := p_datos->>'ruta';
  v_archivo record;
  v_meta jsonb;
  v_id uuid;
begin
  perform 1 from cuidared.envejeciente e join cuidared.indicacion_medica i using (envejeciente_id)
    where e.cuenta_id = p_cuenta_id and i.indicacion_medica_id = p_indicacion_id for share of e;
  if not found then raise no_data_found; end if;
  perform 1 from cuidared.indicacion_medica i where i.indicacion_medica_id = p_indicacion_id for update;
  if not cuidared_interno.evidencia_indicacion_acceso(p_cuenta_id, p_indicacion_id, v_uid, true) then raise insufficient_privilege; end if;
  select * into v_archivo from cuidared_interno.evidencia_validar_archivo(p_datos);
  if v_ruta is null or v_ruta !~ format('^cuenta/%s/indicacion/%s/%s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.%s$',
      p_cuenta_id, p_indicacion_id, v_uid, v_archivo.o_ext) then raise invalid_parameter_value; end if;
  select metadata into v_meta from storage.objects where bucket_id = 'evidencias' and name = v_ruta
    and coalesce(owner_id, owner::text) = v_uid::text;
  if not found or v_meta->>'size' is distinct from v_archivo.o_tamano::text
     or v_meta->>'mimetype' is distinct from v_archivo.o_tipo then raise invalid_parameter_value; end if;
  select evidencia_indicacion_id into v_id from cuidared.evidencia_indicacion where ruta = v_ruta;
  if v_id is null then
    insert into cuidared.evidencia_indicacion(indicacion_medica_id, registrada_por, ruta, nombre_archivo, tipo_mime, tamano_bytes)
    values (p_indicacion_id, v_uid, v_ruta, v_archivo.o_nombre, v_archivo.o_tipo, v_archivo.o_tamano)
    returning evidencia_indicacion_id into v_id;
  end if;
  return jsonb_build_object('evidencia_id', v_id);
end $$;

create function cuidared_api.api_indicacion_listar_evidencias(p_cuenta_id bigint, p_indicacion_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := cuidared_interno.exigir_sesion();
begin
  if not cuidared_interno.evidencia_indicacion_acceso(p_cuenta_id, p_indicacion_id, v_uid, false) then raise insufficient_privilege; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'evidencia_id', evidencia_indicacion_id, 'nombre_archivo', nombre_archivo, 'ruta', ruta
  ) order by fecha_registro, evidencia_indicacion_id) from cuidared.evidencia_indicacion where indicacion_medica_id = p_indicacion_id), '[]'::jsonb);
end $$;

create function cuidared_storage.evidencia_indicacion_permitida(p_nombre text, p_subir boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_match text[];
begin
  if v_uid is null or p_subir is null then return false; end if;
  v_match := regexp_match(p_nombre, '^cuenta/([1-9][0-9]{0,18})/indicacion/([0-9a-f-]{36})/([0-9a-f-]{36})/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$');
  if v_match is null or not coalesce((cuidared_api.api_sesion('validar')->>'vigente')::boolean, false) then return false; end if;
  if p_subir and v_match[3] <> v_uid::text then return false; end if;
  return cuidared_interno.evidencia_indicacion_acceso(v_match[1]::bigint, v_match[2]::uuid, v_uid, p_subir)
    and (p_subir or exists (select 1 from cuidared.evidencia_indicacion where ruta = p_nombre));
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end $$;
revoke all on function cuidared_storage.evidencia_indicacion_permitida(text,boolean) from public, anon;
grant execute on function cuidared_storage.evidencia_indicacion_permitida(text,boolean) to authenticated;

create policy cuidared_evidencia_indicacion_subir on storage.objects for insert to authenticated
with check (bucket_id = 'evidencias' and cuidared_storage.evidencia_indicacion_permitida(name, true));
create policy cuidared_evidencia_indicacion_ver on storage.objects for select to authenticated
using (bucket_id = 'evidencias' and cuidared_storage.evidencia_indicacion_permitida(name, false));

revoke all on function cuidared_api.api_indicacion_preparar_evidencia(bigint,uuid,jsonb),
  cuidared_api.api_indicacion_registrar_evidencia(bigint,uuid,jsonb),
  cuidared_api.api_indicacion_listar_evidencias(bigint,uuid) from public, anon;
grant execute on function cuidared_api.api_indicacion_preparar_evidencia(bigint,uuid,jsonb),
  cuidared_api.api_indicacion_registrar_evidencia(bigint,uuid,jsonb),
  cuidared_api.api_indicacion_listar_evidencias(bigint,uuid) to authenticated;

commit;
