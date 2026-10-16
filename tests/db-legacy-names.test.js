// node tests/db-legacy-names.test.js
const assert = require('assert');
const { toDb, DB_LEGACY_COLUMNS } = require('../db-legacy-names.js');

// renames known keys, leaves unknown/unchanged keys alone
assert.deepStrictEqual(
  toDb('ingredients', { naam: 'Pils', versie_minor: 2, category_id: 1, alpha_pct: null }),
  { name: 'Pils', version_minor: 2, category_id: 1, alpha_pct: null });
assert.deepStrictEqual(toDb('stock_movements', { type: 'consumption', hoeveelheid: 5 }), { movement_type: 'consumption', quantity: 5 });
assert.deepStrictEqual(toDb('lots', { lotcode: 'L1', ontvangstcontrole: true }), { lot_code: 'L1', receiving_check: true });
// unknown table fails loudly
assert.throws(() => toDb('nope', {}));
// no map ever points two old keys to the same column
for (const [t, m] of Object.entries(DB_LEGACY_COLUMNS)) {
  const vals = Object.values(m);
  assert.strictEqual(new Set(vals).size, vals.length, t);
}
console.log('db-legacy-names: all tests passed');
