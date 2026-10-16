// ============================================================================
// db-legacy-names.js — translation layer between old (Dutch) JS property
// names and the English database columns, for code that has not been
// translated yet. GENERATED from supabase/rename-map.json — do not edit by hand.
//
// Reading: queries alias columns in the select string (`naam:name`), so the
// page keeps receiving the old property names.
// Writing: wrap a payload with toDb('<table>', row) to rename its keys.
//
//   supabaseClient.from('ingredients').update(toDb('ingredients', basis))
//
// When a page is translated to English, its toDb()/alias use goes away.
// Domains covered: inventory.
// ============================================================================

const DB_LEGACY_COLUMNS = {
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
  }
};

/** Copy of `row` with old (Dutch) keys renamed to the English columns of `table`. */
function toDb(table, row) {
  const map = DB_LEGACY_COLUMNS[table];
  if (!map) throw new Error('toDb: unknown table ' + table);
  const out = {};
  for (const [k, v] of Object.entries(row)) out[map[k] || k] = v;
  return out;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { toDb, DB_LEGACY_COLUMNS };
}
