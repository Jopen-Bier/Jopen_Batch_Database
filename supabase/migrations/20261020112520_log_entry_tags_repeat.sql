-- Fermentation log: the same action tag can be on one log entry more than
-- once (Jaap, 20-10: several additions done on the same day). Each row
-- ticks off the next plan step with that tag, as before. The key becomes an
-- id; batch_stages reads entry_id / tag_id / batch_id and is unchanged.
-- One transaction.

begin;

alter table public.fermentation_log_entry_tags add column if not exists id bigint generated always as identity;
alter table public.fermentation_log_entry_tags drop constraint fermentation_log_entry_tags_pkey;
alter table public.fermentation_log_entry_tags add constraint fermentation_log_entry_tags_pkey primary key (id);
create index if not exists idx_fermentation_log_entry_tags_entry_id on public.fermentation_log_entry_tags (entry_id);

-- Audit rows now name the row by its id.
drop trigger if exists trg_fermentation_log_entry_tags_audit on public.fermentation_log_entry_tags;
create trigger trg_fermentation_log_entry_tags_audit after insert or update or delete on public.fermentation_log_entry_tags
  for each row execute function public.log_batch_change();

commit;
