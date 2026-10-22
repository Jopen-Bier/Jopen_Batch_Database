// ============================================================================
// dosing-checks.js — ticking off additions per brew (Brewing tab, Additions
// brewers) and per HBT (Processing tab, processing additions):
// batch_dosing_checks rows. Which brews an addition line applies to, the
// tick of a cell and the count of ticked cells. Test: tests/dosing-checks.test.js.
// The saving (insert on tick, delete on untick) is createDosingChecks() in
// batch-report-cards.js.
//
// Browser: <script src="dosing-checks.js">. Node: require('../dosing-checks.js').
// ============================================================================

/**
 * The brews an addition line is dosed in, in brew order: every brew, or only
 * brew 1 for a line "all in the first brew". brews: batch_brews rows.
 * Returns [{ brew, applies }] for every brew (applies false = no tick box).
 */
function brewColumns(line, brews) {
  return brews.slice().sort((a, b) => a.brew_number - b.brew_number)
    .map((brew) => ({ brew, applies: !line.all_in_first_brew || brew.brew_number === 1 }));
}

/** The tick of a cell: kind 'brew' | 'hbt', or null. */
function dosingCheck(checks, lineId, kind, targetId) {
  const field = kind === 'brew' ? 'batch_brew_id' : 'batch_hbt_id';
  return checks.find((c) => c.batch_ingredient_id === lineId && c[field] === targetId) || null;
}

/**
 * Ticked / total cells over lines × targets: { done, total }. targets(line)
 * returns the ids of the brews or HBTs the line applies to.
 */
function dosingProgress(lines, kind, targets, checks) {
  let done = 0, total = 0;
  lines.forEach((line) => targets(line).forEach((id) => {
    total += 1;
    if (dosingCheck(checks, line.id, kind, id)) done += 1;
  }));
  return { done, total };
}

/** Tooltip of a tick: "JL · 07-09 04:31". */
function dosingTitle(check, initialsOf) {
  if (!check) return '';
  const d = new Date(check.checked_at);
  const pad = (n) => String(n).padStart(2, '0');
  const when = Number.isNaN(d.getTime()) ? '' : `${pad(d.getDate())}-${pad(d.getMonth() + 1)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return [initialsOf ? initialsOf(check.checked_by) : '', when].filter(Boolean).join(' · ');
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { brewColumns, dosingCheck, dosingProgress, dosingTitle };
}
