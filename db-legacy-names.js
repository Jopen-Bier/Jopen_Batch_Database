// ============================================================================
// db-legacy-names.js — translation layer between old (Dutch) JS property
// names and the English database columns, for code that has not been
// translated yet. GENERATED from supabase/rename-map.json — do not edit by hand.
//
// Reading: queries alias columns in the select string (`naam:name`), so the
// page keeps receiving the old property names.
// Writing: wrap a payload with toDb('<table>', row) to rename its keys.
// Reading whole rows (select('*')): fromDb('<table>', row) renames the
// English keys back to the old ones (columns without an old name keep
// their English key).
//
//   supabaseClient.from('ingredients').update(toDb('ingredients', basis))
//   const legacyRow = fromDb('recipes', data)
//   supabaseClient.from('recipes').select('*').then(r => fromDbResult('recipes', r))
//
// When a page is translated to English, its toDb()/alias use goes away.
// Domains covered: inventory, recipe, production.
// ============================================================================

const DB_LEGACY_COLUMNS = {
  "batches": {
    "aangemaakt_door": "created_by",
    "aangemaakt_op": "created_at",
    "aantal_brouwsels": "brew_count",
    "batchnummer": "batch_number",
    "bitterheid": "bitterness",
    "brouwdatum": "brew_date",
    "datum_orderpicken": "order_picking_date",
    "gist_bij_1e_brouwsel": "yeast_with_first_brew",
    "gist_door": "yeast_pitched_by",
    "gist_geent_op": "yeast_pitched_on",
    "gist_gerehydrateerd": "yeast_rehydrated",
    "gist_gewicht": "yeast_weight",
    "gist_programma_aan": "yeast_program_on",
    "gist_temp_max": "yeast_temp_max",
    "gist_temp_start": "yeast_temp_start",
    "giststam": "yeast_strain",
    "glt_leeg": "glt_empty",
    "kleur": "color",
    "naam": "name",
    "totaal_eindvolume": "total_final_volume"
  },
  "brew_capacity": {
    "max_brouwsels": "max_brews"
  },
  "brew_planning": {
    "aangemaakt_door": "created_by",
    "aangemaakt_op": "created_at",
    "aantal_brouwsels": "brew_count",
    "bijgewerkt_op": "updated_at",
    "notities": "notes",
    "prio": "is_priority"
  },
  "brew_planning_history": {
    "actie": "action",
    "gewijzigd_door": "updated_by",
    "gewijzigd_op": "updated_at",
    "na": "after",
    "voor": "before"
  },
  "brew_planning_splits": {
    "aangemaakt_op": "created_at"
  },
  "ingredient_categories": {
    "uses_gistfactor": "uses_yeast_factor"
  },
  "ingredient_declarations": {
    "aangemaakt_op": "created_at",
    "is_geen_declaratie": "not_declarable",
    "naam": "name"
  },
  "ingredient_documents": {
    "bestandsnaam": "file_name",
    "geupload_door": "uploaded_by",
    "geupload_op": "uploaded_at",
    "grootte_bytes": "size_bytes",
    "revisiedatum": "revision_date"
  },
  "ingredient_revisions": {
    "aangemaakt_op": "created_at",
    "datum": "date",
    "door": "changed_by_name",
    "gebruiker_id": "user_id",
    "versie_major": "version_major",
    "versie_minor": "version_minor",
    "wijziging": "change_description"
  },
  "ingredients": {
    "aangemaakt_door": "created_by",
    "aangemaakt_op": "created_at",
    "allergenen": "allergens",
    "bewaartemperatuur": "storage_temperature",
    "dichtheid": "density",
    "eenheid": "unit",
    "eenheid_prijs_1": "price_unit_1",
    "eenheid_prijs_2": "price_unit_2",
    "eenheid_prijs_3": "price_unit_3",
    "gewijzigd_door": "updated_by",
    "gewijzigd_op": "updated_at",
    "gistfactor": "yeast_factor",
    "houdbaarheid": "shelf_life",
    "houdbaarheid_eenheid": "shelf_life_unit",
    "houdbaarheid_na_openen": "shelf_life_after_opening",
    "houdbaarheid_na_openen_eenheid": "shelf_life_after_opening_unit",
    "ingredient_declaratie": "ingredient_declaration",
    "kleur_ebc": "color_ebc",
    "leverancier": "supplier",
    "leverancier_2": "supplier_2",
    "leverancier_3": "supplier_3",
    "minimum_voorraad": "minimum_stock",
    "naam": "name",
    "prijs": "price",
    "prijs_2": "price_2",
    "prijs_3": "price_3",
    "prijs_per_kg": "price_per_kg",
    "prijs_per_kg_2": "price_per_kg_2",
    "prijs_per_kg_3": "price_per_kg_3",
    "versie_major": "version_major",
    "versie_minor": "version_minor",
    "versie_status": "version_status"
  },
  "lots": {
    "aangemaakt_door": "created_by",
    "aangemaakt_op": "created_at",
    "aantal_colli": "package_count",
    "document_pad": "document_path",
    "eenheid": "unit",
    "hoeveelheid_ontvangen": "quantity_received",
    "ingangscontrole": "incoming_inspection",
    "leverancier": "supplier",
    "locatie": "location",
    "lotcode": "lot_code",
    "notitie": "note",
    "ontvangen_door": "received_by",
    "ontvangstcontrole": "receiving_check",
    "ontvangstdatum": "received_date",
    "tht_datum": "best_before_date"
  },
  "product_sheet_revisions": {
    "datum": "date",
    "door": "changed_by_name",
    "recipe_versie_major": "recipe_version_major",
    "recipe_versie_minor": "recipe_version_minor",
    "versie": "version",
    "wijzigingen": "change_description"
  },
  "product_sheets": {
    "aangemaakt_door": "created_by",
    "aangemaakt_op": "created_at",
    "bijgewerkt_door": "updated_by",
    "bijgewerkt_obv_versie_major": "based_on_version_major",
    "bijgewerkt_obv_versie_minor": "based_on_version_minor",
    "bijgewerkt_op": "updated_at",
    "eiwit_g": "protein_g",
    "energie_kcal": "energy_kcal",
    "energie_kj": "energy_kj",
    "huidige_versie": "current_version",
    "koolhydraten_g": "carbohydrates_g",
    "opmerkingen": "remarks",
    "vat_dagen": "barrel_days",
    "vat_gerijpt_hl": "barrel_aged_hl",
    "vat_type": "barrel_type",
    "vet_g": "fat_g",
    "zout_g": "salt_g"
  },
  "recipe_brewing_specs": {
    "beluchting": "aeration",
    "beslag_dikte": "mash_thickness",
    "cumm_sparging_vol": "cumulative_sparge_volume",
    "eerste_afloop": "first_wort",
    "eindvolume_brouwsel": "brew_final_volume",
    "gewenste_verdamping": "target_evaporation",
    "inline_sparge_zuur_l": "inline_sparge_acid_l",
    "inmaischen_tannines_l": "mash_in_tannins_l",
    "inmaischen_zuur_l": "mash_in_acid_l",
    "intensiteit_koken": "boil_intensity",
    "kamers_mashfilter": "mash_filter_chambers",
    "koken_zuur_l": "boil_acid_l",
    "lauterfactor": "lauter_factor",
    "maischwater": "mash_water",
    "mash_inmaischen_temp": "mash_in_temp",
    "mash_inmaischen_tijd": "mash_in_time",
    "mash_uitmaischen_temp": "mash_out_temp",
    "mash_uitmaischen_tijd": "mash_out_time",
    "mash_verhogen1_temp": "mash_step1_temp",
    "mash_verhogen1_tijd": "mash_step1_time",
    "mash_verhogen2_temp": "mash_step2_temp",
    "mash_verhogen2_tijd": "mash_step2_time",
    "mash_verhogen3_temp": "mash_step3_temp",
    "mash_verhogen3_tijd": "mash_step3_time",
    "mash_verhogen4_temp": "mash_step4_temp",
    "mash_verhogen4_tijd": "mash_step4_time",
    "naam_special_bin": "special_bin_name",
    "ph_eind_koken": "ph_boil_end",
    "ph_maische": "ph_mash",
    "ph_start_koken": "ph_boil_start",
    "sparging_1e": "sparge_1",
    "sparging_2e": "sparge_2",
    "sparging_3e": "sparge_3",
    "sparging_4e": "sparge_4",
    "spoel_afloop": "sparge_runoff",
    "spoelwater": "sparge_water",
    "stamwort_correctie_brouwhuis": "original_gravity_correction_brewhouse",
    "stort_special_bin_kg": "special_bin_load_kg",
    "totaal_gefiltreerd_volume": "total_lautered_volume",
    "verwacht_extract_begin_kook": "expected_extract_boil_start",
    "volume_kook": "boil_volume",
    "volume_water_additie_terugkoeling": "water_addition_volume_cooling",
    "walsenmolen": "roller_mill",
    "whirlpool_rust": "whirlpool_rest",
    "wortvoorkoeler_temp": "wort_precooler_temp"
  },
  "recipe_comments": {},
  "recipe_costs": {
    "bierverlies_pct": "beer_loss_pct",
    "cost_bh_per_kge": "cost_brewhouse_per_kge",
    "cost_clr_per_kge": "cost_cellar_per_kge",
    "cost_grondstoffen_hl": "cost_ingredients_per_hl"
  },
  "recipe_fermentation": {
    "bier_risico": "beer_risk",
    "bier_status": "beer_status",
    "bitterheid_bh": "bitterness_brewhouse",
    "bitterheid_bh_tol": "bitterness_brewhouse_tol",
    "extract_dry_warm_1": "dry_hop_warm_extract_1",
    "extract_dry_warm_1_tol": "dry_hop_warm_extract_1_tol",
    "extract_dry_warm_2": "dry_hop_warm_extract_2",
    "extract_dry_warm_2_tol": "dry_hop_warm_extract_2_tol",
    "extract_dry_warm_3": "dry_hop_warm_extract_3",
    "extract_dry_warm_3_tol": "dry_hop_warm_extract_3_tol",
    "lager_temp": "lagering_temp",
    "lager_temp_tol": "lagering_temp_tol",
    "lagertijd": "lagering_time",
    "lagertijd_tol": "lagering_time_tol",
    "pasteurisatie": "pasteurization",
    "pasteurisatie_tol": "pasteurization_tol",
    "t_release": "release_temp",
    "t_release_tol": "release_temp_tol",
    "temp_dry_warm": "dry_hop_warm_temp",
    "temp_dry_warm_tol": "dry_hop_warm_temp_tol",
    "troebeling_na_sep": "turbidity_after_separation",
    "troebeling_na_sep_tol": "turbidity_after_separation_tol",
    "vergistingstijd": "fermentation_time",
    "vergistingstijd_tol": "fermentation_time_tol"
  },
  "recipe_ingredients": {
    "alles_in_brouwsel_1": "all_in_first_brew",
    "eenheid": "unit",
    "hdt": "hop_dosing_tank",
    "hoeveelheid": "quantity",
    "kleur_ebc": "color_ebc",
    "notitie": "note",
    "rol": "addition_type",
    "tijdstip": "timing",
    "volgorde": "sort_order"
  },
  "recipe_packaging": {
    "alc_pct": "abv_pct",
    "co2_fles_can_spec": "co2_bottle_can_spec",
    "co2_fles_can_tolerantie": "co2_bottle_can_tolerance",
    "co2_fust_spec": "co2_keg_spec",
    "co2_fust_tolerantie": "co2_keg_tolerance",
    "ean_fles": "ean_bottle",
    "formaten": "formats",
    "tht_blik_maanden": "best_before_can_months",
    "tht_fles_maanden": "best_before_bottle_months",
    "tht_vat_maanden": "best_before_keg_months",
    "zuurstof_fust_spec": "o2_keg_spec"
  },
  "recipe_process_steps": {
    "comment_verwerken": "processing_comment",
    "dry_hop_1_dag": "dry_hop_1_day",
    "dry_hop_2_dag": "dry_hop_2_day",
    "dry_hop_methode_16c": "dry_hop_method_16c",
    "dry_hop_methode_warm": "dry_hop_method_warm",
    "kelder_toevoeging_dag": "cellar_addition_day",
    "keldersplitsing": "cellar_split"
  },
  "recipe_revisions": {
    "datum": "date",
    "door": "changed_by_name",
    "gebruiker_id": "user_id",
    "versie_major": "version_major",
    "versie_minor": "version_minor",
    "wijziging": "change_description"
  },
  "recipe_specs": {
    "bitterheid": "bitterness",
    "bitterheid_tol": "bitterness_tol",
    "co2_fles": "co2_bottle",
    "co2_fles_tol": "co2_bottle_tol",
    "co2_fust": "co2_keg",
    "co2_fust_tol": "co2_keg_tol",
    "kleur": "color",
    "kleur_tol": "color_tol",
    "origineel_extract": "original_extract",
    "origineel_extract_tol": "original_extract_tol",
    "rest_extract": "final_extract",
    "rest_extract_tol": "final_extract_tol",
    "troebeling_lab": "turbidity_lab",
    "troebeling_lab_tol": "turbidity_lab_tol"
  },
  "recipe_water": {},
  "recipes": {
    "aanbevolen_schenktemperatuur": "serving_temperature",
    "aangemaakt_door": "created_by",
    "bierstijl": "beer_style",
    "brouwsel_hl": "brew_volume_hl",
    "gewijzigd_door": "updated_by",
    "gewijzigd_op": "updated_at",
    "kleur": "recipe_color",
    "kleur_srm": "color_srm",
    "kleur_vrije_tekst": "color_free_text",
    "locatie": "location",
    "naam": "name",
    "smaak_keywords": "flavor_keywords",
    "smaakomschrijving": "flavor_description",
    "versie_major": "version_major",
    "versie_minor": "version_minor"
  },
  "stock_movements": {
    "aangemaakt_door": "created_by",
    "aangemaakt_op": "created_at",
    "geboekt_door": "booked_by",
    "geboekt_in_boekhouding": "booked_in_accounting",
    "geboekt_op": "booked_at",
    "hoeveelheid": "quantity",
    "ingevoerde_eenheid": "entered_unit",
    "ingevoerde_hoeveelheid": "entered_quantity",
    "notitie": "note",
    "type": "movement_type"
  },
  "water_settings": {
    "gemeten_op": "measured_on",
    "gewijzigd_door": "updated_by",
    "gewijzigd_op": "updated_at",
    "omschrijving": "description"
  },
  "water_settings_history": {
    "gegevens": "data",
    "geldig_vanaf": "valid_from",
    "gewijzigd_door": "updated_by"
  }
};

