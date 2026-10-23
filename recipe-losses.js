// ============================================================================
// recipe-losses.js — Recipe analytics › Losses: the loss of each closed batch
// from the batch_volume_balance view, its data check, and the loss pooled per
// recipe. The balance itself is volumeBalance() of filling-report.js, so the
// figures match the Filling report tab. Rules: docs/batch-report/
// business-rules.md ("Recipe analytics — Losses"). Test:
// tests/recipe-losses.test.js.
//
// Browser: <script src="filling-report.js"> then <script src="recipe-losses.js">.
// Node: require('../recipe-losses.js').
// ============================================================================

const lossesVolumeBalance = (typeof volumeBalance === 'function')
  ? volumeBalance
  : require('./filling-report.js').volumeBalance;

// Volumes within this many hl count as equal (readings are rounded).
const LOSS_VOLUME_TOLERANCE_HL = 0.5;
// A batch losing more than this share of what it processed is suspect.
const LOSS_LIMIT_SHARE = 0.30;
// A batch that packaged nothing but split at least this share away is a base
// beer for other batches: no loss of its own, and nothing to fix.
const FULLY_SPLIT_SHARE = 0.8;

// Data checks: 'ok' counts; 'fully_split' is left out without a warning; the
// rest are warnings, left out unless the page includes them. tab = the batch
// tab where the data is fixed.
const LOSS_CHECKS = {
  ok: { label: 'OK', warning: false },
  fully_split: { label: 'Fully split to other batches', warning: false },
  no_brew_volume: { label: 'No brew volume', warning: true, tab: 'brewing',
    hint: 'No brew with a brew volume and a whirlpool extract, and no beer received. Fill in the brew log.' },
  not_packaged: { label: 'Not packaged, not split', warning: true, tab: 'filling-report',
    hint: 'Nothing booked as packaged and no split for most of the beer. Book the filling report or record the split.' },
  more_out_than_in: { label: 'More out than in', warning: true, tab: 'processing',
    hint: 'HBT end levels plus splits are more than went into the GLT. Check the HBT end values, the split volumes and the brew volumes.' },
  more_packaged_than_hbt: { label: 'More packaged than in the HBT', warning: true, tab: 'filling-report',
    hint: 'More booked as packaged than the HBT end levels allow, or an HBT without an end level. Check the HBT end values and the article counts.' },
  loss_over_limit: { label: 'Loss over 30%', warning: true, tab: 'filling-report',
    hint: 'Over 30% lost. Often a filling session or its articles were not booked.' },
};

function lossNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** Data check code of a balance (volumeBalance() result) and its HBTs without a level. */
function lossCheck(balance, hbtsWithoutLevel) {
  const tol = LOSS_VOLUME_TOLERANCE_HL;
  const start = balance.startHl || 0;
  if (start <= 0) return 'no_brew_volume';
  const packaged = balance.packagedTotalHl;
  if (packaged <= 0 && balance.splitsPostHl <= 0) {
    if (balance.splitsPreHl > start + tol) return 'more_out_than_in';
    return balance.splitsPreHl >= FULLY_SPLIT_SHARE * start ? 'fully_split' : 'not_packaged';
  }
  if (hbtsWithoutLevel > 0 || balance.remainderHl < -tol) return 'more_packaged_than_hbt';
  if (balance.cellarLossHl < -tol) return 'more_out_than_in';
  const processed = start - balance.splitsPreHl;
  if (processed > 0 && (balance.cellarLossHl + balance.remainderHl) / processed > LOSS_LIMIT_SHARE) return 'loss_over_limit';
  return 'ok';
}

/**
 * One batch_volume_balance row -> { row, balance, processedHl, cellarLossHl,
 * fillingLossHl, lostHl, lossShare, cellarShare, fillingShare, check }.
 * Shares are of the beer the batch processed itself (into GLT + received −
 * splits before processing); null when it processed nothing.
 */
