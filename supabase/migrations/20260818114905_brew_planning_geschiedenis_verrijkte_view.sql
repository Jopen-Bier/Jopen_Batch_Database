-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- View die de audit-trail van brew_planning verrijkt met de naam van de
-- gebruiker die de wijziging deed. security_invoker = true zodat de view
-- gewoon de bestaande RLS-policy op brew_planning_geschiedenis volgt
-- (mag_bekijken('brewing_planning')) i.p.v. de rechten van de view-eigenaar.
create or replace view public.brew_planning_geschiedenis_verrijkt
with (security_invoker = true) as
select
  g.id,
  g.brew_planning_id,
  g.actie,
  g.voor,
  g.na,
  g.gewijzigd_door,
  u.naam as gewijzigd_door_naam,
  g.gewijzigd_op
from public.brew_planning_geschiedenis g
left join public.gebruikers u on u.id = g.gewijzigd_door
order by g.gewijzigd_op desc;
