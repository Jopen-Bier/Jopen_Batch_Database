-- Deleting a whole batch gets its own right in the role matrix (Jaap, 22-10):
-- permission module "batch_deletion" ("Delete batches"). Only admins have it
-- now (is_admin() passes every check); a role gets it by ticking it in
-- rollen.html.
-- - batches DELETE: can_delete('batch_deletion') instead of
--   can_delete('batches'). Deleting rows inside a batch report stays on
--   'batches' (DELETE = EDIT per role); a whole batch no longer goes with it.
-- - storage bucket batch-documents: the files of a deleted batch may also be
--   removed by whoever may delete batches.
-- The report tables cascade from batches (ON DELETE CASCADE); stock movements
-- and beer received from a split still block a delete (no action), as before.
-- Plain ASCII.

begin;

insert into public.permission_modules (module_key, name, sort_order)
values ('batch_deletion', 'Delete batches', 11)
on conflict (module_key) do nothing;

drop policy if exists batches_delete on public.batches;
create policy batches_delete on public.batches
  for delete to authenticated using (public.can_delete('batch_deletion'));

drop policy if exists batch_documents_delete on storage.objects;
create policy batch_documents_delete on storage.objects
  for delete to authenticated using (
    bucket_id = 'batch-documents' and (public.can_edit('batches') or public.can_delete('batch_deletion')));

commit;
