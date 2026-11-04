// node tests/voorraad-forecast.test.js
const assert = require('assert');
const vf = require('../voorraad-forecast.js');

// Newest version per recipe group (regardless of status), as in brouwplanning.html
const recipes = [
  { id: 271, recipe_group_id: 'hc', version_major: 23, version_minor: 0 },
  { id: 669, recipe_group_id: 'hc', version_major: 25, version_minor: 2 },
  { id: 714, recipe_group_id: 'hc', version_major: 27, version_minor: 0 },
  { id: 900, recipe_group_id: null, version_major: 99, version_minor: 0 },
];
const newest = vf.vfNewestVersionPerGroup(recipes);
assert.strictEqual(newest.hc.id, 714);
assert.strictEqual(Object.keys(newest).length, 1);
assert.strictEqual(vf.vfResolveRecipeId({ recipe_id: 669, recipe_group_id: 'hc' }, newest), 714);
assert.strictEqual(vf.vfResolveRecipeId({ recipe_id: 669, recipe_group_id: null }, newest), 669);
assert.strictEqual(vf.vfResolveRecipeId({ recipe_id: 5, recipe_group_id: 'unknown' }, newest), 5);

// Minimal fake Supabase client: chainable filters, resolves with rows from `db`.
function fakeClient(db) {
  return {
    from(table) {
      const filters = [];
      const q = {
        select() { return q; },
        eq(c, v) { filters.push(r => r[c] === v); return q; },
        gte(c, v) { filters.push(r => r[c] >= v); return q; },
        lte(c, v) { filters.push(r => r[c] <= v); return q; },
        in(c, vs) { filters.push(r => vs.includes(r[c])); return q; },
        range(a, b) { return Promise.resolve(run().slice(a, b + 1)).then(data => ({ data, error: null })); },
        then(ok, fail) { return Promise.resolve({ data: run(), error: null }).then(ok, fail); },
      };
      const run = () => (db[table] || []).filter(r => filters.every(f => f(r)));
      return q;
    },
  };
}

// Heavy Cross case: planned on archived v25.2 (HM70), active v27.0 uses Kristalsuiker.
// The split target recipe was also revised (old 800 -> new 801).
const db = {
  brew_planning: [
    { id: 'p1', recipe_id: 669, recipe_group_id: 'hc', aantal_brouwsels: 1, brew_count: 1, iso_year: 2026, week_number: 46 },
  ],
  brew_planning_splits: [
    { brew_planning_id: 'p1', recipe_id: 800, recipe_group_id: 'fruit', hl: 10 },
  ],
  recipes: [
    ...recipes.slice(0, 3).map(r => ({ ...r, name: 'Heavy Cross 29', brew_volume_hl: 29 })),
    { id: 800, recipe_group_id: 'fruit', version_major: 1, version_minor: 0, name: 'Fruit', brew_volume_hl: null },
    { id: 801, recipe_group_id: 'fruit', version_major: 2, version_minor: 0, name: 'Fruit', brew_volume_hl: null },
  ],
  recipe_ingredients: [
    { recipe_id: 669, addition_type: 'sugar', ingredient_id: 1, quantity: 100, unit: 'kg' },  // HM70 (old)
    { recipe_id: 714, addition_type: 'sugar', ingredient_id: 2, quantity: 120, unit: 'kg' },  // Kristalsuiker (new)
    { recipe_id: 800, addition_type: 'fruit', ingredient_id: 3, quantity: 5, unit: 'kg/hl' }, // old split fruit
    { recipe_id: 801, addition_type: 'fruit', ingredient_id: 4, quantity: 6, unit: 'kg/hl' }, // new split fruit
  ],
  ingredients: [
    { id: 1, name: 'HM70', unit: 'kg' }, { id: 2, name: 'Kristalsuiker', unit: 'kg' },
    { id: 3, name: 'Old fruit', unit: 'kg' }, { id: 4, name: 'New fruit', unit: 'kg' },
  ],
};
// The fake client ignores select aliases, so expose the aliased names the module reads.
db.recipe_ingredients.forEach(r => { r.rol = r.addition_type; r.hoeveelheid = r.quantity; r.eenheid = r.unit; });
db.recipes.forEach(r => { r.naam = r.name; r.brouwsel_hl = r.brew_volume_hl; });
db.ingredients.forEach(i => { i.naam = i.name; i.eenheid = i.unit; });

(async () => {
  const res = await vf.vfBerekenVerbruik(fakeClient(db), [{ jaar: 2026, vanWeek: 45, totWeek: 47 }]);
  assert.ok(!res.error, res.error && res.error.message);
  const ids = Object.values(res.perIngredient).map(r => r.ingredientId).sort();
  assert.deepStrictEqual(ids, [2, 4], 'only ingredients of the newest versions are counted');
  assert.strictEqual(res.perIngredient['2|kg'].totaal, 120);
  assert.strictEqual(res.perIngredient['4|kg'].totaal, 60);
  assert.strictEqual(res.perIngredient['2|kg'].perWeek['2026-W46'], 120);
  console.log('voorraad-forecast tests passed');
})().catch(e => { console.error(e); process.exit(1); });
