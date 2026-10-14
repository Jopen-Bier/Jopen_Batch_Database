-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Specifiek voor batches: naast admin/head_brewer mag ook brewer aanmaken/bewerken
-- (zoals de rollenmatrix onder "Batch Creation" al aangeeft), maar niet verwijderen.
create or replace function mag_bewerken_batches()
returns boolean
language sql
security definer
as $$
  select exists (
    select 1 from public.gebruikers
    where id = auth.uid()
      and rol in ('admin', 'head_brewer', 'brewer')
      and actief = true
  );
$$;

-- Opruimen: er stonden dubbele insert-policies met identieke logica
drop policy if exists batches_insert_editor_of_hoger on batches;
drop policy if exists insert_editor on batches;
drop policy if exists update_editor on batches;

create policy batches_insert_mag_bewerken
  on batches for insert
  with check (mag_bewerken_batches());

create policy batches_update_mag_bewerken
  on batches for update
  using (mag_bewerken_batches())
  with check (mag_bewerken_batches());
