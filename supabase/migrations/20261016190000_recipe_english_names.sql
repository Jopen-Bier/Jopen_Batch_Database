-- Architecture clean-up, step 8: domain "recipe" in English.
-- Mapping: supabase/rename-map.json (approved by Jaap, 16-10-2026).
-- Tables stay in schema public.
--
-- Run by hand in the SQL Editor; registered in
-- supabase_migrations.schema_migrations before the file was pushed.
-- One transaction: everything or nothing.

-- ---------------------------------------------------------------------------
-- 0. Remember which product sheets are in sync now. The sync hash includes
--    the addition type values (hoofdmout -> malt, ...), so the stored hash of
--    these sheets is recomputed at the end; the others stay out of sync.
-- ---------------------------------------------------------------------------
create temporary table _step8_in_sync on commit drop as
  select product_sheet_id from public.product_sheet_status where in_sync;

-- The "touch gewijzigd_op" trigger goes first, so the value updates below do
-- not change the last-modified time of every recipe. It comes back as
-- trg_recipes_updated_at in section 7.
drop trigger trg_recipes_gewijzigd_op on public.recipes;

-- ---------------------------------------------------------------------------
-- 1. Dropped columns (decisions Jaap 16-10).
-- ---------------------------------------------------------------------------
-- Planning/report code uses versie_major/minor; huidige_versie was a stale copy.
alter table public.recipes drop column huidige_versie;
alter table public.recipe_revisies drop column versienummer;
-- Empty copies (0 rows filled); recipe_brouwspecificaties is leading.
alter table public.recipe_water drop column maischwater;
alter table public.recipe_water drop column ph_maische;
alter table public.recipe_water drop column ph_start_koken;
alter table public.recipe_water drop column ph_eind_koken;
alter table public.recipe_water drop column beluchting;

-- ---------------------------------------------------------------------------
-- 2. Software recipe name: one column per brewhouse (a recipe can be brewed
--    in both). The existing value goes to the column of recipes.locatie.
-- ---------------------------------------------------------------------------
alter table public.recipe_brouwspecificaties add column brewhouse_recipe_name_wp text;
alter table public.recipe_brouwspecificaties add column brewhouse_recipe_name_jk text;
update public.recipe_brouwspecificaties b
   set brewhouse_recipe_name_wp = case when r.locatie = 'Waarderpolder' then b.recept_naam_software end,
       brewhouse_recipe_name_jk = case when r.locatie = 'Jopen Kerk'    then b.recept_naam_software end
  from public.recipes r
 where r.id = b.recipe_id and nullif(b.recept_naam_software, '') is not null;
-- Fails loudly if a filled name had no location (checked: none).
do $$ begin
  if exists (select 1 from public.recipe_brouwspecificaties
             where nullif(recept_naam_software, '') is not null
               and brewhouse_recipe_name_wp is null and brewhouse_recipe_name_jk is null) then
    raise exception 'recept_naam_software without location: not moved';
  end if;
end $$;
alter table public.recipe_brouwspecificaties drop column recept_naam_software;

-- ---------------------------------------------------------------------------
-- 3. Values in English (check constraints dropped, values updated,
--    constraints re-created under the new column names below).
-- ---------------------------------------------------------------------------
alter table public.recipes drop constraint recipes_status_check;
alter table public.recipes drop constraint recipes_locatie_check;
alter table public.recipe_ingredients drop constraint recipe_ingredients_rol_check;
alter table public.recipe_fermentatie drop constraint recipe_fermentatie_bier_risico_check;
alter table public.recipe_fermentatie drop constraint recipe_fermentatie_bier_status_check;
drop index public.product_sheets_recipe_group_id_actief_idx;

update public.recipes set status = case status when 'concept' then 'draft' when 'actief' then 'active' when 'gearchiveerd' then 'archived' else status end;
update public.recipes set locatie = case locatie when 'Waarderpolder' then 'wp' when 'Jopen Kerk' then 'jk' else locatie end;
update public.recipe_ingredients set rol = case rol
  when 'hoofdmout' then 'malt' when 'hopgift_kook' then 'boil_hop' when 'toegift_brouwerij' then 'brewhouse_addition'
  when 'toegift_kelder' then 'cellar_addition' when 'gist' then 'yeast' else rol end;
update public.recipe_fermentatie set bier_risico = case bier_risico
  when 'Standaard' then 'standard' when 'Gevaarlijk' then 'dangerous' when 'Suikerhoudend' then 'contains_sugar'
  when 'Gevoelig' then 'sensitive' else bier_risico end;
update public.recipe_fermentatie set bier_status = case bier_status
  when 'Standaard' then 'standard' when 'NPI' then 'npi' when 'Te verbeteren' then 'to_improve' else bier_status end;
