-- Fermentation log: a tag can name the cellar plan step it ticks off (Jaap,
-- 20-10: with several open Addition steps, choose which one). A tag without a
-- chosen step ticks off the next open step with that tag, as before.
-- batch_stages is replaced with that rule; its columns are unchanged.
-- One transaction.

begin;

alter table public.batch_cellar_steps add constraint batch_cellar_steps_id_batch_key unique (id, batch_id);

alter table public.fermentation_log_entry_tags add column if not exists batch_cellar_step_id bigint;
alter table public.fermentation_log_entry_tags add constraint fermentation_log_entry_tags_step_fkey
  foreign key (batch_cellar_step_id, batch_id) references public.batch_cellar_steps (id, batch_id)
  on delete set null (batch_cellar_step_id);
create index if not exists idx_fermentation_log_entry_tags_step on public.fermentation_log_entry_tags (batch_cellar_step_id, batch_id);

-- Stage of a batch (business-rules.md "Cellar plan progress").
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
