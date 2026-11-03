-- Brewhouse design: the mash and filter loss is a % of the lab extract, not
-- of the grist kg as in Brewcalc (Jaap, 03-11: start at 7 %, measured ~7 %
-- over 62 WP brews). Comment only. Plain ASCII.

begin;

comment on column public.recipe_brewing_specs.design_brewhouse_loss_pct is
  'Brewhouse design: mash and filter loss in % of the lab extract (lab extract to the start of the boil). Empty = 7.';

commit;
