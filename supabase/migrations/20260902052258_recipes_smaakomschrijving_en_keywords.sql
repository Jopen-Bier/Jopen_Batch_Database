-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Twee nieuwe receptvelden onder Recipe Color: een vrije-tekst smaakomschrijving
-- (3 regels, wrapt) en 6 losse smaak-keyword-invoervelden (als text[] met vaste
-- lengte 6, lege slots blijven '').
alter table recipes add column if not exists smaakomschrijving text;
alter table recipes add column if not exists smaak_keywords text[];
