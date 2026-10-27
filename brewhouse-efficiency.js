// ============================================================================
// brewhouse-efficiency.js — Recipe analytics › Brewhouse efficiency: per brew
// the extract in the wort against the extract the malt could give, with the
// extract of brewhouse sugars taken out. Rules: docs/batch-report/
// business-rules.md ("Recipe analytics — Brewhouse efficiency"). Test:
// tests/brewhouse-efficiency.test.js.
//
// Browser: <script src="batch-ingredients.js"> then <script src="brewhouse-efficiency.js">.
// Node: require('../brewhouse-efficiency.js').
// ============================================================================

const effAmounts = (typeof brewAmount === 'function')
  ? { amountBasis, brewAmount }
  : require('./batch-ingredients.js');

// Efficiency outside these limits is suspect (Jaap, 23-10).
const EFFICIENCY_MIN = 0.70;
const EFFICIENCY_MAX = 1.00;
// Additions whose sugar is in the wort when the whirlpool extract is measured.
const BREWHOUSE_SUGAR_TYPES = ['brewhouse_addition', 'boil_hop'];
const KG_PER_UNIT = { kg: 1, g: 0.001, mg: 0.000001 };

const EFFICIENCY_CHECKS = {
  ok: { label: 'OK', warning: false },
  no_brew_data: { label: 'No brew volume or extract', warning: true, tab: 'brewing',
    hint: 'The brew has no Volume brew or no whirlpool extract. Fill in the brew log.' },
  no_malt: { label: 'No malt', warning: true, tab: 'overview',
    hint: 'The batch has no malt lines. Check the ingredients on the Overview.' },
  malt_without_extract: { label: 'Malt without extract %', warning: true, tab: 'overview',
    hint: 'A malt of this batch has no extract % on its ingredient card. Fill it in from the supplier CoA (Ingredients).' },
  sugar_without_weight: { label: 'Sugar not in kg', warning: true, tab: 'overview',
    hint: 'A brewhouse sugar is in a unit that is not a weight (e.g. litres). Enter it in kg or kg/hl.' },
  out_of_range: { label: 'Efficiency below 70% or above 100%', warning: true, tab: 'overview', acceptable: true,
    hint: 'Usually the malt is entered per batch instead of per brew, or an ingredient is missing. Right after all (e.g. a high-gravity brew)? Mark it as good with a reason.' },
  // Out of range, checked and marked as good (batch_brews.efficiency_accepted_*): counts again.
  accepted: { label: 'Marked as good', warning: false },
};

function effNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/** Extract in the wort, kg: volume hl × 100 l × SG × °P / 100, SG = 259 / (259 − °P). */
function wortExtractKg(volumeHl, plato) {
  const v = effNumber(volumeHl), p = effNumber(plato);
  if (v === null || p === null || v <= 0 || p <= 0 || p >= 259) return null;
  return v * 100 * (259 / (259 - p)) * p / 100;
}

/** kg for one brew of a batch_ingredients row, or null when the unit is not a weight. */
function brewKg(row, brewVolumeHl, brewCount) {
  const basis = effAmounts.amountBasis(row.addition_type, row.unit);
  if (!basis) return null;
  const amount = effAmounts.brewAmount(row.addition_type, row.unit, row.quantity, { brewVolumeHl });
  const perKg = KG_PER_UNIT[String(amount && amount.unit || '').toLowerCase()];
  if (!amount || perKg === undefined) return null;
  const brews = basis.per === 'batch' ? (effNumber(brewCount) || 1) : 1;   // a batch total spread over its brews
  return amount.q * perKg / brews;
}

/**
 * Fermentables of a batch, per brew. rows: batch_ingredients with
 * { addition_type, unit, quantity, is_removed, ingredient: { name, extract_pct } }.
 * Sugars are brewhouse / boil additions with an extract %; a line without an
 * amount is a comment ("Suiker!") and is skipped.
 */
