// node tests/batch-ingredients.test.js
const assert = require('assert');
const b = require('../batch-ingredients.js');

// Cards cover every addition type of recipe_ingredients exactly once.
assert.deepStrictEqual(b.INGREDIENT_CARDS.flatMap((c) => c.types).sort(),
  ['boil_hop', 'brewhouse_addition', 'cellar_addition', 'dry_hop', 'malt', 'yeast']);

assert.strictEqual(b.toNumber('2,75'), 2.75);
assert.strictEqual(b.toNumber(''), null);
assert.strictEqual(b.toNumber('abc'), null);

// Basis per unit (units found in recipe_ingredients, 19-10-2026)
assert.deepStrictEqual(b.amountBasis('malt', 'kg'), { per: 'brew', unit: 'kg' });
assert.deepStrictEqual(b.amountBasis('malt', null), { per: 'brew', unit: 'kg' });
assert.deepStrictEqual(b.amountBasis('boil_hop', 'g'), { per: 'brew', unit: 'g' });
assert.deepStrictEqual(b.amountBasis('dry_hop', 'g'), { per: 'batch', unit: 'g' });
assert.deepStrictEqual(b.amountBasis('brewhouse_addition', 'g/hl'), { per: 'hl', unit: 'g' });
assert.deepStrictEqual(b.amountBasis('cellar_addition', 'ml / hl'), { per: 'hl', unit: 'ml' });
assert.deepStrictEqual(b.amountBasis('cellar_addition', 'mg/l'), { per: 'l', unit: 'mg' });
assert.deepStrictEqual(b.amountBasis('cellar_addition', 'ppm'), { per: 'l', unit: 'mg' });
assert.deepStrictEqual(b.amountBasis('brewhouse_addition', 'g/brew'), { per: 'brew', unit: 'g' });
assert.deepStrictEqual(b.amountBasis('cellar_addition', 'hl'), { per: 'batch', unit: 'hl' });
assert.strictEqual(b.amountBasis('cellar_addition', null), null);

// Worked examples, test-scenarios.md "Deviations": 2 brews × 40 hl
const ctx = { brewCount: 2, brewVolumeHl: 40 };
const row = (o) => Object.assign({ id: o.id || 1, is_added: false, is_removed: false, sort_order: 0 }, o);
const cas90 = row({ id: 1, addition_type: 'dry_hop', unit: 'g', recipe_quantity: 10000, quantity: 8000, ingredient_id: 11 });
const cas45 = row({ id: 2, addition_type: 'dry_hop', unit: 'g', recipe_quantity: 2500, quantity: 3500, ingredient_id: 12 });
const pale = row({ id: 3, addition_type: 'malt', unit: 'kg', recipe_quantity: 405, quantity: 415, ingredient_id: 13 });
const bevasil = row({ id: 4, addition_type: 'cellar_addition', unit: 'ml/hl', recipe_quantity: 40, quantity: 45, ingredient_id: 14 });
const protafloc = row({ id: 5, addition_type: 'brewhouse_addition', unit: 'g/hl', recipe_quantity: 2.75, quantity: 2.75, is_removed: true, ingredient_id: 15 });
const same = row({ id: 6, addition_type: 'malt', unit: 'kg', recipe_quantity: 380, quantity: 380, ingredient_id: 16 });

assert.deepStrictEqual(b.deviationDelta(cas90, ctx), { q: -2000, unit: 'g' });
assert.strictEqual(b.formatAmount(b.deviationDelta(cas90, ctx), { signed: true }), '−2.0 kg');
assert.strictEqual(b.formatAmount(b.deviationDelta(cas45, ctx), { signed: true }), '+1.0 kg');
assert.deepStrictEqual(b.deviationDelta(pale, ctx), { q: 20, unit: 'kg' });
assert.strictEqual(b.formatAmount(b.deviationDelta(pale, ctx), { signed: true }), '+20 kg');
assert.strictEqual(b.formatAmount(b.deviationDelta(bevasil, ctx), { signed: true }), '+400 ml');
assert.strictEqual(b.deviationKind(protafloc), 'Removed');
assert.strictEqual(b.formatAmount(b.deviationDelta(protafloc, ctx), { signed: true }), '−220 g');
assert.strictEqual(b.deviationKind(same), null);
assert.strictEqual(b.deviationDelta(same, ctx), null);

// Inventory effect
assert.strictEqual(b.inventoryEffect({ q: -2000, unit: 'g' }, true, 'CAS90-2025-088'), 'Return to same lot · CAS90-2025-088');
assert.strictEqual(b.inventoryEffect({ q: 1000, unit: 'g' }, true, null), 'Extra issue · lot to choose');
assert.strictEqual(b.inventoryEffect({ q: 1000, unit: 'g' }, false, 'X'), 'Picking list updated');

