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
-- * cellar_plan_parts (Settings › Cellar plan): the order of the plan and
--   the timing values of cellar additions (Jaap, 20-10), instead of a fixed
--   order in the generator.
-- * Recipe data from the review sheets (section 12): standard timing values,
--   dry hop timings, lagering temperatures.
-- * batches.time_zero empty = the end of the last brew (batch_stages.time_zero
--   gives the value in use), so the default is not stored twice.

begin;

-- The texts below contain ° and ·: stop when the script was not read as UTF-8.
do $$ begin
  if length('°·') <> 2 or '°' <> chr(176) then
    raise exception 'This script was not read as UTF-8; nothing was changed';
  end if;
end $$;

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

-- 2b. Cellar plan parts (Settings › Cellar plan) -----------------------------

-- The order of the cellar plan and the timing values of cellar additions.
-- Fixed parts (dry warm, cold dry hop, cooling to lagering temperature,
-- sample to lab, dry hop at lagering temperature) are generated from the
-- recipe; each addition_timing row is a value of
-- recipe_ingredients.timing for cellar additions. Parts with shows_on
-- 'processing' are not in the cellar plan (Processing tab, phase 5). The
-- generator follows sort_order (drag and drop in Settings).
create table if not exists public.cellar_plan_parts (
  id              bigint generated always as identity primary key,
  code            text not null unique check (code ~ '^[a-z0-9_]+$'),
  kind            text not null check (kind in ('dry_warm', 'cold_dry_hop', 'cooling_lagering', 'sample_lab',
                                                'dry_hop_at_lagering', 'addition_timing')),
  label           text not null,
  shows_on        text not null default 'cellar_plan' check (shows_on in ('cellar_plan', 'processing')),
  on_addition_day boolean not null default false,
  sort_order      integer not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid() references public.users(id),
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.users(id),
  constraint cellar_plan_parts_fixed_check check (kind = 'addition_timing' or (code = kind and shows_on = 'cellar_plan' and is_active))
);

insert into public.cellar_plan_parts (code, kind, label, shows_on, on_addition_day, sort_order)
values ('dry_warm', 'dry_warm', 'Dry warm', 'cellar_plan', false, 10),
       ('with_warm_dry_hop', 'addition_timing', 'With warm dry hop', 'cellar_plan', false, 20),
       ('fermentation', 'addition_timing', 'During fermentation (see note)', 'cellar_plan', false, 30),
       ('cold_dry_hop', 'cold_dry_hop', 'Cold dry hop above lagering temperature (cooling + dry hop)', 'cellar_plan', false, 40),
       ('after_cold_dry_hop', 'addition_timing', 'After cold dry hop', 'cellar_plan', false, 50),
       ('cooling_lagering', 'cooling_lagering', 'Cooling to lagering temperature (lagering starts)', 'cellar_plan', false, 60),
       ('sample_lab', 'sample_lab', 'Sample to lab', 'cellar_plan', false, 70),
       ('dry_hop_at_lagering', 'dry_hop_at_lagering', 'Dry hop at lagering temperature', 'cellar_plan', false, 80),
       ('lagering', 'addition_timing', 'Lagering', 'cellar_plan', true, 90),
       ('after_dealcoholisation', 'addition_timing', 'After de-alcoholisation', 'cellar_plan', false, 100),
       ('processing', 'addition_timing', 'Processing', 'processing', false, 110),
       ('centrifuge_inlet', 'addition_timing', 'Inlet centrifuge', 'processing', false, 120),
       ('centrifuge_outlet', 'addition_timing', 'After centrifuge', 'processing', false, 130),
       ('hbt', 'addition_timing', 'HBT', 'processing', false, 140)
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

-- Cellar plan parts: everyone logged in reads (recipe editor dropdown),
-- Settings writes; only timing values can be deleted.
drop trigger if exists trg_cellar_plan_parts_updated_at on public.cellar_plan_parts;
create trigger trg_cellar_plan_parts_updated_at before update on public.cellar_plan_parts
  for each row execute function public.set_updated_at();