function brewFermentables(rows, brewVolumeHl, brewCount) {
  const out = { maltKg: 0, maltPotentialKg: 0, maltLines: 0, maltsWithoutExtract: [], sugarKg: 0, sugarExtractKg: 0, sugarsNotWeighed: [] };
  (rows || []).filter((r) => !r.is_removed).forEach((r) => {
    const ing = r.ingredient || {};
    const pct = effNumber(ing.extract_pct);
    if (r.addition_type === 'malt') {
      const kg = brewKg(r, brewVolumeHl, brewCount);
      if (!kg) return;
      out.maltLines += 1;
      out.maltKg += kg;
      if (pct === null || pct <= 0) { out.maltsWithoutExtract.push(ing.name || '?'); return; }
      out.maltPotentialKg += kg * pct / 100;
    } else if (BREWHOUSE_SUGAR_TYPES.includes(r.addition_type) && pct !== null && pct > 0) {
      if (!effNumber(r.quantity)) return;
      const kg = brewKg(r, brewVolumeHl, brewCount);
      if (kg === null) { out.sugarsNotWeighed.push(ing.name || '?'); return; }
      out.sugarKg += kg;
      out.sugarExtractKg += kg * pct / 100;
    }
  });
  return out;
}

/**
 * Efficiency of one brew: { wortExtractKg, sugarExtractKg, maltPotentialKg,
 * efficiency, sugarShare, check }. efficiency = (wort − sugar extract) ÷ malt
 * potential; sugarShare = sugar extract ÷ wort extract. An out-of-range brew
 * with brew.efficiency_accepted_at is 'accepted'; the other checks are missing
 * data and cannot be marked as good.
 */
function brewEfficiency(brew, fermentables) {
  const f = fermentables;
  const wort = wortExtractKg(brew.brew_volume_hl, brew.whirlpool_extract);
  const fromMalt = wort === null ? null : wort - f.sugarExtractKg;
  const efficiency = fromMalt !== null && f.maltPotentialKg > 0 ? fromMalt / f.maltPotentialKg : null;
  let check = 'ok';
  if (wort === null) check = 'no_brew_data';
  else if (!f.maltLines) check = 'no_malt';
  else if (f.maltsWithoutExtract.length) check = 'malt_without_extract';
  else if (f.sugarsNotWeighed.length) check = 'sugar_without_weight';
  else if (efficiency === null || efficiency < EFFICIENCY_MIN || efficiency > EFFICIENCY_MAX) check = brew.efficiency_accepted_at ? 'accepted' : 'out_of_range';
  return { wortExtractKg: wort, sugarExtractKg: f.sugarExtractKg, maltPotentialKg: f.maltPotentialKg, maltKg: f.maltKg,
    efficiency, sugarShare: wort ? f.sugarExtractKg / wort : null, check };
}

const effCounts = (e, includeWarnings) => e.check === 'ok' || e.check === 'accepted' || (!!includeWarnings && e.efficiency !== null);

/**
 * Over several brews: efficiency pooled as Σ(wort − sugar extract) ÷ Σ malt
 * potential, the mean and spread (sample SD) of the brews, and the sugar share.
 */
function pooledEfficiency(effs, includeWarnings) {
  const counted = effs.filter((e) => effCounts(e, includeWarnings));
  const sum = (fn) => counted.reduce((s, e) => s + fn(e), 0);
  const potential = sum((e) => e.maltPotentialKg), wort = sum((e) => e.wortExtractKg), sugar = sum((e) => e.sugarExtractKg);
  const vals = counted.map((e) => e.efficiency).sort((a, b) => a - b);
  const mean = vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : null;
  const sd = vals.length > 1 ? Math.sqrt(vals.reduce((s, v) => s + (v - mean) ** 2, 0) / (vals.length - 1)) : null;
  return {
    brews: counted.length, total: effs.length,
    efficiency: potential > 0 ? (wort - sugar) / potential : null,
    mean, sd, min: vals.length ? vals[0] : null, max: vals.length ? vals[vals.length - 1] : null,
    sugarShare: wort > 0 ? sugar / wort : null, wortExtractKg: wort, maltPotentialKg: potential,
  };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    EFFICIENCY_MIN, EFFICIENCY_MAX, EFFICIENCY_CHECKS,
    wortExtractKg, brewKg, brewFermentables, brewEfficiency, effCounts, pooledEfficiency,
  };
}
