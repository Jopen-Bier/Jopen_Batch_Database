-- Batch report: documents on the Filling report (Jaap, 21-10). Three
-- documents per batch: Production order, Filling order, Filling report
-- (scans / PDFs), one file each (replacing a file updates the row), plus any
-- number of Other documents. Private storage bucket 'batch-documents'
-- (signed URLs from the app, as ingredient-documents) and table
-- batch_documents. batch_stages appends documents_uploaded (of the three)
-- and other_documents for the Active batches tiles. Plain ASCII.
-- Deleting a batch removes its rows (cascade); the files stay in storage.

begin;

-- 1. Storage bucket and its policies (module "batches") ------------------------

insert into storage.buckets (id, name, public)
values ('batch-documents', 'batch-documents', false)
on conflict (id) do nothing;

-- Path convention: '<batch_id>/<document_type>/<file>'.
drop policy if exists batch_documents_select on storage.objects;
drop policy if exists batch_documents_insert on storage.objects;
drop policy if exists batch_documents_delete on storage.objects;
create policy batch_documents_select on storage.objects
  for select to authenticated using (bucket_id = 'batch-documents' and public.can_view('batches'));
create policy batch_documents_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'batch-documents' and public.can_edit('batches'));
create policy batch_documents_delete on storage.objects
  for delete to authenticated using (bucket_id = 'batch-documents' and public.can_edit('batches'));

-- 2. Documents of a batch ---------------------------------------------------------

create table if not exists public.batch_documents (
  id            bigint generated always as identity primary key,
  batch_id      bigint not null references public.batches(id) on delete cascade,
  document_type text not null check (document_type in ('production_order', 'filling_order', 'filling_report', 'other')),
  file_name     text not null,
  storage_path  text not null unique,
  size_bytes    bigint,
  uploaded_by   uuid default auth.uid() references public.users(id),
  uploaded_at   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references public.users(id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.users(id)
);

-- one file per batch and type, except Other (any number)
create unique index if not exists batch_documents_type_key on public.batch_documents (batch_id, document_type)
  where document_type <> 'other';
create index if not exists idx_batch_documents_batch_id on public.batch_documents (batch_id);
create index if not exists idx_batch_documents_uploaded_by on public.batch_documents (uploaded_by);

drop trigger if exists trg_batch_documents_updated_at on public.batch_documents;
create trigger trg_batch_documents_updated_at before update on public.batch_documents
  for each row execute function public.set_updated_at();
drop trigger if exists trg_batch_documents_audit on public.batch_documents;
create trigger trg_batch_documents_audit after insert or update or delete on public.batch_documents
  for each row execute function public.log_batch_change();

alter table public.batch_documents enable row level security;
drop policy if exists batch_documents_select on public.batch_documents;
drop policy if exists batch_documents_insert on public.batch_documents;
drop policy if exists batch_documents_update on public.batch_documents;
drop policy if exists batch_documents_delete on public.batch_documents;
create policy batch_documents_select on public.batch_documents for select to authenticated using (can_view('batches'));
create policy batch_documents_insert on public.batch_documents for insert to authenticated with check (can_edit('batches'));
create policy batch_documents_update on public.batch_documents for update to authenticated using (can_edit('batches')) with check (can_edit('batches'));
create policy batch_documents_delete on public.batch_documents for delete to authenticated using (can_delete('batches'));
revoke all on public.batch_documents from anon;

-- 3. batch_stages: documents uploaded (columns appended) -------------------------

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
  b.first_incoming_at,
  coalesce(d.documents_uploaded, 0)::integer as documents_uploaded,
  coalesce(d.other_documents, 0)::integer as other_documents
from base b
left join plan p on p.batch_id = b.id
left join lateral (
  select count(distinct bd.document_type) filter (where bd.document_type <> 'other') as documents_uploaded,
         count(*) filter (where bd.document_type = 'other') as other_documents
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
