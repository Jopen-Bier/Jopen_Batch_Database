-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- De delete-then-insert save-flow in recept-invoer.html (schrijfGerelateerdeData)
-- vervangt bij elke recept-opslag altijd de volledige recipe_ingredients-set voor
-- dat recept. Dat "verwijderen" hoort bij het bewerken van een recept, niet bij het
-- verwijderen van het recept zelf. De delete-policy stond echter op mag_verwijderen
-- (can_delete), terwijl insert/update op mag_bewerken (can_edit) staan. Rollen met
-- can_edit=true maar can_delete=false (bv. Brewer) konden hierdoor nooit oude
-- ingrediëntregels kwijtraken bij het opslaan: de DELETE matchte 0 rijen (RLS
-- filtert stil, geen foutmelding), waarna de INSERT er telkens overheen stapelde.
drop policy if exists recipe_ingredients_delete on recipe_ingredients;

create policy recipe_ingredients_delete
  on recipe_ingredients
  for delete
  using (mag_bewerken('recipes'));
