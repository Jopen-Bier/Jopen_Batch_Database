// node tests/recipe-values.test.js
const assert = require('assert');
const v = require('../recipe-values.js');

// Codes must match the check constraints of migration 20261016190000.
assert.deepStrictEqual(Object.keys(v.RECIPE_LOCATION_LABELS).sort(), ['jk', 'wp']);
assert.deepStrictEqual(Object.keys(v.RECIPE_STATUS_LABELS).sort(), ['active', 'archived', 'draft']);
assert.deepStrictEqual(Object.keys(v.ADDITION_TYPE_LABELS).sort(), ['boil_hop', 'brewhouse_addition', 'cellar_addition', 'dry_hop', 'malt', 'yeast']);
assert.deepStrictEqual(Object.keys(v.BEER_RISK_LABELS).sort(), ['contains_sugar', 'dangerous', 'sensitive', 'standard']);
assert.deepStrictEqual(Object.keys(v.BEER_STATUS_LABELS).sort(), ['npi', 'standard', 'to_improve']);
// every code has a colour and a report text
for (const k of Object.keys(v.BEER_RISK_LABELS)) { assert.ok(v.BEER_RISK_COLORS[k], k); assert.ok(v.BEER_RISK_REPORT_TEXT[k], k); }
for (const k of Object.keys(v.BEER_STATUS_LABELS)) { assert.ok(v.BEER_STATUS_COLORS[k], k); assert.ok(v.BEER_STATUS_REPORT_TEXT[k], k); }
// the report text is what the batch report template's conditional formatting matches on
assert.strictEqual(v.BEER_RISK_REPORT_TEXT.contains_sugar, 'Suikerhoudend');
assert.strictEqual(v.BEER_STATUS_REPORT_TEXT.to_improve, 'Te verbeteren');

assert.strictEqual(v.locationLabel('wp'), 'WP');
assert.strictEqual(v.locationLabel(null), '—');
assert.strictEqual(v.locationLabel('elsewhere'), 'elsewhere');
assert.strictEqual(v.valueLabel(v.BEER_RISK_LABELS, 'contains_sugar'), 'Contains sugar');
assert.ok(v.valueOptionsHtml(v.BEER_STATUS_LABELS, { empty: true }).startsWith('<option value="">'));
console.log('recipe-values: all tests passed');
