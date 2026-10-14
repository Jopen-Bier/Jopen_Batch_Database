-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Zelfde patroon/bug als recipe_ingredients: brouwplanning.html vervangt bij het
-- bewerken van een gepland brouwsel altijd de volledige brew_planning_splits-set
-- (delete-then-insert). Dat "verwijderen" hoort bij het bewerken van de planning,
-- niet bij het verwijderen van het brouwsel zelf. Preventieve fix: nog geen rol
-- heeft momenteel can_edit=true/can_delete=false op 'brewing_planning', maar zodra
-- de rollenmatrix ooit zo ingesteld wordt breekt dit op dezelfde manier als bij
-- recipe_ingredients (oude split-regels blijven onzichtbaar hangen, nieuwe stapelen
-- op bij elke edit).
drop policy if exists brew_planning_splits_delete on brew_planning_splits;

create policy brew_planning_splits_delete
  on brew_planning_splits
  for delete
  using (mag_bewerken('brewing_planning'));
