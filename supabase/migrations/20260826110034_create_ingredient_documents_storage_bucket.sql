-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Privé bucket (niet public=true zoals 'Jopen art') — spec sheets alleen
-- toegankelijk voor ingelogde gebruikers met kijkrecht op Ingredients, via
-- signed URLs vanuit de app, geen kale publieke link.
insert into storage.buckets (id, name, public)
values ('ingredient-documents', 'ingredient-documents', false)
on conflict (id) do nothing;

-- Pad-conventie: '<ingredient_id>/<bestand>' — storage.foldername(name)[1] is dus
-- steeds het ingredient_id als tekst. Rechten volgen dezelfde matrix als de
-- ingredient_documenten-tabel zelf (mag_bekijken/mag_bewerken/mag_verwijderen).
create policy ingredient_documents_select on storage.objects
  for select using (
    bucket_id = 'ingredient-documents' and public.mag_bekijken('ingredients')
  );

create policy ingredient_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'ingredient-documents' and public.mag_bewerken('ingredients')
  );

create policy ingredient_documents_delete on storage.objects
  for delete using (
    bucket_id = 'ingredient-documents' and public.mag_verwijderen('ingredients')
  );
