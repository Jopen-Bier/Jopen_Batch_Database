-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table public.ingredient_revisies
  drop constraint ingredient_revisies_ingredient_id_fkey,
  add constraint ingredient_revisies_ingredient_id_fkey
    foreign key (ingredient_id) references public.ingredients(id) on delete cascade;
