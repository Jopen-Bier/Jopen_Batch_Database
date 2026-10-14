-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table public.voorraad_mutaties
  add column if not exists is_spoilage boolean not null default false,
  add column if not exists is_correction boolean not null default false;
