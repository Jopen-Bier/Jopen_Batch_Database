-- Security phase 7 (security review 19-11-2026, P3): SECURITY DEFINER
-- functions get search_path = public, pg_temp instead of public.
--
-- A SECURITY DEFINER function runs with its owner's rights. If its
-- search_path lets a caller put objects in front of the ones it means, the
-- caller's object runs with those rights. pg_temp (each session's own temp
-- schema) is searched FIRST unless it is listed explicitly; listing it last
-- closes that. Nobody but the owner can create objects in public (checked
-- 24-11-2026), so this is defence in depth, not a known hole.
--
-- No function body changes: names resolve exactly as before. mfa_satisfied()
-- already has search_path = '' and is left alone. The loop also covers any
-- SECURITY DEFINER function in public still on the plain 'public' setting.
-- Rollback: alter function ... set search_path = public (per function).

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and p.proconfig @> array['search_path=public']
  loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
  end loop;
end $$;
