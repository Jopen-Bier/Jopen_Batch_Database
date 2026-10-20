// ============================================================================
// batch-ingredients.js — the ingredient snapshot of a batch (batch_ingredients):
// batch amounts, deviations from the recipe, Δ batch and inventory effect,
// EBU / colour input. Rules: docs/batch-report/business-rules.md
// ("Ingredient snapshot and deviations"). Worked examples:
// docs/batch-report/test-scenarios.md ("Deviations"); test:
// tests/batch-ingredients.test.js.
//
// Browser: <script src="batch-ingredients.js"> after brew-calculations.js.
// Node: require('../batch-ingredients.js').
// ============================================================================

// Ingredient cards on the Overview, in page order.
const INGREDIENT_CARDS = [
  { key: 'malt', title: 'Malt & Grains', types: ['malt'] },
  { key: 'hops', title: 'Hops and Herbs', types: ['boil_hop', 'dry_hop'] },
  { key: 'brewhouse', title: 'Additions Brewing', types: ['brewhouse_addition'] },
  { key: 'yeast', title: 'Yeasts', types: ['yeast'] },
  { key: 'cellar', title: 'Additions Cellar', types: ['cellar_addition'] },
];

// Plain-language category per addition type (Changes vs recipe list).
const ADDITION_CATEGORY = {
  malt: 'malt', boil_hop: 'boil hop', dry_hop: 'dry hop',
  brewhouse_addition: 'brewing addition', cellar_addition: 'cellar addition', yeast: 'yeast',
  base_beer: 'base beer',
};

function toNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/** Same number, ignoring float noise from typing (405 vs 405.0000001). */
function sameNumber(a, b) {
  if (a === null || b === null) return a === b;
  return Math.abs(a - b) < 1e-9;
}

/**
 * How a recipe amount scales to the whole batch, from its unit and type.
 * Returns { per: 'hl'|'l'|'brew'|'batch', unit } where unit is the unit of
 * the batch total. Malt and boil hop amounts without a rate are per brew;
 * dry hop and other absolute amounts are batch totals (decision 09-10).
 */
function amountBasis(additionType, unit) {
  const u = String(unit || '').trim().toLowerCase();
  if (u === 'ppm') return { per: 'l', unit: 'mg' };
  const rate = /^([a-z]+)\s*\/\s*(hl|l|brew)$/.exec(u);
  if (rate) return { per: rate[2], unit: rate[1] };
  if (!u) {
    if (additionType === 'malt') return { per: 'brew', unit: 'kg' };
    if (additionType === 'boil_hop') return { per: 'brew', unit: 'g' };
    return null;   // unknown unit: no batch amount
  }
  if (additionType === 'malt' || additionType === 'boil_hop') return { per: 'brew', unit: u };
  return { per: 'batch', unit: u };
}

/**
 * Volume a batch is dosed on, in hl: brews × brew volume + the beer that
 * came in from splits (Jaap, 20-10). ctx = { brewCount, brewVolumeHl, incomingHl }.
 */
function dosingVolumeHl(ctx) {
  return (toNumber(ctx.brewVolumeHl) || 0) * (toNumber(ctx.brewCount) || 0) + (toNumber(ctx.incomingHl) || 0);
}

/** Dosing context of a batch: batch row, its recipe, its batch_stages row. */
function amountContext(batch, recipe, stageRow) {
  return {
    brewCount: batch ? batch.brew_count : null,
    brewVolumeHl: recipe ? recipe.brew_volume_hl : null,
    incomingHl: stageRow ? stageRow.incoming_volume_hl : null,
  };
}

/**
 * Batch total of an amount: { q, unit } or null.
 * ctx = { brewCount, brewVolumeHl, incomingHl } (total volume = dosingVolumeHl).
 * Per brew amounts follow the brews only.
 */
function batchAmount(additionType, unit, amount, ctx) {
  const q = toNumber(amount);
  const basis = amountBasis(additionType, unit);
  if (q === null || !basis) return null;
  const brews = toNumber(ctx.brewCount) || 0;
  const totalHl = dosingVolumeHl(ctx);
  const factor = { brew: brews, hl: totalHl, l: totalHl * 100, batch: 1 }[basis.per];
  return { q: q * factor, unit: basis.unit };
}

/** Amount for one brew (Additions Brewing: "Weigh for this brew"). */
function brewAmount(additionType, unit, amount, ctx) {
  return batchAmount(additionType, unit, amount, { brewCount: 1, brewVolumeHl: ctx.brewVolumeHl, incomingHl: 0 });
}

/** Kind of change of a snapshot row: 'Added' | 'Removed' | 'Changed' | null. */
function deviationKind(row) {
  if (row.is_added) return row.is_removed ? null : 'Added';
  if (row.is_removed) return 'Removed';
  return sameNumber(toNumber(row.quantity), toNumber(row.recipe_quantity)) ? null : 'Changed';
}

/** Alpha / EBC differ from the recipe (amber, but not a stock deviation). */
function alphaDiffers(row) {
  return !row.is_added && !sameNumber(toNumber(row.alpha_pct), toNumber(row.recipe_alpha_pct));
}
function colorDiffers(row) {
  return !row.is_added && !sameNumber(toNumber(row.color_ebc), toNumber(row.recipe_color_ebc));
}

