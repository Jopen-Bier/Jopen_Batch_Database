-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Normaliseer bier_risico waarden (hoofdletters/spaties/trailing quotes)
update recipe_fermentatie
set bier_risico = 'Gevaarlijk'
where bier_risico in ('gevaarlijk', 'Gevaarlijk');

update recipe_fermentatie
set bier_risico = 'Standaard'
where bier_risico in ('standaard', 'Standaard', 'Standaard''', 'Standard');

-- 'Gevoelig' blijft staan als eigen waarde (bewuste keuze: 4e dropdown-optie)

-- Normaliseer bier_status waarden
update recipe_fermentatie
set bier_status = 'NPI'
where bier_status in ('NPI', 'NPI''');

-- 4 recepten met bier_status = 'gevaarlijk'/'Gevoelig' (mis-invoer, risico stond al goed
-- ingevuld in bier_risico) -> Standaard, zoals besproken
update recipe_fermentatie
set bier_status = 'Standaard'
where bier_status in ('gevaarlijk', 'Gevoelig');

-- Check constraints zodat toekomstige invoer (ook buiten de UI-dropdown om, bv. via SQL)
-- binnen de afgesproken vaste lijst blijft
alter table recipe_fermentatie
  drop constraint if exists recipe_fermentatie_bier_risico_check;
alter table recipe_fermentatie
  add constraint recipe_fermentatie_bier_risico_check
  check (bier_risico is null or bier_risico in ('Standaard', 'Gevaarlijk', 'Suikerhoudend', 'Gevoelig'));

alter table recipe_fermentatie
  drop constraint if exists recipe_fermentatie_bier_status_check;
alter table recipe_fermentatie
  add constraint recipe_fermentatie_bier_status_check
  check (bier_status is null or bier_status in ('Standaard', 'NPI', 'Te verbeteren'));
