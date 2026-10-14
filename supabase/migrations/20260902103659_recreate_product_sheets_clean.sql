-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Oude, uit een andere sessie ontstane opzet weg (0 rijen, nog niets live) en opnieuw
-- opbouwen volgens het in deze sessie afgesproken ontwerp.
drop table if exists product_sheet_revisies;
drop table if exists product_sheets;

create table product_sheets (
  id bigint generated always as identity primary key,
  recipe_group_id uuid not null,
  status text not null default 'actief',
  huidige_versie integer not null default 1,

  -- handmatige, niet uit het recept af te leiden label-content
  excise_tax_category text,
  vat_gerijpt_hl numeric,
  vat_type text,
  vat_dagen numeric,
  energie_kj numeric,
  energie_kcal numeric,
  vet_g numeric,
  koolhydraten_g numeric,
  eiwit_g numeric,
  zout_g numeric,
  opmerkingen text,

  -- sync-status: snapshot van alleen de label-relevante receptvelden bij de laatste Update
  -- (specs, kleur, allergenen, ingredientenlijst, smaakomschrijving/keywords, schenktemperatuur,
  -- kleur_vrije_tekst). Bewust GEEN vergelijking op recipes.versie_major/minor als geheel --
  -- niet elke receptwijziging raakt de product sheet.
  sync_snapshot jsonb,

  bijgewerkt_obv_versie_major integer,
  bijgewerkt_obv_versie_minor integer,
  bijgewerkt_op timestamptz,
  bijgewerkt_door uuid references auth.users(id),

  aangemaakt_op timestamptz not null default now(),
  aangemaakt_door uuid references auth.users(id)
);

comment on column product_sheets.sync_snapshot is
  'Snapshot van alleen de label-relevante receptvelden bij de laatste Update, voor de rood/groen sync-status. Vergelijk live tegen dezelfde velden, niet tegen recipes.versie_major/minor als geheel.';

create unique index product_sheets_recipe_group_id_actief_idx
  on product_sheets (recipe_group_id) where status <> 'gearchiveerd';

create table product_sheet_revisies (
  id bigint generated always as identity primary key,
  product_sheet_id bigint not null references product_sheets(id) on delete cascade,
  versie integer not null,
  recipe_versie_major integer,
  recipe_versie_minor integer,
  datum date not null default current_date,
  door uuid references auth.users(id),
  wijzigingen text,
  created_at timestamptz not null default now()
);

create index product_sheet_revisies_product_sheet_id_idx on product_sheet_revisies (product_sheet_id);

alter table product_sheets enable row level security;
alter table product_sheet_revisies enable row level security;

insert into permission_modules (module_key, naam, volgorde)
values ('product_sheets', 'Product Sheets', 8)
on conflict (module_key) do nothing;

insert into role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, 'product_sheets', true,
  r.naam in ('admin', 'Head brewer'),
  r.naam in ('admin', 'Head brewer')
from roles r
on conflict (role_id, module_key) do nothing;

create policy product_sheets_select on product_sheets
  for select using (mag_bekijken('product_sheets'));
create policy product_sheets_insert on product_sheets
  for insert with check (mag_bewerken('product_sheets'));
create policy product_sheets_update on product_sheets
  for update using (mag_bewerken('product_sheets'));
create policy product_sheets_delete on product_sheets
  for delete using (mag_verwijderen('product_sheets'));

create policy product_sheet_revisies_select on product_sheet_revisies
  for select using (mag_bekijken('product_sheets'));
create policy product_sheet_revisies_insert on product_sheet_revisies
  for insert with check (mag_bewerken('product_sheets'));
