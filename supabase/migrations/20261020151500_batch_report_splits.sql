-- Batch report, phase 8: Splits (docs/batch-report/data-model.md).
-- Base beer lines in recipes and batches (the source beer by recipe group,
-- share in %), split_batch() for the Split / transfer popup (new batch,
-- existing batch or discard, with the Transfer log entry on the source
-- batch), and batch_stages for split batches (incoming volume, stage, Time 0).
-- One transaction: either everything or nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * A base beer line is addition_type 'base_beer' with
--   source_recipe_group_id (recipes.recipe_group_id: the beer over all its
--   versions, Jaap 20-10), quantity = share in %, unit '%', no ingredient.
--   No foreign key: recipe_group_id is shared by the versions, not unique.
-- * Batch volume for dosing = brews x brew volume + volume of the incoming
--   transfers (Jaap, 20-10); batch_stages.incoming_volume_hl gives the
--   incoming part. Batches with a fractional brew count keep dosing on it.
-- * A batch without started brews that receives beer counts as brewed: it
--   goes to Fermentation (or Lagering) from the first incoming transfer,
--   which is also its Time 0 and start date when nothing else is set.
-- * New batch from a split: next number in the year's sequence (YY + 3
--   digits), brew count 0, name of the recipe.

begin;

-- Plain ASCII on purpose (the SQL Editor changed a non-ASCII character in
-- the dry run): the middle dot of the texts is chr(183).

-- 1. Base beer lines ----------------------------------------------------------

alter table public.recipe_ingredients add column if not exists source_recipe_group_id uuid;
alter table public.batch_ingredients add column if not exists source_recipe_group_id uuid;

alter table public.recipe_ingredients drop constraint if exists recipe_ingredients_addition_type_check;
alter table public.recipe_ingredients add constraint recipe_ingredients_addition_type_check
  check (addition_type in ('malt', 'boil_hop', 'dry_hop', 'brewhouse_addition', 'cellar_addition', 'yeast', 'base_beer'));
alter table public.recipe_ingredients drop constraint if exists recipe_ingredients_base_beer_check;
alter table public.recipe_ingredients add constraint recipe_ingredients_base_beer_check
  check ((addition_type = 'base_beer') = (source_recipe_group_id is not null)
         and (addition_type <> 'base_beer' or (ingredient_id is null and quantity > 0 and quantity <= 100)));

alter table public.batch_ingredients drop constraint if exists batch_ingredients_addition_type_check;
alter table public.batch_ingredients add constraint batch_ingredients_addition_type_check
  check (addition_type in ('malt', 'boil_hop', 'dry_hop', 'brewhouse_addition', 'cellar_addition', 'yeast', 'base_beer'));
alter table public.batch_ingredients drop constraint if exists batch_ingredients_base_beer_check;
alter table public.batch_ingredients add constraint batch_ingredients_base_beer_check
  check ((addition_type = 'base_beer') = (source_recipe_group_id is not null));

create index if not exists idx_recipe_ingredients_source_group on public.recipe_ingredients (source_recipe_group_id)
  where source_recipe_group_id is not null;

-- The recipe editor saves base beer lines with the other lines.
create or replace function public.save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb)
returns void
language plpgsql
set search_path to 'public'
as $function$
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
  set ingredient_id          = (l ->> 'ingredient_id')::bigint,
      addition_type          = l ->> 'addition_type',
      quantity               = (l ->> 'quantity')::numeric,
      unit                   = l ->> 'unit',
      timing                 = l ->> 'timing',
      sort_order             = (l ->> 'sort_order')::integer,
      note                   = l ->> 'note',
      hop_dosing_tank        = (l ->> 'hop_dosing_tank')::integer,
      alpha_pct              = (l ->> 'alpha_pct')::numeric,
      color_ebc              = (l ->> 'color_ebc')::numeric,
      all_in_first_brew      = coalesce((l ->> 'all_in_first_brew')::boolean, false),
      source_recipe_group_id = (l ->> 'source_recipe_group_id')::uuid
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
  where ri.id = (l ->> 'id')::bigint
    and ri.id = any (v_keep);

  insert into recipe_ingredients (
    recipe_id, ingredient_id, addition_type, quantity, unit, timing, sort_order,
    note, hop_dosing_tank, alpha_pct, color_ebc, all_in_first_brew, source_recipe_group_id)
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
         coalesce((l ->> 'all_in_first_brew')::boolean, false),
         (l ->> 'source_recipe_group_id')::uuid
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality as t(l, ord)
  where l ->> 'id' is null
     or not ((l ->> 'id')::bigint = any (v_keep))
  order by ord;