/** Δ batch of a row as { q, unit } (positive = more than the recipe), or null. */
function deviationDelta(row, ctx) {
  const kind = deviationKind(row);
  if (!kind) return null;
  const recipe = batchAmount(row.addition_type, row.unit, row.recipe_quantity, ctx);
  const batch = batchAmount(row.addition_type, row.unit, row.quantity, ctx);
  if (kind === 'Added') return batch;
  if (kind === 'Removed') return recipe ? { q: -recipe.q, unit: recipe.unit } : null;
  if (!recipe && !batch) return null;
  const unit = (batch || recipe).unit;
  return { q: (batch ? batch.q : 0) - (recipe ? recipe.q : 0), unit };
}

/**
 * Inventory effect text. Not picked yet: only the picking list changes.
 * Picked: positive Δ is an extra issue, negative a return to the same lot.
 */
function inventoryEffect(delta, orderPickingComplete, lotText) {
  if (!orderPickingComplete) return 'Picking list updated';
  const lot = lotText || 'lot to choose';
  if (!delta || delta.q === 0) return '—';
  return delta.q > 0 ? `Extra issue · ${lot}` : `Return to same lot · ${lot}`;
}

/**
 * 8000 g → '8.0 kg', 400 ml → '400 ml', 2.75 g → '2.75 g'. Amounts of 1000
 * or more of g / ml / mg move up a unit and show one decimal; others show up
 * to two decimals. signed: '+' / '−' in front.
 */
function formatAmount(amount, { signed = false } = {}) {
  if (!amount || amount.q === null || amount.q === undefined) return '—';
  let q = amount.q, unit = amount.unit;
  const up = { g: 'kg', ml: 'l', mg: 'g' }[unit];
  const scaled = !!up && Math.abs(q) >= 1000;
  if (scaled) { q /= 1000; unit = up; }
  const text = Math.abs(q).toLocaleString('en-GB', { minimumFractionDigits: scaled ? 1 : 0, maximumFractionDigits: scaled ? 1 : 2 });
  const sign = q < 0 ? '−' : signed && q > 0 ? '+' : '';
  return `${sign}${text} ${unit}`;
}

/**
 * Rows of the "Changes vs recipe" list, in card order. A row added in the
 * batch only counts once it has an amount (as the mockup).
 * names: { ingredientId: name }; lots: { ingredientId: 'LOT-1 + LOT-2' }.
 */
function deviationList(rows, ctx, { orderPickingComplete = false, names = {}, lots = {} } = {}) {
  const order = INGREDIENT_CARDS.flatMap((c) => c.types);
  return rows
    .map((row) => ({ row, kind: deviationKind(row) }))
    .filter((d) => d.kind && !(d.kind === 'Added' && toNumber(d.row.quantity) === null))
    .sort((a, b) => order.indexOf(a.row.addition_type) - order.indexOf(b.row.addition_type) || (a.row.sort_order ?? 0) - (b.row.sort_order ?? 0) || a.row.id - b.row.id)
    .map(({ row, kind }) => {
      const delta = deviationDelta(row, ctx);
      return {
        id: row.id,
        kind,
        name: names[row.ingredient_id] || row.note || '(no ingredient)',
        category: ADDITION_CATEGORY[row.addition_type] || row.addition_type,
        recipe: kind === 'Added' ? null : batchAmount(row.addition_type, row.unit, row.recipe_quantity, ctx),
        batch: kind === 'Removed' ? null : batchAmount(row.addition_type, row.unit, row.quantity, ctx),
        delta,
        effect: inventoryEffect(delta, orderPickingComplete, lots[row.ingredient_id]),
        reason: row.deviation_reason || '',
        needsReason: !String(row.deviation_reason || '').trim(),
      };
    });
}

/** Boil time in minutes from a boil-hop timing ('45', '45 min'), else null. */
function boilTimeMin(timing) {
  const m = /^\s*(\d+)\s*(min)?\s*$/i.exec(String(timing ?? ''));
  return m ? Number(m[1]) : null;
}

/**
 * Hop weights per hop over the whole batch: [{ name, boilG, dryG }], heaviest
 * first. Boil amounts are per brew, dry hop amounts are batch totals.
 */
function hopTotals(rows, ctx, names = {}) {
  const totals = new Map();
  rows.filter((r) => !r.is_removed && (r.addition_type === 'boil_hop' || r.addition_type === 'dry_hop')).forEach((r) => {
    const amount = batchAmount(r.addition_type, r.unit, r.quantity, ctx);
    if (!amount) return;
    const grams = amount.unit === 'kg' ? amount.q * 1000 : amount.unit === 'g' ? amount.q : null;
    if (grams === null) return;
    const name = names[r.ingredient_id] || r.note || '(no ingredient)';
    const t = totals.get(name) || { name, boilG: 0, dryG: 0 };
    if (r.addition_type === 'boil_hop') t.boilG += grams; else t.dryG += grams;
    totals.set(name, t);
  });
  return [...totals.values()].sort((a, b) => (b.boilG + b.dryG) - (a.boilG + a.dryG));
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    INGREDIENT_CARDS, ADDITION_CATEGORY,
    toNumber, sameNumber, amountBasis, dosingVolumeHl, amountContext, batchAmount, brewAmount,
    deviationKind, alphaDiffers, colorDiffers, deviationDelta, inventoryEffect,
    formatAmount, deviationList, boilTimeMin, hopTotals,
  };
}
