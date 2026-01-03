-- Grant usage of h3_postgis functions to postgres and API roles
-- h3_postgis provides PostGIS integration for h3

do $$
declare
  extoid oid := (select oid from pg_extension where extname = 'h3_postgis');
  extschema text := (select nspname from pg_namespace where oid = (select extnamespace from pg_extension where extname = 'h3_postgis'));
  r record;
begin
  -- Grant execute on all h3_postgis functions to postgres and API roles
  for r in (
    select p.oid, p.proname
    from pg_proc p
    join pg_depend d on p.oid = d.objid
    where d.refobjid = extoid and d.classid = 'pg_proc'::regclass
  ) loop
    execute format('grant execute on function %s(%s) to postgres, anon, authenticated, service_role;',
      r.oid::regproc, pg_get_function_identity_arguments(r.oid));
  end loop;

  -- Grant usage on the extension schema if not public
  if extschema != 'public' then
    execute format('grant usage on schema %I to postgres, anon, authenticated, service_role;', extschema);
  end if;
end $$;