// Added and removed rows
const added = row({ id: 7, addition_type: 'yeast', unit: 'g/hl', recipe_quantity: null, quantity: 50, is_added: true, ingredient_id: 17 });
assert.strictEqual(b.deviationKind(added), 'Added');
assert.strictEqual(b.formatAmount(b.deviationDelta(added, ctx)), '4.0 kg');            // 50 g/hl × 80 hl
assert.strictEqual(b.deviationKind({ ...added, is_removed: true }), null);           // added then removed: no change left
// a removed recipe line without amount has no Δ but is still listed
assert.strictEqual(b.deviationDelta(row({ addition_type: 'cellar_addition', unit: null, recipe_quantity: null, quantity: null, is_removed: true }), ctx), null);

// Alpha / EBC differences are flagged, but are not stock deviations
const hop = row({ addition_type: 'boil_hop', unit: 'g', recipe_quantity: 2500, quantity: 2500, recipe_alpha_pct: 13.4, alpha_pct: 12.9 });
assert.strictEqual(b.alphaDiffers(hop), true);
assert.strictEqual(b.deviationKind(hop), null);
assert.strictEqual(b.colorDiffers(row({ recipe_color_ebc: 9, color_ebc: 9 })), false);
assert.strictEqual(b.alphaDiffers({ ...hop, is_added: true }), false);

// Brew amount (one brew)
assert.deepStrictEqual(b.brewAmount('brewhouse_addition', 'g/hl', 11, ctx), { q: 440, unit: 'g' });

// Deviation list: card order, names, lots, reasons
const list = b.deviationList([bevasil, cas90, same, pale, protafloc, added], ctx, {
  orderPickingComplete: true, names: { 11: 'Cascade T90', 13: 'Pale Ale Malt', 14: 'Bevasil', 15: 'Protafloc', 17: 'US-05' },
  lots: { 11: 'CAS90-2025-088' } });
assert.deepStrictEqual(list.map((d) => [d.kind, d.name]),
  [['Changed', 'Pale Ale Malt'], ['Changed', 'Cascade T90'], ['Removed', 'Protafloc'], ['Added', 'US-05'], ['Changed', 'Bevasil']]);
assert.strictEqual(list[1].effect, 'Return to same lot · CAS90-2025-088');
assert.strictEqual(list[0].effect, 'Extra issue · lot to choose');
assert.strictEqual(list[2].batch, null);
assert.strictEqual(list[3].recipe, null);
assert.ok(list.every((d) => d.needsReason));
assert.strictEqual(b.deviationList([{ ...added, quantity: null }], ctx).length, 0);      // added, no amount yet
assert.strictEqual(b.deviationList([{ ...pale, deviation_reason: '  ' }], ctx)[0].needsReason, true);
assert.strictEqual(b.deviationList([{ ...pale, deviation_reason: 'Short in stock' }], ctx)[0].needsReason, false);
assert.strictEqual(b.deviationList([{ ...pale, ingredient_id: null, note: 'Blend with Adriaan' }], ctx)[0].name, 'Blend with Adriaan');

// Boil time from timing text
assert.strictEqual(b.boilTimeMin('45'), 45);
assert.strictEqual(b.boilTimeMin('0 min'), 0);
assert.strictEqual(b.boilTimeMin('warm'), null);

// Hop totals over the batch: boil per brew × brews, dry hop as is, removed rows left out
const totals = b.hopTotals([
  row({ addition_type: 'boil_hop', unit: 'g', quantity: 2500, ingredient_id: 21 }),
  row({ addition_type: 'dry_hop', unit: 'g', quantity: 7500, ingredient_id: 21 }),
  row({ addition_type: 'boil_hop', unit: 'g', quantity: 250, ingredient_id: 22 }),
  row({ addition_type: 'dry_hop', unit: 'g', quantity: 1000, ingredient_id: 23, is_removed: true }),
], ctx, { 21: 'Citra T45', 22: 'Flex hop', 23: 'Cascade' });
assert.deepStrictEqual(totals, [{ name: 'Citra T45', boilG: 5000, dryG: 7500 }, { name: 'Flex hop', boilG: 500, dryG: 0 }]);

// Formatting
assert.strictEqual(b.formatAmount({ q: 2.75, unit: 'g' }), '2.75 g');
assert.strictEqual(b.formatAmount({ q: 1500, unit: 'ml' }), '1.5 l');
assert.strictEqual(b.formatAmount(null), '—');

console.log('batch-ingredients: all tests passed');
