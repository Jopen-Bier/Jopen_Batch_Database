// ============================================================================
// batch-brews.js — the brew log of a batch (batch_brews): its rows, the
// calculated values per brew and the GLT total. Rules:
// docs/batch-report/business-rules.md ("Brewing (per brew, grey/calculated)");
// test: tests/batch-brews.test.js.
//
// Browser: <script src="batch-brews.js">. Node: require('../batch-brews.js').
// ============================================================================

// Brew log rows, top to bottom. kind: section | num | text | datetime | yesno |
// select | user | calc. only: 'wp' / 'jk' = shown for that brewhouse only.
// recipe: key into the recipe values passed to recipeValue() (null = none).
const BREW_LOG_ROWS = [
  { kind: 'section', label: 'General' },
  { key: 'software_order_number', label: 'Order no. software', kind: 'text' },
  { key: 'brewer_id', label: 'Brewer start', kind: 'user' },
  { key: 'mash_in_started_at', label: 'Start mashing', kind: 'datetime' },
  { kind: 'section', label: 'Mashing' },
  { key: 'mash_water_hl', label: 'Mash water', unit: 'hl', kind: 'num', recipe: 'mash_water' },
  { key: 'mash_in_ph', label: 'pH after mashing-in', kind: 'num' },
  { key: 'mash_acid_l', label: 'Acid correction', unit: 'l', kind: 'num', recipe: 'mash_in_acid_l' },
  { key: 'mash_corrected_ph', label: 'pH after correction', kind: 'num', recipe: 'ph_mash' },
  { key: 'is_iodine_test_ok', label: 'Iodine test OK?', kind: 'yesno' },
  { key: 'has_mash_schedule_deviation', label: 'Deviation from mash schedule?', kind: 'yesno' },
  { kind: 'section', label: 'Filtration · mash filter', only: 'wp' },
  { kind: 'section', label: 'Filtration · lauter tun', only: 'jk' },
  { key: 'first_wort_extract', label: 'Plato first wort', unit: '°P', kind: 'num' },
  { key: 'last_runnings_extract', label: 'Extract last runnings', unit: '°P', kind: 'num' },
  { key: 'cumulative_sparge_volume_hl', label: 'Cumulative sparging volume', unit: 'hl', kind: 'num', only: 'wp', recipe: 'cumulative_sparge_volume' },
  { key: 'last_runnings_ph', label: 'Last runnings pH', kind: 'num', only: 'wp' },
  { key: 'first_wort_volume_hl', label: 'First runnings', unit: 'hl', kind: 'num', only: 'jk', recipe: 'first_wort' },
  { key: 'sparge_water_hl', label: 'Sparge water', unit: 'hl', kind: 'num', only: 'jk', recipe: 'sparge_water' },
  { key: 'sparge_runnings_hl', label: 'Sparge runnings', unit: 'hl', kind: 'num', only: 'jk', recipe: 'sparge_runoff' },
  { key: 'lauter_time_min', label: 'Filtration time', unit: 'min', kind: 'num' },
  { kind: 'section', label: 'Boiling' },
  { key: 'boil_start_ph', label: 'pH start boil', kind: 'num', recipe: 'ph_boil_start' },
  { key: 'boil_start_extract', label: 'Extract start boil', unit: '°P', kind: 'num', recipe: 'expected_extract_boil_start' },
  { key: 'boil_start_volume_hl', label: 'Volume start boil (80 °C)', unit: 'hl', kind: 'num', recipe: 'boil_volume' },
  { key: 'boil_acid_l', label: 'Acid correction', unit: 'l', kind: 'num', recipe: 'boil_acid_l' },
  { key: 'boil_acid_ph_note', label: 'pH after acid correction / time', kind: 'text' },
  { key: 'boil_time_min', label: 'Total boil time', unit: 'min', kind: 'num' },
  { key: 'boil_end_extract', label: 'Extract end boil', unit: '°P', kind: 'num' },
  { key: 'evaporation_pct', label: 'Evaporation', unit: '%', kind: 'calc', recipe: 'target_evaporation' },
  { key: 'extra_addition', label: 'Extra addition', kind: 'text' },
  { kind: 'section', label: 'Whirlpool / end of boil' },
  { key: 'whirlpool_volume_hl', label: 'Volume whirlpool', unit: 'hl', kind: 'num' },
  { key: 'whirlpool_extract', label: 'Extract', unit: '°P', kind: 'num', recipe: 'original_extract' },
  { key: 'whirlpool_ph', label: 'pH', kind: 'num', recipe: 'ph_boil_end' },
  { key: 'whirlpool_rest_min', label: 'Actual rest time', unit: 'min', kind: 'num', recipe: 'whirlpool_rest' },
  { key: 'aeration_ppm', label: 'Aeration', unit: 'ppm', kind: 'num', recipe: 'aeration' },
  { key: 'water_addition_hl', label: 'Water addition', unit: 'hl', kind: 'num' },
  { key: 'brew_volume_hl', label: 'Volume brew', unit: 'hl', kind: 'num', recipe: 'brew_volume_hl' },
  { key: 'volume_to_glt_hl', label: 'Volume to GLT', unit: 'hl', kind: 'calc', recipe: 'brew_volume_hl' },
  { key: 'extract_to_glt', label: 'Extract to GLT', unit: '°P', kind: 'calc', recipe: 'original_extract' },
  { key: 'glt_total', label: 'GLT total so far', kind: 'calc' },
  { kind: 'section', label: 'End' },
  { key: 'brewer_end_id', label: 'Brewer end', kind: 'user' },
  { key: 'brewing_ended_at', label: 'End of brewing', kind: 'datetime' },
  { key: 'process_pause', label: 'Pause in process (hh:mm)', kind: 'text', only: 'jk' },
  { key: 'total_brewing_h', label: 'Total brewing time', unit: 'h', kind: 'calc' },
  { kind: 'section', label: 'Hygiene & CIP', only: 'jk' },
  { key: 'is_aeration_filter_steamed', label: 'Aeration filter steamed?', kind: 'yesno', only: 'jk' },
  { key: 'is_wort_line_sterilized', label: 'Wort line sterilised?', kind: 'yesno', only: 'jk' },
  { key: 'ckt_cip_program', label: 'CKT CIP', kind: 'select', only: 'jk', options: ['lo-de', 'lo-zu-de', 'lo-de-hw', 'lo-zu-de-hw'] },
  { key: 'spent_grain_bin', label: 'Spent grain bin number', kind: 'text', only: 'jk' },
];

