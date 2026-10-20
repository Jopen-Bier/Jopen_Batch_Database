// ============================================================================
// splits.js — calculations of the Split / transfer popup: the next batch
// number, the log text (as split_batch() writes it), what is left in the
// tank, the incoming beer of the receiving batch and the base beer check
// (share per recipe group). Rules: docs/batch-report/business-rules.md
// ("Transfers (splits)"); mockup SplitBatch.dc.html. Test: tests/splits.test.js.
//
// Browser: <script src="splits.js">. Node: require('../splits.js').
// ============================================================================

function splitNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

const hl1 = (v) => (splitNumber(v) || 0).toFixed(1);

/**
 * Next batch number of the year (YY + 3 digits), as split_batch() gives it:
 * lastNumber = the highest number of this year, or null for the first.
 * Only a preview: the database hands out the number when saving.
 */
function nextBatchNumber(lastNumber, yy) {
  const last = /^\d{5}$/.test(String(lastNumber || '')) && String(lastNumber).slice(0, 2) === yy ? Number(lastNumber) : Number(yy) * 1000;
  return String(last + 1);
}

/** Log text on the source batch (same text as split_batch()). */
function transferLogText({ volumeHl, tankCode, destination, batchNumber, recipeName, reason, comment }) {
  const to = destination === 'new' ? ` to new batch ${batchNumber || '…'} (${recipeName || '…'})`
    : destination === 'batch' ? ` to batch ${batchNumber || '…'}`
      : ` discarded${String(reason || '').trim() ? ' · ' + String(reason).trim() : ''}`;
  return `Transfer · ${hl1(volumeHl)} hl${tankCode ? ' from ' + tankCode : ''}${to}${String(comment || '').trim() ? ' · ' + String(comment).trim() : ''}`;
}

/** Volume left in a tank: what was in it − the transfers out of it − this one. */
function tankAfterTransfer(startHl, transfers, tankId, volumeHl) {
  const start = splitNumber(startHl);
  if (start === null) return null;
  const out = transfers.filter((t) => t.from_tank_id === tankId).reduce((s, t) => s + (splitNumber(t.volume_hl) || 0), 0);
  return start - out - (splitNumber(volumeHl) || 0);
}

/** Σ hl of incoming lines ({ volume_hl } or { hl }). */
function incomingTotalHl(lines) {
  return lines.reduce((s, l) => s + (splitNumber(l.volume_hl ?? l.hl) || 0), 0);
}

/**
 * Base beer check of the receiving recipe. baseLines: base_beer lines
 * ({ source_recipe_group_id, quantity = share % }); sources: incoming beer
 * incl. this transfer ({ groupId, hl }). Returns { rows: [{ groupId,
 * sharePct, expectedHl, actualHl }], unexpected: [groupId] (incoming beer
 * that is not a base beer of the recipe), totalHl }. Without base beer lines
 * there is nothing to check (rows and unexpected empty).
 */
function baseBeerCheck(baseLines, sources) {
  const totalHl = incomingTotalHl(sources);
  if (!baseLines.length) return { rows: [], unexpected: [], totalHl };
  const actual = new Map();
  sources.forEach((s) => actual.set(s.groupId, (actual.get(s.groupId) || 0) + (splitNumber(s.hl) || 0)));
  const rows = baseLines.map((l) => {
    const share = splitNumber(l.quantity) || 0;
    return { groupId: l.source_recipe_group_id, sharePct: share, expectedHl: totalHl * share / 100, actualHl: actual.get(l.source_recipe_group_id) || 0 };
  });
  const known = new Set(rows.map((x) => x.groupId));
  return { rows, unexpected: [...actual.keys()].filter((g) => !known.has(g)), totalHl };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { nextBatchNumber, transferLogText, tankAfterTransfer, incomingTotalHl, baseBeerCheck };
}