update public.product_sheets set status = case status when 'actief' then 'active' when 'gearchiveerd' then 'archived' else status end;

-- ---------------------------------------------------------------------------
-- 4. Rename tables and columns.
-- ---------------------------------------------------------------------------
alter table public.recipes rename column naam to name;
alter table public.recipes rename column bierstijl to beer_style;
alter table public.recipes rename column locatie to location;
alter table public.recipes rename column versie_major to version_major;
alter table public.recipes rename column versie_minor to version_minor;
alter table public.recipes rename column aangemaakt_door to created_by;
alter table public.recipes rename column gewijzigd_door to updated_by;
alter table public.recipes rename column gewijzigd_op to updated_at;
alter table public.recipes rename column brouwsel_hl to brew_volume_hl;
alter table public.recipes rename column kleur to recipe_color;
alter table public.recipes rename column smaakomschrijving to flavor_description;
alter table public.recipes rename column smaak_keywords to flavor_keywords;
alter table public.recipes rename column aanbevolen_schenktemperatuur to serving_temperature;
alter table public.recipes rename column kleur_srm to color_srm;
alter table public.recipes rename column kleur_vrije_tekst to color_free_text;

alter table public.recipe_brouwspecificaties rename to recipe_brewing_specs;
alter table public.recipe_brewing_specs rename column kamers_mashfilter to mash_filter_chambers;
alter table public.recipe_brewing_specs rename column walsenmolen to roller_mill;
alter table public.recipe_brewing_specs rename column beslag_dikte to mash_thickness;
alter table public.recipe_brewing_specs rename column volume_kook to boil_volume;
alter table public.recipe_brewing_specs rename column wortvoorkoeler_temp to wort_precooler_temp;
alter table public.recipe_brewing_specs rename column eindvolume_brouwsel to brew_final_volume;
alter table public.recipe_brewing_specs rename column gewenste_verdamping to target_evaporation;
alter table public.recipe_brewing_specs rename column intensiteit_koken to boil_intensity;
alter table public.recipe_brewing_specs rename column whirlpool_rust to whirlpool_rest;
alter table public.recipe_brewing_specs rename column lauterfactor to lauter_factor;
alter table public.recipe_brewing_specs rename column stort_special_bin_kg to special_bin_load_kg;
alter table public.recipe_brewing_specs rename column naam_special_bin to special_bin_name;
alter table public.recipe_brewing_specs rename column mash_inmaischen_temp to mash_in_temp;
alter table public.recipe_brewing_specs rename column mash_inmaischen_tijd to mash_in_time;
alter table public.recipe_brewing_specs rename column mash_verhogen1_temp to mash_step1_temp;
alter table public.recipe_brewing_specs rename column mash_verhogen1_tijd to mash_step1_time;
alter table public.recipe_brewing_specs rename column mash_verhogen2_temp to mash_step2_temp;
alter table public.recipe_brewing_specs rename column mash_verhogen2_tijd to mash_step2_time;
alter table public.recipe_brewing_specs rename column mash_verhogen3_temp to mash_step3_temp;
alter table public.recipe_brewing_specs rename column mash_verhogen3_tijd to mash_step3_time;
alter table public.recipe_brewing_specs rename column mash_verhogen4_temp to mash_step4_temp;
alter table public.recipe_brewing_specs rename column mash_verhogen4_tijd to mash_step4_time;
alter table public.recipe_brewing_specs rename column mash_uitmaischen_temp to mash_out_temp;
alter table public.recipe_brewing_specs rename column mash_uitmaischen_tijd to mash_out_time;
alter table public.recipe_brewing_specs rename column cumm_sparging_vol to cumulative_sparge_volume;
alter table public.recipe_brewing_specs rename column verwacht_extract_begin_kook to expected_extract_boil_start;
alter table public.recipe_brewing_specs rename column volume_water_additie_terugkoeling to water_addition_volume_cooling;
alter table public.recipe_brewing_specs rename column sparging_1e to sparge_1;
alter table public.recipe_brewing_specs rename column sparging_2e to sparge_2;
alter table public.recipe_brewing_specs rename column sparging_3e to sparge_3;
alter table public.recipe_brewing_specs rename column sparging_4e to sparge_4;
alter table public.recipe_brewing_specs rename column eerste_afloop to first_wort;
alter table public.recipe_brewing_specs rename column spoelwater to sparge_water;
alter table public.recipe_brewing_specs rename column spoel_afloop to sparge_runoff;
alter table public.recipe_brewing_specs rename column totaal_gefiltreerd_volume to total_lautered_volume;
alter table public.recipe_brewing_specs rename column inmaischen_zuur_l to mash_in_acid_l;
alter table public.recipe_brewing_specs rename column inmaischen_tannines_l to mash_in_tannins_l;
alter table public.recipe_brewing_specs rename column koken_zuur_l to boil_acid_l;
alter table public.recipe_brewing_specs rename column inline_sparge_zuur_l to inline_sparge_acid_l;
alter table public.recipe_brewing_specs rename column maischwater to mash_water;
alter table public.recipe_brewing_specs rename column ph_maische to ph_mash;
alter table public.recipe_brewing_specs rename column ph_start_koken to ph_boil_start;
alter table public.recipe_brewing_specs rename column ph_eind_koken to ph_boil_end;
alter table public.recipe_brewing_specs rename column beluchting to aeration;
alter table public.recipe_brewing_specs rename column stamwort_correctie_brouwhuis to original_gravity_correction_brewhouse;


