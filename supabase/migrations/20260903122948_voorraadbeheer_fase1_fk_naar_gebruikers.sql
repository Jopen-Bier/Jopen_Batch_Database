-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table public.grondstof_lots drop constraint grondstof_lots_aangemaakt_door_fkey;
alter table public.grondstof_lots add constraint grondstof_lots_aangemaakt_door_fkey
  foreign key (aangemaakt_door) references public.gebruikers(id);

alter table public.voorraad_mutaties drop constraint voorraad_mutaties_aangemaakt_door_fkey;
alter table public.voorraad_mutaties add constraint voorraad_mutaties_aangemaakt_door_fkey
  foreign key (aangemaakt_door) references public.gebruikers(id);

alter table public.voorraad_mutaties drop constraint voorraad_mutaties_geboekt_door_fkey;
alter table public.voorraad_mutaties add constraint voorraad_mutaties_geboekt_door_fkey
  foreign key (geboekt_door) references public.gebruikers(id);
