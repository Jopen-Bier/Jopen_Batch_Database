-- Brewing: "Spoelwater" in the Mashing block of the Excel brew sheet (a fixed
-- row for WP and JK; 0.6-0.9 hl per brew at WP) gets its own column (Jaap,
-- 21-10): batch_brews.mash_rinse_water_hl, "Rinse water" on the Brewing tab.
-- The 2026 import kept these values as brew comments "Spoelwater: <hl>"
-- until now: they move into the column and the comments are removed (only
-- comments that are exactly that text and a number, on a brew without a
-- value yet). Plain ASCII.

begin;

alter table public.batch_brews
  add column if not exists mash_rinse_water_hl numeric;

comment on column public.batch_brews.mash_rinse_water_hl is 'Rinse water (Spoelwater, mashing), hl';

with moved as (
  update public.batch_brews b
  set mash_rinse_water_hl = replace(substring(c.comment from '^Spoelwater: ([0-9]+([.,][0-9]+)?)$'), ',', '.')::numeric
  from public.batch_brew_comments c
  where c.batch_id = b.batch_id
    and c.brew_number = b.brew_number
    and c.comment ~ '^Spoelwater: [0-9]+([.,][0-9]+)?$'
    and b.mash_rinse_water_hl is null
  returning c.id
)
delete from public.batch_brew_comments where id in (select id from moved);

commit;