alter table public.recipe_fermentatie rename to recipe_fermentation;
alter table public.recipe_fermentation rename column t_release to release_temp;
alter table public.recipe_fermentation rename column temp_dry_warm to dry_hop_warm_temp;
alter table public.recipe_fermentation rename column extract_dry_warm_1 to dry_hop_warm_extract_1;
alter table public.recipe_fermentation rename column extract_dry_warm_2 to dry_hop_warm_extract_2;
alter table public.recipe_fermentation rename column extract_dry_warm_3 to dry_hop_warm_extract_3;
alter table public.recipe_fermentation rename column vergistingstijd to fermentation_time;
alter table public.recipe_fermentation rename column lagertijd to lagering_time;
alter table public.recipe_fermentation rename column lager_temp to lagering_temp;
alter table public.recipe_fermentation rename column pasteurisatie to pasteurization;
alter table public.recipe_fermentation rename column troebeling_na_sep to turbidity_after_separation;
alter table public.recipe_fermentation rename column bier_risico to beer_risk;
alter table public.recipe_fermentation rename column bier_status to beer_status;
alter table public.recipe_fermentation rename column t_release_tol to release_temp_tol;
alter table public.recipe_fermentation rename column temp_dry_warm_tol to dry_hop_warm_temp_tol;
alter table public.recipe_fermentation rename column extract_dry_warm_1_tol to dry_hop_warm_extract_1_tol;
alter table public.recipe_fermentation rename column extract_dry_warm_2_tol to dry_hop_warm_extract_2_tol;
alter table public.recipe_fermentation rename column extract_dry_warm_3_tol to dry_hop_warm_extract_3_tol;
alter table public.recipe_fermentation rename column vergistingstijd_tol to fermentation_time_tol;
alter table public.recipe_fermentation rename column lagertijd_tol to lagering_time_tol;
alter table public.recipe_fermentation rename column lager_temp_tol to lagering_temp_tol;
alter table public.recipe_fermentation rename column pasteurisatie_tol to pasteurization_tol;
alter table public.recipe_fermentation rename column troebeling_na_sep_tol to turbidity_after_separation_tol;
alter table public.recipe_fermentation rename column bitterheid_bh to bitterness_brewhouse;
alter table public.recipe_fermentation rename column bitterheid_bh_tol to bitterness_brewhouse_tol;

alter table public.recipe_ingredients rename column rol to addition_type;
alter table public.recipe_ingredients rename column hoeveelheid to quantity;
alter table public.recipe_ingredients rename column eenheid to unit;
alter table public.recipe_ingredients rename column tijdstip to timing;
alter table public.recipe_ingredients rename column volgorde to sort_order;
alter table public.recipe_ingredients rename column notitie to note;
alter table public.recipe_ingredients rename column hdt to hop_dosing_tank;
alter table public.recipe_ingredients rename column kleur_ebc to color_ebc;
alter table public.recipe_ingredients rename column alles_in_brouwsel_1 to all_in_first_brew;

alter table public.recipe_kosten rename to recipe_costs;
alter table public.recipe_costs rename column cost_clr_per_kge to cost_cellar_per_kge;
alter table public.recipe_costs rename column cost_bh_per_kge to cost_brewhouse_per_kge;
alter table public.recipe_costs rename column cost_grondstoffen_hl to cost_ingredients_per_hl;
alter table public.recipe_costs rename column bierverlies_pct to beer_loss_pct;

