-- Beheerbare lijst met documenttypen (zelfde patroon als eenheden), zodat
-- er later makkelijk een derde type bij kan zonder codewijziging.
create table if not exists document_typen (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text,
  sort_order int not null default 0,
  aangemaakt_op timestamptz not null default now()
);

alter table document_typen enable row level security;

create policy document_typen_select on document_typen
  for select using (true);
create policy document_typen_insert on document_typen
  for insert with check (mag_bewerken('settings'));
create policy document_typen_update on document_typen
  for update using (mag_bewerken('settings')) with check (mag_bewerken('settings'));
create policy document_typen_delete on document_typen
  for delete using (mag_verwijderen('settings'));

insert into document_typen (code, label, sort_order) values
  ('product_sheet', 'Product sheet', 1),
  ('coa', 'Certificate of Analysis (CoA)', 2)
on conflict (code) do nothing;

-- Documenttype + status + auto-archivering op ingredient_documenten.
-- Alle bestaande documenten zijn tot nu toe altijd product sheets geweest
-- (bevestigd door Jaap), dus die backfill is veilig.
alter table ingredient_documenten
  add column if not exists document_type_id uuid references document_typen(id),
  add column if not exists status text not null default 'actief';

alter table ingredient_documenten
  drop constraint if exists ingredient_documenten_status_check;
alter table ingredient_documenten
  add constraint ingredient_documenten_status_check check (status in ('actief', 'gearchiveerd'));

update ingredient_documenten
  set document_type_id = (select id from document_typen where code = 'product_sheet')
  where document_type_id is null;

alter table ingredient_documenten
  alter column document_type_id set not null;

create index if not exists idx_ingredient_documenten_ing_status_type
  on ingredient_documenten (ingredient_id, status, document_type_id);

-- Nog geen UPDATE-policy op ingredient_documenten -- nodig voor de nieuwe
-- Edit/Archive/Restore-acties.
create policy ingredient_documenten_update on ingredient_documenten
  for update using (mag_bewerken('ingredients')) with check (mag_bewerken('ingredients'));
