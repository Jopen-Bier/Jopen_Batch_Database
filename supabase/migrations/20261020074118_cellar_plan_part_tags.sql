-- Cellar plan: a tag per plan part (Jaap, 20-10: a separate milestone tag
-- "Cooling 16C" for the cooling before a cold dry hop). Settings › Cellar
-- plan chooses the tag of each part; the generator uses it. "Apply order to
-- the recipes" now also gives planned batches without log entries the new
-- plan. One transaction.

begin;

-- 1. Tag per part --------------------------------------------------------------

alter table public.cellar_plan_parts add column if not exists tag_id bigint references public.cellar_action_tags(id);
create index if not exists idx_cellar_plan_parts_tag_id on public.cellar_plan_parts (tag_id);

-- Defaults: the tags the generator used so far; the cooling before a cold
-- dry hop gets "Cooling 16C" when that tag exists.
update public.cellar_plan_parts p
set tag_id = t.id
from public.cellar_action_tags t
where p.tag_id is null
  and t.code = case p.kind
                 when 'dry_warm' then 'dry_warm'
                 when 'cold_dry_hop' then coalesce((select code from public.cellar_action_tags where code = 'cooling_16c'), 'cooling')
                 when 'cooling_lagering' then 'cooling'
                 when 'sample_lab' then 'sample_lab'
                 when 'dry_hop_at_lagering' then 'dryhopping'
                 else 'addition'
               end;

alter table public.cellar_plan_parts alter column tag_id set not null;

-- 2. Generator uses the tag of the part ---------------------------------------
-- (Same function as in 20261019194854_batch_report_fermentation.sql; only the
-- tag of the generated steps now comes from cellar_plan_parts.tag_id. The
-- dry hop step after a cooling keeps the tag "dryhopping".)

create or replace function public.generate_recipe_cellar_steps(p_recipe_id bigint, p_reset_order boolean default false)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_ferm      recipe_fermentation%rowtype;
  v_ps        recipe_process_steps%rowtype;
  v_spec      recipe_specs%rowtype;
  v_lag_temp  numeric;
  v_lag_label text;
  v_part      record;
  v_cold      record;
  v_line      record;
  v_n         integer := 0;
  v_count     integer;
  v_cooled    boolean := false;   -- a cooling step is already planned
  v_cold_hop  boolean := false;   -- a cold dry hop comes before the lagering cooling
  v_tag       text;               -- tag of the part (Settings › Cellar plan)
