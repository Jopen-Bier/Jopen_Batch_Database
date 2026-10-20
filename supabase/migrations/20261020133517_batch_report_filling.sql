-- Batch report, phase 6: Filling (docs/batch-report/data-model.md).
-- Filling sessions per HBT and package format with their checks and "HBT
-- finished?", and the filling measurements (bottle / can: TPO, HSO, DO, HS
-- volume, pressure, temperature, CO2; keg: CO2, O2). batch_stages gets the
-- Filling and Filled stages. One transaction: either everything or nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * filling_sessions has unique (batch_id, session_number) and unique
--   (id, batch_id); its HBT and its measurements are tied to the same batch
--   (foreign keys over both columns). Deleting an HBT keeps the session
--   without an HBT (so "HBT finished?" is only offered once an HBT is chosen,
--   in the page, not as a constraint).
-- * Stage Filling starts with the first filling date (as HBT starts with the
--   first processing date), not with an empty session.
-- * batch_stages adds first_filling_date, hbts_finished, filled_volume_hl.

begin;

-- 1. Filling sessions --------------------------------------------------------

create table if not exists public.filling_sessions (
  id                         bigint generated always as identity primary key,
  batch_id                   bigint not null references public.batches(id) on delete cascade,
  session_number             integer not null check (session_number > 0),
  filling_date               date,
  batch_hbt_id               bigint,
  package_format             text check (package_format in ('bottle', 'can', 'keg')),
  volume_hl                  numeric check (volume_hl >= 0),
  start_time                 time,
  end_time                   time,
  sampled_by                 uuid references public.users(id),
  is_first_package_checked   boolean,
  is_fill_tube_checked_first boolean,
  is_fill_tube_checked_end   boolean,
  are_burst_bottles_controlled boolean,
  is_hbt_finished            boolean not null default false,
  created_at                 timestamptz not null default now(),
  created_by                 uuid default auth.uid() references public.users(id),
  updated_at                 timestamptz not null default now(),
  updated_by                 uuid references public.users(id),
  constraint filling_sessions_number_key unique (batch_id, session_number),
  constraint filling_sessions_id_batch_key unique (id, batch_id),
  constraint filling_sessions_hbt_fkey foreign key (batch_hbt_id, batch_id)
    references public.batch_hbts (id, batch_id) on delete set null (batch_hbt_id)
);

create index if not exists idx_filling_sessions_hbt on public.filling_sessions (batch_hbt_id, batch_id);

-- 2. Filling measurements ----------------------------------------------------

create table if not exists public.filling_measurements (
  id                 bigint generated always as identity primary key,
  batch_id           bigint not null,
  filling_session_id bigint not null,
  measured_time      time,
  tpo_ppb            numeric,
  hso_ppb            numeric,
  do_ppb             numeric,
  headspace_volume   numeric,
  pressure_bar       numeric,
  temp_c             numeric,
  co2_gl             numeric,   -- bottle / can, at 20 °C
  keg_co2_gl         numeric,
  keg_o2_ppb         numeric,
  created_at         timestamptz not null default now(),
  created_by         uuid default auth.uid() references public.users(id),
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.users(id),
  constraint filling_measurements_session_fkey foreign key (filling_session_id, batch_id)
    references public.filling_sessions (id, batch_id) on delete cascade
);

create index if not exists idx_filling_measurements_session on public.filling_measurements (filling_session_id, batch_id);
create index if not exists idx_filling_measurements_batch_id on public.filling_measurements (batch_id);

-- 3. Triggers, RLS, grants ---------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['filling_sessions', 'filling_measurements'] loop
    execute format('drop trigger if exists trg_%1$s_updated_at on public.%1$I', t);
    execute format('create trigger trg_%1$s_updated_at before update on public.%1$I
                    for each row execute function public.set_updated_at()', t);
    execute format('drop trigger if exists trg_%1$s_audit on public.%1$I', t);
    execute format('create trigger trg_%1$s_audit after insert or update or delete on public.%1$I
                    for each row execute function public.log_batch_change()', t);

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

-- 4. Stage of a batch: Filling and Filled ------------------------------------

-- business-rules.md "Stage of a batch": Filled when the batch has HBTs and
-- every one has a filling session with "HBT finished?"; Filling from the
-- first filling date. Columns are only appended.
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
)
select
  b.id as batch_id,
  case
    when b.status = 'completed' then 'closed'
    when coalesce(h.hbts_total, 0) > 0 and fs.hbts_finished >= h.hbts_total then 'filled'
    when fs.first_filling_date is not null then 'filling'
    when ps.first_processing_date is not null then 'hbt'
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
  p.lagering_started_at,
  ps.first_processing_date,
  coalesce(h.hbts_total, 0)::integer as hbts_total,
  coalesce(h.hbts_released, 0)::integer as hbts_released,
  h.hbt_codes,
  coalesce(h.hbt_formats, '{}') as hbt_formats,
  fs.first_filling_date,
  coalesce(fs.hbts_finished, 0)::integer as hbts_finished,
  fs.filled_volume_hl
from public.batches b
left join lateral (
  select count(*) filter (where bb.mash_in_started_at is not null) as brews_started,
         count(*) filter (where bb.brewing_ended_at is not null) as brews_ended,
         min(bb.mash_in_started_at) as first_mash_in_at,
         max(bb.brewing_ended_at) as last_brew_ended_at
  from public.batch_brews bb
  where bb.batch_id = b.id
) br on true
left join plan p on p.batch_id = b.id
left join lateral (
  select min(s.processing_date) as first_processing_date
  from public.processing_sessions s
  where s.batch_id = b.id
) ps on true
left join lateral (
  select count(*) as hbts_total,
         count(bh.released_at) as hbts_released,
         string_agg(t.code, ' · ' order by bh.sort_order, t.number) as hbt_codes,
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
