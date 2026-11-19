-- Security phase 1 (security review 19-11-2026, P1.3): close the API to
-- visitors who are not logged in. Rollback: docs/security/phase1-rollback.sql.
--
-- Before this migration the anon role (publishable key, no session) had
-- SELECT/INSERT/UPDATE/DELETE on 42 public tables and views, usage on all
-- sequences, and EXECUTE on the permission helpers. RLS kept most of it shut,
-- but 9 tables had a SELECT policy "using (true)" for every role, so the
-- role/permission matrix and the water settings were readable without login.
--
-- No page reads the database before login (login.html and accept-invite.html
-- make no table or rpc calls; nav.js loads rights only for a logged-in user),
-- so anon needs none of this. Logged-in users keep exactly what they had.
--
-- 1. The 9 open SELECT policies apply to authenticated only.
-- 2. anon loses every table, view and sequence grant in public, now and for
--    objects created later.
-- 3. Functions that were executable by PUBLIC (and so by anon) are granted
--    explicitly to the roles that use them, then revoked from PUBLIC/anon.
--    claude_reader keeps the plain helpers used inside views it reads
--    (contract_line_status, product_sheet_status). Trigger functions need no
--    EXECUTE grant to fire.
--
-- Idempotent: ALTER POLICY, GRANT and REVOKE can all run twice.

begin;

-- 1. Open SELECT policies: logged-in users only ---------------------------
alter policy document_types_select          on public.document_types          to authenticated;
alter policy ingredient_categories_select   on public.ingredient_categories   to authenticated;
alter policy ingredient_declarations_select on public.ingredient_declarations to authenticated;
alter policy permission_modules_select      on public.permission_modules      to authenticated;
alter policy role_permissions_select        on public.role_permissions        to authenticated;
alter policy roles_select                   on public.roles                   to authenticated;
alter policy units_select                   on public.units                   to authenticated;
alter policy water_settings_select          on public.water_settings          to authenticated;
alter policy water_settings_history_select  on public.water_settings_history  to authenticated;

-- 2. No table, view or sequence rights for anon ----------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables    from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;

-- 3. Functions: explicit grants, nothing for PUBLIC/anon --------------------
-- Permission helpers (SECURITY DEFINER), used by RLS and storage policies.
grant execute on function public.can_view(text)    to authenticated, service_role;
grant execute on function public.can_edit(text)    to authenticated, service_role;
grant execute on function public.can_delete(text)  to authenticated, service_role;
grant execute on function public.is_admin()        to authenticated, service_role;
grant execute on function public.current_role_id() to authenticated, service_role;
revoke execute on function public.can_view(text)    from public, anon;
revoke execute on function public.can_edit(text)    from public, anon;
revoke execute on function public.can_delete(text)  from public, anon;
revoke execute on function public.is_admin()        from public, anon;
revoke execute on function public.current_role_id() from public, anon;

-- Plain helpers, also used inside views that claude_reader reads.
grant execute on function public.convert_quantity(numeric, text, text)             to authenticated, service_role, claude_reader;
grant execute on function public.pick_contract_line(text, bigint, date, text)      to authenticated, service_role, claude_reader;
grant execute on function public.product_sheet_calculated_color(bigint)            to authenticated, service_role, claude_reader;
grant execute on function public.product_sheet_relevant_hash(uuid)                 to authenticated, service_role, claude_reader;
grant execute on function public.product_sheet_relevant_recipe_id(uuid)            to authenticated, service_role, claude_reader;
grant execute on function public.tolerance_value(text)                             to authenticated, service_role, claude_reader;
revoke execute on function public.convert_quantity(numeric, text, text)            from public, anon;
revoke execute on function public.pick_contract_line(text, bigint, date, text)     from public, anon;
revoke execute on function public.product_sheet_calculated_color(bigint)           from public, anon;
revoke execute on function public.product_sheet_relevant_hash(uuid)                from public, anon;
revoke execute on function public.product_sheet_relevant_recipe_id(uuid)           from public, anon;
revoke execute on function public.tolerance_value(text)                            from public, anon;

-- Trigger functions: never called directly.
revoke execute on function public.lots_pick_contract_line() from public, anon;
revoke execute on function public.set_updated_at()          from public, anon;
revoke execute on function public.water_settings_stamp()    from public, anon;

commit;
