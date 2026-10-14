-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Server-side sync-status berekening voor product sheets. Vergelijkt alleen de
-- velden die daadwerkelijk in de product sheet terechtkomen (niet het hele
-- recept) tegen de snapshot-hash die bij de laatste "Update" is vastgelegd --
-- zo triggert een wijziging aan bv. kosten of procesparameters geen onnodige
-- rood-status.

create or replace function product_sheet_relevant_recipe_id(p_recipe_group_id uuid)
returns bigint language sql stable as $$
  select id from recipes
  where recipe_group_id = p_recipe_group_id
  order by versie_major desc, versie_minor desc
  limit 1
$$;

create or replace function product_sheet_calculated_color(p_recipe_id bigint)
returns numeric language sql stable as $$
  select round(
    coalesce(sum(ri.hoeveelheid * ri.kleur_ebc * 0.08), 0) / nullif(r.brouwsel_hl, 0) + 1.75
  , 2)
  from recipes r
  left join recipe_ingredients ri on ri.recipe_id = r.id and ri.rol = 'hoofdmout'
  where r.id = p_recipe_id
  group by r.brouwsel_hl
$$;

create or replace function product_sheet_relevant_hash(p_recipe_group_id uuid)
returns text language sql stable as $$
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
      select string_agg(coalesce(i.ingredient_declaratie,'') || ':' || coalesce(i.allergenen::text,''), ',' order by i.id)
      from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
      where ri2.recipe_id = r.id
    ), '')
  )
  from recipes r
  left join recipe_specificaties s on s.recipe_id = r.id
  where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
$$;

create or replace view product_sheet_status
with (security_invoker = true) as
select
  ps.id as product_sheet_id,
  ps.recipe_group_id,
  ps.status,
  ps.huidige_versie,
  ps.bijgewerkt_op,
  ps.bijgewerkt_obv_versie_major,
  ps.bijgewerkt_obv_versie_minor,
  (ps.sync_snapshot->>'hash') as opgeslagen_hash,
  product_sheet_relevant_hash(ps.recipe_group_id) as huidige_hash,
  coalesce((ps.sync_snapshot->>'hash') = product_sheet_relevant_hash(ps.recipe_group_id), false) as in_sync
from product_sheets ps
where ps.status <> 'gearchiveerd';
