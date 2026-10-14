-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Stabiele receptreferentie voor brouwplanning: recipe_id wijst naar één
-- specifieke recept-versierij en wordt "loos" (gearchiveerd/onvindbaar)
-- zodra iemand een major-versie-wijziging opslaat (nieuwe recipes-rij,
-- oude naar status='gearchiveerd'). recipe_group_id is stabiel over alle
-- versies van hetzelfde bier heen en bestond al op recipes (aangemaakt voor
-- de versiegeschiedenis-feature). Vanaf nu resolvet de frontend een gepland
-- brouwsel altijd via recipe_group_id -> nieuwste versie in die groep,
-- i.p.v. rechtstreeks op recipe_id te vertrouwen.
alter table brew_planning
  add column if not exists recipe_group_id uuid;

update brew_planning bp
set recipe_group_id = r.recipe_group_id
from recipes r
where r.id = bp.recipe_id
  and bp.recipe_group_id is null;

create index if not exists idx_brew_planning_recipe_group_id
  on brew_planning (recipe_group_id);
