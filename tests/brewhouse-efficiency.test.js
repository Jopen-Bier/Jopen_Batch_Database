// node tests/brewhouse-efficiency.test.js
const assert = require('assert');
const e = require('../brewhouse-efficiency.js');

const near = (a, b, tol = 1e-6) => assert.ok(Math.abs(a - b) < tol, `${a} != ${b}`);
const line = (addition_type, unit, quantity, name, extract_pct, extra = {}) => ({ addition_type, unit, quantity, is_removed: false, ingredient: { name, extract_pct }, ...extra });

// Wort extract: 40 hl at 15 °P, SG = 259 / 244
near(e.wortExtractKg(40, 15), 4000 * (259 / 244) * 0.15);
near(e.wortExtractKg('40', '15'), e.wortExtractKg(40, 15));
assert.strictEqual(e.wortExtractKg(null, 15), null);
assert.strictEqual(e.wortExtractKg(40, 0), null);

// Malt is per brew (no unit or kg); a malt line without extract % is reported
const malt = [line('malt', 'kg', 700, 'Pilsner Malt', 81), line('malt', null, 195, 'Wheat Malt', '83'), line('malt', 'kg', 10, 'Rice Husks', 0.1, { is_removed: true })];
const f = e.brewFermentables(malt, 40, 8);
near(f.maltKg, 895);
near(f.maltPotentialKg, 700 * 0.81 + 195 * 0.83);
assert.strictEqual(f.maltLines, 2);
assert.deepStrictEqual(f.maltsWithoutExtract, []);
const missing = e.brewFermentables([...malt, line('malt', 'kg', 20, 'Chocolate Wheat', null)], 40, 8);
assert.deepStrictEqual(missing.maltsWithoutExtract, ['Chocolate Wheat']);

// Sugars: kg/hl × brew volume of the recipe, g per brew, batch totals spread over the brews
const sugars = [
  line('brewhouse_addition', 'kg/hl', 3.39, 'Kristalsuiker', 100),        // 135.6 kg per brew
  line('brewhouse_addition', 'g/hl', 10, 'Maltodextrin', 95),             // 0.4 kg
  line('boil_hop', 'g', 5000, 'Lactose', 95),                             // 5 kg per brew
  line('brewhouse_addition', 'kg', 24, 'Glucose Syrup', 80),              // batch total over 8 brews: 3 kg
  line('boil_hop', 'g', null, 'Suiker!', 100),                            // a comment: skipped
  line('brewhouse_addition', 'g/hl', 20, 'Calcium chloride', null),       // no extract: not a sugar
  line('cellar_addition', 'kg/hl', 2, 'Glucose Syrup', 80),               // cellar: not in the wort
];
const s = e.brewFermentables(sugars, 40, 8);
near(s.sugarKg, 135.6 + 0.4 + 5 + 3);
near(s.sugarExtractKg, 135.6 + 0.4 * 0.95 + 5 * 0.95 + 3 * 0.8);
assert.deepStrictEqual(e.brewFermentables([line('brewhouse_addition', 'l/hl', 2, 'Honey', 80)], 40, 8).sugarsNotWeighed, ['Honey']);

// Efficiency: sugar extract is taken out of the wort before dividing by the malt potential
const brew = { brew_volume_hl: 40, whirlpool_extract: 15 };
const plain = e.brewEfficiency(brew, f);
near(plain.efficiency, e.wortExtractKg(40, 15) / f.maltPotentialKg);
assert.strictEqual(plain.check, 'ok');
near(plain.sugarShare, 0);
const withSugar = e.brewEfficiency({ brew_volume_hl: 40, whirlpool_extract: 18 }, e.brewFermentables([...malt, ...sugars], 40, 8));
near(withSugar.efficiency, (e.wortExtractKg(40, 18) - s.sugarExtractKg) / f.maltPotentialKg);
near(withSugar.sugarShare, s.sugarExtractKg / e.wortExtractKg(40, 18));

// Checks, in order
assert.strictEqual(e.brewEfficiency({ brew_volume_hl: null, whirlpool_extract: 15 }, f).check, 'no_brew_data');
assert.strictEqual(e.brewEfficiency(brew, e.brewFermentables([], 40, 8)).check, 'no_malt');
assert.strictEqual(e.brewEfficiency(brew, missing).check, 'malt_without_extract');
assert.strictEqual(e.brewEfficiency(brew, e.brewFermentables([...malt, line('brewhouse_addition', 'l/hl', 2, 'Honey', 80)], 40, 8)).check, 'sugar_without_weight');
assert.strictEqual(e.brewEfficiency(brew, e.brewFermentables([line('malt', 'kg', 460, 'Pilsner Malt', 81)], 40, 8)).check, 'out_of_range');   // 26256: 171%
assert.strictEqual(e.brewEfficiency({ brew_volume_hl: 40, whirlpool_extract: 9 }, f).check, 'out_of_range');                                      // 51%
Object.values(e.EFFICIENCY_CHECKS).filter((c) => c.warning).forEach((c) => assert.ok(c.hint && c.tab));