alter table public.recipe_processtappen rename to recipe_process_steps;
alter table public.recipe_process_steps rename column keldersplitsing to cellar_split;
alter table public.recipe_process_steps rename column dry_hop_methode_warm to dry_hop_method_warm;
alter table public.recipe_process_steps rename column dry_hop_methode_16c to dry_hop_method_16c;
alter table public.recipe_process_steps rename column dry_hop_1_dag to dry_hop_1_day;
alter table public.recipe_process_steps rename column dry_hop_2_dag to dry_hop_2_day;
alter table public.recipe_process_steps rename column kelder_toevoeging_dag to cellar_addition_day;
alter table public.recipe_process_steps rename column comment_verwerken to processing_comment;

alter table public.recipe_revisies rename to recipe_revisions;
alter table public.recipe_revisions rename column datum to date;
alter table public.recipe_revisions rename column door to changed_by_name;
alter table public.recipe_revisions rename column wijziging to change_description;
alter table public.recipe_revisions rename column versie_major to version_major;
alter table public.recipe_revisions rename column versie_minor to version_minor;
alter table public.recipe_revisions rename column gebruiker_id to user_id;

alter table public.recipe_specificaties rename to recipe_specs;
alter table public.recipe_specs rename column origineel_extract to original_extract;
alter table public.recipe_specs rename column rest_extract to final_extract;
alter table public.recipe_specs rename column bitterheid to bitterness;
alter table public.recipe_specs rename column kleur to color;
alter table public.recipe_specs rename column troebeling_lab to turbidity_lab;
alter table public.recipe_specs rename column co2_fles to co2_bottle;
alter table public.recipe_specs rename column co2_fust to co2_keg;
alter table public.recipe_specs rename column origineel_extract_tol to original_extract_tol;
alter table public.recipe_specs rename column rest_extract_tol to final_extract_tol;
alter table public.recipe_specs rename column bitterheid_tol to bitterness_tol;
alter table public.recipe_specs rename column kleur_tol to color_tol;
alter table public.recipe_specs rename column troebeling_lab_tol to turbidity_lab_tol;
alter table public.recipe_specs rename column co2_fles_tol to co2_bottle_tol;
alter table public.recipe_specs rename column co2_fust_tol to co2_keg_tol;

alter table public.recipe_verpakking rename to recipe_packaging;
alter table public.recipe_packaging rename column ean_fles to ean_bottle;
alter table public.recipe_packaging rename column tht_fles_maanden to best_before_bottle_months;
alter table public.recipe_packaging rename column tht_vat_maanden to best_before_keg_months;
alter table public.recipe_packaging rename column tht_blik_maanden to best_before_can_months;
alter table public.recipe_packaging rename column alc_pct to abv_pct;
alter table public.recipe_packaging rename column formaten to formats;
alter table public.recipe_packaging rename column co2_fles_can_spec to co2_bottle_can_spec;
alter table public.recipe_packaging rename column co2_fles_can_tolerantie to co2_bottle_can_tolerance;
alter table public.recipe_packaging rename column co2_fust_spec to co2_keg_spec;
alter table public.recipe_packaging rename column co2_fust_tolerantie to co2_keg_tolerance;
alter table public.recipe_packaging rename column zuurstof_fust_spec to o2_keg_spec;


alter table public.product_sheets rename column huidige_versie to current_version;
alter table public.product_sheets rename column vat_gerijpt_hl to barrel_aged_hl;
alter table public.product_sheets rename column vat_type to barrel_type;
alter table public.product_sheets rename column vat_dagen to barrel_days;
alter table public.product_sheets rename column energie_kj to energy_kj;
alter table public.product_sheets rename column energie_kcal to energy_kcal;
alter table public.product_sheets rename column vet_g to fat_g;
alter table public.product_sheets rename column koolhydraten_g to carbohydrates_g;
alter table public.product_sheets rename column eiwit_g to protein_g;
alter table public.product_sheets rename column zout_g to salt_g;
alter table public.product_sheets rename column opmerkingen to remarks;
alter table public.product_sheets rename column bijgewerkt_obv_versie_major to based_on_version_major;
alter table public.product_sheets rename column bijgewerkt_obv_versie_minor to based_on_version_minor;
alter table public.product_sheets rename column bijgewerkt_op to updated_at;
alter table public.product_sheets rename column bijgewerkt_door to updated_by;
alter table public.product_sheets rename column aangemaakt_op to created_at;
alter table public.product_sheets rename column aangemaakt_door to created_by;

alter table public.product_sheet_revisies rename to product_sheet_revisions;
alter table public.product_sheet_revisions rename column versie to version;
alter table public.product_sheet_revisions rename column recipe_versie_major to recipe_version_major;
alter table public.product_sheet_revisions rename column recipe_versie_minor to recipe_version_minor;
alter table public.product_sheet_revisions rename column datum to date;
alter table public.product_sheet_revisions rename column door to changed_by_name;
alter table public.product_sheet_revisions rename column wijzigingen to change_description;

