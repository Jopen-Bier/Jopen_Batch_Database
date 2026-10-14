-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Beheerbare lijst van ingredient declarations (Settings), zelfde patroon als
-- de eenheden-tabel. Dropdown op de ingredient-kaart met "Other" als vrije-tekst
-- ontsnapping voor eenmalige waarden (kruiden/fruit/extracten etc.) -- zie
-- ingredient_declaratie_ruw_review sessie-overleg.
create table if not exists ingredient_declaraties (
  id uuid primary key default gen_random_uuid(),
  naam text not null unique,
  is_geen_declaratie boolean not null default false,
  sort_order integer not null default 0,
  aangemaakt_op timestamptz not null default now()
);

alter table ingredient_declaraties enable row level security;

create policy ingredient_declaraties_select on ingredient_declaraties
  for select using (true);
create policy ingredient_declaraties_insert on ingredient_declaraties
  for insert with check (mag_bewerken('settings'));
create policy ingredient_declaraties_update on ingredient_declaraties
  for update using (mag_bewerken('settings')) with check (mag_bewerken('settings'));
create policy ingredient_declaraties_delete on ingredient_declaraties
  for delete using (mag_verwijderen('settings'));

insert into ingredient_declaraties (naam, is_geen_declaratie, sort_order) values
  ('Hops', false, 1),
  ('Barley', false, 2),
  ('Yeast', false, 3),
  ('Wheat', false, 4),
  ('Natural Flavouring', false, 5),
  ('Sugar', false, 6),
  ('Oats', false, 7),
  ('-no declaration-', true, 8)
on conflict (naam) do nothing;
