-- Packaging (Jaap, 22-10), found in the 2026 filling reports:
-- - material "Keg collar" (Fustkraag): the paper collar on a keg with the
--   batch and beer data. No bill of materials yet (not every keg got one).
-- - "20L other keg" as an article and a material, for kegs of another brewery
--   or owner (Warsteiner, Florijn, Global Keg). Which keg it was goes in the
--   new comment on the booked row. BOM: the keg and a keg cap, as the other
--   20L kegs.
-- - comment on filling_session_articles and filling_session_materials.
-- Additive. RLS is unchanged (row policies cover the new column). Plain ASCII.

begin;

alter table public.filling_session_articles add column if not exists comment text;
alter table public.filling_session_materials add column if not exists comment text;

insert into public.packaging_materials (code, name, unit, sort_order)
values ('other_keg_20', 'Other keg 20L', 'pcs', 285),
       ('keg_collar', 'Keg collar', 'pcs', 295)
on conflict (code) do nothing;

insert into public.packaging_articles (code, name, package_format, liters_per_unit, sort_order)
values ('other_keg_20', '20L other keg', 'keg', 20,
        (select coalesce(max(sort_order), 0) + 10 from public.packaging_articles))
on conflict (code) do nothing;

insert into public.packaging_article_materials (article_id, material_id, quantity)
select a.id, m.id, 1
from public.packaging_articles a, public.packaging_materials m
where a.code = 'other_keg_20' and m.code in ('other_keg_20', 'keg_cap')
on conflict (article_id, material_id) do nothing;

commit;
