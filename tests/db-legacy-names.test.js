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

// --- step 8: inverse direction and arrays ---
const { fromDb, fromDbResult } = require('../db-legacy-names.js');
assert.deepStrictEqual(fromDb('recipes', { id: 1, name: 'IPA', location: 'wp', status: 'active' }),
  { id: 1, naam: 'IPA', locatie: 'wp', status: 'active' });
// a column without an old name keeps its English key
assert.deepStrictEqual(fromDb('recipe_brewing_specs', { brewhouse_recipe_name_wp: 'X', mash_water: 3 }),
  { brewhouse_recipe_name_wp: 'X', maischwater: 3 });
assert.strictEqual(fromDb('recipes', null), null);
// toDb and fromDb are each other's inverse
const row = { naam: 'IPA', brouwsel_hl: 60, kleur: '#fff', recipe_group_id: 'g' };
assert.deepStrictEqual(fromDb('recipes', toDb('recipes', row)), row);
// arrays
assert.deepStrictEqual(toDb('recipe_ingredients', [{ rol: 'malt' }, { hoeveelheid: 2 }]), [{ addition_type: 'malt' }, { quantity: 2 }]);
assert.deepStrictEqual(fromDbResult('recipe_ingredients', { data: [{ addition_type: 'malt' }], error: null }),
  { data: [{ rol: 'malt' }], error: null });
assert.deepStrictEqual(fromDbResult('recipe_specs', { data: null, error: null }), { data: null, error: null });
// tables without renames are known too
assert.deepStrictEqual(toDb('recipe_comments', { comments: [] }), { comments: [] });
assert.throws(() => fromDb('nope', {}));
console.log('db-legacy-names (step 8): all tests passed');