// Marked as good: only an out-of-range brew, then it counts again
const highGravity = e.brewFermentables([line('malt', 'kg', 980, 'Pilsner Malt', 80)], 20, 4);
const hgBrew = { brew_volume_hl: 18, whirlpool_extract: 26 };                    // ~66%, a real high-gravity brew
assert.strictEqual(e.brewEfficiency(hgBrew, highGravity).check, 'out_of_range');
const accepted = e.brewEfficiency({ ...hgBrew, efficiency_accepted_at: '2026-10-27T09:00:00Z' }, highGravity);
assert.strictEqual(accepted.check, 'accepted');
assert.ok(e.effCounts(accepted, false));
assert.ok(!e.EFFICIENCY_CHECKS.accepted.warning);
assert.ok(e.EFFICIENCY_CHECKS.out_of_range.acceptable);
assert.strictEqual(e.brewEfficiency({ brew_volume_hl: null, whirlpool_extract: 26, efficiency_accepted_at: '2026-10-27' }, highGravity).check, 'no_brew_data');
assert.strictEqual(e.brewEfficiency({ ...brew, efficiency_accepted_at: '2026-10-27' }, f).check, 'ok');   // in range: stays ok

// Pooled over brews, warnings only when asked
const a = e.brewEfficiency(brew, f);
const b = e.brewEfficiency({ brew_volume_hl: 39, whirlpool_extract: 14.8 }, f);
const bad = e.brewEfficiency(brew, e.brewFermentables([line('malt', 'kg', 460, 'Pilsner Malt', 81)], 40, 8));
const p = e.pooledEfficiency([a, b, bad]);
assert.strictEqual(p.brews, 2);
assert.strictEqual(p.total, 3);
near(p.efficiency, (a.wortExtractKg + b.wortExtractKg) / (2 * f.maltPotentialKg));
near(p.mean, (a.efficiency + b.efficiency) / 2);
near(p.sd, Math.abs(a.efficiency - b.efficiency) / Math.sqrt(2));
assert.strictEqual(e.pooledEfficiency([a, b, bad], true).brews, 3);
assert.strictEqual(e.pooledEfficiency([]).efficiency, null);

// Steps: filtration × boil × whirlpool = efficiency, also with sugar (Mooie Nel-like brew)
const stepBrew = { brew_volume_hl: 37.4, whirlpool_extract: 15.3, boil_start_volume_hl: 41, boil_start_extract: 14.6, whirlpool_volume_hl: 41.3 };
const st = e.brewEfficiency(stepBrew, f);
near(st.filtration, e.wortExtractKg(41, 14.6) / f.maltPotentialKg);
near(st.boil, e.wortExtractKg(41.3, 15.3) / e.wortExtractKg(41, 14.6));
near(st.whirlpool, 37.4 / 41.3);                                                   // same °P: the volume ratio
near(st.filtration * st.boil * st.whirlpool, st.efficiency);
const sw = e.brewEfficiency({ ...stepBrew, whirlpool_extract: 17 }, e.brewFermentables([...malt, ...sugars], 40, 8));
near(sw.boil, (e.wortExtractKg(41.3, 17) - sw.sugarExtractKg) / e.wortExtractKg(41, 14.6));
near(sw.filtration * sw.boil * sw.whirlpool, sw.efficiency);
assert.ok(e.hasSteps(st));
const noStart = e.brewEfficiency({ ...stepBrew, boil_start_volume_hl: null }, f);
assert.strictEqual(noStart.filtration, null);
assert.strictEqual(noStart.boil, null);
near(noStart.whirlpool, st.whirlpool);
assert.ok(!e.hasSteps(noStart));
assert.strictEqual(noStart.check, 'ok');                                          // the steps have no checks (Jaap, 28-10)

// Pooled steps: over brews with all three points, multiplying to their efficiency; where the extract went
const st2 = e.brewEfficiency({ ...stepBrew, brew_volume_hl: 36.5, boil_start_volume_hl: 40.2 }, f);
const ps = e.pooledEfficiency([st, st2, noStart]);
assert.strictEqual(ps.brews, 3);
assert.strictEqual(ps.steps.brews, 2);
near(ps.steps.filtration * ps.steps.boil * ps.steps.whirlpool, ps.steps.efficiency);
near(ps.steps.efficiency, (st.wortExtractKg + st2.wortExtractKg) / (2 * f.maltPotentialKg));
near(ps.lost.filtration + ps.lost.boil + ps.lost.whirlpool + ps.lost.inWort - ps.lost.boilGain, 1);
near(ps.lost.inWort, ps.steps.efficiency);
assert.ok(ps.steps.whirlpoolSpread.sd > 0);
const over = e.pooledEfficiency([e.brewEfficiency({ ...stepBrew, boil_start_volume_hl: 36 }, f)]);   // boil above 100 %
assert.ok(over.steps.boil > 1);
assert.strictEqual(over.lost.boil, 0);
assert.ok(over.lost.boilGain > 0);
near(over.lost.inWort, over.steps.efficiency);
const normal = e.pooledEfficiency([e.brewEfficiency({ ...stepBrew, boil_start_volume_hl: 46, boil_start_extract: 14.3 }, f)]);
assert.ok(normal.steps.boil < 1 && normal.lost.boilGain === 0);
near(normal.lost.filtration + normal.lost.boil + normal.lost.whirlpool + normal.lost.inWort, 1);

console.log('brewhouse-efficiency: all tests passed');