end;
$function$;

-- The batch snapshot copies the base beer lines too.
create or replace function public.snapshot_batch_ingredients(p_batch_id bigint)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_count integer;
begin
  if auth.uid() is not null and not can_view('batches') then
    raise exception 'no access to batches' using errcode = '42501';
  end if;

  -- two users opening the same batch at once must not both copy
  perform pg_advisory_xact_lock(hashtext('snapshot_batch_ingredients'), p_batch_id::integer);

  if exists (select 1 from batch_ingredients where batch_id = p_batch_id) then
    return 0;
  end if;

  insert into batch_ingredients (
    batch_id, recipe_ingredient_id, ingredient_id, addition_type, timing, unit, sort_order,
    recipe_quantity, quantity, recipe_alpha_pct, alpha_pct, recipe_color_ebc, color_ebc,
    hop_dosing_tank, all_in_first_brew, note, source_recipe_group_id)
  select b.id, ri.id, ri.ingredient_id, ri.addition_type, ri.timing, ri.unit, ri.sort_order,
         ri.quantity, ri.quantity, ri.alpha_pct, ri.alpha_pct, ri.color_ebc, ri.color_ebc,
         ri.hop_dosing_tank, ri.all_in_first_brew, ri.note, ri.source_recipe_group_id
  from batches b
  join recipe_ingredients ri on ri.recipe_id = b.recipe_id
  where b.id = p_batch_id
  order by ri.addition_type, ri.sort_order, ri.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

-- 2. Split / transfer ----------------------------------------------------------

-- One call per save of the Split / transfer popup: the transfer, the new
-- batch when the destination is 'new', and a log entry with tag Transfer on
-- the source batch. Runs with the rights of the user (RLS on every table).
-- Returns { transfer_id, to_batch_id, batch_number, log_entry_id }.
create or replace function public.split_batch(
  p_batch_id       bigint,
  p_transferred_at timestamptz,
  p_volume_hl      numeric,
  p_from_tank_id   bigint,
  p_destination    text,            -- 'new' | 'batch' | 'discard'
  p_recipe_id      bigint default null,
  p_to_batch_id    bigint default null,
  p_reason         text default null,
  p_comment        text default null)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_to_batch   bigint := p_to_batch_id;
  v_number     text;
  v_recipe     record;
  v_yy         text := to_char(now() at time zone 'Europe/Amsterdam', 'YY');
  v_transfer   bigint;
  v_entry      bigint;
  v_tank       text;
  v_text       text;
  v_dot        text := ' ' || chr(183) || ' ';   -- space, middle dot, space
