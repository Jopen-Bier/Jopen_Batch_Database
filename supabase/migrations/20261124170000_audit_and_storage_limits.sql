-- Security phase 6 (security review 19-11-2026, P2.2 and P2.5).
--
-- 1. Audit trail for the batch header, lots and stock movements.
--    batch_audit_log already records every change to the batch child tables
--    (log_batch_change(): old and new row, who, when). The batches row itself,
--    lots and stock_movements were not logged.
--    - batches: same trigger and log; log_batch_change() now takes batch_id
--      from the row's own id for table 'batches' (no foreign key on
--      batch_audit_log.batch_id, so the history survives deleting a batch).
--    - lots, stock_movements: new inventory_audit_log, same shape, readable
--      with the inventory view right, written only by the trigger.
--    Both logs are append-only for app users: SELECT only, no insert, update
--    or delete (RLS and grants). claude_reader cannot read the new log
--    (changed_by is people data, like batch_audit_log).
--
-- 2. Storage buckets: size and type limits, matching what the upload buttons
--    accept (batch-documents: PDF + images; ingredient-documents: PDF, Word,
--    Excel, images). No SVG anywhere: it can carry script. All files stored
--    today are PDFs of at most 4.3 MB. The ingredient-documents policies were
--    "to public" (anon was blocked by can_*); now "to authenticated".
--
-- Idempotent. Rollback: docs/security/phase6-rollback.sql.

begin;

-- 1a. batch header into batch_audit_log --------------------------------------
create or replace function public.log_batch_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_old    jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new    jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_row_id text;
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;

  if tg_nargs = 0 then
    v_row_id := v_row ->> 'id';
  else
    select string_agg(v_row ->> k, ':' order by ord)
    into v_row_id
    from unnest(tg_argv) with ordinality as a(k, ord);
  end if;

  insert into batch_audit_log (batch_id, table_name, row_id, action, old_data, new_data)
  values (
    -- the batches row is its own batch (security phase 6)
    coalesce((v_row ->> 'batch_id')::bigint,
             case when tg_table_name = 'batches' then (v_row ->> 'id')::bigint end),
    tg_table_name, v_row_id, lower(tg_op), v_old, v_new);

  return null;
end;
$$;

drop trigger if exists trg_batches_audit on public.batches;
create trigger trg_batches_audit
  after insert or update or delete on public.batches
  for each row execute function public.log_batch_change();

-- 1b. lots and stock_movements into inventory_audit_log -----------------------
create table if not exists public.inventory_audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  row_id text not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  old_data jsonb,
  new_data jsonb,
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now()
);
create index if not exists idx_inventory_audit_log_row on public.inventory_audit_log (table_name, row_id);
comment on table public.inventory_audit_log is
  'Who changed what in lots and stock_movements (security phase 6). Written only by log_inventory_change(); append-only.';

alter table public.inventory_audit_log enable row level security;
drop policy if exists inventory_audit_log_select on public.inventory_audit_log;
create policy inventory_audit_log_select on public.inventory_audit_log
  for select to authenticated using ((select can_view('inventory')));

revoke all on public.inventory_audit_log from anon, authenticated, claude_reader;
grant select on public.inventory_audit_log to authenticated;

create or replace function public.log_inventory_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;
  insert into inventory_audit_log (table_name, row_id, action, old_data, new_data)
  values (tg_table_name, coalesce(v_new, v_old) ->> 'id', lower(tg_op), v_old, v_new);
  return null;
end;
$$;
revoke execute on function public.log_inventory_change() from public, anon, authenticated;

drop trigger if exists trg_lots_audit on public.lots;
create trigger trg_lots_audit
  after insert or update or delete on public.lots
  for each row execute function public.log_inventory_change();

drop trigger if exists trg_stock_movements_audit on public.stock_movements;
create trigger trg_stock_movements_audit
  after insert or update or delete on public.stock_movements
  for each row execute function public.log_inventory_change();

-- 2. Storage limits --------------------------------------------------------
update storage.buckets
   set file_size_limit = 25 * 1024 * 1024,
       allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
 where id = 'batch-documents';

update storage.buckets
   set file_size_limit = 25 * 1024 * 1024,
       allowed_mime_types = array[
         'application/pdf',
         'application/msword',
         'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
         'application/vnd.ms-excel',
         'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
         'image/jpeg', 'image/png']
 where id = 'ingredient-documents';

update storage.buckets
   set file_size_limit = 2 * 1024 * 1024,
       allowed_mime_types = array['image/png', 'image/jpeg']
 where id = 'Jopen art';

alter policy ingredient_documents_select on storage.objects to authenticated;
alter policy ingredient_documents_insert on storage.objects to authenticated;
alter policy ingredient_documents_delete on storage.objects to authenticated;

commit;