/** Copy of `row` (or of each row in an array) with old (Dutch) keys renamed to the English columns of `table`. */
function toDb(table, row) {
  const map = DB_LEGACY_COLUMNS[table];
  if (!map) throw new Error('toDb: unknown table ' + table);
  if (Array.isArray(row)) return row.map(r => toDb(table, r));
  const out = {};
  for (const [k, v] of Object.entries(row)) out[map[k] || k] = v;
  return out;
}

/** Copy of `row` with English column keys of `table` renamed to the old (Dutch) keys. null stays null. */
function fromDb(table, row) {
  const map = DB_LEGACY_COLUMNS[table];
  if (!map) throw new Error('fromDb: unknown table ' + table);
  if (row === null || row === undefined) return row;
  const inverse = {};
  for (const [oldKey, newKey] of Object.entries(map)) inverse[newKey] = oldKey;
  const out = {};
  for (const [k, v] of Object.entries(row)) out[inverse[k] || k] = v;
  return out;
}

/**
 * Applies fromDb() to a Supabase result ({ data, error }) — data may be one
 * row, an array of rows or null. For use as `.then(r => fromDbResult('recipes', r))`.
 */
function fromDbResult(table, result) {
  if (!DB_LEGACY_COLUMNS[table]) throw new Error('fromDbResult: unknown table ' + table);
  if (result && result.data) {
    result.data = Array.isArray(result.data) ? result.data.map(r => fromDb(table, r)) : fromDb(table, result.data);
  }
  return result;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { toDb, fromDb, fromDbResult, DB_LEGACY_COLUMNS };
}
