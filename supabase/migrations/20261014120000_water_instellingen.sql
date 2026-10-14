-- Waterprofiel (bronwater) en caps voor de water salts calculator op de
-- receptpagina. Eén vaste rij (id = 1), te bewerken onder Settings › Water.
-- Elke wijziging komt via een trigger in water_instellingen_historie, zodat
-- altijd terug te zien is welk waterprofiel op een bepaald moment gold
-- (FSSC 22000-spoor). Zoutfactoren staan bewust in de code (waterzouten.js).
create table if not exists water_instellingen (
  id smallint primary key default 1 check (id = 1),
  omschrijving text not null default 'Jopen ambient water',
  gemeten_op date,
  ca numeric not null,
  mg numeric not null,
  na numeric not null,
  cl numeric not null,
  so4 numeric not null,
  alkalinity numeric,
  max_ca numeric not null default 300,
  max_mg numeric not null default 30,
  max_cl numeric not null default 400,
  max_so4 numeric not null default 600,
  gewijzigd_op timestamptz not null default now(),
  gewijzigd_door uuid references gebruikers(id)
);

create table if not exists water_instellingen_historie (
  id bigint generated always as identity primary key,
  geldig_vanaf timestamptz not null,
  gewijzigd_door uuid references gebruikers(id),
  gegevens jsonb not null
);

alter table water_instellingen enable row level security;
alter table water_instellingen_historie enable row level security;

create policy water_instellingen_select on water_instellingen
  for select using (true);
create policy water_instellingen_update on water_instellingen
  for update using (mag_bewerken('settings')) with check (mag_bewerken('settings'));
-- Geen insert/delete-policy: er is altijd precies één rij (hieronder gezet).

create policy water_instellingen_historie_select on water_instellingen_historie
  for select using (true);
-- Historie wordt alleen door de trigger (security definer) geschreven.

create or replace function water_instellingen_stempel() returns trigger as $$
begin
  new.gewijzigd_op := now();
  new.gewijzigd_door := auth.uid();
  return new;
end;
$$ language plpgsql;

create or replace function water_instellingen_log() returns trigger as $$
begin
  insert into water_instellingen_historie (geldig_vanaf, gewijzigd_door, gegevens)
    values (new.gewijzigd_op, new.gewijzigd_door, to_jsonb(new));
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_water_instellingen_stempel on water_instellingen;
create trigger trg_water_instellingen_stempel
  before update on water_instellingen
  for each row execute function water_instellingen_stempel();

drop trigger if exists trg_water_instellingen_log on water_instellingen;
create trigger trg_water_instellingen_log
  after insert or update on water_instellingen
  for each row execute function water_instellingen_log();

-- Startwaarden: Jopen ambient water (opgegeven door Jaap, oktober 2026).
insert into water_instellingen (id, omschrijving, ca, mg, na, cl, so4, alkalinity)
values (1, 'Jopen ambient water', 21.3, 3.3, 24.5, 28.7, 17.7, 65.3)
on conflict (id) do nothing;
