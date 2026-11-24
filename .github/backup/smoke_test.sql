-- App smoke test on a RESTORED copy of the database (security phase 6).
-- Run by the nightly trial restore and the weekly Restore test, after
-- herstel.sh, in the throwaway container only: it grants table rights that
-- a real Supabase project gives by default but the restore leaves out
-- (--no-privileges). Never run against production.
--
-- Row counts (tel_rijen.sql) prove the data came back; this proves the app
-- would work on it: rights helpers, RLS, two-factor rule (when the backup
-- has it) and views.
-- Any failed check raises an error, so psql -v ON_ERROR_STOP=1 fails the step.

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;

do $smoke$
declare
  v_admin uuid;
  v_mfa boolean := to_regprocedure('public.mfa_satisfied()') is not null;
  v_n bigint;
  v_all bigint;
  v_rec record;
begin
  -- 1. Every table in public has RLS on
  select count(*) into v_n
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_n > 0 then
    raise exception 'smoke test: % table(s) in public without row level security', v_n;
  end if;

  -- 2. The rights helpers the policies depend on exist. mfa_satisfied()
  --    only in backups made after security phase 5 (24-11-2026); an older
  --    backup is checked for what it should contain, not for today's code.
  perform 'public.is_admin()'::regprocedure, 'public.can_view(text)'::regprocedure,
          'public.current_role_id()'::regprocedure;

  -- 3. Every view can be queried
  for v_rec in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relkind = 'v' loop
    execute format('select count(*) from public.%I', v_rec.relname) into v_n;
  end loop;

  -- 4. An active admin from the restored accounts sees the batches after the
  --    two-factor code (aal2) and nothing before it (aal1, role requires MFA)
  select u.id into v_admin
  from public.users u join public.roles r on r.id = u.role_id
  where r.name = 'admin' and u.is_active limit 1;
  if v_admin is null then
    raise exception 'smoke test: no active admin account in the restored data';
  end if;
  select count(*) into v_all from public.batches;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);   -- auth.uid() in the restore stub
  set local role authenticated;
  if not public.is_admin() then
    reset role;
    raise exception 'smoke test: admin with code entered is not admin';
  end if;
  select count(*) into v_n from public.batches;
  reset role;
  if v_n <> v_all then
    raise exception 'smoke test: admin sees % of % batches', v_n, v_all;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);   -- auth.uid() in the restore stub
  set local role authenticated;
  select count(*) into v_n from public.batches;
  reset role;
  if v_mfa and v_n <> 0 and v_all > 0 then
    raise exception 'smoke test: admin without two-factor code sees % batches (expected 0)', v_n;
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'smoke test passed: RLS on all tables, helpers present, views queryable, admin sees %/% batches%',
    v_all, v_all, case when v_mfa then ' with code and 0 without' else ' (backup from before two-factor authentication)' end;
end
$smoke$;
