-- Architecture clean-up, step 7: domain "inventory" in English.
-- Mapping: supabase/rename-map.json (approved by Jaap, 16-10-2026).
-- Tables stay in schema public.
--
-- Run by hand in the SQL Editor; registered in
-- supabase_migrations.schema_migrations before the file was pushed.
-- One transaction: everything or nothing.

-- ---------------------------------------------------------------------------
-- 1. ingredients: retire the old text category and the duplicate created_at.
-- ---------------------------------------------------------------------------
-- 6 current ingredients only have the old text category: fill category_id
-- from it first (mapping verified: no existing row disagrees).
update public.ingredients i set category_id = c.id
from public.ingredient_categories c
where i.category_id is null and i.categorie is not null
  and c.name = case i.categorie when 'graan' then 'Malt/Grain' when 'hop' then 'Hops'
                                when 'gist' then 'Yeast' when 'additief' then 'Additives' end;
alter table public.ingredients drop constraint ingredients_categorie_check;
alter table public.ingredients drop column categorie;
-- Two creation timestamps existed; aangemaakt_op is kept (becomes created_at).
alter table public.ingredients drop column created_at;

-- ---------------------------------------------------------------------------
-- 2. Status values in English (check constraint dropped, values updated,
--    constraint re-created under the new column name below).
-- ---------------------------------------------------------------------------
alter table public.ingredients drop constraint ingredients_status_check;
alter table public.ingredients drop constraint ingredients_versie_status_check;
alter table public.ingredient_documenten drop constraint ingredient_documenten_status_check;
alter table public.grondstof_lots drop constraint grondstof_lots_status_check;
alter table public.voorraad_mutaties drop constraint voorraad_mutaties_type_check;

update public.ingredients set status = case status when 'concept' then 'draft' when 'actief' then 'active' when 'uitfaserend' then 'phasing_out' else status end;
update public.ingredients set versie_status = case versie_status when 'huidig' then 'current' when 'gearchiveerd' then 'archived' else versie_status end;
update public.ingredient_documenten set status = case status when 'actief' then 'active' when 'gearchiveerd' then 'archived' else status end;
update public.grondstof_lots set status = case status when 'actief' then 'active' when 'leeg' then 'empty' when 'afgesloten' then 'closed' else status end;
update public.voorraad_mutaties set type = case type when 'ontvangst' then 'receipt' when 'reservering' then 'reservation' when 'uitboeking' then 'consumption' when 'correctie' then 'correction' else type end;

-- ---------------------------------------------------------------------------
-- 3. Rename tables and columns.
-- ---------------------------------------------------------------------------
alter table public.ingredients rename column naam to name;
alter table public.ingredients rename column eenheid to unit;
alter table public.ingredients rename column prijs to price;
alter table public.ingredients rename column gistfactor to yeast_factor;
alter table public.ingredients rename column leverancier to supplier;
alter table public.ingredients rename column aangemaakt_door to created_by;
alter table public.ingredients rename column gewijzigd_door to updated_by;
alter table public.ingredients rename column gewijzigd_op to updated_at;
alter table public.ingredients rename column versie_major to version_major;
alter table public.ingredients rename column versie_minor to version_minor;
alter table public.ingredients rename column versie_status to version_status;
alter table public.ingredients rename column aangemaakt_op to created_at;
alter table public.ingredients rename column leverancier_2 to supplier_2;
alter table public.ingredients rename column prijs_2 to price_2;
alter table public.ingredients rename column eenheid_prijs_1 to price_unit_1;
alter table public.ingredients rename column eenheid_prijs_2 to price_unit_2;
alter table public.ingredients rename column kleur_ebc to color_ebc;
alter table public.ingredients rename column allergenen to allergens;
alter table public.ingredients rename column ingredient_declaratie to ingredient_declaration;
alter table public.ingredients rename column bewaartemperatuur to storage_temperature;
alter table public.ingredients rename column houdbaarheid to shelf_life;
alter table public.ingredients rename column houdbaarheid_na_openen to shelf_life_after_opening;
alter table public.ingredients rename column dichtheid to density;
alter table public.ingredients rename column houdbaarheid_eenheid to shelf_life_unit;
alter table public.ingredients rename column houdbaarheid_na_openen_eenheid to shelf_life_after_opening_unit;
alter table public.ingredients rename column leverancier_3 to supplier_3;
alter table public.ingredients rename column prijs_3 to price_3;
alter table public.ingredients rename column eenheid_prijs_3 to price_unit_3;
alter table public.ingredients rename column prijs_per_kg to price_per_kg;
alter table public.ingredients rename column prijs_per_kg_2 to price_per_kg_2;
alter table public.ingredients rename column prijs_per_kg_3 to price_per_kg_3;
alter table public.ingredients rename column minimum_voorraad to minimum_stock;