alter table public.hop_utilisatie_curve rename to hop_utilization_curve;
alter table public.hop_utilization_curve rename column kooktijd_min to boil_time_min;
alter table public.hop_utilization_curve rename column rendement_pct to utilization_pct;

alter table public.water_instellingen rename to water_settings;
alter table public.water_settings rename column omschrijving to description;
alter table public.water_settings rename column gemeten_op to measured_on;
alter table public.water_settings rename column gewijzigd_op to updated_at;
alter table public.water_settings rename column gewijzigd_door to updated_by;

alter table public.water_instellingen_historie rename to water_settings_history;
alter table public.water_settings_history rename column geldig_vanaf to valid_from;
alter table public.water_settings_history rename column gewijzigd_door to updated_by;
alter table public.water_settings_history rename column gegevens to data;

-- View: output columns in English (definition rewritten in section 7).

alter view public.product_sheet_status rename column huidige_versie to current_version;
alter view public.product_sheet_status rename column bijgewerkt_op to updated_at;
alter view public.product_sheet_status rename column bijgewerkt_obv_versie_major to based_on_version_major;
alter view public.product_sheet_status rename column bijgewerkt_obv_versie_minor to based_on_version_minor;
alter view public.product_sheet_status rename column opgeslagen_hash to stored_hash;
alter view public.product_sheet_status rename column huidige_hash to current_hash;

-- ---------------------------------------------------------------------------
-- 5. Check constraints, defaults and the partial index with English values.
-- ---------------------------------------------------------------------------
alter table public.recipes add constraint recipes_status_check check (status in ('draft','active','archived'));
alter table public.recipes add constraint recipes_location_check check (location in ('wp','jk'));
alter table public.recipes alter column status set default 'active';
alter table public.recipe_ingredients add constraint recipe_ingredients_addition_type_check
  check (addition_type in ('malt','boil_hop','dry_hop','brewhouse_addition','cellar_addition','yeast'));
alter table public.recipe_fermentation add constraint recipe_fermentation_beer_risk_check
  check (beer_risk is null or beer_risk in ('standard','dangerous','contains_sugar','sensitive'));
alter table public.recipe_fermentation add constraint recipe_fermentation_beer_status_check
  check (beer_status is null or beer_status in ('standard','npi','to_improve'));
alter table public.product_sheets add constraint product_sheets_status_check check (status in ('active','archived'));
alter table public.product_sheets alter column status set default 'active';
create unique index product_sheets_recipe_group_id_active_idx on public.product_sheets (recipe_group_id) where status <> 'archived';

-- ---------------------------------------------------------------------------
-- 6. Who-columns point to public.users (were auth.users); no orphans found.
--    Constraint, index, sequence and policy names follow the tables.
-- ---------------------------------------------------------------------------
alter table public.recipes drop constraint recipes_aangemaakt_door_fkey;
alter table public.recipes drop constraint recipes_gewijzigd_door_fkey;
alter table public.recipes add constraint recipes_created_by_fkey foreign key (created_by) references public.users(id);
alter table public.recipes add constraint recipes_updated_by_fkey foreign key (updated_by) references public.users(id);
alter table public.product_sheets drop constraint product_sheets_aangemaakt_door_fkey;
alter table public.product_sheets drop constraint product_sheets_bijgewerkt_door_fkey;
alter table public.product_sheets add constraint product_sheets_created_by_fkey foreign key (created_by) references public.users(id);
alter table public.product_sheets add constraint product_sheets_updated_by_fkey foreign key (updated_by) references public.users(id);
alter table public.recipe_revisions drop constraint recipe_revisies_gebruiker_id_fkey;
alter table public.recipe_revisions add constraint recipe_revisions_user_id_fkey foreign key (user_id) references public.users(id);

