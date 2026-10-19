-- Batch report, phase 4: Fermentation log (docs/batch-report/data-model.md).
-- Action tags, the cellar plan per recipe (generated from recipe data) and per
-- batch (snapshot), the fermentation log with tags, transfers out, Time 0 /
-- lager tank on the batch, and the lagering stage in batch_stages.
-- One transaction: either everything or nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * Cellar steps get planned_day (indicative day from Time 0) next to
--   trigger_value (°P / °C), and generated_key (which generated step a row
--   is), so regeneration can update a step instead of adding a copy.
-- * The batch snapshot keeps snapshot_batch_ingredients() and adds
--   snapshot_batch_cellar_steps(); the insert trigger calls both (no rename,
--   the pages already call the first one).
-- * batches.time_zero empty = the end of the last brew (batch_stages.time_zero
--   gives the value in use), so the default is not stored twice.

begin;

-- 1. Batch columns -----------------------------------------------------------

alter table public.batches add column if not exists time_zero timestamptz;
alter table public.batches add column if not exists lt_tank_id bigint references public.tanks(id);
create index if not exists idx_batches_lt_tank_id on public.batches (lt_tank_id);

-- 2. Action tags (Settings) ---------------------------------------------------

create table if not exists public.cellar_action_tags (
  id           bigint generated always as identity primary key,
  code         text not null unique check (code ~ '^[a-z0-9_]+$'),
  label        text not null,
  is_milestone boolean not null default false,
  sort_order   integer not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid() references public.users(id),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.users(id)
);

insert into public.cellar_action_tags (code, label, is_milestone, sort_order)
values ('24h_purge', '24h purge', false, 10),
       ('purge', 'Purge', false, 20),
       ('spunding', 'Spunding', false, 30),
       ('dry_warm', 'Dry warm', true, 40),
       ('dryhopping', 'Dryhopping', true, 50),
       ('tasting', 'Tasting', false, 60),
       ('cooling', 'Cooling', true, 70),
       ('addition', 'Addition', true, 80),
       ('pump_start', 'Pump start', false, 90),
       ('pump_stop', 'Pump stop', false, 100),
       ('transfer', 'Transfer', false, 110),
       ('transport', 'Transport', false, 120),
       ('processing', 'Processing', false, 130),
       ('sample_lab', 'Sample to lab', true, 140),
       ('blending', 'Blending', false, 150),
       ('other', 'Other', false, 160)
on conflict (code) do nothing;

-- 3. Cellar plan per recipe ---------------------------------------------------

create table if not exists public.recipe_cellar_steps (
  id                    bigint generated always as identity primary key,
  recipe_id             bigint not null references public.recipes(id) on delete cascade,
  sort_order            integer not null,
  tag_id                bigint not null references public.cellar_action_tags(id),
  title                 text not null,
  description           text,
  trigger_type          text not null check (trigger_type in ('extract', 'day', 'after_previous', 'temperature')),
  trigger_value         numeric,
  trigger_tol           numeric,
  planned_day           numeric,
  recipe_ingredient_ids bigint[] not null default '{}',
  starts_lagering       boolean not null default false,
  is_generated          boolean not null default true,
  generated_key         text,
  created_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.users(id),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.users(id),
  constraint recipe_cellar_steps_day_check check (trigger_type <> 'day' or planned_day is not null),
  constraint recipe_cellar_steps_key_unique unique (recipe_id, generated_key)
);

create index if not exists idx_recipe_cellar_steps_recipe_id on public.recipe_cellar_steps (recipe_id, sort_order);

-- 4. Cellar plan per batch (snapshot; done-status is derived from the log) ---

create table if not exists public.batch_cellar_steps (
  id                    bigint generated always as identity primary key,
  batch_id              bigint not null references public.batches(id) on delete cascade,
  recipe_cellar_step_id bigint references public.recipe_cellar_steps(id) on delete set null,
  sort_order            integer not null,
  tag_id                bigint not null references public.cellar_action_tags(id),
  title                 text not null,
  description           text,
  trigger_type          text not null check (trigger_type in ('extract', 'day', 'after_previous', 'temperature')),
  trigger_value         numeric,
  trigger_tol           numeric,
  planned_day           numeric,
  recipe_ingredient_ids bigint[] not null default '{}',
  starts_lagering       boolean not null default false,
  created_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.users(id),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.users(id)
);

