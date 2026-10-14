-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

ALTER TABLE recipe_ingredients ADD COLUMN IF NOT EXISTS alles_in_brouwsel_1 boolean NOT NULL DEFAULT false;