begin
  if auth.uid() is not null and not can_edit('batches') then
    raise exception 'no edit rights on batches' using errcode = '42501';
  end if;
  if p_destination not in ('new', 'batch', 'discard') then
    raise exception 'destination must be new, batch or discard' using errcode = '22023';
  end if;
  if p_volume_hl is null or p_volume_hl <= 0 then
    raise exception 'the volume must be more than 0 hl' using errcode = '22023';
  end if;
  if p_transferred_at is null then
    raise exception 'the transfer moment is missing' using errcode = '22023';
  end if;

  if p_destination = 'new' then
    select id, name into v_recipe from recipes where id = p_recipe_id;
    if not found then
      raise exception 'choose an existing recipe for the new batch' using errcode = '22023';
    end if;
    -- next number of this year (YY + 3 digits); two saves at once wait for each other
    perform pg_advisory_xact_lock(hashtext('next_batch_number'));
    select (coalesce(max(batch_number::integer), v_yy::integer * 1000) + 1)::text
    into v_number
    from batches
    where batch_number ~ ('^' || v_yy || '[0-9]{3}$');
    insert into batches (batch_number, recipe_id, brew_count, name, status, created_by)
    values (v_number, v_recipe.id, 0, v_recipe.name, 'planned', auth.uid())
    returning id into v_to_batch;
  elsif p_destination = 'batch' then
    select batch_number into v_number from batches where id = p_to_batch_id;
    if not found then
      raise exception 'the receiving batch does not exist' using errcode = '22023';
    end if;
  end if;

  insert into batch_transfers (batch_id, from_tank_id, destination, to_batch_id, volume_hl, transferred_at, reason, comment, updated_by)
  values (p_batch_id, p_from_tank_id, case when p_destination = 'discard' then 'discard' else 'batch' end,
          case when p_destination = 'discard' then null else v_to_batch end,
          p_volume_hl, p_transferred_at, nullif(btrim(p_reason), ''), nullif(btrim(p_comment), ''), auth.uid())
  returning id into v_transfer;

  select code into v_tank from tanks where id = p_from_tank_id;
  v_text := 'Transfer' || v_dot || trim(to_char(p_volume_hl, 'FM999990.0')) || ' hl'
            || coalesce(' from ' || v_tank, '')
            || case p_destination
                 when 'new' then ' to new batch ' || v_number || ' (' || v_recipe.name || ')'
                 when 'batch' then ' to batch ' || v_number
                 else ' discarded' || coalesce(v_dot || nullif(btrim(p_reason), ''), '')
               end
            || coalesce(v_dot || nullif(btrim(p_comment), ''), '');
  insert into fermentation_log_entries (batch_id, measured_at, comment, updated_by)
  values (p_batch_id, p_transferred_at, v_text, auth.uid())
  returning id into v_entry;
  insert into fermentation_log_entry_tags (entry_id, tag_id, batch_id)
  select v_entry, t.id, p_batch_id from cellar_action_tags t where t.code = 'transfer';

  return jsonb_build_object('transfer_id', v_transfer, 'to_batch_id', case when p_destination = 'discard' then null else v_to_batch end,
                            'batch_number', v_number, 'log_entry_id', v_entry);
end;
$function$;

revoke all on function public.split_batch(bigint, timestamptz, numeric, bigint, text, bigint, bigint, text, text) from public, anon;
grant execute on function public.split_batch(bigint, timestamptz, numeric, bigint, text, bigint, bigint, text, text) to authenticated;

-- 3. Stage of a batch: split batches ---------------------------------------------

