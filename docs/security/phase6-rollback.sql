-- Rollback for supabase/migrations/20261124170000_audit_and_storage_limits.sql.
-- NOT a migration: run by hand in the SQL Editor only if phase 6 breaks
-- something, then fix forward. Keeps the logged history (inventory_audit_log
-- and the batches rows in batch_audit_log); only stops new logging and
-- lifts the storage limits.

begin;

drop trigger if exists trg_batches_audit on public.batches;
drop trigger if exists trg_lots_audit on public.lots;
drop trigger if exists trg_stock_movements_audit on public.stock_movements;

update storage.buckets set file_size_limit = null, allowed_mime_types = null
 where id in ('batch-documents', 'ingredient-documents', 'Jopen art');

alter policy ingredient_documents_select on storage.objects to public;
alter policy ingredient_documents_insert on storage.objects to public;
alter policy ingredient_documents_delete on storage.objects to public;

commit;
