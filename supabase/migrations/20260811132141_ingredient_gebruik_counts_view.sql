-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Ingrediëntenpagina duurde bijna 10s om te laden: laadIngredienten() haalde
-- ALLE 8000+ rijen van recipe_ingredients (ingredient_id, recipe_id) client-
-- side op, via 9 sequentiële gepagineerde requests van 1000 rijen, puur om
-- per ingrediënt te tellen in hoeveel recepten het voorkomt ("Used in X
-- recipes"-kolom). Deze view doet die telling server-side; de pagina hoeft
-- nu nog maar 1 lichte request te doen (max. 676 rijen, 1 per ingrediënt).
--
-- security_invoker = true: de view leest met de RLS-rechten van de
-- inloggende gebruiker op recipe_ingredients zelf (mag_bekijken('recipes')),
-- dus exact hetzelfde zichtbaarheidsgedrag als de oude rechtstreekse query.
create or replace view ingredient_gebruik_counts
with (security_invoker = true) as
select ingredient_id, count(distinct recipe_id) as aantal_recepten
from recipe_ingredients
where ingredient_id is not null
group by ingredient_id;

grant select on ingredient_gebruik_counts to anon, authenticated;
