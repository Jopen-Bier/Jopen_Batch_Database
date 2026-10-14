-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Documenten (spec sheets / TDS / CoA-achtige bijlagen) gekoppeld aan een ingrediënt.
-- Bestand zelf staat in Storage (bucket 'ingredient-documents'); deze tabel is de
-- metadata-laag, incl. de door de gebruiker ingevoerde revisiedatum van het document
-- (dit is de datum die ÓP het document staat, niet de upload-datum).
create table if not exists public.ingredient_documenten (
  id bigint generated always as identity primary key,
  ingredient_id bigint not null references public.ingredients(id) on delete cascade,
  bestandsnaam text not null,
  storage_path text not null unique,
  grootte_bytes bigint,
  revisiedatum date not null,
  geupload_door uuid references auth.users(id),
  geupload_op timestamptz not null default now()
);

create index if not exists idx_ingredient_documenten_ingredient_id
  on public.ingredient_documenten(ingredient_id);

alter table public.ingredient_documenten enable row level security;

-- Zelfde rechtenpatroon als de rest van de ingredient-kaart: matrix-gestuurd via
-- de generieke mag_bekijken/mag_bewerken/mag_verwijderen('ingredients')-functies.
create policy ingredient_documenten_select on public.ingredient_documenten
  for select using (public.mag_bekijken('ingredients'));

create policy ingredient_documenten_insert on public.ingredient_documenten
  for insert with check (public.mag_bewerken('ingredients'));

create policy ingredient_documenten_delete on public.ingredient_documenten
  for delete using (public.mag_verwijderen('ingredients'));