/** Brew log rows for a brewhouse ('wp' / 'jk'; anything else shows the shared rows only). */
function brewLogRows(location) {
  return BREW_LOG_ROWS.filter((r) => !r.only || r.only === location);
}

function num(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/** Evaporation % = (extract end − extract start) / extract start × 100. */
function evaporationPct(boilStartExtract, boilEndExtract) {
  const s = num(boilStartExtract), e = num(boilEndExtract);
  if (!s || e === null) return null;
  return (e - s) / s * 100;
}

/** Volume to GLT = volume brew + water addition. */
function volumeToGlt(brewVolumeHl, waterAdditionHl) {
  const v = num(brewVolumeHl);
  return v === null ? null : v + (num(waterAdditionHl) || 0);
}

/** Extract to GLT = extract × volume brew / volume to GLT (water dilutes). */
function extractToGlt(whirlpoolExtract, brewVolumeHl, waterAdditionHl) {
  const ex = num(whirlpoolExtract), v = num(brewVolumeHl), toGlt = volumeToGlt(brewVolumeHl, waterAdditionHl);
  if (ex === null || v === null || !toGlt) return null;
  return ex * v / toGlt;
}

/** 'hh:mm' → minutes; empty or malformed → 0. */
function pauseMinutes(text) {
  const m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(String(text || ''));
  return m ? Number(m[1]) * 60 + Number(m[2]) : 0;
}

/** Total brewing time in hours, minus the pause (JK). null when not complete. */
function totalBrewingHours(startedAt, endedAt, pause) {
  if (!startedAt || !endedAt) return null;
  const ms = new Date(endedAt) - new Date(startedAt);
  if (!(ms > 0)) return null;
  return (ms - pauseMinutes(pause) * 60000) / 3600000;
}

/**
 * Calculated values for every brew (sorted by brew_number), with the GLT
 * total running over the brews so far: { brewNumber, evaporationPct,
 * volumeToGltHl, extractToGlt, totalBrewingH, glt: { volumeHl, extract, ph } }.
 * GLT extract is volume-weighted; pH is the mean whirlpool pH.
 */
function brewCalculations(brews) {
  let vol = 0, extractVol = 0;
  const phs = [];
  return brews.slice().sort((a, b) => a.brew_number - b.brew_number).map((b) => {
    const v = volumeToGlt(b.brew_volume_hl, b.water_addition_hl);
    const ex = extractToGlt(b.whirlpool_extract, b.brew_volume_hl, b.water_addition_hl);
    if (v !== null && ex !== null) { vol += v; extractVol += v * ex; }
    const ph = num(b.whirlpool_ph);
    if (ph !== null) phs.push(ph);
    return {
      brewNumber: b.brew_number,
      evaporationPct: evaporationPct(b.boil_start_extract, b.boil_end_extract),
      volumeToGltHl: v,
      extractToGlt: ex,
      totalBrewingH: totalBrewingHours(b.mash_in_started_at, b.brewing_ended_at, b.process_pause),
      glt: {
        volumeHl: vol || null,
        extract: vol ? extractVol / vol : null,
        ph: phs.length ? phs.reduce((s, x) => s + x, 0) / phs.length : null,
      },
    };
  });
}

/** Tolerance as a number from text such as '0.5', '±0.5'; null when empty. */
function toleranceValue(tol) {
  const n = num(String(tol ?? '').replace(/[^\d.,-]/g, ''));
  return n === null ? null : Math.abs(n);
}

/** true / false / null (no value or no spec): value within spec ± tol. */
function withinSpec(value, spec, tol) {
  const v = num(value), s = num(spec);
  if (v === null || s === null) return null;
  return Math.abs(v - s) <= (tol ?? 0) + 1e-9;
}

/** Volume tolerance at GLT (decision 09-10). */
const VOLUME_TOL_HL = 0.5;

/** Next free brew number. */
function nextBrewNumber(brews) {
  return brews.reduce((m, b) => Math.max(m, b.brew_number), 0) + 1;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BREW_LOG_ROWS, VOLUME_TOL_HL, brewLogRows,
    evaporationPct, volumeToGlt, extractToGlt, pauseMinutes, totalBrewingHours,
    brewCalculations, toleranceValue, withinSpec, nextBrewNumber,
  };
}