create index if not exists idx_batch_cellar_steps_batch_id on public.batch_cellar_steps (batch_id, sort_order);

-- 5. Fermentation log ---------------------------------------------------------

create table if not exists public.fermentation_log_entries (
  id          bigint generated always as identity primary key,
  batch_id    bigint not null references public.batches(id) on delete cascade,
  measured_at timestamptz not null,
  extract     numeric,
  temp_high   numeric,
  temp_low    numeric,
  ph          numeric,
  comment     text,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid() references public.users(id),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.users(id),
  constraint fermentation_log_entries_id_batch_key unique (id, batch_id)
);

create index if not exists idx_fermentation_log_entries_batch_id on public.fermentation_log_entries (batch_id, measured_at);

-- batch_id must be the batch of the entry: the foreign key covers both.
create table if not exists public.fermentation_log_entry_tags (
  entry_id   bigint not null,
  tag_id     bigint not null references public.cellar_action_tags(id),
  batch_id   bigint not null,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references public.users(id),
  primary key (entry_id, tag_id),
  constraint fermentation_log_entry_tags_entry_fkey foreign key (entry_id, batch_id)
    references public.fermentation_log_entries (id, batch_id) on delete cascade
);

create index if not exists idx_fermentation_log_entry_tags_batch_id on public.fermentation_log_entry_tags (batch_id);
create index if not exists idx_fermentation_log_entry_tags_tag_id on public.fermentation_log_entry_tags (tag_id);

-- 6. Transfers out (simple form now, full flow in phase 8) -------------------

create table if not exists public.batch_transfers (
  id             bigint generated always as identity primary key,
  batch_id       bigint not null references public.batches(id) on delete cascade,
  from_tank_id   bigint references public.tanks(id),
  destination    text not null check (destination in ('batch', 'discard')),
  to_batch_id    bigint references public.batches(id),
  volume_hl      numeric not null check (volume_hl > 0),
  transferred_at timestamptz not null,
  reason         text,
  comment        text,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid() references public.users(id),
  updated_at     timestamptz not null default now(),
  updated_by     uuid references public.users(id),
  constraint batch_transfers_to_batch_check check ((destination = 'batch') = (to_batch_id is not null)),
  constraint batch_transfers_not_self check (to_batch_id is distinct from batch_id),
  constraint batch_transfers_discard_reason check (destination <> 'discard' or nullif(btrim(reason), '') is not null)
);

create index if not exists idx_batch_transfers_batch_id on public.batch_transfers (batch_id);
create index if not exists idx_batch_transfers_to_batch_id on public.batch_transfers (to_batch_id);
create index if not exists idx_batch_transfers_from_tank_id on public.batch_transfers (from_tank_id);

-- 7. Triggers, RLS, grants ----------------------------------------------------

-- Batch tables: updated_at, audit trail, module "batches".
do $$
declare
  t text;
