-- Packaging: the GdV (Gebrouwen door Vrouwen) 20L keg as a material (Jaap,
-- 21-10). The article gbr_door_vrouwen_keg_20 existed, but the keg itself
-- could not be booked out: the old filling reports have "GdV 20L" under
-- kegs used. Its BOM gets the keg next to the keg cap, as the Jopen 20L keg.
-- Additive. Plain ASCII.

begin;

insert into public.packaging_materials (code, name, unit, sort_order)
values ('gbr_door_vrouwen_keg_20', 'GdV keg 20L', 'pcs', 265)
on conflict (code) do nothing;

insert into public.packaging_article_materials (article_id, material_id, quantity)
select a.id, m.id, 1
from public.packaging_articles a, public.packaging_materials m
where a.code = 'gbr_door_vrouwen_keg_20' and m.code = 'gbr_door_vrouwen_keg_20'
on conflict (article_id, material_id) do nothing;

commit;