-- business-rules.md "Stage of a batch": a batch without started brews that
-- receives beer counts as brewed from its first incoming transfer. Columns
-- are only appended: incoming_volume_hl, first_incoming_at.
create or replace view public.batch_stages
with (security_invoker = true)
as
with step_link as (
  -- steps chosen on a tag (fermentation_log_entry_tags.batch_cellar_step_id)
  select et.batch_cellar_step_id as step_id, min(e.measured_at) as done_at
  from public.fermentation_log_entry_tags et
  join public.fermentation_log_entries e on e.id = et.entry_id
  where et.batch_cellar_step_id is not null
  group by 1
),
open_step as (
  -- steps not chosen on any tag, numbered per tag in plan order
  select bcs.id, bcs.batch_id, bcs.tag_id,
         row_number() over (partition by bcs.batch_id, bcs.tag_id order by bcs.sort_order, bcs.id) as occurrence
  from public.batch_cellar_steps bcs
  where not exists (select 1 from step_link l where l.step_id = bcs.id)
),
free_tag as (
  -- tags without a chosen step, numbered per tag in log order
  select et.batch_id, et.tag_id, e.measured_at,
         row_number() over (partition by et.batch_id, et.tag_id order by e.measured_at, e.id, et.id) as occurrence
  from public.fermentation_log_entry_tags et
  join public.fermentation_log_entries e on e.id = et.entry_id
  where et.batch_cellar_step_id is null
),
step_state as (
  -- a chosen step is done by its tag; the n-th free tag with tag T ticks
  -- off the n-th open step with tag T
  select s.batch_id, s.id, s.sort_order, s.title, s.starts_lagering,
         coalesce(l.done_at, f.measured_at) as done_at
  from public.batch_cellar_steps s
  left join step_link l on l.step_id = s.id
  left join open_step o on o.id = s.id
  left join free_tag f on f.batch_id = o.batch_id and f.tag_id = o.tag_id and f.occurrence = o.occurrence
),
plan as (
  select batch_id,
         count(*) as steps_total,
         count(done_at) as steps_done,
         (array_agg(title order by sort_order, id) filter (where done_at is null))[1] as next_step,
         min(done_at) filter (where starts_lagering) as lagering_started_at
  from step_state
  group by batch_id
),
incoming as (
  select t.to_batch_id as batch_id, sum(t.volume_hl) as volume_hl, min(t.transferred_at) as first_at
  from public.batch_transfers t
  where t.to_batch_id is not null
  group by t.to_batch_id
),
base as (
  select b.id, b.status, b.time_zero, b.brew_count,
         ceil(coalesce(b.brew_count, 0))::integer as brews_planned,
         br.brews_started, br.brews_ended, br.first_mash_in_at, br.last_brew_ended_at,
         inc.volume_hl as incoming_volume_hl, inc.first_at as first_incoming_at,
         -- all brews ended, or no brew started and beer came in (split batch)
         (ceil(coalesce(b.brew_count, 0)) > 0 and coalesce(br.brews_ended, 0) >= ceil(b.brew_count))
           or (coalesce(br.brews_started, 0) = 0 and inc.first_at is not null) as is_brewed
  from public.batches b
  left join lateral (
    select count(*) filter (where bb.mash_in_started_at is not null) as brews_started,
           count(*) filter (where bb.brewing_ended_at is not null) as brews_ended,
           min(bb.mash_in_started_at) as first_mash_in_at,
           max(bb.brewing_ended_at) as last_brew_ended_at
    from public.batch_brews bb
    where bb.batch_id = b.id
  ) br on true
  left join incoming inc on inc.batch_id = b.id
)
select
  b.id as batch_id,
  case
    when b.status = 'completed' then 'closed'
    when coalesce(h.hbts_total, 0) > 0 and fs.hbts_finished >= h.hbts_total then 'filled'
    when fs.first_filling_date is not null then 'filling'
    when ps.first_processing_date is not null then 'hbt'
    when b.is_brewed and p.lagering_started_at is not null then 'lagering'
    when b.is_brewed then 'fermentation'
    when coalesce(b.brews_started, 0) > 0 then 'brewing'
    else 'raw'
  end as stage,
  coalesce((b.first_mash_in_at at time zone 'Europe/Amsterdam')::date,
           case when coalesce(b.brews_started, 0) = 0 then (b.first_incoming_at at time zone 'Europe/Amsterdam')::date end) as start_date,
  null::date as end_date,
  b.brews_planned,
  coalesce(b.brews_started, 0)::integer as brews_started,
  coalesce(b.brews_ended, 0)::integer as brews_ended,
  b.last_brew_ended_at,
  coalesce(b.time_zero, b.last_brew_ended_at,
           case when coalesce(b.brews_started, 0) = 0 then b.first_incoming_at end) as time_zero,
  coalesce(p.steps_total, 0)::integer as cellar_steps_total,
  coalesce(p.steps_done, 0)::integer as cellar_steps_done,
  p.next_step as next_cellar_step,
  p.lagering_started_at,
  ps.first_processing_date,
  coalesce(h.hbts_total, 0)::integer as hbts_total,
  coalesce(h.hbts_released, 0)::integer as hbts_released,
  h.hbt_codes,
  coalesce(h.hbt_formats, '{}') as hbt_formats,
  fs.first_filling_date,
  coalesce(fs.hbts_finished, 0)::integer as hbts_finished,
  fs.filled_volume_hl,
  coalesce(b.incoming_volume_hl, 0) as incoming_volume_hl,
  b.first_incoming_at
from base b
left join plan p on p.batch_id = b.id
left join lateral (
  select min(s.processing_date) as first_processing_date
  from public.processing_sessions s
  where s.batch_id = b.id
) ps on true
left join lateral (
  select count(*) as hbts_total,
         count(bh.released_at) as hbts_released,
         string_agg(t.code, ' ' || chr(183) || ' ' order by bh.sort_order, t.number) as hbt_codes,
         array(select distinct f from public.batch_hbts x, unnest(x.intended_formats) f where x.batch_id = b.id order by f) as hbt_formats
  from public.batch_hbts bh
  join public.tanks t on t.id = bh.tank_id
  where bh.batch_id = b.id
) h on true
left join lateral (
  select min(f.filling_date) as first_filling_date,
         count(distinct f.batch_hbt_id) filter (where f.is_hbt_finished) as hbts_finished,
         sum(f.volume_hl) as filled_volume_hl
  from public.filling_sessions f
  where f.batch_id = b.id
) fs on true;

revoke all on public.batch_stages from anon;
grant select on public.batch_stages to authenticated;

commit;
