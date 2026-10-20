// ============================================================================
// filling.js — calculations of the Filling tab: spec limits per measurement
// (recipe_packaging, with the house limits as fallback), out-of-spec cells,
// quality / process capability (Cpk, estimated share in spec), the HBT
// filling status and the day number. Rules: docs/batch-report/business-rules.md
// ("Filling"); formula as mockup Filling.dc.html. Test: tests/filling.test.js.
//
// Browser: <script src="filling.js">. Node: require('../filling.js').
// ============================================================================

// Maxima used when the recipe has no value (mockup Filling.dc.html).
const FILLING_DEFAULT_MAX = { tpo_ppb: 100, hso_ppb: 50, do_ppb: 50, keg_o2_ppb: 50 };

// Quality rows: measurement column, label, decimals of the average.
const QUALITY_PARAMETERS = [
  { field: 'co2_gl', label: 'CO2 bottle/can', decimals: 2 },
  { field: 'hso_ppb', label: 'HSO bottle/can', decimals: 0 },
  { field: 'do_ppb', label: 'DO bottle/can', decimals: 0 },
  { field: 'tpo_ppb', label: 'TPO bottle/can', decimals: 0 },
  { field: 'keg_co2_gl', label: 'CO2 keg', decimals: 2 },
  { field: 'keg_o2_ppb', label: 'Oxygen keg', decimals: 0 },
];

function fillNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/**
 * Spec limits per measurement column: { lo, hi } (lo null = maximum only),
 * or null when there is no spec. CO2 = spec ± tolerance.
 */
function fillingLimits(packaging) {
  const p = packaging || {};
  const max = (v, fallback) => ({ lo: null, hi: fillNumber(v) ?? fallback });
  const band = (spec, tol) => {
    const s = fillNumber(spec);
    if (s === null) return null;
    const t = fillNumber(tol) || 0;
    return { lo: s - t, hi: s + t };
  };
  return {
    tpo_ppb: max(p.tpo_spec, FILLING_DEFAULT_MAX.tpo_ppb),
    hso_ppb: max(p.hso_spec, FILLING_DEFAULT_MAX.hso_ppb),
    do_ppb: max(p.do_spec, FILLING_DEFAULT_MAX.do_ppb),
    co2_gl: band(p.co2_bottle_can_spec, p.co2_bottle_can_tolerance),
    keg_co2_gl: band(p.co2_keg_spec, p.co2_keg_tolerance),
    keg_o2_ppb: max(p.o2_keg_spec, FILLING_DEFAULT_MAX.keg_o2_ppb),
  };
}

/** true when a value is outside its limits (a maximum is exclusive: < 100). */
function outOfSpec(value, limit) {
  const v = fillNumber(value);
  if (v === null || !limit) return false;
  if (limit.lo !== null && v < limit.lo - 1e-9) return true;
  return limit.lo === null ? v >= limit.hi : v > limit.hi + 1e-9;
}

/** Standard normal cumulative distribution (as the mockup). */
function phi(z) {
  const t = 1 / (1 + 0.2316419 * Math.abs(z));
  const d = 0.3989423 * Math.exp(-z * z / 2);
  const p = d * t * (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))));
  return z > 0 ? 1 - p : p;
}

/**
 * Process capability of values against a limit: { n, mean, sd, cpk, inSpec }
 * (inSpec = estimated share 0–1). Needs 2 values and a limit, else the
 * statistics are null. Sample standard deviation.
 */
function capability(values, limit) {
  const xs = values.map(fillNumber).filter((v) => v !== null);
  const n = xs.length;
  if (n < 2) return { n, mean: null, sd: null, cpk: null, inSpec: null };
  const mean = xs.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(xs.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1)) || 0.0001;
  if (!limit) return { n, mean, sd, cpk: null, inSpec: null };
  const { lo, hi } = limit;
  const cpk = lo === null ? (hi - mean) / (3 * sd) : Math.min(hi - mean, mean - lo) / (3 * sd);
  const inSpec = lo === null ? phi((hi - mean) / sd) : phi((hi - mean) / sd) - phi((lo - mean) / sd);
  return { n, mean, sd, cpk, inSpec };
}

/** 'ok' (≥ 1.33) | 'warn' (≥ 1) | 'bad' | '' (no Cpk). */
function cpkClass(cpk) {
  if (cpk === null || cpk === undefined) return '';
  return cpk >= 1.33 ? 'ok' : cpk >= 1 ? 'warn' : 'bad';
}

/** Quality rows over all filling measurements of the batch. */
function qualityRows(measurements, packaging) {
  const limits = fillingLimits(packaging);
  return QUALITY_PARAMETERS.map((q) => ({ ...q, limit: limits[q.field], ...capability(measurements.map((m) => m[q.field]), limits[q.field]) }));
}

/**
 * Filling status per HBT: 'finished' when one of its sessions has "HBT
 * finished?", 'filling' with any session, else 'not_started'.
 */
function hbtFillStatus(hbt, sessions) {
  const own = sessions.filter((s) => s.batch_hbt_id === hbt.id);
  if (own.some((s) => s.is_hbt_finished)) return 'finished';
  return own.length ? 'filling' : 'not_started';
}

/** Day number of a date: days since 31-12-2023 (6 October 2026 = 1010). */
function dayNumber(date) {
  if (!date) return null;
  const d = typeof date === 'string' ? new Date(`${date.slice(0, 10)}T12:00:00Z`) : new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate(), 12));
  return Math.round((d - Date.UTC(2023, 11, 31, 12)) / 86400000);
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FILLING_DEFAULT_MAX, QUALITY_PARAMETERS, fillingLimits, outOfSpec, phi, capability, cpkClass,
    qualityRows, hbtFillStatus, dayNumber,
  };
}
