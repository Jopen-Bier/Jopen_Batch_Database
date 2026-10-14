-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Consistent met recipe_revisies.door (tekst, niet een FK naar auth.users) --
-- eenvoudiger voor weergave, geen embed-join nodig.
alter table product_sheet_revisies drop constraint if exists product_sheet_revisies_door_fkey;
alter table product_sheet_revisies alter column door type text using door::text;
