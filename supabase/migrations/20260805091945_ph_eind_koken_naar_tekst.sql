-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table public.recipe_brouwspecificaties
  alter column ph_eind_koken type text using ph_eind_koken::text;