alter table public.recipe_brewing_specs rename constraint recipe_brouwspecificaties_pkey to recipe_brewing_specs_pkey;
alter table public.recipe_brewing_specs rename constraint recipe_brouwspecificaties_recipe_id_fkey to recipe_brewing_specs_recipe_id_fkey;
alter table public.recipe_fermentation rename constraint recipe_fermentatie_pkey to recipe_fermentation_pkey;
alter table public.recipe_fermentation rename constraint recipe_fermentatie_recipe_id_fkey to recipe_fermentation_recipe_id_fkey;
alter table public.recipe_costs rename constraint recipe_kosten_pkey to recipe_costs_pkey;
alter table public.recipe_costs rename constraint recipe_kosten_recipe_id_fkey to recipe_costs_recipe_id_fkey;
alter table public.recipe_process_steps rename constraint recipe_processtappen_pkey to recipe_process_steps_pkey;
alter table public.recipe_process_steps rename constraint recipe_processtappen_recipe_id_fkey to recipe_process_steps_recipe_id_fkey;
alter table public.recipe_revisions rename constraint recipe_revisies_pkey to recipe_revisions_pkey;
alter table public.recipe_revisions rename constraint recipe_revisies_recipe_id_fkey to recipe_revisions_recipe_id_fkey;
alter table public.recipe_specs rename constraint recipe_specificaties_pkey to recipe_specs_pkey;
alter table public.recipe_specs rename constraint recipe_specificaties_recipe_id_fkey to recipe_specs_recipe_id_fkey;
alter table public.recipe_packaging rename constraint recipe_verpakking_pkey to recipe_packaging_pkey;
alter table public.recipe_packaging rename constraint recipe_verpakking_recipe_id_fkey to recipe_packaging_recipe_id_fkey;
alter table public.product_sheet_revisions rename constraint product_sheet_revisies_pkey to product_sheet_revisions_pkey;
alter table public.product_sheet_revisions rename constraint product_sheet_revisies_product_sheet_id_fkey to product_sheet_revisions_product_sheet_id_fkey;
alter table public.hop_utilization_curve rename constraint hop_utilisatie_curve_pkey to hop_utilization_curve_pkey;
alter table public.water_settings rename constraint water_instellingen_pkey to water_settings_pkey;
alter table public.water_settings rename constraint water_instellingen_id_check to water_settings_id_check;
alter table public.water_settings rename constraint water_instellingen_gewijzigd_door_fkey to water_settings_updated_by_fkey;
alter table public.water_settings_history rename constraint water_instellingen_historie_pkey to water_settings_history_pkey;
alter table public.water_settings_history rename constraint water_instellingen_historie_gewijzigd_door_fkey to water_settings_history_updated_by_fkey;
alter index public.product_sheet_revisies_product_sheet_id_idx rename to product_sheet_revisions_product_sheet_id_idx;
alter sequence public.product_sheet_revisies_id_seq rename to product_sheet_revisions_id_seq;
alter sequence public.recipe_revisies_id_seq rename to recipe_revisions_id_seq;
alter sequence public.water_instellingen_historie_id_seq rename to water_settings_history_id_seq;

alter policy recipe_brouwspecificaties_select on public.recipe_brewing_specs rename to recipe_brewing_specs_select;
alter policy recipe_brouwspecificaties_insert on public.recipe_brewing_specs rename to recipe_brewing_specs_insert;
alter policy recipe_brouwspecificaties_update on public.recipe_brewing_specs rename to recipe_brewing_specs_update;
alter policy recipe_brouwspecificaties_delete on public.recipe_brewing_specs rename to recipe_brewing_specs_delete;
alter policy recipe_fermentatie_select on public.recipe_fermentation rename to recipe_fermentation_select;
alter policy recipe_fermentatie_insert on public.recipe_fermentation rename to recipe_fermentation_insert;
alter policy recipe_fermentatie_update on public.recipe_fermentation rename to recipe_fermentation_update;
alter policy recipe_fermentatie_delete on public.recipe_fermentation rename to recipe_fermentation_delete;
alter policy recipe_kosten_select on public.recipe_costs rename to recipe_costs_select;
alter policy recipe_kosten_insert on public.recipe_costs rename to recipe_costs_insert;
alter policy recipe_kosten_update on public.recipe_costs rename to recipe_costs_update;
alter policy recipe_kosten_delete on public.recipe_costs rename to recipe_costs_delete;
alter policy recipe_processtappen_select on public.recipe_process_steps rename to recipe_process_steps_select;
alter policy recipe_processtappen_insert on public.recipe_process_steps rename to recipe_process_steps_insert;
alter policy recipe_processtappen_update on public.recipe_process_steps rename to recipe_process_steps_update;
alter policy recipe_processtappen_delete on public.recipe_process_steps rename to recipe_process_steps_delete;
alter policy recipe_revisies_select on public.recipe_revisions rename to recipe_revisions_select;
alter policy recipe_revisies_insert on public.recipe_revisions rename to recipe_revisions_insert;
alter policy recipe_revisies_update on public.recipe_revisions rename to recipe_revisions_update;
alter policy recipe_revisies_delete on public.recipe_revisions rename to recipe_revisions_delete;
alter policy recipe_specificaties_select on public.recipe_specs rename to recipe_specs_select;
alter policy recipe_specificaties_insert on public.recipe_specs rename to recipe_specs_insert;
alter policy recipe_specificaties_update on public.recipe_specs rename to recipe_specs_update;
alter policy recipe_specificaties_delete on public.recipe_specs rename to recipe_specs_delete;
alter policy recipe_verpakking_select on public.recipe_packaging rename to recipe_packaging_select;
alter policy recipe_verpakking_insert on public.recipe_packaging rename to recipe_packaging_insert;
alter policy recipe_verpakking_update on public.recipe_packaging rename to recipe_packaging_update;
alter policy recipe_verpakking_delete on public.recipe_packaging rename to recipe_packaging_delete;
alter policy product_sheet_revisies_select on public.product_sheet_revisions rename to product_sheet_revisions_select;
alter policy product_sheet_revisies_insert on public.product_sheet_revisions rename to product_sheet_revisions_insert;
alter policy hop_utilisatie_curve_select on public.hop_utilization_curve rename to hop_utilization_curve_select;
alter policy hop_utilisatie_curve_insert on public.hop_utilization_curve rename to hop_utilization_curve_insert;
alter policy hop_utilisatie_curve_update on public.hop_utilization_curve rename to hop_utilization_curve_update;
alter policy hop_utilisatie_curve_delete on public.hop_utilization_curve rename to hop_utilization_curve_delete;
alter policy water_instellingen_select on public.water_settings rename to water_settings_select;
alter policy water_instellingen_update on public.water_settings rename to water_settings_update;
alter policy water_instellingen_historie_select on public.water_settings_history rename to water_settings_history_select;

