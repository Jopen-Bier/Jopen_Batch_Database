// node tests/recipe-losses.test.js
const assert = require('assert');
const r = require('../recipe-losses.js');

const row = (o) => ({ recipe_id: 1, recipe_group_id: 'g1', glt_hl: null, incoming_hl: 0, splits_before_hl: 0, splits_after_hl: 0,
  in_hbt_hl: 0, hbts_without_level: 0, bottle_hl: 0, can_hl: 0, keg_hl: 0, tank_hl: 0, ...o });
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-6, `${a} != ${b}`);

// A normal batch (26006): 121.3 hl into GLT, 108.1 in HBT, 103.0 in cans
const ok = r.batchLoss(row({ glt_hl: '121.3', in_hbt_hl: '108.1', can_hl: '103' }));
assert.strictEqual(ok.check, 'ok');
near(ok.processedHl, 121.3);
near(ok.cellarLossHl, 13.2);
near(ok.fillingLossHl, 5.1);
near(ok.lostHl, 18.3);
near(ok.lossShare, 18.3 / 121.3);
near(ok.cellarShare + ok.fillingShare, ok.lossShare);

// Splits before processing come off the processed volume, splits from the HBT do not (26093)
const sp = r.batchLoss(row({ glt_hl: 119.9, in_hbt_hl: 108.2, splits_after_hl: 68.2, tank_hl: 40 }));
assert.strictEqual(sp.check, 'ok');
near(sp.processedHl, 119.9);
near(sp.cellarLossHl, 11.7);
near(sp.fillingLossHl, 0);
const pre = r.batchLoss(row({ glt_hl: 318.5, splits_before_hl: 10, in_hbt_hl: 273.8, can_hl: 260.9 }));
near(pre.processedHl, 308.5);
near(pre.cellarLossHl, 34.7);

// Beer received from a split counts as going in (a split batch without brews)
const rec = r.batchLoss(row({ incoming_hl: '93.4', in_hbt_hl: 87.3, can_hl: 81.9 }));
assert.strictEqual(rec.check, 'ok');
near(rec.processedHl, 93.4);

// Data checks, each from a real 2026 batch
assert.strictEqual(r.batchLoss(row({ splits_before_hl: 0, in_hbt_hl: 105.1, bottle_hl: 101.7 })).check, 'no_brew_volume');        // 26017
assert.strictEqual(r.batchLoss(row({ glt_hl: 122.3, splits_before_hl: 112.9 })).check, 'fully_split');                              // 26009
assert.strictEqual(r.batchLoss(row({ glt_hl: 123.9 })).check, 'not_packaged');                                                     // 26086
assert.strictEqual(r.batchLoss(row({ glt_hl: 58.5, splits_before_hl: 104 })).check, 'more_out_than_in');                            // 26182
assert.strictEqual(r.batchLoss(row({ glt_hl: 124.9, splits_before_hl: 20, in_hbt_hl: 117.3, can_hl: 111.5 })).check, 'more_out_than_in'); // 26025
assert.strictEqual(r.batchLoss(row({ glt_hl: 129.7, in_hbt_hl: 59, can_hl: 110.9 })).check, 'more_packaged_than_hbt');             // 26265
assert.strictEqual(r.batchLoss(row({ incoming_hl: 40, in_hbt_hl: 10, hbts_without_level: 1, can_hl: 28, keg_hl: 9.1 })).check, 'more_packaged_than_hbt'); // 26132
assert.strictEqual(r.batchLoss(row({ glt_hl: 32.3, in_hbt_hl: 31.3, bottle_hl: 5.4 })).check, 'loss_over_limit');                  // 26169
// Within the tolerance is not a warning
assert.strictEqual(r.batchLoss(row({ glt_hl: 40, in_hbt_hl: 40.4, keg_hl: 39 })).check, 'ok');
Object.values(r.LOSS_CHECKS).filter((c) => c.warning).forEach((c) => assert.ok(c.hint && c.tab));

// Pooled: lost hl over processed hl; warnings and fully split batches only when asked / never
const big = r.batchLoss(row({ glt_hl: 318.3, in_hbt_hl: 278.5, can_hl: 265.7 }));
const warn = r.batchLoss(row({ glt_hl: 32.3, in_hbt_hl: 31.3, bottle_hl: 5.4 }));
const split = r.batchLoss(row({ glt_hl: 122.3, splits_before_hl: 112.9 }));
const p = r.pooledLoss([ok, big, warn, split]);
assert.strictEqual(p.batches, 2);
assert.strictEqual(p.total, 4);
near(p.processedHl, 121.3 + 318.3);
near(p.lostHl, 18.3 + 52.6);
near(p.lossShare, (18.3 + 52.6) / (121.3 + 318.3));
near(p.minShare, Math.min(ok.lossShare, big.lossShare));
const pw = r.pooledLoss([ok, big, warn, split], true);
assert.strictEqual(pw.batches, 3);                               // the warning counts, the fully split batch never
assert.strictEqual(r.pooledLoss([]).lossShare, null);

// Versions of one recipe group together, named after the newest version
const recipes = [
  { id: 361, name: 'Mooie Nel', version_major: 11, version_minor: 1, recipe_group_id: 'mn' },
  { id: 673, name: 'Mooie Nel', version_major: 12, version_minor: 1, recipe_group_id: 'mn' },
  { id: 363, name: 'Mooie Nel Guava Passionfruit Split', version_major: 2, version_minor: 1, recipe_group_id: 'guava' },
];
const g = r.lossesByRecipe([
  r.batchLoss(row({ recipe_id: 361, recipe_group_id: 'mn', glt_hl: 120, in_hbt_hl: 108, can_hl: 104 })),
  r.batchLoss(row({ recipe_id: 673, recipe_group_id: 'mn', glt_hl: 120, in_hbt_hl: 106, can_hl: 101 })),
  r.batchLoss(row({ recipe_id: 363, recipe_group_id: 'guava', incoming_hl: 60, in_hbt_hl: 60, can_hl: 56.2 })),
], recipes);
assert.strictEqual(g.length, 2);
const mn = g.find((x) => x.groupId === 'mn');
assert.strictEqual(mn.losses.length, 2);
assert.deepStrictEqual(mn.versions, ['12.1', '11.1']);
assert.strictEqual(g.find((x) => x.groupId === 'guava').name, 'Mooie Nel Guava Passionfruit Split');

console.log('recipe-losses: all tests passed');