begin
  -- auth.uid() is empty only for the migration owner (backfill below).
  if auth.uid() is not null and not can_edit('recipes') then
    raise exception 'no edit rights on recipes' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('generate_recipe_cellar_steps'), p_recipe_id::integer);

  select * into v_ferm from recipe_fermentation where recipe_id = p_recipe_id;
  select * into v_ps from recipe_process_steps where recipe_id = p_recipe_id;
  select * into v_spec from recipe_specs where recipe_id = p_recipe_id;
  v_lag_temp := v_ferm.lagering_temp;
  -- 0 °P final extract / warm dry hop extract means "not filled in".
  v_spec.final_extract := nullif(v_spec.final_extract, 0);
  v_ferm.dry_hop_warm_extract_1 := nullif(v_ferm.dry_hop_warm_extract_1, 0);
  v_lag_label := coalesce(v_lag_temp::float8 || ' °C', 'lagering temperature');

  create temporary table if not exists _gen_steps (
    n integer, generated_key text, tag_code text, title text, description text,
    trigger_type text, trigger_value numeric, trigger_tol numeric, planned_day numeric,
    recipe_ingredient_ids bigint[], starts_lagering boolean
  ) on commit drop;

  for v_part in select * from cellar_plan_parts where shows_on = 'cellar_plan' order by sort_order, id loop
    select t.code into v_tag from cellar_action_tags t where t.id = v_part.tag_id;

    if v_part.kind = 'dry_warm' then
      if exists (select 1 from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                 and lower(btrim(timing)) like 'warm%') then
        v_n := v_n + 1;
        insert into _gen_steps
        select v_n, 'dry_warm', v_tag, 'Dry warm',
               nullif(concat_ws(' · ',
                 case when v_ferm.dry_hop_warm_temp is not null then 'at ' || v_ferm.dry_hop_warm_temp::float8 || ' °C' end,
                 nullif(btrim(v_ps.dry_hop_method_warm), ''), nullif(btrim(v_ps.dry_hop_comment_warm), '')), ''),
               case when v_ferm.dry_hop_warm_extract_1 is not null then 'extract'
                    when v_ps.dry_hop_1_day is not null then 'day' else 'after_previous' end,
               v_ferm.dry_hop_warm_extract_1,
               case when v_ferm.dry_hop_warm_extract_1 is not null then tolerance_value(v_ferm.dry_hop_warm_extract_1_tol) end,
               v_ps.dry_hop_1_day,
               array(select id from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                     and lower(btrim(timing)) like 'warm%' order by sort_order, id),
               false;
      end if;

    elsif v_part.kind = 'cold_dry_hop' then
      -- Per cold dry hop temperature above the lagering temperature (warmest
      -- first): cool, then dry hop.
      for v_cold in
        select (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric as temp,
               array_agg(id order by sort_order, id) as ids
        from recipe_ingredients
        where recipe_id = p_recipe_id and addition_type = 'dry_hop' and lower(btrim(timing)) ~ '^cold_-?[0-9]'
        group by 1
        having v_lag_temp is null or (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric > v_lag_temp
        order by 1 desc
      loop
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'cooling_dry_hop:' || v_cold.temp::float8, v_tag,
          'Cooling to ' || v_cold.temp::float8 || ' °C', null,
          case when v_cooled or v_spec.final_extract is null then 'after_previous' else 'extract' end,
          case when v_cooled then null else v_spec.final_extract end,
          case when v_cooled then null else tolerance_value(v_spec.final_extract_tol) end,
          null, '{}', false);
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, 'dryhopping',
          'Dryhopping @' || v_cold.temp::float8 || ' °C',
          nullif(concat_ws(' · ', nullif(btrim(v_ps.dry_hop_method_16c), ''), nullif(btrim(v_ps.dry_hop_comment_16c), '')), ''),
          'after_previous', null, null, null, v_cold.ids, false);
        v_cooled := true;
        v_cold_hop := true;
      end loop;
      -- Dry hops without a timing: shown here so they are not forgotten.
      if exists (select 1 from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                 and nullif(btrim(timing), '') is null) then
        v_n := v_n + 1;
        insert into _gen_steps
        select v_n, 'dry_hop:unset', 'dryhopping', 'Dryhopping', 'Timing not set in the recipe',
               'after_previous', null, null, null,
               array(select id from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                     and nullif(btrim(timing), '') is null order by sort_order, id),
               false;
        v_cold_hop := true;
      end if;

    elsif v_part.kind = 'cooling_lagering' then
      v_n := v_n + 1;
      insert into _gen_steps values (v_n, 'cooling_lagering', v_tag, 'Cooling to ' || v_lag_label,
        nullif(concat_ws(' · ', 'Lagering temperature from recipe',
          case when v_ferm.lagering_time is not null then v_ferm.lagering_time::float8 || ' days' end,
          case when v_cold_hop then 'cool < 24 h after the dry hop' end), ''),
        case when v_cooled or v_spec.final_extract is null then 'after_previous' else 'extract' end,
        case when v_cooled then null else v_spec.final_extract end,
        case when v_cooled then null else tolerance_value(v_spec.final_extract_tol) end,
        null, '{}', true);
      v_cooled := true;

    elsif v_part.kind = 'sample_lab' then
      v_n := v_n + 1;
      insert into _gen_steps values (v_n, 'sample_lab', v_tag, 'Sample to lab', 'Always after cooling',
        'after_previous', null, null, null, '{}', false);

    elsif v_part.kind = 'dry_hop_at_lagering' then
      -- Cold dry hop at or below the lagering temperature (e.g. cold_2 with
      -- lagering at 2 °C).
      for v_cold in
        select (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric as temp,
               array_agg(id order by sort_order, id) as ids
        from recipe_ingredients
        where recipe_id = p_recipe_id and addition_type = 'dry_hop' and lower(btrim(timing)) ~ '^cold_-?[0-9]'
        group by 1
        having v_lag_temp is not null and (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric <= v_lag_temp
        order by 1 desc
      loop
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, v_tag,
          'Dryhopping @' || v_cold.temp::float8 || ' °C',
          nullif(concat_ws(' · ', nullif(btrim(v_ps.dry_hop_method_16c), ''), nullif(btrim(v_ps.dry_hop_comment_16c), '')), ''),
          'after_previous', null, null, null, v_cold.ids, false);
      end loop;

    else
      -- A timing value of cellar additions: one step per line with it.
      for v_line in
        select ri.id, coalesce(i.name, nullif(btrim(ri.note), ''), 'cellar addition') as name, ri.note
        from recipe_ingredients ri left join ingredients i on i.id = ri.ingredient_id
        where ri.recipe_id = p_recipe_id and ri.addition_type = 'cellar_addition'
          and lower(btrim(ri.timing)) = v_part.code
        order by ri.sort_order, ri.id
      loop
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'addition:' || v_line.id, v_tag, 'Addition · ' || v_line.name,
          nullif(concat_ws(' · ', case when not v_part.on_addition_day then lower(left(v_part.label, 1)) || substr(v_part.label, 2) end,
                                  nullif(btrim(v_line.note), '')), ''),
          case when v_part.on_addition_day and v_ps.cellar_addition_day is not null then 'day' else 'after_previous' end,
          null, null,
          case when v_part.on_addition_day then v_ps.cellar_addition_day end,
          array[v_line.id], false);
      end loop;
    end if;
  end loop;

  -- Cellar additions with a timing that is not a value in Settings (or none):
  -- at the end, to check in the recipe.
  for v_line in
    select ri.id, coalesce(i.name, nullif(btrim(ri.note), ''), 'cellar addition') as name, ri.note
    from recipe_ingredients ri left join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id and ri.addition_type = 'cellar_addition'
      and not exists (select 1 from cellar_plan_parts p where p.kind = 'addition_timing' and p.code = lower(btrim(ri.timing)))
    order by ri.sort_order, ri.id
  loop
    v_n := v_n + 1;
    insert into _gen_steps values (v_n, 'addition:' || v_line.id, 'addition', 'Addition · ' || v_line.name,
      nullif(concat_ws(' · ', 'timing to check in the recipe', nullif(btrim(v_line.note), '')), ''),
      case when v_ps.cellar_addition_day is not null then 'day' else 'after_previous' end,
      null, null, v_ps.cellar_addition_day, array[v_line.id], false);
  end loop;

  -- Apply: generated rows take the new content (their place in the plan is
  -- kept, it may have been moved by hand); rows changed by hand only get
  -- their linked lines refreshed; generated rows not asked for go.
  delete from recipe_cellar_steps s
  where s.recipe_id = p_recipe_id and s.is_generated
    and not exists (select 1 from _gen_steps g where g.generated_key = s.generated_key);

  update recipe_cellar_steps s
  set tag_id = t.id, title = g.title, description = g.description, trigger_type = g.trigger_type,
      trigger_value = g.trigger_value, trigger_tol = g.trigger_tol, planned_day = g.planned_day,
      recipe_ingredient_ids = g.recipe_ingredient_ids, starts_lagering = g.starts_lagering,
      updated_by = auth.uid()
  from _gen_steps g join cellar_action_tags t on t.code = g.tag_code
  where s.recipe_id = p_recipe_id and s.is_generated and s.generated_key = g.generated_key
    and (s.tag_id, s.title, s.description, s.trigger_type, s.trigger_value, s.trigger_tol, s.planned_day,
         s.recipe_ingredient_ids, s.starts_lagering)
        is distinct from
        (t.id, g.title, g.description, g.trigger_type, g.trigger_value, g.trigger_tol, g.planned_day,
         g.recipe_ingredient_ids, g.starts_lagering);

  update recipe_cellar_steps s
  set recipe_ingredient_ids = g.recipe_ingredient_ids, updated_by = auth.uid()
  from _gen_steps g
  where s.recipe_id = p_recipe_id and not s.is_generated and s.generated_key = g.generated_key
    and s.recipe_ingredient_ids is distinct from g.recipe_ingredient_ids;

  -- New generated steps go right after the step generated before them.
  insert into recipe_cellar_steps (recipe_id, sort_order, tag_id, title, description, trigger_type,
    trigger_value, trigger_tol, planned_day, recipe_ingredient_ids, starts_lagering, is_generated, generated_key)
  select p_recipe_id,
         coalesce((select max(s.sort_order) from recipe_cellar_steps s join _gen_steps p on p.generated_key = s.generated_key
                   where s.recipe_id = p_recipe_id and p.n < g.n), 0) + 1,
         t.id, g.title, g.description, g.trigger_type, g.trigger_value, g.trigger_tol, g.planned_day,
         g.recipe_ingredient_ids, g.starts_lagering, true, g.generated_key
  from _gen_steps g join cellar_action_tags t on t.code = g.tag_code
  where not exists (select 1 from recipe_cellar_steps s where s.recipe_id = p_recipe_id and s.generated_key = g.generated_key)
  order by g.n;

  -- Renumber 10, 20, 30 … in the resulting order. With p_reset_order a step
  -- with a generated key takes its place in the generated order; any other
  -- step stays right after the keyed step it followed.
  update recipe_cellar_steps s
  set sort_order = o.rn * 10
  from (
    select x.id, row_number() over (
             order by case when p_reset_order then coalesce(x.n, x.anchor_n) else 0 end,
                      case when p_reset_order and x.n is null then 1 else 0 end, x.sort_order, x.id) as rn
    from (
      select s2.id, s2.sort_order, g.n,
             coalesce((select max(g3.n) from recipe_cellar_steps s3 join _gen_steps g3 on g3.generated_key = s3.generated_key
                       where s3.recipe_id = p_recipe_id
                         and (s3.sort_order < s2.sort_order or (s3.sort_order = s2.sort_order and s3.id < s2.id))), 0) as anchor_n
      from recipe_cellar_steps s2
      left join _gen_steps g on g.generated_key = s2.generated_key
      where s2.recipe_id = p_recipe_id
    ) x
  ) o
  where s.id = o.id and s.sort_order <> o.rn * 10;

  drop table _gen_steps;   -- the next call may run as another role
  select count(*) into v_count from recipe_cellar_steps where recipe_id = p_recipe_id;
  return v_count;