begin
  foreach t in array array['batch_cellar_steps', 'fermentation_log_entries', 'fermentation_log_entry_tags', 'batch_transfers'] loop
    if t <> 'fermentation_log_entry_tags' then
      execute format('drop trigger if exists trg_%1$s_updated_at on public.%1$I', t);
      execute format('create trigger trg_%1$s_updated_at before update on public.%1$I
                      for each row execute function public.set_updated_at()', t);
    end if;
    execute format('drop trigger if exists trg_%1$s_audit on public.%1$I', t);
    execute format('create trigger trg_%1$s_audit after insert or update or delete on public.%1$I
                    for each row execute function public.log_batch_change(%2$s)', t,
                   case when t = 'fermentation_log_entry_tags' then '''entry_id'', ''tag_id''' else '' end);

    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %1$s_select on public.%1$I', t);
    execute format('drop policy if exists %1$s_insert on public.%1$I', t);
    execute format('drop policy if exists %1$s_update on public.%1$I', t);
    execute format('drop policy if exists %1$s_delete on public.%1$I', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated using (can_view(''batches''))', t);
    execute format('create policy %1$s_insert on public.%1$I for insert to authenticated with check (can_edit(''batches''))', t);
    execute format('create policy %1$s_update on public.%1$I for update to authenticated using (can_edit(''batches'')) with check (can_edit(''batches''))', t);
    execute format('create policy %1$s_delete on public.%1$I for delete to authenticated using (can_delete(''batches''))', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- Recipe cellar plan: as recipe_ingredients (module "recipes").
drop trigger if exists trg_recipe_cellar_steps_updated_at on public.recipe_cellar_steps;
create trigger trg_recipe_cellar_steps_updated_at before update on public.recipe_cellar_steps
  for each row execute function public.set_updated_at();
alter table public.recipe_cellar_steps enable row level security;
drop policy if exists recipe_cellar_steps_select on public.recipe_cellar_steps;
drop policy if exists recipe_cellar_steps_insert on public.recipe_cellar_steps;
drop policy if exists recipe_cellar_steps_update on public.recipe_cellar_steps;
drop policy if exists recipe_cellar_steps_delete on public.recipe_cellar_steps;
create policy recipe_cellar_steps_select on public.recipe_cellar_steps for select to authenticated using (can_view('recipes'));
create policy recipe_cellar_steps_insert on public.recipe_cellar_steps for insert to authenticated with check (can_edit('recipes'));
create policy recipe_cellar_steps_update on public.recipe_cellar_steps for update to authenticated using (can_edit('recipes')) with check (can_edit('recipes'));
create policy recipe_cellar_steps_delete on public.recipe_cellar_steps for delete to authenticated using (can_edit('recipes'));
revoke all on public.recipe_cellar_steps from anon;

-- Action tags: everyone logged in reads, Settings writes (as tanks).
drop trigger if exists trg_cellar_action_tags_updated_at on public.cellar_action_tags;
create trigger trg_cellar_action_tags_updated_at before update on public.cellar_action_tags
  for each row execute function public.set_updated_at();
alter table public.cellar_action_tags enable row level security;
drop policy if exists cellar_action_tags_select on public.cellar_action_tags;
drop policy if exists cellar_action_tags_insert on public.cellar_action_tags;
drop policy if exists cellar_action_tags_update on public.cellar_action_tags;
drop policy if exists cellar_action_tags_delete on public.cellar_action_tags;
create policy cellar_action_tags_select on public.cellar_action_tags for select to authenticated using (true);
create policy cellar_action_tags_insert on public.cellar_action_tags for insert to authenticated with check (can_edit('settings'));
create policy cellar_action_tags_update on public.cellar_action_tags for update to authenticated using (can_edit('settings')) with check (can_edit('settings'));
create policy cellar_action_tags_delete on public.cellar_action_tags for delete to authenticated using (can_delete('settings'));
revoke all on public.cellar_action_tags from anon;

-- 8. Helpers for the generator ------------------------------------------------

-- '±0.5', '0,5', '-' -> 0.5, 0.5, null (as toleranceValue() in batch-brews.js).
create or replace function public.tolerance_value(p_text text)
returns numeric
language sql
immutable
set search_path = public
as $$
  select abs(nullif(replace(substring(coalesce(p_text, '') from '-?[0-9]+(?:[.,][0-9]+)?'), ',', '.'), '')::numeric)
$$;

-- Where a cellar addition is dosed, from its free-text timing (decision #5:
-- by keywords). The standard values are the codes themselves. Returns one of
-- lagering, after_cold_dry_hop, fermentation, after_dealcoholisation (cellar
-- plan), processing, centrifuge_inlet, centrifuge_outlet, hbt (Processing
-- tab), or null when the text says nothing known. Order matters: a text that
-- names both lagering and processing goes to Processing.
create or replace function public.cellar_addition_timing(p_timing text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when t = '' then null
    when t in ('lagering', 'after_cold_dry_hop', 'fermentation', 'after_dealcoholisation',
               'processing', 'centrifuge_inlet', 'centrifuge_outlet', 'hbt') then t
    when t ~ 'hbt' then 'hbt'
    when t ~ '(after|exit).*(centrifug|fuge)|(centrifug|fuge).*(exit|outlet)' then 'centrifuge_outlet'
    when t ~ 'de-?alc' then 'after_dealcoholisation'
    when t ~ 'before centrifug|inlet|centrifugering' or t = 'fuge' then 'centrifuge_inlet'
    when t ~ 'process|verwerking|dosing keg|in line|\mfuge\M' then 'processing'
    when t ~ 'koude dry ?hop|cold dry ?hop' then 'after_cold_dry_hop'
    when t ~ 'lager|lageing|matur|matruation|corpedo' then 'lagering'
    when t ~ 'warm|plato|ferment|gist|yeast|[0-9] ?p\M' then 'fermentation'
    else null
  end
  from (select lower(btrim(coalesce(p_timing, ''))) as t) x
$$;

-- 9. Cellar plan generation (business-rules.md, "Cellar plan generation") ----

-- Builds the generated steps of one recipe from its dry hops, cellar
-- additions, fermentation and lagering data. A step changed by hand
-- (is_generated = false) keeps its text and trigger; only its linked lines
-- are refreshed. Generated steps the recipe no longer asks for are removed;
-- steps added by hand stay. Returns the number of steps of the recipe.
create or replace function public.generate_recipe_cellar_steps(p_recipe_id bigint)
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
  v_cold      record;
  v_line      record;
  v_n         integer := 0;
  v_count     integer;
  v_after_cold boolean := false;
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

  -- 1. Dry warm
  if exists (select 1 from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
             and lower(btrim(timing)) like 'warm%') then
    v_n := v_n + 1;
    insert into _gen_steps
    select v_n, 'dry_warm', 'dry_warm', 'Dry warm',
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

  -- Additions during fermentation come before the cooling.
  for v_line in
    select ri.id, coalesce(i.name, nullif(btrim(ri.note), ''), 'cellar addition') as name, ri.note
    from recipe_ingredients ri left join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id and ri.addition_type = 'cellar_addition'
      and cellar_addition_timing(ri.timing) = 'fermentation'
    order by ri.sort_order, ri.id
  loop
    v_n := v_n + 1;
    insert into _gen_steps values (v_n, 'addition:' || v_line.id, 'addition', 'Addition · ' || v_line.name,
      nullif(btrim(v_line.note), ''), 'after_previous', null, null, null, array[v_line.id], false);
  end loop;

  -- 2-3. Cold dry hop above the lagering temperature: cool, then dry hop.
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
    insert into _gen_steps values (v_n, 'cooling_dry_hop:' || v_cold.temp::float8, 'cooling',
      'Cooling to ' || v_cold.temp::float8 || ' °C', null,
      case when v_after_cold or v_spec.final_extract is null then 'after_previous' else 'extract' end,
      case when v_after_cold then null else v_spec.final_extract end,
      case when v_after_cold then null else tolerance_value(v_spec.final_extract_tol) end,
      null, '{}', false);
    v_n := v_n + 1;
    insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, 'dryhopping',
      'Dryhopping @' || v_cold.temp::float8 || ' °C',
      nullif(concat_ws(' · ', nullif(btrim(v_ps.dry_hop_method_16c), ''), nullif(btrim(v_ps.dry_hop_comment_16c), '')), ''),
      'after_previous', null, null, null, v_cold.ids, false);
    v_after_cold := true;
  end loop;

  -- Dry hops without a timing: shown so they are not forgotten.
  if exists (select 1 from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
             and nullif(btrim(timing), '') is null) then
    v_n := v_n + 1;
    insert into _gen_steps
    select v_n, 'dry_hop:unset', 'dryhopping', 'Dryhopping', 'Timing not set in the recipe',
           'after_previous', null, null, null,
           array(select id from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                 and nullif(btrim(timing), '') is null order by sort_order, id),
           false;
    v_after_cold := true;
  end if;

  -- 4. Cooling to the lagering temperature: always; lagering starts here.
  v_n := v_n + 1;
  insert into _gen_steps values (v_n, 'cooling_lagering', 'cooling', 'Cooling to ' || v_lag_label,
    nullif(concat_ws(' · ', 'Lagering temperature from recipe',
      case when v_ferm.lagering_time is not null then v_ferm.lagering_time::float8 || ' days' end,
      case when v_after_cold then 'cool < 24 h after the dry hop' end), ''),
    case when v_after_cold or v_spec.final_extract is null then 'after_previous' else 'extract' end,
    case when v_after_cold then null else v_spec.final_extract end,
    case when v_after_cold then null else tolerance_value(v_spec.final_extract_tol) end,
    null, '{}', true);

  -- Cold dry hop at or below the lagering temperature: after that cooling.
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
    insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, 'dryhopping',
      'Dryhopping @' || v_cold.temp::float8 || ' °C',
      nullif(concat_ws(' · ', nullif(btrim(v_ps.dry_hop_method_16c), ''), nullif(btrim(v_ps.dry_hop_comment_16c), '')), ''),
      'after_previous', null, null, null, v_cold.ids, false);
  end loop;

  -- 5. Sample to lab: after the last cooling (decision #4).
  v_n := v_n + 1;
  insert into _gen_steps values (v_n, 'sample_lab', 'sample_lab', 'Sample to lab', 'Always after cooling',
    'after_previous', null, null, null, '{}', false);

  -- 6. Cellar additions: after the cold dry hop, on the addition day, after
  --    de-alcoholisation; a timing that says nothing known also lands here.
  for v_line in
    select ri.id, coalesce(i.name, nullif(btrim(ri.note), ''), 'cellar addition') as name, ri.note,
           coalesce(cellar_addition_timing(ri.timing), 'unknown') as place
    from recipe_ingredients ri left join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id and ri.addition_type = 'cellar_addition'
      and coalesce(cellar_addition_timing(ri.timing), 'unknown') in ('after_cold_dry_hop', 'lagering', 'unknown', 'after_dealcoholisation')
    order by case coalesce(cellar_addition_timing(ri.timing), 'unknown')
               when 'after_cold_dry_hop' then 1 when 'lagering' then 2 when 'unknown' then 3 else 4 end,
             ri.sort_order, ri.id
  loop
    v_n := v_n + 1;
    insert into _gen_steps values (v_n, 'addition:' || v_line.id, 'addition', 'Addition · ' || v_line.name,
      nullif(concat_ws(' · ',
        case v_line.place when 'after_cold_dry_hop' then 'after the cold dry hop'
                          when 'after_dealcoholisation' then 'after de-alcoholisation'
                          when 'unknown' then 'timing to check in the recipe' end,
        nullif(btrim(v_line.note), '')), ''),
      case when v_line.place in ('lagering', 'unknown') and v_ps.cellar_addition_day is not null then 'day' else 'after_previous' end,
      null, null,
      case when v_line.place in ('lagering', 'unknown') then v_ps.cellar_addition_day end,
      array[v_line.id], false);
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

  -- Renumber 10, 20, 30 … in the resulting order.
  update recipe_cellar_steps s
  set sort_order = o.rn * 10
  from (select id, row_number() over (order by sort_order, id) as rn
        from recipe_cellar_steps where recipe_id = p_recipe_id) o
  where s.id = o.id and s.sort_order <> o.rn * 10;

  drop table _gen_steps;   -- the next call may run as another role
  select count(*) into v_count from recipe_cellar_steps where recipe_id = p_recipe_id;
  return v_count;
end;
$$;

revoke execute on function public.generate_recipe_cellar_steps(bigint) from public, anon;
grant execute on function public.generate_recipe_cellar_steps(bigint) to authenticated;

-- The recipe editor saves the plan as it shows it, then regenerates. Steps
-- of this recipe are updated (they keep their id), new ones inserted
-- (including the steps of the previous version when saving a new version),
-- removed ones deleted. One transaction.
create or replace function public.save_recipe_cellar_steps(p_recipe_id bigint, p_steps jsonb)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_keep bigint[];
begin
  if not can_edit('recipes') then
    raise exception 'no edit rights on recipes' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_steps, '[]'::jsonb)) <> 'array' then
    raise exception 'p_steps must be a JSON array';
  end if;

  select coalesce(array_agg((e ->> 'id')::bigint), '{}') into v_keep
  from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb)) e
  where (e ->> 'id') is not null
    and exists (select 1 from recipe_cellar_steps s where s.id = (e ->> 'id')::bigint and s.recipe_id = p_recipe_id);

  delete from recipe_cellar_steps where recipe_id = p_recipe_id and id <> all (v_keep);

  update recipe_cellar_steps s
  set sort_order = (e ->> 'sort_order')::integer,
      tag_id = (e ->> 'tag_id')::bigint,
      title = e ->> 'title',
      description = nullif(btrim(e ->> 'description'), ''),
      trigger_type = e ->> 'trigger_type',
      trigger_value = (e ->> 'trigger_value')::numeric,
      trigger_tol = (e ->> 'trigger_tol')::numeric,
      planned_day = (e ->> 'planned_day')::numeric,
      starts_lagering = coalesce((e ->> 'starts_lagering')::boolean, false),
      is_generated = coalesce((e ->> 'is_generated')::boolean, false),
      updated_by = auth.uid()
  from jsonb_array_elements(p_steps) e
  where s.recipe_id = p_recipe_id and s.id = (e ->> 'id')::bigint
    and (s.sort_order, s.tag_id, s.title, s.description, s.trigger_type, s.trigger_value, s.trigger_tol,
         s.planned_day, s.starts_lagering, s.is_generated)
        is distinct from
        ((e ->> 'sort_order')::integer, (e ->> 'tag_id')::bigint, e ->> 'title', nullif(btrim(e ->> 'description'), ''),
         e ->> 'trigger_type', (e ->> 'trigger_value')::numeric, (e ->> 'trigger_tol')::numeric,
         (e ->> 'planned_day')::numeric, coalesce((e ->> 'starts_lagering')::boolean, false),
         coalesce((e ->> 'is_generated')::boolean, false));

  insert into recipe_cellar_steps (recipe_id, sort_order, tag_id, title, description, trigger_type,
    trigger_value, trigger_tol, planned_day, starts_lagering, is_generated, generated_key)
  select p_recipe_id, (e ->> 'sort_order')::integer, (e ->> 'tag_id')::bigint, e ->> 'title',
         nullif(btrim(e ->> 'description'), ''), e ->> 'trigger_type', (e ->> 'trigger_value')::numeric,
         (e ->> 'trigger_tol')::numeric, (e ->> 'planned_day')::numeric,
         coalesce((e ->> 'starts_lagering')::boolean, false), coalesce((e ->> 'is_generated')::boolean, false),
         e ->> 'generated_key'
  from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb)) e
  where (e ->> 'id') is null or not ((e ->> 'id')::bigint = any (v_keep));

  return generate_recipe_cellar_steps(p_recipe_id);
