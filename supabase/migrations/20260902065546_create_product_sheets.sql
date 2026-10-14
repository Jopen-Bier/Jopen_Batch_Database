-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Product sheets: gegenereerd vanuit levende receptdata, met een bewuste "Update"-stap
-- i.p.v. automatische sync. Alleen echte label-specifieke velden die niet uit het
-- recept af te leiden zijn staan hier; specs/ingredienten/flavor/colour/schenktemp
-- komen altijd live uit recipes/recipe_specificaties/recipe_ingredients.

create table if not exists product_sheets (
  id bigint generated always as identity primary key,
  recipe_group_id uuid not null,
  status text not null default 'concept' check (status in ('concept', 'actief', 'gearchiveerd')),
  huidige_versie integer not null default 1,

  -- Niet uit het recept af te leiden, blijven handmatige velden op de product sheet zelf
  excise_tax_category text,
  vat_gerijpt_hl numeric,
  vat_type text,
  vat_dagen integer,
  energie_kj numeric,
  energie_kcal numeric,
  vet_g numeric,
  koolhydraten_g numeric,
  eiwit_g numeric,
  zout_g numeric,

  -- Snapshot van alle live-afgeleide, label-relevante velden op het moment van de
  -- laatste Update (specs, berekende kleur, turbidity-categorie, ingredienten+allergenen,
  -- smaakomschrijving/keywords/kleur/schenktemp van het recept op dat moment).
  -- Wordt bij het tonen van het recept live vergeleken met een verse berekening om
  -- de rood/groen-syncstatus te bepalen -- alleen deze velden tellen mee, niet het
  -- hele recept (zie sessie-afspraak: niet elke receptwijziging is relevant voor het label).
  live_data_snapshot jsonb,

  bijgewerkt_op timestamptz,
  bijgewerkt_door uuid references auth.users(id),

  created_at timestamptz not null default now(),
  aangemaakt_door uuid references auth.users(id)
);

create index if not exists idx_product_sheets_recipe_group_id on product_sheets(recipe_group_id);

comment on table product_sheets is 'Product sheets (etiketinformatie), gegenereerd vanuit levende receptdata met een bewuste Update-stap. Zie project-documentatie voor de sync-logica.';
comment on column product_sheets.live_data_snapshot is 'jsonb snapshot van alle label-relevante, live-afgeleide velden zoals ze waren bij de laatste Update -- basis voor de rood/groen-syncstatus.';

-- Revisiehistorie, zelfde patroon als recipe_revisies/ingredient_revisies.
-- Versienummer van de product sheet staat los van het receptversienummer;
-- recipe_versie_major/minor legt vast van welke receptversie de update kwam.
create table if not exists product_sheet_revisies (
  id bigint generated always as identity primary key,
  product_sheet_id bigint not null references product_sheets(id) on delete cascade,
  versie integer not null,
  recipe_versie_major integer,
  recipe_versie_minor integer,
  datum date not null default current_date,
  door uuid references auth.users(id),
  wijziging text
);

create index if not exists idx_product_sheet_revisies_product_sheet_id on product_sheet_revisies(product_sheet_id);

comment on table product_sheet_revisies is 'Revisiehistorie van product sheets, analoog aan recipe_revisies.';

alter table product_sheets enable row level security;
alter table product_sheet_revisies enable row level security;

create policy product_sheets_select on product_sheets for select using (mag_bekijken('product_sheets'));
create policy product_sheets_insert on product_sheets for insert with check (mag_bewerken('product_sheets'));
create policy product_sheets_update on product_sheets for update using (mag_bewerken('product_sheets'));
create policy product_sheets_delete on product_sheets for delete using (mag_verwijderen('product_sheets'));

create policy product_sheet_revisies_select on product_sheet_revisies for select using (mag_bekijken('product_sheets'));
create policy product_sheet_revisies_insert on product_sheet_revisies for insert with check (mag_bewerken('product_sheets'));