alter table public.ingredient_categories rename column uses_gistfactor to uses_yeast_factor;

alter table public.ingredient_revisies rename to ingredient_revisions;
alter table public.ingredient_revisions rename column versie_major to version_major;
alter table public.ingredient_revisions rename column versie_minor to version_minor;
alter table public.ingredient_revisions rename column datum to date;
alter table public.ingredient_revisions rename column door to changed_by_name;
alter table public.ingredient_revisions rename column wijziging to change_description;
alter table public.ingredient_revisions rename column gebruiker_id to user_id;
alter table public.ingredient_revisions rename column aangemaakt_op to created_at;

alter table public.ingredient_documenten rename to ingredient_documents;
alter table public.ingredient_documents rename column bestandsnaam to file_name;
alter table public.ingredient_documents rename column grootte_bytes to size_bytes;
alter table public.ingredient_documents rename column revisiedatum to revision_date;
alter table public.ingredient_documents rename column geupload_door to uploaded_by;
alter table public.ingredient_documents rename column geupload_op to uploaded_at;

alter table public.ingredient_declaraties rename to ingredient_declarations;
alter table public.ingredient_declarations rename column naam to name;
alter table public.ingredient_declarations rename column is_geen_declaratie to not_declarable;
alter table public.ingredient_declarations rename column aangemaakt_op to created_at;

alter table public.grondstof_lots rename to lots;
alter table public.lots rename column leverancier to supplier;
alter table public.lots rename column lotcode to lot_code;
alter table public.lots rename column ontvangstdatum to received_date;
alter table public.lots rename column hoeveelheid_ontvangen to quantity_received;
alter table public.lots rename column eenheid to unit;
alter table public.lots rename column aantal_colli to package_count;
alter table public.lots rename column locatie to location;
alter table public.lots rename column ontvangstcontrole to receiving_check;
alter table public.lots rename column ingangscontrole to incoming_inspection;
alter table public.lots rename column tht_datum to best_before_date;
alter table public.lots rename column document_pad to document_path;
alter table public.lots rename column notitie to note;
alter table public.lots rename column aangemaakt_door to created_by;
alter table public.lots rename column aangemaakt_op to created_at;
alter table public.lots rename column ontvangen_door to received_by;

alter table public.voorraad_mutaties rename to stock_movements;
alter table public.stock_movements rename column type to movement_type;
alter table public.stock_movements rename column hoeveelheid to quantity;
alter table public.stock_movements rename column notitie to note;
alter table public.stock_movements rename column geboekt_in_boekhouding to booked_in_accounting;
alter table public.stock_movements rename column geboekt_door to booked_by;
alter table public.stock_movements rename column geboekt_op to booked_at;
alter table public.stock_movements rename column aangemaakt_door to created_by;
alter table public.stock_movements rename column aangemaakt_op to created_at;
alter table public.stock_movements rename column ingevoerde_hoeveelheid to entered_quantity;
alter table public.stock_movements rename column ingevoerde_eenheid to entered_unit;

-- View: usage count per ingredient.
alter view public.ingredient_gebruik_counts rename to ingredient_usage_counts;
alter view public.ingredient_usage_counts rename column aantal_recepten to recipe_count;

