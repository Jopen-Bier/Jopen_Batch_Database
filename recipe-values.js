// ============================================================================
// recipe-values.js — the fixed value lists of the recipe domain, in one place.
//
// The database stores short English codes (see supabase/rename-map.json,
// "status_values"); everything a user sees goes through the labels below.
// Loaded in the browser (<script src="recipe-values.js">) and in Node
// (require('../recipe-values.js'), batch report generator).
// ============================================================================

// recipes.location
const RECIPE_LOCATION_LABELS = { wp: 'WP', jk: 'JK' };

// recipes.status
const RECIPE_STATUS_LABELS = { draft: 'Draft', active: 'Active', archived: 'Archived' };

// recipe_ingredients.addition_type
const ADDITION_TYPE_LABELS = {
  malt: 'Malt',
  boil_hop: 'Hop (boil)',
  dry_hop: 'Dry hop',
  brewhouse_addition: 'Brewhouse addition',
  cellar_addition: 'Cellar addition',
  yeast: 'Yeast',
};

// recipe_fermentation.beer_risk / beer_status
const BEER_RISK_LABELS = { standard: 'Standard', dangerous: 'Dangerous', contains_sugar: 'Contains sugar', sensitive: 'Sensitive' };
const BEER_STATUS_LABELS = { standard: 'Standard', npi: 'NPI', to_improve: 'To improve' };

// Badge colours, as in the conditional formatting of Moederdata.
const BEER_RISK_COLORS = {
  contains_sugar: ['#FF66FF', '#ffffff'],
  dangerous: ['#548235', '#ffffff'],
  standard: ['#00B0F0', '#ffffff'],
  sensitive: ['#A9D18E', '#1f1f1f'],
};
const BEER_STATUS_COLORS = {
  to_improve: ['#FFC000', '#1f1f1f'],
  standard: ['#92D050', '#1f1f1f'],
  npi: ['#FF0000', '#ffffff'],
};

// Text written into the Excel batch report. The template's conditional
// formatting (Recipe Sheet N17:P20 etc.) matches on this Dutch text, so it
// stays Dutch until the template itself is changed.
const BEER_RISK_REPORT_TEXT = { standard: 'Standaard', dangerous: 'Gevaarlijk', contains_sugar: 'Suikerhoudend', sensitive: 'Gevoelig' };
const BEER_STATUS_REPORT_TEXT = { standard: 'Standaard', npi: 'NPI', to_improve: 'Te verbeteren' };

/** Label for a code from one of the lists above; unknown codes are shown as-is, empty as '—'. */
function valueLabel(labels, code) {
  if (code === null || code === undefined || code === '') return '—';
  return labels[code] || String(code);
}

function locationLabel(code) { return valueLabel(RECIPE_LOCATION_LABELS, code); }

/** <option> elements for a <select>, with an optional empty first option. */
function valueOptionsHtml(labels, { empty = false } = {}) {
  return (empty ? '<option value="">—</option>' : '') +
    Object.entries(labels).map(([code, label]) => `<option value="${code}">${label}</option>`).join('');
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    RECIPE_LOCATION_LABELS, RECIPE_STATUS_LABELS, ADDITION_TYPE_LABELS,
    BEER_RISK_LABELS, BEER_STATUS_LABELS, BEER_RISK_COLORS, BEER_STATUS_COLORS,
    BEER_RISK_REPORT_TEXT, BEER_STATUS_REPORT_TEXT,
    valueLabel, locationLabel, valueOptionsHtml,
  };
}
