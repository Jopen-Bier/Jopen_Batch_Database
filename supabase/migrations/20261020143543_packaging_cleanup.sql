-- Batch report, phase 7 follow-up (Jaap, 20-10, rooktest): neck labels are no
-- longer used, and the Global Keg is not filled. Removes the neck label
-- materials with their bill-of-materials lines, and the Global Keg article
-- (its BOM lines go with it) and material. Stops when one of them is booked
-- on a filling session (then make it inactive in Settings instead).

begin;

do $$ begin
  if exists (select 1 from public.filling_session_materials f join public.packaging_materials m on m.id = f.material_id
             where m.code in ('label_33_neck', 'label_75_neck', 'global_keg_20'))
     or exists (select 1 from public.filling_session_articles f join public.packaging_articles a on a.id = f.article_id
                where a.code = 'global_keg_20') then
    raise exception 'A neck label or the Global Keg is booked on a filling session; nothing was changed';
  end if;
end $$;

delete from public.packaging_article_materials
where material_id in (select id from public.packaging_materials where code in ('label_33_neck', 'label_75_neck', 'global_keg_20'));

delete from public.packaging_articles where code = 'global_keg_20';

delete from public.packaging_materials where code in ('label_33_neck', 'label_75_neck', 'global_keg_20');

commit;