end;
$$;

revoke execute on function public.save_recipe_cellar_steps(bigint, jsonb) from public, anon;
grant execute on function public.save_recipe_cellar_steps(bigint, jsonb) to authenticated;

-- 10. Batch snapshot of the cellar plan --------------------------------------

create or replace function public.snapshot_batch_cellar_steps(p_batch_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if auth.uid() is not null and not can_view('batches') then
    raise exception 'no access to batches' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('snapshot_batch_cellar_steps'), p_batch_id::integer);

  if exists (select 1 from batch_cellar_steps where batch_id = p_batch_id) then
    return 0;
  end if;

  insert into batch_cellar_steps (batch_id, recipe_cellar_step_id, sort_order, tag_id, title, description,
    trigger_type, trigger_value, trigger_tol, planned_day, recipe_ingredient_ids, starts_lagering)
  select b.id, s.id, s.sort_order, s.tag_id, s.title, s.description,
         s.trigger_type, s.trigger_value, s.trigger_tol, s.planned_day, s.recipe_ingredient_ids, s.starts_lagering
  from batches b
  join recipe_cellar_steps s on s.recipe_id = b.recipe_id
  where b.id = p_batch_id
  order by s.sort_order, s.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.snapshot_batch_cellar_steps(bigint) from public, anon;