alter table public.cellar_plan_parts enable row level security;
drop policy if exists cellar_plan_parts_select on public.cellar_plan_parts;
drop policy if exists cellar_plan_parts_insert on public.cellar_plan_parts;
drop policy if exists cellar_plan_parts_update on public.cellar_plan_parts;
drop policy if exists cellar_plan_parts_delete on public.cellar_plan_parts;
create policy cellar_plan_parts_select on public.cellar_plan_parts for select to authenticated using (true);
create policy cellar_plan_parts_insert on public.cellar_plan_parts for insert to authenticated with check (can_edit('settings') and kind = 'addition_timing');
create policy cellar_plan_parts_update on public.cellar_plan_parts for update to authenticated using (can_edit('settings')) with check (can_edit('settings'));
create policy cellar_plan_parts_delete on public.cellar_plan_parts for delete to authenticated using (can_delete('settings') and kind = 'addition_timing');
revoke all on public.cellar_plan_parts from anon;

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

-- 9. Cellar plan generation (business-rules.md, "Cellar plan generation") ----

-- Builds the generated steps of one recipe from its dry hops, cellar
-- additions, fermentation and lagering data, in the order of
-- cellar_plan_parts. A step changed by hand (is_generated = false) keeps its
-- text and trigger; only its linked lines are refreshed. Generated steps the
-- recipe no longer asks for are removed; steps added by hand stay.
-- New generated steps go after the step generated before them; existing
-- steps keep their place, unless p_reset_order: then every step is put in
-- the order of cellar_plan_parts (a step added by hand stays right after the
-- generated step it followed). Returns the number of steps of the recipe.
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

    if v_part.kind = 'dry_warm' then
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
        insert into _gen_steps values (v_n, 'cooling_dry_hop:' || v_cold.temp::float8, 'cooling',
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
      insert into _gen_steps values (v_n, 'cooling_lagering', 'cooling', 'Cooling to ' || v_lag_label,
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
      insert into _gen_steps values (v_n, 'sample_lab', 'sample_lab', 'Sample to lab', 'Always after cooling',
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
        insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, 'dryhopping',
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
        insert into _gen_steps values (v_n, 'addition:' || v_line.id, 'addition', 'Addition · ' || v_line.name,
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

-- Settings › Cellar plan "Apply to the recipes": every recipe that gets a
-- plan (active, or used by a planned batch) is regenerated in the order of
-- cellar_plan_parts. Batches keep the plan they have.
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
  if not (can_edit('settings') and can_edit('recipes')) then
    raise exception 'needs edit rights on settings and recipes' using errcode = '42501';
  end if;
  for r in select id from recipes
           where status = 'active' or id in (select recipe_id from batches where status = 'planned')
           order by id loop
    perform generate_recipe_cellar_steps(r.id, true);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke execute on function public.apply_cellar_plan_order() from public, anon;
grant execute on function public.apply_cellar_plan_order() to authenticated;

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

-- 12. Recipe data from the review sheets (Jaap, 19/20-10) -------------------

-- Only recipes that get a cellar plan: active ones and the recipes of
-- planned batches. Archived recipes keep their texts as history. Every
-- change is guarded by the value it had, so data edited since the review is
-- left alone. Planned batches get the same change in their ingredient copy.
create temporary table _scope on commit drop as
select id as recipe_id from public.recipes
where status = 'active' or id in (select recipe_id from public.batches where status = 'planned');

-- a. Cellar addition timings -> standard values; extra text moves to the note.
create temporary table _timing_map (old_timing text primary key, new_timing text not null, note_text text) on commit drop;
insert into _timing_map (old_timing, new_timing, note_text) values
  ('lagering', 'lagering', null),
  ('Lagering', 'lagering', null),
  ('lageing', 'lagering', null),
  ('Start lagering', 'lagering', 'at start of lagering'),
  ('matruation (0C)', 'lagering', 'maturation at 0 °C'),
  ('lagering (to hit pH 4,2 +/- 0,1', 'lagering', 'to hit pH 4,2 ± 0,1'),
  ('LAGERING (to hit pH 4,2 +/- 0,1)', 'lagering', 'to hit pH 4,2 ± 0,1'),
  ('lagering (test first)', 'lagering', 'test first'),
  ('Lagering (measure clarity first)', 'lagering', 'measure clarity first'),
  ('lagering (dislove in 5-10 L of hot water)', 'lagering', 'dissolve in 5–10 l of hot water'),
  ('Lagering ( 2 days before Cnetrifuge)', 'lagering', '2 days before centrifuge'),
  ('Lagering with Corpedo', 'lagering', 'with Corpedo'),
  ('Corpedo', 'lagering', 'with Corpedo'),
  ('na koude dryhop', 'after_cold_dry_hop', null),
  ('na koude dryhop (check if base beer has it already)', 'after_cold_dry_hop', 'check if base beer has it already'),
  ('Warm', 'fermentation', 'warm'),
  ('4 Plato before FG', 'fermentation', '4 °P before FG'),
  ('5 Plato before FG', 'fermentation', '5 °P before FG'),
  ('At 12.5P', 'fermentation', 'at 12.5 °P'),
  ('bij de gist', 'fermentation', 'with the yeast'),
  ('lagering after de-alc', 'after_dealcoholisation', null),
  ('after dealcolisation', 'after_dealcoholisation', null),
  ('after de-alc', 'after_dealcoholisation', null),
  ('verwerking', 'processing', null),
  ('Verwerking', 'processing', null),
  ('processing', 'processing', null),
  ('verwerking - in mg/l @ can/bottle/keg (batches with low IBU)', 'processing', 'in mg/l at can/bottle/keg (batches with low IBU)'),
  ('lagering/ processing', 'processing', 'lagering or processing'),
  ('Lagering/ processing', 'processing', 'lagering or processing'),
  ('lagering/processing', 'processing', 'lagering or processing'),
  ('lagering/ processing with dosing keg', 'processing', 'lagering, or processing with dosing keg'),
  ('lagering or in line with dosing keg', 'processing', 'lagering, or in line with dosing keg'),
  ('lagering or dosing in line with dosing keg', 'processing', 'lagering, or in line with dosing keg'),
  ('fuge or cellar', 'processing', 'centrifuge or cellar'),
  ('inlet centrifuge', 'centrifuge_inlet', null),
  ('centrifugering', 'centrifuge_inlet', null),
  ('fuge', 'centrifuge_inlet', null),
  ('Lagering/ processing with dosing keg before centrifuge', 'centrifuge_inlet', 'lagering, or with dosing keg before centrifuge'),
  ('after centrifuge', 'centrifuge_outlet', null),
  ('centrifuge exit', 'centrifuge_outlet', null),
  ('HBT', 'hbt', null),
  ('hbt', 'hbt', null),
  ('HBT (only if needed, ask LT)', 'hbt', 'only if needed, ask LT');

-- b. Lines from the review (by line id; the old value is checked).
create temporary table _line_fix (line_id bigint primary key, addition_type text not null, old_timing text,
                                  new_timing text not null, note_text text) on commit drop;
insert into _line_fix (line_id, addition_type, old_timing, new_timing, note_text) values
  (15208, 'cellar_addition', null, 'with_warm_dry_hop', null),   -- Guave got the love: fruit puree
  (6441,  'cellar_addition', null, 'processing', null),          -- Porno Blond: Tetrahop 9%
  (16788, 'cellar_addition', 'milled!', 'lagering', 'milled!'),  -- Stout Of This World: coffee beans
  (16789, 'cellar_addition', null, 'lagering', null),            -- Stout Of This World: maple syrup
  (16790, 'cellar_addition', null, 'lagering', null),            -- Stout Of This World: Super F
  (17049, 'dry_hop', null, 'cold_16', null), (17050, 'dry_hop', null, 'cold_16', null),
  (17051, 'dry_hop', null, 'cold_16', null),                     -- Aperolling in the DIPA
  (10758, 'dry_hop', null, 'warm', null), (10759, 'dry_hop', null, 'warm', null),
  (10760, 'dry_hop', null, 'warm', null),                        -- Blurred Lines NEWTEST
  (15195, 'dry_hop', null, 'warm', null),                        -- Guave got the love: fruit puree
  (8725, 'dry_hop', null, 'cold_12', null), (8726, 'dry_hop', null, 'cold_12', null),
  (8727, 'dry_hop', null, 'cold_12', null), (8728, 'dry_hop', null, 'cold_12', null),   -- Hazy NONnetje
  (17095, 'dry_hop', null, 'cold_12', null), (17096, 'dry_hop', null, 'cold_12', null),
  (17097, 'dry_hop', null, 'cold_12', null),                     -- Heavy Cross 29
  (17595, 'dry_hop', null, 'cold_2', null), (17596, 'dry_hop', null, 'cold_2', null);   -- Nonnetje IPA

create temporary table _line_change on commit drop as
select ri.id, ri.timing as old_timing, ri.note as old_note, m.new_timing,
       nullif(concat_ws(' · ', nullif(btrim(ri.note), ''), m.note_text), '') as new_note
from public.recipe_ingredients ri
join _scope sc on sc.recipe_id = ri.recipe_id
join _timing_map m on m.old_timing = ri.timing
where ri.addition_type = 'cellar_addition' and (m.new_timing <> ri.timing or m.note_text is not null)
union all
select ri.id, ri.timing, ri.note, f.new_timing,
       nullif(concat_ws(' · ', nullif(btrim(ri.note), ''), f.note_text), '')
from public.recipe_ingredients ri
join _line_fix f on f.line_id = ri.id and f.addition_type = ri.addition_type
where ri.timing is not distinct from f.old_timing;

update public.batch_ingredients bi
set timing = c.new_timing, note = c.new_note
from _line_change c, public.batches b
where bi.recipe_ingredient_id = c.id and b.id = bi.batch_id and b.status = 'planned'
  and bi.timing is not distinct from c.old_timing and bi.note is not distinct from c.old_note;

update public.recipe_ingredients ri
set timing = c.new_timing, note = c.new_note
from _line_change c
where ri.id = c.id;

-- c. Braubeviale Barth Haas: the 6 empty dry hop lines go ("no dry hop").
delete from public.batch_ingredients bi
using public.batches b
where b.id = bi.batch_id and b.status = 'planned'
  and bi.recipe_ingredient_id in (15941, 15942, 15943, 15944, 15945, 15946)
  and bi.ingredient_id is null and bi.quantity is null;
delete from public.recipe_ingredients
where id in (15941, 15942, 15943, 15944, 15945, 15946) and recipe_id = 618
  and addition_type = 'dry_hop' and ingredient_id is null and quantity is null;

-- d. Lagering temperature where it was empty.
update public.recipe_fermentation f
set lagering_temp = v.temp
from (values (681, 0), (680, 0), (679, 0), (623, 0), (622, 0), (205, 0), (616, 0), (236, 0), (261, 0),
             (266, 0), (317, 0), (336, 0), (578, 0), (582, 0), (667, 0), (625, 2), (624, 2), (382, 2)) v(recipe_id, temp)
where f.recipe_id = v.recipe_id and f.lagering_temp is null;


-- 13. Backfill ----------------------------------------------------------------

-- Cellar plan for every active recipe and every recipe of a planned batch.
do $$
declare
  r record;
begin
  for r in select id from public.recipes
           where status = 'active' or id in (select recipe_id from public.batches where status = 'planned')
           order by id loop
    perform public.generate_recipe_cellar_steps(r.id);
  end loop;
end $$;

-- Plan snapshot for every planned batch (as the ingredients in phase 2).
select public.snapshot_batch_cellar_steps(b.id)
from public.batches b
where b.status = 'planned'
order by b.id;

commit;