function batchLoss(row) {
  const balance = lossesVolumeBalance({
    gltHl: row.glt_hl,
    incomingHl: row.incoming_hl,
    transfers: [
      { from_tank_id: 'glt', volume_hl: lossNumber(row.splits_before_hl) || 0 },
      { from_tank_id: 'hbt', volume_hl: lossNumber(row.splits_after_hl) || 0 },
    ],
    hbtTankIds: ['hbt'],
    hbtEndTotalHl: row.in_hbt_hl,
    packagedHl: { bottle: lossNumber(row.bottle_hl) || 0, can: lossNumber(row.can_hl) || 0, keg: lossNumber(row.keg_hl) || 0, tank: lossNumber(row.tank_hl) || 0 },
  });
  const check = lossCheck(balance, lossNumber(row.hbts_without_level) || 0);
  const processedHl = balance.startHl === null ? null : balance.startHl - balance.splitsPreHl;
  const cellarLossHl = balance.cellarLossHl;
  const fillingLossHl = balance.startHl === null ? null : balance.remainderHl;
  const lostHl = cellarLossHl === null ? null : cellarLossHl + fillingLossHl;
  const share = (x) => (processedHl > 0 && x !== null ? x / processedHl : null);
  return { row, balance, processedHl, cellarLossHl, fillingLossHl, lostHl,
    lossShare: share(lostHl), cellarShare: share(cellarLossHl), fillingShare: share(fillingLossHl), check };
}

/** Whether a batch counts in the averages: check ok, or a warning when includeWarnings. */
function lossCounts(loss, includeWarnings) {
  if (loss.check === 'ok') return true;
  return !!includeWarnings && LOSS_CHECKS[loss.check].warning && loss.processedHl > 0;
}

/** Pooled over the batches that count: lost hl / processed hl (not a mean of percentages). */
function pooledLoss(losses, includeWarnings) {
  const counted = losses.filter((l) => lossCounts(l, includeWarnings));
  const sum = (k) => counted.reduce((s, l) => s + (l[k] || 0), 0);
  const processedHl = sum('processedHl'), cellarLossHl = sum('cellarLossHl'), fillingLossHl = sum('fillingLossHl');
  const share = (x) => (processedHl > 0 ? x / processedHl : null);
  const shares = counted.map((l) => l.lossShare).filter((x) => x !== null).sort((a, b) => a - b);
  return {
    batches: counted.length, total: losses.length, processedHl, cellarLossHl, fillingLossHl, lostHl: cellarLossHl + fillingLossHl,
    lossShare: share(cellarLossHl + fillingLossHl), cellarShare: share(cellarLossHl), fillingShare: share(fillingLossHl),
    minShare: shares.length ? shares[0] : null, maxShare: shares.length ? shares[shares.length - 1] : null,
  };
}

/**
 * Losses grouped per recipe (all versions of a recipe_group_id together).
 * recipes: rows { id, name, version_major, version_minor, recipe_group_id }.
 * Returns [{ groupId, name (of the newest version), versions, losses }].
 */
function lossesByRecipe(losses, recipes) {
  const recipeById = new Map((recipes || []).map((r) => [r.id, r]));
  const groups = new Map();
  losses.forEach((l) => {
    const recipe = recipeById.get(l.row.recipe_id);
    const key = l.row.recipe_group_id || (recipe && recipe.recipe_group_id) || 'recipe-' + l.row.recipe_id;
    if (!groups.has(key)) groups.set(key, { groupId: key, recipes: new Map(), losses: [] });
    const g = groups.get(key);
    g.losses.push(l);
    if (recipe) g.recipes.set(recipe.id, recipe);
  });
  const vKey = (r) => (Number(r.version_major) || 0) * 10000 + (Number(r.version_minor) || 0);
  return [...groups.values()].map((g) => {
    const rs = [...g.recipes.values()].sort((a, b) => vKey(b) - vKey(a));
    return { groupId: g.groupId, name: rs.length ? rs[0].name : '?', versions: rs.map((r) => `${r.version_major}.${r.version_minor}`), losses: g.losses };
  });
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    LOSS_VOLUME_TOLERANCE_HL, LOSS_LIMIT_SHARE, FULLY_SPLIT_SHARE, LOSS_CHECKS,
    lossCheck, batchLoss, lossCounts, pooledLoss, lossesByRecipe,
  };
}
