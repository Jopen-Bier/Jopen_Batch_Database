-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- 1) allergenen: NULL = nog niet beoordeeld, [] = bewust "geen allergenen"
alter table public.ingredients alter column allergenen drop default;
alter table public.ingredients alter column allergenen drop not null;

-- Bestaande lege lijsten zijn niet te onderscheiden van "nooit bekeken" -> NULL.
-- gewijzigd_op-trigger tijdelijk uit, anders krijgen 555 ingrediënten een nieuwe "last modified".
alter table public.ingredients disable trigger trg_ingredients_gewijzigd_op;
update public.ingredients set allergenen = null where allergenen = '[]'::jsonb;
alter table public.ingredients enable trigger trg_ingredients_gewijzigd_op;

-- 2) Product sheet-hash: NULL hasht als '[]' zodat de sync-status van bestaande sheets niet verandert.
CREATE OR REPLACE FUNCTION public.product_sheet_relevant_hash(p_recipe_group_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select md5(
    coalesce(s.origineel_extract::text,'') || '|' || coalesce(s.origineel_extract_tol,'') || '|' ||
    coalesce(s.rest_extract::text,'') || '|' || coalesce(s.rest_extract_tol,'') || '|' ||
    coalesce(s.alcohol::text,'') || '|' || coalesce(s.alcohol_tol,'') || '|' ||
    coalesce(s.bitterheid::text,'') || '|' || coalesce(s.bitterheid_tol,'') || '|' ||
    coalesce(product_sheet_calculated_color(r.id)::text,'') || '|' || coalesce(s.kleur_tol,'') || '|' ||
    coalesce(s.ph::text,'') || '|' || coalesce(s.ph_tol,'') || '|' ||
    coalesce(s.troebeling_lab::text,'') || '|' || coalesce(s.troebeling_lab_tol,'') || '|' ||
    coalesce(s.co2_fles::text,'') || '|' || coalesce(s.co2_fles_tol,'') || '|' ||
    coalesce(s.co2_can::text,'') || '|' || coalesce(s.co2_can_tol,'') || '|' ||
    coalesce(s.co2_fust::text,'') || '|' || coalesce(s.co2_fust_tol,'') || '|' ||
    coalesce(s.headspace_o2::text,'') || '|' || coalesce(s.headspace_o2_tol,'') || '|' ||
    coalesce(s.dissolved_o2::text,'') || '|' || coalesce(s.dissolved_o2_tol,'') || '|' ||
    coalesce(r.smaakomschrijving,'') || '|' ||
    coalesce(array_to_string(r.smaak_keywords, ','),'') || '|' ||
    coalesce(r.kleur_vrije_tekst,'') || '|' ||
    coalesce(r.aanbevolen_schenktemperatuur::text,'') || '|' ||
    coalesce((
      select string_agg(ri.ingredient_id::text || ':' || coalesce(ri.hoeveelheid::text,'') || ':' || coalesce(ri.eenheid,'') || ':' || ri.rol, ',' order by ri.ingredient_id, ri.rol)
      from recipe_ingredients ri where ri.recipe_id = r.id
    ), '') || '|' ||
    coalesce((
      select string_agg(coalesce(i.ingredient_declaratie,'') || ':' || coalesce(i.allergenen, '[]'::jsonb)::text, ',' order by i.id)
      from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
      where ri2.recipe_id = r.id
    ), '')
  )
  from recipes r
  left join recipe_specificaties s on s.recipe_id = r.id
  where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
$function$;

-- 3) Nieuwe rechtenmodule Statistics (standaard alleen admin via de ingebouwde bypass)
insert into public.permission_modules (module_key, naam, volgorde)
values ('statistics', 'Statistics', 10)
on conflict (module_key) do nothing;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, 'statistics', false, false, false from public.roles r
where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.module_key = 'statistics');
