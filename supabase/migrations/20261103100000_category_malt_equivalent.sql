-- Ingredient categories: a switch "Malt equivalent" (Jaap, 03-11), like
-- Alpha % / Extract % / Yeast factor. Categories with the switch show the
-- field ingredients.malt_equivalent on the ingredient card (mash filter load
-- per kg relative to malt; empty = 1). On for Malt/Grain. Additive; RLS
-- unchanged (existing policies of ingredient_categories). Plain ASCII.

begin;

alter table public.ingredient_categories
  add column if not exists uses_malt_equivalent boolean not null default false;
comment on column public.ingredient_categories.uses_malt_equivalent is
  'Ingredients of this category show the Malt equivalent field (mash filter load).';

update public.ingredient_categories set uses_malt_equivalent = true where name = 'Malt/Grain';

commit;
