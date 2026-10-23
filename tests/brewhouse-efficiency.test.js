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

console.log('brewhouse-efficiency: all tests passed');
