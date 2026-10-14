-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table batches
  alter column aantal_brouwsels type numeric using aantal_brouwsels::numeric;
