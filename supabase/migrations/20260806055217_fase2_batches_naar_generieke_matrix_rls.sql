-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

drop policy if exists batches_delete_admin on batches;
drop policy if exists batches_insert_mag_bewerken on batches;
drop policy if exists batches_select_authenticated on batches;
drop policy if exists batches_update_mag_bewerken on batches;
drop policy if exists delete_editor on batches;
drop policy if exists select_alle on batches;

create policy batches_select on batches
  for select using (mag_bekijken('batches'));

create policy batches_insert on batches
  for insert with check (mag_bewerken('batches'));

create policy batches_update on batches
  for update using (mag_bewerken('batches')) with check (mag_bewerken('batches'));

create policy batches_delete on batches
  for delete using (mag_verwijderen('batches'));