-- ---------------------------------------------------------------------------
-- 4. Check constraints and defaults with the English values.
-- ---------------------------------------------------------------------------
alter table public.ingredients add constraint ingredients_status_check check (status in ('draft','active','phasing_out'));
alter table public.ingredients add constraint ingredients_version_status_check check (version_status in ('current','archived'));
alter table public.ingredients alter column status set default 'active';
alter table public.ingredients alter column version_status set default 'current';
alter table public.ingredients rename constraint ingredients_houdbaarheid_eenheid_check to ingredients_shelf_life_unit_check;
alter table public.ingredients rename constraint ingredients_houdbaarheid_na_openen_eenheid_check to ingredients_shelf_life_after_opening_unit_check;
alter table public.ingredient_documents add constraint ingredient_documents_status_check check (status in ('active','archived'));
alter table public.ingredient_documents alter column status set default 'active';
alter table public.lots add constraint lots_status_check check (status in ('active','empty','closed'));
alter table public.lots alter column status set default 'active';
alter table public.stock_movements add constraint stock_movements_movement_type_check check (movement_type in ('receipt','reservation','consumption','correction'));

-- ---------------------------------------------------------------------------
-- 5. Who-columns point to public.users (were auth.users); no orphans found.
-- ---------------------------------------------------------------------------
alter table public.ingredients drop constraint ingredients_aangemaakt_door_fkey;
alter table public.ingredients drop constraint ingredients_gewijzigd_door_fkey;
alter table public.ingredients add constraint ingredients_created_by_fkey foreign key (created_by) references public.users(id);
alter table public.ingredients add constraint ingredients_updated_by_fkey foreign key (updated_by) references public.users(id);
alter table public.ingredient_documents drop constraint ingredient_documenten_geupload_door_fkey;
alter table public.ingredient_documents add constraint ingredient_documents_uploaded_by_fkey foreign key (uploaded_by) references public.users(id);

-- ---------------------------------------------------------------------------
-- 6. Constraint, index and sequence names follow the tables.
-- ---------------------------------------------------------------------------
alter table public.ingredient_declarations rename constraint ingredient_declaraties_pkey to ingredient_declarations_pkey;
alter table public.ingredient_declarations rename constraint ingredient_declaraties_naam_key to ingredient_declarations_name_key;
alter table public.ingredient_documents rename constraint ingredient_documenten_pkey to ingredient_documents_pkey;
alter table public.ingredient_documents rename constraint ingredient_documenten_document_type_id_fkey to ingredient_documents_document_type_id_fkey;
alter table public.ingredient_documents rename constraint ingredient_documenten_ingredient_id_fkey to ingredient_documents_ingredient_id_fkey;
alter table public.ingredient_documents rename constraint ingredient_documenten_storage_path_key to ingredient_documents_storage_path_key;
alter table public.ingredient_revisions rename constraint ingredient_revisies_pkey to ingredient_revisions_pkey;
alter table public.ingredient_revisions rename constraint ingredient_revisies_ingredient_id_fkey to ingredient_revisions_ingredient_id_fkey;
alter table public.ingredient_revisions rename constraint ingredient_revisies_gebruiker_id_fkey to ingredient_revisions_user_id_fkey;
alter table public.lots rename constraint grondstof_lots_pkey to lots_pkey;
alter table public.lots rename constraint grondstof_lots_ingredient_id_fkey to lots_ingredient_id_fkey;
alter table public.lots rename constraint grondstof_lots_aangemaakt_door_fkey to lots_created_by_fkey;
alter table public.lots rename constraint grondstof_lots_ontvangen_door_fkey to lots_received_by_fkey;
alter table public.stock_movements rename constraint voorraad_mutaties_pkey to stock_movements_pkey;
alter table public.stock_movements rename constraint voorraad_mutaties_lot_id_fkey to stock_movements_lot_id_fkey;
alter table public.stock_movements rename constraint voorraad_mutaties_batch_id_fkey to stock_movements_batch_id_fkey;
alter table public.stock_movements rename constraint voorraad_mutaties_recipe_ingredient_id_fkey to stock_movements_recipe_ingredient_id_fkey;
alter table public.stock_movements rename constraint voorraad_mutaties_aangemaakt_door_fkey to stock_movements_created_by_fkey;
alter table public.stock_movements rename constraint voorraad_mutaties_geboekt_door_fkey to stock_movements_booked_by_fkey;
alter index public.idx_grondstof_lots_ingredient rename to idx_lots_ingredient;
alter index public.idx_grondstof_lots_status rename to idx_lots_status;
alter index public.idx_ingredient_documenten_ing_status_type rename to idx_ingredient_documents_ing_status_type;
alter index public.idx_ingredient_documenten_ingredient_id rename to idx_ingredient_documents_ingredient_id;
alter index public.idx_ingredient_revisies_ingredient_id rename to idx_ingredient_revisions_ingredient_id;
alter index public.idx_voorraad_mutaties_batch rename to idx_stock_movements_batch;
alter index public.idx_voorraad_mutaties_lot rename to idx_stock_movements_lot;
alter index public.idx_voorraad_mutaties_type rename to idx_stock_movements_movement_type;
alter sequence public.grondstof_lots_id_seq rename to lots_id_seq;
alter sequence public.ingredient_documenten_id_seq rename to ingredient_documents_id_seq;
alter sequence public.ingredient_revisies_id_seq rename to ingredient_revisions_id_seq;
alter sequence public.voorraad_mutaties_id_seq rename to stock_movements_id_seq;

