// node tests/fermentation-log.test.js  (dates are local time, as in the browser)
const assert = require('assert');
const f = require('../fermentation-log.js');

const T0 = new Date(2026, 8, 28, 14, 0).toISOString();          // 28-09 14:00
const at = (d, h, m = 0) => new Date(2026, 8, d, h, m).toISOString();

// Time 0: the batch value wins, else the end of the last brew
assert.strictEqual(f.effectiveTimeZero({ time_zero: T0 }, { last_brew_ended_at: at(27, 9) }), T0);
assert.strictEqual(f.effectiveTimeZero({ time_zero: null }, { last_brew_ended_at: T0 }), T0);
assert.strictEqual(f.effectiveTimeZero({}, null), null);
assert.strictEqual(f.daysSince(at(29, 8), T0), 0.8);
assert.strictEqual(f.daysSince(null, T0), null);

// Log lines: decrease, hours, gap days (mockup: 2 → 5 October has 2 gaps)
const entries = [
  { id: 3, measured_at: at(30, 8), extract: '10.2' },
  { id: 1, measured_at: T0, extract: 15.0 },
  { id: 2, measured_at: at(29, 8), extract: 13.1 },
  { id: 4, measured_at: new Date(2026, 9, 3, 8).toISOString(), extract: null },
];
const lines = f.logLines(entries, T0);
assert.deepStrictEqual(lines.map((l) => l.kind), ['entry', 'entry', 'entry', 'gap', 'gap', 'entry']);
assert.deepStrictEqual(lines.filter((l) => l.kind === 'entry').map((l) => l.entry.id), [1, 2, 3, 4]);
assert.strictEqual(lines[1].decrease, 1.9);
assert.strictEqual(lines[1].hours, 18);
assert.strictEqual(lines[0].decrease, null);
assert.strictEqual(lines[0].hours, null);
assert.strictEqual(lines[3].date, '2026-10-01');
assert.strictEqual(lines[3].days, 2.8);
assert.strictEqual(lines[5].decrease, null);             // no extract on that entry
assert.deepStrictEqual(f.logLines([], T0), []);

// Plan progress: n-th occurrence of a tag ticks off the n-th step with that tag
const steps = [
  { id: 11, sort_order: 10, tag_id: 1, title: 'Dry warm' },
  { id: 12, sort_order: 20, tag_id: 2, title: 'Cooling to 16 °C' },
  { id: 13, sort_order: 30, tag_id: 3, title: 'Dryhopping @16 °C' },
  { id: 14, sort_order: 40, tag_id: 2, title: 'Cooling to 0 °C' },
  { id: 15, sort_order: 50, tag_id: 4, title: 'Sample to lab' },
];
const log = [{ id: 1, measured_at: at(30, 8) }, { id: 2, measured_at: at(29, 8) }, { id: 3, measured_at: new Date(2026, 9, 6, 8).toISOString() }];
const p = f.planProgress(steps, log, [{ entry_id: 1, tag_id: 2 }, { entry_id: 3, tag_id: 2 }, { entry_id: 2, tag_id: 1 }]);
assert.deepStrictEqual(p.rows.map((r) => (r.doneBy ? r.doneBy.id : r.isNext ? 'next' : '-')), [2, 1, 'next', 3, '-']);
assert.strictEqual(p.done, 3);
assert.strictEqual(p.total, 5);
assert.deepStrictEqual(f.planProgress(steps, [], []).rows.map((r) => r.isNext), [true, false, false, false, false]);

// ADF and theoretical ABV: first and last extract in the log
const a = f.attenuation([{ id: 1, measured_at: T0, extract: 15 }, { id: 2, measured_at: at(30, 8), extract: null }, { id: 3, measured_at: at(29, 8), extract: '3,0' }]);
assert.strictEqual(a.adf.toFixed(1), '80.0');
assert.strictEqual(a.abv.toFixed(2), '6.40');
assert.deepStrictEqual(f.attenuation([{ id: 1, measured_at: T0, extract: 15 }]), { adf: null, abv: null });

// When
assert.strictEqual(f.stepWhen({ trigger_type: 'extract', trigger_value: 5, trigger_tol: 0.5, planned_day: 3 }, null, T0), 'at 5 °P (±0.5) · ~day 3 (01-10)');
assert.strictEqual(f.stepWhen({ trigger_type: 'day', planned_day: 10 }, null, T0), 'day 10 from Time 0 (08-10)');
assert.strictEqual(f.stepWhen({ trigger_type: 'day', planned_day: 10 }, null, null), 'day 10 from Time 0');
assert.strictEqual(f.stepWhen({ trigger_type: 'after_previous' }, { title: 'Cooling to 16 °C' }, T0), 'after cooling to 16 °C');
assert.strictEqual(f.stepWhen({ trigger_type: 'after_previous' }, null, T0), 'during fermentation');

// Calculators (mockup Calculators.dc.html)
assert.deepStrictEqual(f.nagardoDose('8000', '2,5'), { weightG: 20, waterL: 2 });
const alg = f.alginateDose(8000, 0.4);
assert.strictEqual(alg.preL, 32);
assert.strictEqual(alg.alginateG, 640);
assert.strictEqual(alg.waterL, 32);
assert.strictEqual(f.nagardoDose('', 2), null);

console.log('fermentation-log: all tests passed');
