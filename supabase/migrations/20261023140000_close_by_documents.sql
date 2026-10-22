-- Closed also when all three documents are on the Filling report (Jaap, 23-10):
-- production order, filling order and filling report = the batch is done.
-- batch_stages as in 20261023090000, only the closed rule changes:
-- status 'completed', or both filling report checks, or 3/3 documents.
-- The view keeps its columns. Plain ASCII.

begin;

create or replace view public.batch_stages
with (security_invoker = true)
as
with step_link as (
  -- steps chosen on a tag (fermentation_log_entry_tags.batch_cellar_step_id)
  select et.batch_cellar_step_id as step_id, min(e.measured_at) as done_at
  from public.fermentation_log_entry_tags et
  join public.fermentation_log_entries e on e.id = et.entry_id
  where et.batch_cellar_step_id is not null
  group by et.batch_cellar_step_id
), open_step as (
  select bcs.id, bcs.batch_id, bcs.tag_id,
         row_number() over (partition by bcs.batch_id, bcs.tag_id order by bcs.sort_order, bcs.id) as occurrence
  from public.batch_cellar_steps bcs
  where not exists (select 1 from step_link l where l.step_id = bcs.id)
), free_tag as (
  select et.batch_id, et.tag_id, e.measured_at,
         row_number() over (partition by et.batch_id, et.tag_id order by e.measured_at, e.id, et.id) as occurrence
  from public.fermentation_log_entry_tags et
  join public.fermentation_log_entries e on e.id = et.entry_id
  where et.batch_cellar_step_id is null
), step_state as (
  select s.batch_id, s.id, s.sort_order, s.title, s.starts_lagering,
         coalesce(l.done_at, f.measured_at) as done_at
  from public.batch_cellar_steps s
  left join step_link l on l.step_id = s.id
  left join open_step o on o.id = s.id
  left join free_tag f on f.batch_id = o.batch_id and f.tag_id = o.tag_id and f.occurrence = o.occurrence
), plan as (
  select step_state.batch_id,
         count(*) as steps_total,
         count(step_state.done_at) as steps_done,
         (array_agg(step_state.title order by step_state.sort_order, step_state.id) filter (where step_state.done_at is null))[1] as next_step,
         min(step_state.done_at) filter (where step_state.starts_lagering) as lagering_started_at
  from step_state
  group by step_state.batch_id
), incoming as (
  select t.to_batch_id as batch_id, sum(t.volume_hl) as volume_hl, min(t.transferred_at) as first_at
  from public.batch_transfers t
  where t.to_batch_id is not null
  group by t.to_batch_id
), base as (
  select b_1.id, b_1.status, b_1.time_zero, b_1.brew_count,
         b_1.lagering_started_at as manual_lagering_at,
         b_1.filling_report_checked_at, b_1.mdrank_processed_at,
         ceil(coalesce(b_1.brew_count, 0::numeric))::integer as brews_planned,
         br.brews_started, br.brews_ended, br.first_mash_in_at, br.last_brew_ended_at,
         inc.volume_hl as incoming_volume_hl, inc.first_at as first_incoming_at,
         ceil(coalesce(b_1.brew_count, 0::numeric)) > 0::numeric and coalesce(br.brews_ended, 0::bigint)::numeric >= ceil(b_1.brew_count)
           or coalesce(br.brews_started, 0::bigint) = 0 and inc.first_at is not null as is_brewed
  from public.batches b_1
  left join lateral (
    select count(*) filter (where bb.mash_in_started_at is not null) as brews_started,
           count(*) filter (where bb.brewing_ended_at is not null) as brews_ended,
           min(bb.mash_in_started_at) as first_mash_in_at,
           max(bb.brewing_ended_at) as last_brew_ended_at
    from public.batch_brews bb
    where bb.batch_id = b_1.id
  ) br on true
  left join incoming inc on inc.batch_id = b_1.id
)
select b.id as batch_id,
  case
    when b.status = 'completed'::text
      or b.filling_report_checked_at is not null and b.mdrank_processed_at is not null
      or coalesce(d.documents_uploaded, 0) >= 3 then 'closed'::text
    when coalesce(h.hbts_total, 0::bigint) > 0 and fs.hbts_finished >= h.hbts_total
      or em.emptied_at is not null then 'filled'::text
    when fs.first_filling_date is not null then 'filling'::text
    when ps.first_processing_date is not null then 'hbt'::text
    when lt.on_barrels then 'barrel'::text
    when b.is_brewed and lag.started_at is not null then 'lagering'::text
    when b.is_brewed then 'fermentation'::text
    when coalesce(b.brews_started, 0::bigint) > 0 then 'brewing'::text
    else 'raw'::text
  end as stage,
  coalesce((b.first_mash_in_at at time zone 'Europe/Amsterdam'::text)::date,
    case when coalesce(b.brews_started, 0::bigint) = 0 then (b.first_incoming_at at time zone 'Europe/Amsterdam'::text)::date else null::date end) as start_date,
  case when b.filling_report_checked_at is not null and b.mdrank_processed_at is not null
    then (greatest(b.filling_report_checked_at, b.mdrank_processed_at) at time zone 'Europe/Amsterdam'::text)::date
    else null::date end as end_date,
  b.brews_planned,
  coalesce(b.brews_started, 0::bigint)::integer as brews_started,
  coalesce(b.brews_ended, 0::bigint)::integer as brews_ended,
  b.last_brew_ended_at,
  coalesce(b.time_zero, b.last_brew_ended_at,
    case when coalesce(b.brews_started, 0::bigint) = 0 then b.first_incoming_at else null::timestamp with time zone end) as time_zero,
  coalesce(p.steps_total, 0::bigint)::integer as cellar_steps_total,
  coalesce(p.steps_done, 0::bigint)::integer as cellar_steps_done,
  p.next_step as next_cellar_step,
  lag.started_at as lagering_started_at,
  ps.first_processing_date,
  coalesce(h.hbts_total, 0::bigint)::integer as hbts_total,
  coalesce(h.hbts_released, 0::bigint)::integer as hbts_released,
  h.hbt_codes,
  coalesce(h.hbt_formats, '{}'::text[]) as hbt_formats,
  fs.first_filling_date,
  coalesce(fs.hbts_finished, 0::bigint)::integer as hbts_finished,
  fs.filled_volume_hl,
  coalesce(b.incoming_volume_hl, 0::numeric) as incoming_volume_hl,
  b.first_incoming_at,
  coalesce(d.documents_uploaded, 0::bigint)::integer as documents_uploaded,
  coalesce(d.other_documents, 0::bigint)::integer as other_documents,
  em.emptied_at,
  coalesce(lt.on_barrels, false) as on_barrels,
  b.filling_report_checked_at,
  b.mdrank_processed_at
