-- Rollback for supabase/migrations/20261119120000_lock_down_anon_access.sql.
-- NOT a migration: run by hand in the SQL Editor only if phase 1 breaks
-- something, then fix forward with a new migration. Restores the grants and
-- policy roles exactly as they were on 19-11-2026 (captured live before the
-- change). The extra explicit grants to authenticated/service_role/
-- claude_reader are left in place: they are harmless with PUBLIC restored.

begin;

-- 1. Policies back to all roles
alter policy document_types_select          on public.document_types          to public;
alter policy ingredient_categories_select   on public.ingredient_categories   to public;
alter policy ingredient_declarations_select on public.ingredient_declarations to public;
alter policy permission_modules_select      on public.permission_modules      to public;
alter policy role_permissions_select        on public.role_permissions        to public;
alter policy roles_select                   on public.roles                   to public;
alter policy units_select                   on public.units                   to public;
alter policy water_settings_select          on public.water_settings          to public;
alter policy water_settings_history_select  on public.water_settings_history  to public;

-- 2. anon table/view grants (the 42 objects that had them) and sequences
grant select, insert, update, delete on
  public.batch_volume_balance, public.batches, public.brew_capacity,
  public.brew_planning, public.brew_planning_history,
  public.brew_planning_history_detailed, public.brew_planning_splits,
  public.breweries, public.contract_line_status, public.contract_lines,
  public.contracts, public.document_types, public.ingredient_categories,
  public.ingredient_declarations, public.ingredient_documents,
  public.ingredient_revisions, public.ingredient_usage_counts,
  public.ingredients, public.lots, public.permission_modules,
  public.product_sheet_revisions, public.product_sheet_status,
  public.product_sheets, public.recipe_brewing_specs, public.recipe_comments,
  public.recipe_costs, public.recipe_fermentation, public.recipe_ingredients,
  public.recipe_packaging, public.recipe_process_steps,
  public.recipe_revisions, public.recipe_specs, public.recipe_water,
  public.recipes, public.role_permissions, public.roles,
  public.stock_movements, public.suppliers, public.units, public.users,
  public.water_settings, public.water_settings_history
to anon;
grant select, usage on all sequences in schema public to anon;
alter default privileges for role postgres in schema public grant select, insert, update, delete on tables to anon;
alter default privileges for role postgres in schema public grant select, usage on sequences to anon;

-- 3. EXECUTE back to PUBLIC
grant execute on function public.can_view(text)                          to public;
grant execute on function public.can_edit(text)                          to public;
grant execute on function public.can_delete(text)                        to public;
grant execute on function public.is_admin()                              to public;
grant execute on function public.current_role_id()                       to public;
grant execute on function public.convert_quantity(numeric, text, text)   to public;
grant execute on function public.pick_contract_line(text, bigint, date, text) to public;
grant execute on function public.product_sheet_calculated_color(bigint)  to public;
grant execute on function public.product_sheet_relevant_hash(uuid)       to public;
grant execute on function public.product_sheet_relevant_recipe_id(uuid)  to public;
grant execute on function public.tolerance_value(text)                   to public;
grant execute on function public.lots_pick_contract_line()               to public;
grant execute on function public.set_updated_at()                        to public;
grant execute on function public.water_settings_stamp()                  to public;

commit;