-- Policy names follow the tables.
alter policy grondstof_lots_select on public.lots rename to lots_select;
alter policy grondstof_lots_insert on public.lots rename to lots_insert;
alter policy grondstof_lots_update on public.lots rename to lots_update;
alter policy grondstof_lots_delete on public.lots rename to lots_delete;
alter policy ingredient_documenten_select on public.ingredient_documents rename to ingredient_documents_select;
alter policy ingredient_documenten_insert on public.ingredient_documents rename to ingredient_documents_insert;
alter policy ingredient_documenten_update on public.ingredient_documents rename to ingredient_documents_update;
alter policy ingredient_documenten_delete on public.ingredient_documents rename to ingredient_documents_delete;
alter policy ingredient_revisies_select on public.ingredient_revisions rename to ingredient_revisions_select;
alter policy ingredient_revisies_insert on public.ingredient_revisions rename to ingredient_revisions_insert;
alter policy ingredient_declaraties_select on public.ingredient_declarations rename to ingredient_declarations_select;
alter policy ingredient_declaraties_insert on public.ingredient_declarations rename to ingredient_declarations_insert;
alter policy ingredient_declaraties_update on public.ingredient_declarations rename to ingredient_declarations_update;
alter policy ingredient_declaraties_delete on public.ingredient_declarations rename to ingredient_declarations_delete;
alter policy voorraad_mutaties_select on public.stock_movements rename to stock_movements_select;
alter policy voorraad_mutaties_insert on public.stock_movements rename to stock_movements_insert;
alter policy voorraad_mutaties_update on public.stock_movements rename to stock_movements_update;
alter policy voorraad_mutaties_delete on public.stock_movements rename to stock_movements_delete;

-- ---------------------------------------------------------------------------
-- 7. Functions and triggers that use the renamed columns.
-- ---------------------------------------------------------------------------
-- Generic "touch updated_at" trigger function (recipes switch to it in step 8).
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger trg_ingredients_gewijzigd_op on public.ingredients;
drop function public.set_ingredients_gewijzigd_op();
create trigger trg_ingredients_updated_at before update on public.ingredients
  for each row execute function public.set_updated_at();

-- Product sheet hash: same output, only the two ingredient column names change
-- (verified before/after: identical hash for all product sheets).

create or replace function public.product_sheet_relevant_hash(p_recipe_group_id uuid)
returns text language sql stable as $function$
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
      select string_agg(coalesce(i.ingredient_declaration,'') || ':' || coalesce(i.allergens, '[]'::jsonb)::text, ',' order by i.id)
      from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
      where ri2.recipe_id = r.id
    ), '')
  )
  from recipes r
  left join recipe_specificaties s on s.recipe_id = r.id
  where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
$function$;