-- ---------------------------------------------------------------------------
-- 7. Functions, triggers and the sync view on the new names.
-- ---------------------------------------------------------------------------
-- (trg_recipes_gewijzigd_op was dropped in section 1.)
drop function public.set_gewijzigd_op();
create trigger trg_recipes_updated_at before update on public.recipes
  for each row execute function public.set_updated_at();

drop trigger trg_water_instellingen_stempel on public.water_settings;
drop trigger trg_water_instellingen_log on public.water_settings;
alter function public.water_instellingen_stempel() rename to water_settings_stamp;
alter function public.water_instellingen_log() rename to water_settings_log;
create or replace function public.water_settings_stamp()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
create or replace function public.water_settings_log()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into water_settings_history (valid_from, updated_by, data)
    values (new.updated_at, new.updated_by, to_jsonb(new));
  return new;
end;
$$;
create trigger trg_water_settings_stamp before update on public.water_settings
  for each row execute function public.water_settings_stamp();
create trigger trg_water_settings_log after insert or update on public.water_settings
  for each row execute function public.water_settings_log();

-- Existing history rows: JSON keys follow the column names.
update public.water_settings_history h
   set data = (select jsonb_object_agg(coalesce(k.new_key, e.key), e.value)
                 from jsonb_each(h.data) e
                 left join (values ('omschrijving','description'), ('gemeten_op','measured_on'),
                                   ('gewijzigd_op','updated_at'), ('gewijzigd_door','updated_by')) k(old_key, new_key)
                   on k.old_key = e.key)
 where h.data is not null;

create or replace function public.product_sheet_relevant_recipe_id(p_recipe_group_id uuid)
returns bigint language sql stable as $function$
  select id from recipes
  where recipe_group_id = p_recipe_group_id
  order by version_major desc, version_minor desc
  limit 1
$function$;

create or replace function public.product_sheet_calculated_color(p_recipe_id bigint)
returns numeric language sql stable as $function$
  select round(
    coalesce(sum(ri.quantity * ri.color_ebc * 0.08), 0) / nullif(r.brew_volume_hl, 0) + 1.75
  , 2)
  from recipes r
  left join recipe_ingredients ri on ri.recipe_id = r.id and ri.addition_type = 'malt'
  where r.id = p_recipe_id
  group by r.brew_volume_hl
$function$;