from base b
left join plan p on p.batch_id = b.id
left join lateral (
  -- log tags: first Cooling 16C / Cooling, and whether the batch went on barrels
  select min(e.measured_at) filter (where t.code in ('cooling_16c', 'cooling')) as cooled_at,
         bool_or(t.code = 'to_barrels') as on_barrels
  from public.fermentation_log_entry_tags et
  join public.fermentation_log_entries e on e.id = et.entry_id
  join public.cellar_action_tags t on t.id = et.tag_id
  where et.batch_id = b.id
) lt on true
left join lateral (
  select least(p.lagering_started_at, lt.cooled_at, b.manual_lagering_at,
               case when coalesce(b.brews_started, 0::bigint) = 0 then b.first_incoming_at end) as started_at
) lag on true
left join lateral (
  select max(t.transferred_at) as emptied_at
  from public.batch_transfers t
  where t.batch_id = b.id and t.empties_tank
) em on true
left join lateral (
  select count(distinct bd.document_type) filter (where bd.document_type <> 'other'::text) as documents_uploaded,
         count(*) filter (where bd.document_type = 'other'::text) as other_documents
  from public.batch_documents bd
  where bd.batch_id = b.id
) d on true
left join lateral (
  select min(s.processing_date) as first_processing_date
  from public.processing_sessions s
  where s.batch_id = b.id
) ps on true
left join lateral (
  select count(*) as hbts_total,
         count(bh.released_at) as hbts_released,
         string_agg(t.code, (' '::text || chr(183)) || ' '::text order by bh.sort_order, t.number) as hbt_codes,
         array(select distinct f.f from public.batch_hbts x, lateral unnest(x.intended_formats) f(f)
               where x.batch_id = b.id order by f.f) as hbt_formats
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
