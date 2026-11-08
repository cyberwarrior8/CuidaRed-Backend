-- Inspección de solo lectura para preparar fase 2. No aplicar como migración.
-- ID02. © 2026 Equipo CuidaRed – INTEC.
-- Ejecutar únicamente cuando el usuario permita la inspección pendiente.
select jsonb_build_object(
  'columnas', (
    select jsonb_agg(fila) from (
      select table_name, column_name, data_type, character_maximum_length,
             is_nullable, column_default
      from information_schema.columns
      where table_schema = 'cuidared'
        and table_name in ('cuenta', 'membresia', 'cuidador', 'configuracion_cuenta',
          'parametro', 'tipo_cuenta', 'categoria_cuenta', 'rol', 'tipo_cuidado', 'plan')
      order by table_name, ordinal_position
    ) fila
  ),
  'restricciones', (
    select jsonb_agg(fila) from (
      select n.nspname as esquema, c.relname as tabla, k.conname,
             pg_get_constraintdef(k.oid) as definicion
      from pg_constraint k
      join pg_class c on c.oid = k.conrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'cuidared'
        and c.relname in ('cuenta', 'membresia', 'cuidador', 'configuracion_cuenta')
      order by c.relname, k.conname
    ) fila
  ),
  'triggers', (
    select jsonb_agg(fila) from (
      select c.relname as tabla, t.tgname, pg_get_triggerdef(t.oid) as definicion
      from pg_trigger t join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'cuidared' and not t.tgisinternal
        and c.relname in ('cuenta', 'membresia', 'cuidador', 'configuracion_cuenta')
      order by c.relname, t.tgname
    ) fila
  ),
  'funciones', (
    select jsonb_agg(fila) from (
      select p.proname, pg_get_function_identity_arguments(p.oid) as argumentos,
             p.prosecdef as security_definer
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'cuidared'
        and p.proname ~ '(cuenta|membresia|cuidador|configuracion|prueba|vigencia|suscrip)'
      order by p.proname
    ) fila
  )
) as inspeccion_fase_2;
