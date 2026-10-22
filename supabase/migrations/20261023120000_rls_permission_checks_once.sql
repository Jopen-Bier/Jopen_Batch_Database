-- Speed (Jaap, 23-10: Active batches and the batch tabs load slowly).
-- The policies call can_view / can_edit / can_delete / is_admin() directly,
-- so Postgres runs the permission lookup again for every row: batch_stages
-- (a view over ~10 tables) took ~630 ms for a normal user against ~25 ms
-- without RLS. Wrapped as (select can_view('batches')) the check runs once
-- per query (an InitPlan): the same rule, ~27 ms.
-- Every policy in public and storage that calls these functions is rewritten
-- in place (ALTER POLICY, same name, same command and roles); nothing is
-- dropped. Policies already wrapped are skipped, so a rerun changes nothing.
-- Plain ASCII.

do $$
declare
  p record;
  v_qual text;
  v_check text;
  v_n int := 0;
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check
    from pg_policies
    where schemaname in ('public', 'storage')
      and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~ '\m(can_view|can_edit|can_delete|is_admin)\('
      and (coalesce(qual, '') || ' ' || coalesce(with_check, '')) !~* 'select (can_view|can_edit|can_delete|is_admin)\('
  loop
    v_qual := regexp_replace(p.qual, '\m(can_view|can_edit|can_delete)\((''[a-z_]+''::text)\)', '(select \1(\2))', 'g');
    v_qual := regexp_replace(v_qual, '\mis_admin\(\)', '(select is_admin())', 'g');
    v_check := regexp_replace(p.with_check, '\m(can_view|can_edit|can_delete)\((''[a-z_]+''::text)\)', '(select \1(\2))', 'g');
    v_check := regexp_replace(v_check, '\mis_admin\(\)', '(select is_admin())', 'g');
    execute format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename)
      || case when p.qual is not null then format(' using (%s)', v_qual) else '' end
      || case when p.with_check is not null then format(' with check (%s)', v_check) else '' end;
    v_n := v_n + 1;
  end loop;
  raise notice '% policies now check the permission once per query', v_n;
end $$;