grant execute on function public.snapshot_batch_cellar_steps(bigint) to authenticated;

create or replace function public.snapshot_new_batch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform snapshot_batch_ingredients(new.id);
  perform snapshot_batch_cellar_steps(new.id);
  return null;
end;
$$;

revoke execute on function public.snapshot_new_batch() from public, anon, authenticated;

-- 11. Stage of a batch: lagering ---------------------------------------------

-- business-rules.md "Stage of a batch" / "Cellar plan progress": the n-th
-- log entry with tag T ticks off the n-th plan step with tag T. Lagering
-- starts when the step with starts_lagering is done (decision #3: the
-- cooling, not choosing an LT). Columns are only appended.
create or replace view public.batch_stages
with (security_invoker = true)
as
with step_state as (
  select s.batch_id, s.id, s.sort_order, s.title, s.starts_lagering,
         done.measured_at as done_at
  from (select bcs.*, row_number() over (partition by bcs.batch_id, bcs.tag_id order by bcs.sort_order, bcs.id) as occurrence
        from public.batch_cellar_steps bcs) s
  left join lateral (
    select e.measured_at
    from public.fermentation_log_entry_tags et
    join public.fermentation_log_entries e on e.id = et.entry_id
    where et.batch_id = s.batch_id and et.tag_id = s.tag_id
    order by e.measured_at, e.id
    offset s.occurrence - 1 limit 1
  ) done on true
),
plan as (
  select batch_id,
         count(*) as steps_total,
         count(done_at) as steps_done,
         (array_agg(title order by sort_order, id) filter (where done_at is null))[1] as next_step,
         min(done_at) filter (where starts_lagering) as lagering_started_at
  from step_state
  group by batch_id
)
select
  b.id as batch_id,
  case
    when b.status = 'completed' then 'closed'
    when ceil(coalesce(b.brew_count, 0)) > 0
         and coalesce(br.brews_ended, 0) >= ceil(b.brew_count)
         and p.lagering_started_at is not null then 'lagering'
    when ceil(coalesce(b.brew_count, 0)) > 0
         and coalesce(br.brews_ended, 0) >= ceil(b.brew_count) then 'fermentation'
    when coalesce(br.brews_started, 0) > 0 then 'brewing'
    else 'raw'
  end as stage,
  (br.first_mash_in_at at time zone 'Europe/Amsterdam')::date as start_date,
  null::date as end_date,
  ceil(coalesce(b.brew_count, 0))::integer as brews_planned,
  coalesce(br.brews_started, 0)::integer as brews_started,
  coalesce(br.brews_ended, 0)::integer as brews_ended,
  br.last_brew_ended_at,
  coalesce(b.time_zero, br.last_brew_ended_at) as time_zero,
  coalesce(p.steps_total, 0)::integer as cellar_steps_total,
  coalesce(p.steps_done, 0)::integer as cellar_steps_done,
  p.next_step as next_cellar_step,
  p.lagering_started_at
from public.batches b
left join lateral (
  select count(*) filter (where bb.mash_in_started_at is not null) as brews_started,
         count(*) filter (where bb.brewing_ended_at is not null) as brews_ended,
         min(bb.mash_in_started_at) as first_mash_in_at,
         max(bb.brewing_ended_at) as last_brew_ended_at
  from public.batch_brews bb
  where bb.batch_id = b.id
) br on true
left join plan p on p.batch_id = b.id;

revoke all on public.batch_stages from anon;
grant select on public.batch_stages to authenticated;

-- 12. Backfill ----------------------------------------------------------------

-- Cellar plan for every active recipe.
do $$
declare
  r record;
begin
  for r in select id from public.recipes where status = 'active' order by id loop
    perform public.generate_recipe_cellar_steps(r.id);
  end loop;
end $$;

-- Plan snapshot for every planned batch (as the ingredients in phase 2).
select public.snapshot_batch_cellar_steps(b.id)
from public.batches b
where b.status = 'planned'
order by b.id;

commit;
