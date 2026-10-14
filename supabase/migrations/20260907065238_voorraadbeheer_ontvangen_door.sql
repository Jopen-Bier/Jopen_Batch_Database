-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table public.grondstof_lots
  add column if not exists ontvangen_door uuid references public.gebruikers(id);
