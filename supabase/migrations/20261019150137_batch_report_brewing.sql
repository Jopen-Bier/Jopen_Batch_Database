-- Batch report, phase 3: Brewing (docs/batch-report/data-model.md).
-- Brew log per brew (batch_brews), brewer's comments (batch_brew_comments),
-- batch columns for the brew day, and the brewing / fermentation stages in
-- batch_stages. One transaction: either everything or nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * batches.glt_tank_id comes in this phase (data model: phase 4): the GLT
--   is chosen on the brew day and Active batches sorts Brewing by tank.
-- * Brews needed = brew_count rounded up (brew_count has values such as
--   3.33); a batch with 0 brews never reaches Brewing / Fermentation here.

begin;

-- 1. Batch columns -----------------------------------------------------------

alter table public.batches add column if not exists brewhouse_recipe_number text;
alter table public.batches add column if not exists glt_tank_id bigint references public.tanks(id);
create index if not exists idx_batches_glt_tank_id on public.batches (glt_tank_id);

-- yeast_pitched_by: free text, empty in every row (checked 19-10) -> user.
do $$
begin
  if (select data_type from information_schema.columns
      where table_schema = 'public' and table_name = 'batches' and column_name = 'yeast_pitched_by') = 'text' then
    if exists (select 1 from public.batches where nullif(btrim(yeast_pitched_by), '') is not null) then
      raise exception 'batches.yeast_pitched_by has values; convert them by hand first';
    end if;
    alter table public.batches alter column yeast_pitched_by type uuid using null;
    alter table public.batches add constraint batches_yeast_pitched_by_fkey
      foreign key (yeast_pitched_by) references public.users(id);
  end if;
end $$;

-- 2. Brew log: one row per brew ---------------------------------------------

create table if not exists public.batch_brews (
  id                          bigint generated always as identity primary key,
  batch_id                    bigint not null references public.batches(id) on delete cascade,
  brew_number                 integer not null check (brew_number > 0),
  software_order_number       text,   -- naming-ok: software_order_number (English; "software" also occurs in an old Dutch name)
  brewer_id                   uuid references public.users(id),
  mash_in_started_at          timestamptz,
  mash_water_hl               numeric,
  mash_in_ph                  numeric,
  mash_acid_l                 numeric,
  mash_corrected_ph           numeric,
  is_iodine_test_ok           boolean,
  has_mash_schedule_deviation boolean,
  first_wort_extract          numeric,
  last_runnings_extract       numeric,
  cumulative_sparge_volume_hl numeric,
  last_runnings_ph            numeric,
  first_wort_volume_hl        numeric,
  sparge_water_hl             numeric,
  sparge_runnings_hl          numeric,
  lauter_time_min             numeric,
  boil_start_ph               numeric,
  boil_start_extract          numeric,
  boil_start_volume_hl        numeric,
  boil_acid_l                 numeric,
  boil_acid_ph_note           text,
  boil_time_min               numeric,
  boil_end_extract            numeric,
  extra_addition              text,
  whirlpool_volume_hl         numeric,
  whirlpool_extract           numeric,
  whirlpool_ph                numeric,
  whirlpool_rest_min          numeric,
  aeration_ppm                numeric,
  water_addition_hl           numeric,
  brew_volume_hl              numeric,
  brewing_ended_at            timestamptz,
  process_pause               text,
  is_aeration_filter_steamed  boolean,
  is_wort_line_sterilized     boolean,
  ckt_cip_program             text check (ckt_cip_program in ('lo-de', 'lo-zu-de', 'lo-de-hw', 'lo-zu-de-hw')),
  spent_grain_bin             text,
  created_at                  timestamptz not null default now(),
  created_by                  uuid default auth.uid() references public.users(id),
  updated_at                  timestamptz not null default now(),
  updated_by                  uuid references public.users(id),
  constraint batch_brews_batch_brew_number_key unique (batch_id, brew_number)
);

-- 3. Brewer's comments (brew_number empty = all brews) ----------------------

create table if not exists public.batch_brew_comments (
  id           bigint generated always as identity primary key,
  batch_id     bigint not null references public.batches(id) on delete cascade,
  brew_number  integer check (brew_number > 0),
  comment_time time,
  comment      text not null,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid() references public.users(id),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.users(id)
);

create index if not exists idx_batch_brew_comments_batch_id on public.batch_brew_comments (batch_id);

-- 4. Triggers, RLS, grants for both tables ----------------------------------

do $$
declare
  t text;
begin
  foreach t in array array['batch_brews', 'batch_brew_comments'] loop
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

-- 5. Stage of a batch: brewing and fermentation -----------------------------

-- business-rules.md "Stage of a batch". Brews needed = brew_count rounded up.
-- Columns are only appended (create or replace view keeps the old ones).
create or replace view public.batch_stages
with (security_invoker = true)
as
select
  b.id as batch_id,
  case
    when b.status = 'completed' then 'closed'
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
  br.last_brew_ended_at
from public.batches b
left join lateral (
  select count(*) filter (where bb.mash_in_started_at is not null) as brews_started,
         count(*) filter (where bb.brewing_ended_at is not null) as brews_ended,
         min(bb.mash_in_started_at) as first_mash_in_at,
         max(bb.brewing_ended_at) as last_brew_ended_at
  from public.batch_brews bb
  where bb.batch_id = b.id
) br on true;

revoke all on public.batch_stages from anon;
grant select on public.batch_stages to authenticated;

commit;
