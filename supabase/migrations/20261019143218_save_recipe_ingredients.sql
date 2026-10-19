-- Saving the ingredient lines of a recipe in one transaction, keeping the id
-- of every line that still exists.
--
-- Until now recept-invoer.html deleted all lines of the recipe and inserted
-- them again: two separate requests (a failed insert left the recipe without
-- ingredients) and every line got a new id on every save (nothing could
-- point at a recipe line: batch_ingredients, the cellar plan of phase 4).
--
-- save_recipe_ingredients(recipe_id, lines):
-- * a line whose "id" belongs to this recipe is updated;
-- * a line without "id", or with the id of another recipe (copy from a recipe,
--   new major version), is inserted as a new line;
-- * lines of this recipe that are not in the list are deleted.
-- Runs with the rights of the caller (RLS on recipe_ingredients applies);
-- without edit rights on recipes it stops with an error.
-- Additive only, idempotent.

begin;

create or replace function public.save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_keep bigint[];
begin
  -- RLS would only silently skip rows; say it instead
  if auth.uid() is not null and not can_edit('recipes') then
    raise exception 'no edit rights on recipes' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' then
    raise exception 'p_lines must be a JSON array' using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
    where l ->> 'id' is not null
    group by l ->> 'id' having count(*) > 1
  ) then
    raise exception 'the same ingredient line occurs twice' using errcode = '22023';
  end if;

  -- ids in the list that are lines of this recipe
  select coalesce(array_agg(ri.id), '{}')
  into v_keep
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
  join recipe_ingredients ri on ri.id = (l ->> 'id')::bigint and ri.recipe_id = p_recipe_id;

  delete from recipe_ingredients
  where recipe_id = p_recipe_id
    and not (id = any (v_keep));

  update recipe_ingredients ri
  set ingredient_id     = (l ->> 'ingredient_id')::bigint,
      addition_type     = l ->> 'addition_type',
      quantity          = (l ->> 'quantity')::numeric,
      unit              = l ->> 'unit',
      timing            = l ->> 'timing',
      sort_order        = (l ->> 'sort_order')::integer,
      note              = l ->> 'note',
      hop_dosing_tank   = (l ->> 'hop_dosing_tank')::integer,
      alpha_pct         = (l ->> 'alpha_pct')::numeric,
      color_ebc         = (l ->> 'color_ebc')::numeric,
      all_in_first_brew = coalesce((l ->> 'all_in_first_brew')::boolean, false)
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
  where ri.id = (l ->> 'id')::bigint
    and ri.id = any (v_keep);

  insert into recipe_ingredients (
    recipe_id, ingredient_id, addition_type, quantity, unit, timing, sort_order,
    note, hop_dosing_tank, alpha_pct, color_ebc, all_in_first_brew)
  select p_recipe_id,
         (l ->> 'ingredient_id')::bigint,
         l ->> 'addition_type',
         (l ->> 'quantity')::numeric,
         l ->> 'unit',
         l ->> 'timing',
         (l ->> 'sort_order')::integer,
         l ->> 'note',
         (l ->> 'hop_dosing_tank')::integer,
         (l ->> 'alpha_pct')::numeric,
         (l ->> 'color_ebc')::numeric,
         coalesce((l ->> 'all_in_first_brew')::boolean, false)
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality as t(l, ord)
  where l ->> 'id' is null
     or not ((l ->> 'id')::bigint = any (v_keep))
  order by ord;
end;
$$;

revoke execute on function public.save_recipe_ingredients(bigint, jsonb) from public, anon;
grant execute on function public.save_recipe_ingredients(bigint, jsonb) to authenticated;

commit;
