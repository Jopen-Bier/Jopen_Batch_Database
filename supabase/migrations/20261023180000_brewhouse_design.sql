-- Brewhouse design on the recipe page (Brewcalc 1.00 in the app; Jaap, 23-10).
-- 1. ingredients.malt_equivalent: how much a raw material counts as filter
--    load in the mash filter, per kg (Brewcalc "ME factor": malt 1, wheat 0.7,
--    oat flakes 0.75, barley flakes 0.85). Empty = 1. Filled from Brewcalc's list.
-- 2. recipe_brewing_specs: the design inputs that have no column yet, saved
--    with the recipe so the next brewer sees how it was designed. Water/grist
--    ratio (mash_thickness), evaporation (target_evaporation), chambers
--    (mash_filter_chambers) and mash-in temperature (mash_in_temp) already
--    have a column. Additive; RLS unchanged (existing policies of both tables).
-- Plain ASCII.

begin;

alter table public.ingredients
  add column if not exists malt_equivalent numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ingredients_malt_equivalent_check') then
    alter table public.ingredients add constraint ingredients_malt_equivalent_check
      check (malt_equivalent > 0 and malt_equivalent <= 1.5);
  end if;
end $$;
comment on column public.ingredients.malt_equivalent is
  'Mash filter load per kg relative to malt (Brewcalc ME factor). Empty = 1.';

-- Brewcalc ME factors, by name over all versions of the ingredient; only rows
-- that are still empty.
update public.ingredients i set malt_equivalent = v.me
from (values
  ('wheat malt', 0.7), ('wheat malt dark', 0.7), ('bio tarwemout', 0.7), ('tarwemout chateau', 0.7),
  ('ongemoute tarwe', 0.7), ('bio ongemoute tarwe', 0.7),
  ('oat flakes', 0.75), ('bio havervlokken', 0.75), ('malted oats', 0.75),
  ('barley flakes', 0.85), ('gerstevlokken(kaapse)', 0.85),
  ('rice husks', 0.02)
) as v(name, me)
where lower(i.name) = v.name and i.malt_equivalent is null;

alter table public.recipe_brewing_specs
  add column if not exists design_cast_extract numeric,
  add column if not exists design_hop_correction numeric,
  add column if not exists design_whirlpool_loss_pct numeric,
  add column if not exists design_brewhouse_loss_pct numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'recipe_brewing_specs_design_check') then
    alter table public.recipe_brewing_specs add constraint recipe_brewing_specs_design_check check (
      (design_cast_extract is null or (design_cast_extract > 0 and design_cast_extract < 40))
      and (design_hop_correction is null or (design_hop_correction >= 0 and design_hop_correction <= 10))
      and (design_whirlpool_loss_pct is null or (design_whirlpool_loss_pct >= 0 and design_whirlpool_loss_pct < 100))
      and (design_brewhouse_loss_pct is null or (design_brewhouse_loss_pct >= 0 and design_brewhouse_loss_pct < 100)));
  end if;
end $$;
comment on column public.recipe_brewing_specs.design_cast_extract is 'Brewhouse design: extract at casting (deg P); above the original extract means dilution water.';
comment on column public.recipe_brewing_specs.design_hop_correction is 'Brewhouse design: factor on the whirlpool loss for the hop load (Brewcalc 3 for hoppy beers).';
comment on column public.recipe_brewing_specs.design_whirlpool_loss_pct is 'Brewhouse design: standard whirlpool loss in % (Brewcalc 2).';
comment on column public.recipe_brewing_specs.design_brewhouse_loss_pct is 'Brewhouse design: brewhouse loss in % of the grist kg below the lab extract (Brewcalc 1.5).';

commit;
