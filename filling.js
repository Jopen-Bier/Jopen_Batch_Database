// ============================================================================
// filling.js — calculations of the Filling tab: spec limits per measurement
// (TPO / HSO / DO / keg O2 from recipe_packaging with the house limits as
// fallback, CO2 per package from recipe_specs), out-of-spec cells,
// quality / process capability (Cpk, estimated share in spec), the HBT
// filling status and the day number. Rules: docs/batch-report/business-rules.md
// ("Filling"); formula as mockup Filling.dc.html. Test: tests/filling.test.js.
//
// Browser: <script src="filling.js">. Node: require('../filling.js').
// ============================================================================

// Maxima used when the recipe has no value (mockup Filling.dc.html).
const FILLING_DEFAULT_MAX = { tpo_ppb: 100, hso_ppb: 50, do_ppb: 50, keg_o2_ppb: 50 };

// Quality rows: measurement column, label, decimals of the average.
// CO2 is split by package: bottle and can have their own spec (recipe_specs).
const QUALITY_PARAMETERS = [
  { field: 'co2_gl', format: 'bottle', label: 'CO2 bottle', decimals: 2 },
  { field: 'co2_gl', format: 'can', label: 'CO2 can', decimals: 2 },
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
 * or null when there is no spec. CO2 = spec ± tolerance from recipe_specs
 * (Recipe › Specifications), for the package of the session: format 'can'
 * uses the can spec, otherwise the bottle spec; kegs the keg spec.
 */
function fillingLimits(packaging, specs, format) {
  const p = packaging || {};
  const sp = specs || {};
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
    co2_gl: format === 'can' ? band(sp.co2_can, sp.co2_can_tol) : band(sp.co2_bottle, sp.co2_bottle_tol),
    keg_co2_gl: band(sp.co2_keg, sp.co2_keg_tol),
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

/**
 * Quality rows over all filling measurements of the batch; formatOf(m) gives
 * the package of a measurement's session (the CO2 rows per package).
 */
function qualityRows(measurements, packaging, specs, formatOf = () => null) {
  return QUALITY_PARAMETERS.map((q) => {
    const limit = fillingLimits(packaging, specs, q.format)[q.field];
    const own = q.format ? measurements.filter((m) => (formatOf(m) === 'can' ? 'can' : 'bottle') === q.format) : measurements;
    return { ...q, limit, ...capability(own.map((m) => m[q.field]), limit) };
  });
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

/** Day number = day of the year, three digits: 1 January '001' … 31 December '365' / '366'. */
function dayNumber(date) {
  if (!date) return null;
  const [y, m, d] = typeof date === 'string'
    ? date.slice(0, 10).split('-').map(Number)
    : [date.getFullYear(), date.getMonth() + 1, date.getDate()];
  const day = Math.round((Date.UTC(y, m - 1, d) - Date.UTC(y, 0, 1)) / 86400000) + 1;
  return String(day).padStart(3, '0');
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FILLING_DEFAULT_MAX, QUALITY_PARAMETERS, fillingLimits, outOfSpec, phi, capability, cpkClass,
    qualityRows, hbtFillStatus, dayNumber,
  };
}
