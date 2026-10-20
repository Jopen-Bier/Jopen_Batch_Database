// ============================================================================
// processing.js — calculations of the Processing tab: session duration, HBT
// end value, CO2 / O2 / turbidity / PU status, minimum maturation and the
// cellar loss. Rules: docs/batch-report/business-rules.md ("Processing /
// HBT"); test: tests/processing.test.js.
//
// Browser: <script src="processing.js">. Node: require('../processing.js').
// Package formats (PACKAGE_FORMATS, formatsText) live in batch-stages.js.
// ============================================================================

const O2_HBT_MAX_PPB = 50;            // O2 in HBT: red from 50 ppb (business-rules.md)

function procNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

function minutesOfDay(time) {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(time || ''));
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

/** Minutes from start to end time; an end before the start runs past midnight. */
function durationMinutes(start, end) {
  const a = minutesOfDay(start), b = minutesOfDay(end);
  if (a === null || b === null) return null;
  return b >= a ? b - a : b + 1440 - a;
}

/** 140 -> '2h 20m'. */
function durationText(minutes) {
  if (minutes === null || minutes === undefined) return '—';
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`;
}

/**
 * End value of an HBT = its last reading (by sort_order) that has a level; a
 * row that is still being filled in does not count yet.
 */
function hbtEnd(readings) {
  const sorted = readings.filter((r) => procNumber(r.level_hl) !== null)
    .sort((a, b) => a.sort_order - b.sort_order || a.id - b.id);
  return sorted[sorted.length - 1] || null;
}

/** CO2 spec of a target from recipe_packaging: { spec, tol } or null. */
function co2Spec(packaging, target) {
  const p = packaging || {};
  const spec = target === 'keg' ? procNumber(p.co2_keg_spec) : target === 'bottle' || target === 'can' ? procNumber(p.co2_bottle_can_spec) : null;
  if (spec === null) return null;
  const tol = procNumber(target === 'keg' ? p.co2_keg_tolerance : p.co2_bottle_can_tolerance) || 0;
  return { spec, tol };
}

/** 'OK' | 'High' | 'Low' | null (no value or no spec). */
function co2Status(value, spec) {
  const v = procNumber(value);
  if (v === null || !spec) return null;
  if (Math.abs(v - spec.spec) <= spec.tol + 1e-9) return 'OK';
  return v > spec.spec ? 'High' : 'Low';
}

const o2High = (value) => procNumber(value) !== null && procNumber(value) >= O2_HBT_MAX_PPB;
/** Turbidity above the recipe's turbidity after separation. */
const turbidityHigh = (value, max) => procNumber(value) !== null && procNumber(max) !== null && procNumber(value) > procNumber(max);
/** PU outside pasteurisation ± tol. */
function puOutOfSpec(value, spec, tol) {
  const v = procNumber(value), s = procNumber(spec);
  if (v === null || s === null) return false;
  return Math.abs(v - s) > (procNumber(tol) || 0) + 1e-9;
}

/**
 * Minimum maturation: days since lagering started vs the recipe lagering
 * time. { days, required, ok } — ok null when either is unknown.
 */
function maturation(lageringStartedAt, lageringTimeDays, now = new Date()) {
  const required = procNumber(lageringTimeDays);
  const days = lageringStartedAt ? (new Date(now) - new Date(lageringStartedAt)) / 86400000 : null;
  return { days, required, ok: days === null || required === null ? null : days >= required };
}

/**
 * Cellar loss = volume into GLT − splits from GLT / LT − total HBT end volume.
 * transfers: batch_transfers rows; hbtTankIds: tank ids of the batch's HBTs
 * (a transfer from one of those is after processing, not a cellar split).
 */
function cellarLoss({ gltVolumeHl, transfers = [], hbtTankIds = [], hbtEndTotalHl }) {
  const hbt = new Set(hbtTankIds);
  const splitsHl = transfers.filter((t) => !hbt.has(t.from_tank_id)).reduce((s, t) => s + (procNumber(t.volume_hl) || 0), 0);
  const glt = procNumber(gltVolumeHl);
  if (glt === null) return { lossHl: null, splitsHl, negative: false };
  const lossHl = glt - splitsHl - (procNumber(hbtEndTotalHl) || 0);
  return { lossHl, splitsHl, negative: lossHl < -1e-9 };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    O2_HBT_MAX_PPB, durationMinutes, durationText, hbtEnd,
    co2Spec, co2Status, o2High, turbidityHigh, puOutOfSpec, maturation, cellarLoss,
  };
}
