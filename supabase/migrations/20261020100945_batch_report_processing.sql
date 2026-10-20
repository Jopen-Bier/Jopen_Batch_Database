-- Batch report, phase 5: Processing (docs/batch-report/data-model.md).
-- Processing sessions (centrifuge start measurements), processing comments,
-- the bright beer tanks (HBT) of a batch with their readings and release,
-- batch columns for the check before processing and the tasting, and the
-- HBT stage in batch_stages. One transaction: either everything or nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * batch_hbts and processing_sessions get unique (id, batch_id), so a
--   reading can only point at an HBT and a session of its own batch
--   (foreign keys over both columns).
-- * processing_sessions: unique (batch_id, session_number).
-- * batch_stages adds hbts_total, hbts_released, hbt_codes, hbt_formats and
--   first_processing_date (for the HBT tiles on Active batches).

begin;

-- 1. Batch columns -----------------------------------------------------------

alter table public.batches add column if not exists cellar_additions_done boolean not null default false;
alter table public.batches add column if not exists tasting_comment text;
alter table public.batches add column if not exists tasting_result text check (tasting_result in ('go', 'no_go'));

-- 2. Processing sessions -----------------------------------------------------

create table if not exists public.processing_sessions (
  id                     bigint generated always as identity primary key,
  batch_id               bigint not null references public.batches(id) on delete cascade,
  session_number         integer not null check (session_number > 0),
  started_by             uuid references public.users(id),
  ended_by               uuid references public.users(id),
  processing_date        date,
  start_time             time,
  end_time               time,
  tank_id                bigint references public.tanks(id),
  outlet                 text check (outlet in ('standpipe', 'bottom_valve')),
  discharge_count        integer check (discharge_count >= 0),
  discharge_interval_min numeric,
  centrifuge_in_time     time,
  centrifuge_in_o2_ppb   numeric,
  centrifuge_in_co2_gl   numeric,
  centrifuge_out_time    time,
  centrifuge_out_o2_ppb  numeric,
  centrifuge_out_co2_gl  numeric,
  start_flow_hl_h        numeric,
  start_turbidity_ebc    numeric,
  created_at             timestamptz not null default now(),
  created_by             uuid default auth.uid() references public.users(id),
  updated_at             timestamptz not null default now(),
  updated_by             uuid references public.users(id),
  constraint processing_sessions_number_key unique (batch_id, session_number),
  constraint processing_sessions_id_batch_key unique (id, batch_id)
);

create index if not exists idx_processing_sessions_tank_id on public.processing_sessions (tank_id);

-- 3. Processing comments -----------------------------------------------------

create table if not exists public.processing_comments (
  id           bigint generated always as identity primary key,
  batch_id     bigint not null references public.batches(id) on delete cascade,
  comment_time time,
  comment      text not null,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid() references public.users(id),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.users(id)
);

create index if not exists idx_processing_comments_batch_id on public.processing_comments (batch_id);

-- 4. Bright beer tanks of a batch --------------------------------------------

create table if not exists public.batch_hbts (
  id                bigint generated always as identity primary key,
  batch_id          bigint not null references public.batches(id) on delete cascade,
  tank_id           bigint not null references public.tanks(id),
  intended_formats  text[] not null default '{}' check (intended_formats <@ array['bottle', 'can', 'keg']::text[]),
  avg_inline_o2_ppb numeric,
  avg_pu            numeric,
  avg_turbidity_ebc numeric,
  avg_flow_hl_h     numeric,
  released_at       timestamptz,
  released_by       uuid references public.users(id),
  sort_order        integer not null default 0,
  created_at        timestamptz not null default now(),
  created_by        uuid default auth.uid() references public.users(id),
  updated_at        timestamptz not null default now(),
  updated_by        uuid references public.users(id),
  constraint batch_hbts_batch_tank_key unique (batch_id, tank_id),
  constraint batch_hbts_id_batch_key unique (id, batch_id),
  constraint batch_hbts_released_check check ((released_at is null) = (released_by is null))
);

create index if not exists idx_batch_hbts_tank_id on public.batch_hbts (tank_id);

-- 5. HBT readings (last row of an HBT = its end value) -----------------------

create table if not exists public.hbt_readings (
  id                    bigint generated always as identity primary key,
  batch_id              bigint not null,
  batch_hbt_id          bigint not null,
  processing_session_id bigint,
  sort_order            integer not null,
  level_hl              numeric,
  o2_ppb                numeric,
  co2_gl                numeric,
  co2_target            text check (co2_target in ('bottle', 'can', 'keg')),
  comment               text,
  created_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.users(id),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.users(id),
  constraint hbt_readings_hbt_fkey foreign key (batch_hbt_id, batch_id)
    references public.batch_hbts (id, batch_id) on delete cascade,
  constraint hbt_readings_session_fkey foreign key (processing_session_id, batch_id)
    references public.processing_sessions (id, batch_id) on delete set null (processing_session_id)
);

create index if not exists idx_hbt_readings_hbt on public.hbt_readings (batch_hbt_id, batch_id, sort_order);
create index if not exists idx_hbt_readings_session on public.hbt_readings (processing_session_id, batch_id);
create index if not exists idx_hbt_readings_batch_id on public.hbt_readings (batch_id);

-- 6. Triggers, RLS, grants ---------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['processing_sessions', 'processing_comments', 'batch_hbts', 'hbt_readings'] loop
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

-- 7. Stage of a batch: HBT ---------------------------------------------------

-- business-rules.md "Stage of a batch": HBT when a processing session has a
-- processing date (also for a batch without brews, e.g. a split). Columns
-- are only appended.
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
  coalesce(h.hbt_formats, '{}') as hbt_formats
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
) h on true;

revoke all on public.batch_stages from anon;
grant select on public.batch_stages to authenticated;

commit;