end;
$$;

revoke execute on function public.generate_recipe_cellar_steps(bigint, boolean) from public, anon;
grant execute on function public.generate_recipe_cellar_steps(bigint, boolean) to authenticated;

-- 3. "Apply order to the recipes": recipes, then planned batches -------------

-- Every recipe that gets a plan is regenerated in the Settings order; a
-- planned batch without fermentation log entries gets the new plan of its
-- recipe (nothing is ticked off yet, so nothing is lost). Returns the number
-- of recipes.
create or replace function public.apply_cellar_plan_order()
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  r record;
  v_n integer := 0;
begin
  -- auth.uid() is empty only for the migration owner (below).
  if auth.uid() is not null and not (can_edit('settings') and can_edit('recipes')) then
    raise exception 'needs edit rights on settings and recipes' using errcode = '42501';
  end if;
  for r in select id from recipes
           where status = 'active' or id in (select recipe_id from batches where status = 'planned')
           order by id loop
    perform generate_recipe_cellar_steps(r.id, true);
    v_n := v_n + 1;
  end loop;

  delete from batch_cellar_steps s
  using batches b
  where b.id = s.batch_id and b.status = 'planned'
    and not exists (select 1 from fermentation_log_entries e where e.batch_id = b.id);
  perform snapshot_batch_cellar_steps(b.id)
  from batches b
  where b.status = 'planned'
    and not exists (select 1 from batch_cellar_steps s where s.batch_id = b.id);
  return v_n;
end;
$$;

revoke execute on function public.apply_cellar_plan_order() from public, anon;
grant execute on function public.apply_cellar_plan_order() to authenticated;

-- 4. Plans with the new tags (order of each plan unchanged) -------------------

do $$
declare
  r record;
begin
  for r in select id from public.recipes
           where status = 'active' or id in (select recipe_id from public.batches where status = 'planned')
           order by id loop
    perform public.generate_recipe_cellar_steps(r.id, false);
  end loop;
end $$;

delete from public.batch_cellar_steps s
using public.batches b
where b.id = s.batch_id and b.status = 'planned'
  and not exists (select 1 from public.fermentation_log_entries e where e.batch_id = b.id);

select count(*) as batches_with_new_plan
from (select public.snapshot_batch_cellar_steps(b.id)
      from public.batches b
      where b.status = 'planned'
        and not exists (select 1 from public.batch_cellar_steps s where s.batch_id = b.id)) x;

commit;
