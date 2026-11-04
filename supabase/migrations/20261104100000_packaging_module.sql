-- Packaging becomes its own database (Jaap, 04-11): a Packaging page under
-- Databases with SKUs (packaging_articles + bill of materials) and Materials,
-- moved out of Settings.
-- 1. New permission module 'packaging'; writes on the three packaging tables
--    check it instead of 'settings'. Reads stay open (the Filling report
--    needs them). Admin only for now: no role_permissions rows are added, so
--    only is_admin() passes until roles are ticked in the role matrix.
-- 2. Preparation for packaging stock keeping: a category per material and a
--    reorder level (minimum stock). The categories of the existing materials
--    are filled from their names. Plain ASCII.

begin;

insert into public.permission_modules (module_key, name, sort_order)
values ('packaging', 'Packaging', 12)
on conflict (module_key) do nothing;

alter policy packaging_articles_insert on public.packaging_articles
  with check ((select can_edit('packaging')));
alter policy packaging_articles_update on public.packaging_articles
  using ((select can_edit('packaging'))) with check ((select can_edit('packaging')));
alter policy packaging_articles_delete on public.packaging_articles
  using ((select can_delete('packaging')));

alter policy packaging_materials_insert on public.packaging_materials
  with check ((select can_edit('packaging')));
alter policy packaging_materials_update on public.packaging_materials
  using ((select can_edit('packaging'))) with check ((select can_edit('packaging')));
alter policy packaging_materials_delete on public.packaging_materials
  using ((select can_delete('packaging')));

alter policy packaging_article_materials_insert on public.packaging_article_materials
  with check ((select can_edit('packaging')));
alter policy packaging_article_materials_update on public.packaging_article_materials
  using ((select can_edit('packaging'))) with check ((select can_edit('packaging')));
alter policy packaging_article_materials_delete on public.packaging_article_materials
  using ((select can_delete('packaging')));

alter table public.packaging_materials
  add column if not exists category text not null default 'other'
    check (category in ('bottle', 'can', 'label', 'closure', 'box', 'keg', 'other')),
  add column if not exists reorder_level numeric check (reorder_level >= 0);

comment on column public.packaging_materials.category is
  'Kind of material, groups the Materials list and later the packaging stock: bottle, can, label, closure, box, keg, other.';
comment on column public.packaging_materials.reorder_level is
  'Minimum stock in the material unit; below this the material should be ordered. Empty = no warning. For the packaging stock keeping to come.';

update public.packaging_materials set category = case
    when name ilike 'bottle %' then 'bottle'
    when name ilike 'can %' and name not ilike 'can lid%' then 'can'
    when name ilike '%label%' then 'label'
    when name ilike 'outer box%' then 'box'
    when name ilike any (array['crown cork%', 'cork%', 'muselet%', 'can lid%', '%keg cap%']) then 'closure'
    when name ilike '%keg%' and name not ilike '%collar%' then 'keg'
    else 'other'
  end
where category = 'other';

commit;