create or replace function public.product_sheet_relevant_hash(p_recipe_group_id uuid)
returns text language sql stable as $function$
  select md5(
    coalesce(s.original_extract::text,'') || '|' || coalesce(s.original_extract_tol,'') || '|' ||
    coalesce(s.final_extract::text,'') || '|' || coalesce(s.final_extract_tol,'') || '|' ||
    coalesce(s.alcohol::text,'') || '|' || coalesce(s.alcohol_tol,'') || '|' ||
    coalesce(s.bitterness::text,'') || '|' || coalesce(s.bitterness_tol,'') || '|' ||
    coalesce(product_sheet_calculated_color(r.id)::text,'') || '|' || coalesce(s.color_tol,'') || '|' ||
    coalesce(s.ph::text,'') || '|' || coalesce(s.ph_tol,'') || '|' ||
    coalesce(s.turbidity_lab::text,'') || '|' || coalesce(s.turbidity_lab_tol,'') || '|' ||
    coalesce(s.co2_bottle::text,'') || '|' || coalesce(s.co2_bottle_tol,'') || '|' ||
    coalesce(s.co2_can::text,'') || '|' || coalesce(s.co2_can_tol,'') || '|' ||
    coalesce(s.co2_keg::text,'') || '|' || coalesce(s.co2_keg_tol,'') || '|' ||
    coalesce(s.headspace_o2::text,'') || '|' || coalesce(s.headspace_o2_tol,'') || '|' ||
    coalesce(s.dissolved_o2::text,'') || '|' || coalesce(s.dissolved_o2_tol,'') || '|' ||
    coalesce(r.flavor_description,'') || '|' ||
    coalesce(array_to_string(r.flavor_keywords, ','),'') || '|' ||
    coalesce(r.color_free_text,'') || '|' ||
    coalesce(r.serving_temperature::text,'') || '|' ||
    coalesce((
      select string_agg(ri.ingredient_id::text || ':' || coalesce(ri.quantity::text,'') || ':' || coalesce(ri.unit,'') || ':' || ri.addition_type, ',' order by ri.ingredient_id, ri.addition_type)
      from recipe_ingredients ri where ri.recipe_id = r.id
    ), '') || '|' ||
    coalesce((
      select string_agg(coalesce(i.ingredient_declaration,'') || ':' || coalesce(i.allergens, '[]'::jsonb)::text, ',' order by i.id)
      from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
      where ri2.recipe_id = r.id
    ), '')
  )
  from recipes r
  left join recipe_specs s on s.recipe_id = r.id
  where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
$function$;

create or replace view public.product_sheet_status with (security_invoker = true) as
  select ps.id as product_sheet_id,
         ps.recipe_group_id,
         ps.status,
         ps.current_version,
         ps.updated_at,
         ps.based_on_version_major,
         ps.based_on_version_minor,
         ps.sync_snapshot ->> 'hash' as stored_hash,
         product_sheet_relevant_hash(ps.recipe_group_id) as current_hash,
         coalesce((ps.sync_snapshot ->> 'hash') = product_sheet_relevant_hash(ps.recipe_group_id), false) as in_sync
    from public.product_sheets ps
   where ps.status <> 'archived';

-- ---------------------------------------------------------------------------
-- 8. Product sheet sync snapshots: JSON keys in English (as written by
--    productsheet-vullen.js from now on), and a fresh hash for the sheets
--    that were in sync before this script.
-- ---------------------------------------------------------------------------
update public.product_sheets p
   set sync_snapshot = (select jsonb_object_agg(coalesce(k.new_key, e.key), e.value)
                          from jsonb_each(p.sync_snapshot) e
                          left join (values
                            ('origineel_extract','original_extract'),
                            ('origineel_extract_tol','original_extract_tol'),
                            ('rest_extract','final_extract'),
                            ('rest_extract_tol','final_extract_tol'),
                            ('bitterheid','bitterness'),
                            ('bitterheid_tol','bitterness_tol'),
                            ('kleur_ebc','color_ebc'),
                            ('kleur_tol','color_tol'),
                            ('troebeling_lab','turbidity_lab'),
                            ('troebeling_lab_tol','turbidity_lab_tol'),
                            ('co2_fles','co2_bottle'),
                            ('co2_fles_tol','co2_bottle_tol'),
                            ('co2_fust','co2_keg'),
                            ('co2_fust_tol','co2_keg_tol'),
                            ('smaakomschrijving','flavor_description'),
                            ('smaak_keywords','flavor_keywords'),
                            ('kleur_vrije_tekst','color_free_text'),
                            ('aanbevolen_schenktemperatuur','serving_temperature'),
                            ('allergenen_tekst','allergens_text'),
                            ('ingredienten_malt_label','ingredients_malt_label'),
                            ('ingredienten_hop_label','ingredients_hop_label'),
                            ('ingredienten_additief_label','ingredients_additive_label'),
                            ('ingredienten_gist_label','ingredients_yeast_label')
                          ) k(old_key, new_key) on k.old_key = e.key)
 where p.sync_snapshot is not null;

update public.product_sheets p
   set sync_snapshot = jsonb_set(p.sync_snapshot, '{hash}', to_jsonb(public.product_sheet_relevant_hash(p.recipe_group_id)))
 where p.id in (select product_sheet_id from _step8_in_sync);

-- Fails loudly if the in-sync set changed.
do $$ begin
  if (select count(*) from public.product_sheet_status where in_sync)
     <> (select count(*) from _step8_in_sync) then
    raise exception 'product sheet in-sync count changed';
  end if;
end $$;
