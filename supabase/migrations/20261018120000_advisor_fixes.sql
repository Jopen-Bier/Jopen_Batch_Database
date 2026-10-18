-- Step 10: fixes from the Supabase advisors after the English rename.
-- No data changes. One transaction: either everything or nothing.

begin;

-- 1. Fixed search_path on the functions that did not have one yet
--    (advisor: function_search_path_mutable).
alter function public.set_updated_at()                 set search_path = public;
alter function public.water_settings_stamp()           set search_path = public;
alter function public.product_sheet_calculated_color   set search_path = public;
alter function public.product_sheet_relevant_hash      set search_path = public;
alter function public.product_sheet_relevant_recipe_id set search_path = public;

-- 2. Trigger functions are not meant to be called via /rest/v1/rpc.
--    Triggers keep firing: EXECUTE is only checked when a trigger is created.
revoke execute on function public.log_brew_planning_change() from public, anon, authenticated;
revoke execute on function public.water_settings_log()       from public, anon, authenticated;

-- 3. Login-related functions: never for anonymous callers.
revoke execute on function public.admin_get_last_logins() from public, anon;
revoke execute on function public.set_last_login()        from public, anon;

-- 4. "write_admin" was FOR ALL, so it also counted as a second SELECT policy
--    next to "_select" (advisor: multiple_permissive_policies). Split it into
--    insert/update/delete with the same check; read access is unchanged.
drop policy roles_write_admin on public.roles;
create policy roles_insert_admin on public.roles for insert with check (is_admin());
create policy roles_update_admin on public.roles for update using (is_admin()) with check (is_admin());
create policy roles_delete_admin on public.roles for delete using (is_admin());

drop policy role_permissions_write_admin on public.role_permissions;
create policy role_permissions_insert_admin on public.role_permissions for insert with check (is_admin());
create policy role_permissions_update_admin on public.role_permissions for update using (is_admin()) with check (is_admin());
create policy role_permissions_delete_admin on public.role_permissions for delete using (is_admin());

drop policy users_write_admin on public.users;
create policy users_insert_admin on public.users for insert to authenticated with check (is_admin());
create policy users_update_admin on public.users for update to authenticated using (is_admin()) with check (is_admin());
create policy users_delete_admin on public.users for delete to authenticated using (is_admin());

-- 5. Indexes on the foreign keys that are actually joined on
--    (advisor: unindexed_foreign_keys). The who-columns (created_by,
--    updated_by, …) are left without an index: small tables, never filtered.
create index if not exists idx_recipe_ingredients_recipe_id        on public.recipe_ingredients (recipe_id);
create index if not exists idx_recipe_ingredients_ingredient_id    on public.recipe_ingredients (ingredient_id);
create index if not exists idx_recipe_revisions_recipe_id          on public.recipe_revisions (recipe_id);
create index if not exists idx_brew_planning_splits_recipe_id      on public.brew_planning_splits (recipe_id);
create index if not exists idx_stock_movements_recipe_ingredient_id on public.stock_movements (recipe_ingredient_id);

commit;
