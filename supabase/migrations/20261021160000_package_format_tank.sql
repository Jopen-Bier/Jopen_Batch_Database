-- Packaging: a fourth package format "tank" (Jaap, 21-10): tank beer for the
-- Jopenkerk, processed into the 60 hl transport tank TT60 and delivered like a
-- filled product. Counts as packaged in the volume balance and the pie chart;
-- measured like a keg (CO2 / O2).
-- - the four checks on bottle / can / keg get 'tank';
-- - tank TT60 (type hbt, 60 hl, WP) is added INACTIVE: it is a fill in the
--   history (the beer is "in an HBT" before it is packaged, so the balance
--   adds up) but is not offered in the tank dropdowns;
-- - article "Tank beer Jopenkerk (TT60)", counted in hl (100 l per unit),
--   without materials.
-- Constraints are only widened. Plain ASCII.

begin;

alter table public.batch_hbts drop constraint if exists batch_hbts_intended_formats_check;
alter table public.batch_hbts add constraint batch_hbts_intended_formats_check
  check (intended_formats <@ array['bottle', 'can', 'keg', 'tank']::text[]);

alter table public.filling_sessions drop constraint if exists filling_sessions_package_format_check;
alter table public.filling_sessions add constraint filling_sessions_package_format_check
  check (package_format = any (array['bottle', 'can', 'keg', 'tank']::text[]));

alter table public.hbt_readings drop constraint if exists hbt_readings_co2_target_check;
alter table public.hbt_readings add constraint hbt_readings_co2_target_check
  check (co2_target = any (array['bottle', 'can', 'keg', 'tank']::text[]));

alter table public.packaging_articles drop constraint if exists packaging_articles_package_format_check;
alter table public.packaging_articles add constraint packaging_articles_package_format_check
  check (package_format = any (array['bottle', 'can', 'keg', 'tank']::text[]));

insert into public.tanks (code, tank_type, number, location, volume_hl, is_active)
values ('TT60', 'hbt', 60, 'wp', 60, false)
on conflict (code) do nothing;

insert into public.packaging_articles (code, name, package_format, liters_per_unit, sort_order)
values ('tank_jopenkerk', 'Tank beer Jopenkerk (TT60)', 'tank', 100,
        (select coalesce(max(sort_order), 0) + 10 from public.packaging_articles))
on conflict (code) do nothing;

commit;
