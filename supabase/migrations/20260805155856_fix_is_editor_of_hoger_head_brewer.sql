-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

create or replace function is_editor_of_hoger()
returns boolean
language sql
security definer
as $$
  select exists (
    select 1 from public.gebruikers
    where id = auth.uid()
      and rol in ('admin', 'head_brewer')
      and actief = true
  );
$$;
