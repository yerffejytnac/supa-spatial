-- Grant usage of h3 functions to postgres and API roles
-- h3 installs functions in the schema where the extension is created (typically public or extensions)

do $$
declare
  extoid oid := (select oid from pg_extension where extname = 'h3');
  extschema text := (select nspname from pg_namespace where oid = (select extnamespace from pg_extension where extname = 'h3'));
  r record;
begin
  -- Grant execute on all h3 functions to postgres and API roles
  for r in (
    select p.oid, p.proname
    from pg_proc p
    join pg_depend d on p.oid = d.objid
    where d.refobjid = extoid and d.classid = 'pg_proc'::regclass
  ) loop
    execute format('grant execute on function %s(%s) to postgres, anon, authenticated, service_role;',
      r.oid::regproc, pg_get_function_identity_arguments(r.oid));
  end loop;

  -- Grant usage on h3 types to postgres and API roles
  for r in (
    select t.oid, t.typname
    from pg_type t
    join pg_depend d on t.oid = d.objid
    where d.refobjid = extoid and d.classid = 'pg_type'::regclass
      and t.typname not like '%[]'
  ) loop
    begin
      execute format('grant usage on type %s to postgres, anon, authenticated, service_role;', r.oid::regtype);
    exception when others then
      -- Some types may not support GRANT USAGE, skip them
      null;
    end;
  end loop;

  -- Grant usage on the extension schema if not public
  if extschema != 'public' then
    execute format('grant usage on schema %I to postgres, anon, authenticated, service_role;', extschema);
  end if;
end $$;
