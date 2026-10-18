\pset footer off
select 'policy' as k, tablename||'.'||policyname||' '||cmd||' '||array_to_string(roles,',') as v from pg_policies where schemaname='public' and tablename in ('roles','role_permissions','users') order by 2;
select 'search_path' as k, proname||' '||coalesce(array_to_string(proconfig,','),'NONE') as v from pg_proc where pronamespace='public'::regnamespace order by 2;
select 'anon_exec' as k, proname||' anon='||has_function_privilege('anon',oid,'execute')||' auth='||has_function_privilege('authenticated',oid,'execute') as v from pg_proc where pronamespace='public'::regnamespace order by 2;
select 'index' as k, indexname as v from pg_indexes where schemaname='public' and indexname like 'idx_%_id' order by 2;
-- triggers still fire for a role without EXECUTE on the trigger function
create role t_noexec nologin bypassrls;
grant usage on schema public, auth to t_noexec;
grant execute on function auth.uid() to t_noexec;
grant select, update on public.brew_planning, public.water_settings to t_noexec;
select 'history_before' as k, count(*)::text as v from public.brew_planning_history;
select 'wsh_before' as k, count(*)::text as v from public.water_settings_history;
set role t_noexec;
select 'noexec_has_exec' as k, has_function_privilege('public.log_brew_planning_change()','execute')::text as v;
update public.brew_planning set notes = coalesce(notes,'') || ' ' where id = (select id from public.brew_planning limit 1);
update public.water_settings set id = id where id = (select id from public.water_settings limit 1);
reset role;
select 'history_after' as k, count(*)::text as v from public.brew_planning_history;
select 'wsh_after' as k, count(*)::text as v from public.water_settings_history;
