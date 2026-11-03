-- Recipe review by Daniel (Recipe_and_brew_sheet_review_2026-10-23.xlsx, tab Data).
-- Data corrections only; recipe versions are not bumped (agreed with Jaap).
-- Every statement is guarded on the old value, so the migration is idempotent.

-- 1. ADF is a percentage everywhere (column adf_pct, unit '%' in the UI,
--    fermentation log compares against a percentage). Convert the rows that
--    were stored as a fraction (all values < 2 are fractions: no stored value
--    lies between 1.08 and 10) and their fraction tolerances (0.03 -> 3).
update public.recipe_specs
set adf_pct_tol = trim(trailing '.' from trim(trailing '0' from (adf_pct_tol::numeric * 100)::text))
where adf_pct < 2
  and adf_pct_tol ~ '^0\.[0-9]+$'
  and adf_pct_tol::numeric > 0;

update public.recipe_specs
set adf_pct = adf_pct * 100
where adf_pct < 2;

-- Recipes already stored as a percentage but with a fraction tolerance.
update public.recipe_specs
set adf_pct_tol = '3'
where adf_pct >= 2 and adf_pct_tol = '0.03';

-- 2. F04: ADF did not match OE/FE -> recalculate as (OE - FE) / OE.
update public.recipe_specs
set adf_pct = round((original_extract - final_extract) / original_extract * 100, 1)
where recipe_id in (205, 270, 364, 392, 402, 450, 451, 657, 658, 685, 699)
  and original_extract > 0 and final_extract is not null;

-- 3. F07: tolerances with decimal comma / % sign -> plain number.
update public.recipe_specs
set alcohol_tol = '0.5'
where alcohol_tol = '0,5%'
  and recipe_id in (73, 161, 183, 195, 208, 214, 215, 238, 249, 252, 253, 261, 265, 268,
                    277, 297, 298, 304, 305, 306, 311, 323, 327, 331, 340, 373, 374, 375,
                    403, 404, 409, 410, 411, 429, 432, 443, 459, 460, 489, 490, 492, 494,
                    510, 513, 515, 516, 576, 577, 627, 651, 664, 696, 697, 700, 702, 703);

update public.recipe_specs
set original_extract_tol = replace(original_extract_tol, ',', '.')
where original_extract_tol like '%,%'
  and recipe_id in (254, 434, 468, 469, 473, 661, 701);

update public.recipe_specs
set final_extract_tol = replace(final_extract_tol, ',', '.')
where final_extract_tol like '%,%'
  and recipe_id in (254, 434, 468, 469, 473, 661, 701);

update public.recipe_fermentation
set dry_hop_warm_extract_1_tol = '0.5'
where recipe_id = 434 and dry_hop_warm_extract_1_tol = '0,5';

update public.recipe_fermentation
set dry_hop_warm_extract_1_tol = nullif(dry_hop_warm_extract_1_tol, '-'),
    dry_hop_warm_extract_2_tol = nullif(dry_hop_warm_extract_2_tol, '-'),
    dry_hop_warm_extract_3_tol = nullif(dry_hop_warm_extract_3_tol, '-'),
    dry_hop_warm_temp_tol      = nullif(dry_hop_warm_temp_tol, '-')
where recipe_id = 661;

-- 4. F14: whirlpool rest agreed per recipe (only where the recipe had none).
--    Heavy Cross 29: applied to the current version 714 (691 is archived).
--    Malle Babbe V2 (97) and Lifes A Beach 30 test (653) are archived without
--    an active successor and are skipped.
update public.recipe_brewing_specs
set whirlpool_rest = 15
where whirlpool_rest is null
  and recipe_id in (223, 297, 331, 405, 502, 682, 686, 714);

update public.recipe_brewing_specs
set whirlpool_rest = 20
where whirlpool_rest is null and recipe_id = 651;
