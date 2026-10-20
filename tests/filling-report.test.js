// node tests/filling-report.test.js
const assert = require('assert');
const r = require('../filling-report.js');

// Master data as the mockup: two can articles sharing can / lid
const articles = new Map([
  [1, { id: 1, code: 'box_12x33_can', package_format: 'can', liters_per_unit: 3.96, sort_order: 80 }],
  [2, { id: 2, code: 'box_24x33_can', package_format: 'can', liters_per_unit: '7.92', sort_order: 90 }],
  [3, { id: 3, code: 'keykeg_20', package_format: 'keg', liters_per_unit: 20, sort_order: 120 }],
]);
// materials: 10 can 33, 11 lid, 12 box 12, 13 box 24, 20 keykeg, 21 keykeg cap
const bom = r.bomByArticle([
  { article_id: 1, material_id: 10, quantity: 12 }, { article_id: 1, material_id: 11, quantity: 12 }, { article_id: 1, material_id: 12, quantity: 1 },
  { article_id: 2, material_id: 10, quantity: 24 }, { article_id: 2, material_id: 11, quantity: 24 }, { article_id: 2, material_id: 13, quantity: 1 },
  { article_id: 3, material_id: 20, quantity: 1 }, { article_id: 3, material_id: 21, quantity: 1 },
]);

// Book in / book out of a session
const s1 = r.sessionBook(
  [{ article_id: 1, quantity: 800 }, { article_id: 2, quantity: '100' }, { article_id: 3, quantity: null }],
  [{ material_id: 10, quantity: 12055 }, { material_id: 11, quantity: '11990' }, { material_id: 13, quantity: null }, { material_id: 99, quantity: 5 }],
  articles, bom);
assert.strictEqual(Math.round(s1.litres), 3960);
assert.deepStrictEqual(s1.articles.map((a) => Math.round(a.litres)), [3168, 792, 0]);
assert.strictEqual(Math.round(s1.litresByFormat.can), 3960);
assert.strictEqual(s1.litresByFormat.keg, 0);
const mat = (id) => s1.materials.find((m) => m.material_id === id);
assert.deepStrictEqual(s1.materials.map((m) => m.material_id), [10, 11, 12, 13, 20, 21, 99]);   // expected first, then other booked
assert.deepStrictEqual([mat(10).expected, mat(10).used, mat(10).loss], [12000, 12055, 55]);
assert.strictEqual(mat(11).loss, -10);
assert.deepStrictEqual([mat(12).expected, mat(12).used, mat(12).loss, mat(12).row], [800, null, null, null]);
assert.strictEqual(mat(13).loss, null);          // booked but empty
assert.strictEqual(mat(20).expected, 0);         // article without count
assert.deepStrictEqual([mat(99).expected, mat(99).loss], [0, 5]);
assert.strictEqual(r.materialLossClass(55), 'lost');
assert.strictEqual(r.materialLossClass(-10), 'short');
assert.strictEqual(r.materialLossClass(0), 'ok');
assert.strictEqual(r.materialLossClass(null), '');

// Over all sessions: material rows of several sessions add up
const all = r.sessionBook([{ article_id: 3, quantity: 30 }, { article_id: 3, quantity: 10 }],
  [{ material_id: 20, quantity: 31 }, { material_id: 20, quantity: 10 }, { material_id: 21, quantity: null }], articles, bom);
assert.deepStrictEqual([all.materials[0].expected, all.materials[0].used, all.materials[0].loss], [40, 41, 1]);
assert.strictEqual(all.materials[1].used, null);
assert.deepStrictEqual(r.articleTotals([{ article_id: 3, quantity: 30 }, { article_id: 1, quantity: 2 }, { article_id: 3, quantity: 10 }, { article_id: 7, quantity: 1 }], articles)
  .map((x) => [x.article.id, x.count, x.litres]), [[1, 2, 7.92], [3, 40, 800]]);

// Session difference: filled litres against the session volume (hl), ±3 % green
assert.deepStrictEqual(r.sessionDifference(3960, 40.5), { diffL: -90, ok: true });
assert.strictEqual(r.sessionDifference(3800, 40.5).ok, false);
assert.strictEqual(r.sessionDifference(3960, null), null);

// Volume balance (mockup: 80 hl GLT, 3 hl split from GLT, 75.5 hl in HBT)
const b = r.volumeBalance({
  gltHl: 80, hbtEndTotalHl: 75.5, hbtTankIds: [12, 14],
  transfers: [{ from_tank_id: 7, volume_hl: 3 }, { from_tank_id: 14, volume_hl: '1.5' }],
  packagedHl: { bottle: 19.8, can: 39.6, keg: 12.7 },
});
assert.strictEqual(b.splitsPreHl, 3);
assert.strictEqual(b.splitsPostHl, 1.5);
assert.strictEqual(b.cellarLossHl.toFixed(2), '1.50');
assert.strictEqual(b.availableHl, 74);
assert.strictEqual(b.packagedTotalHl.toFixed(1), '72.1');
assert.strictEqual(b.remainderHl.toFixed(1), '1.9');
assert.strictEqual(b.remainderShare.toFixed(4), '0.0257');
assert.strictEqual(b.remainderOk, true);
assert.strictEqual(b.cellarLossNegative, false);
assert.strictEqual(b.preTransfers.length, 1);
const neg = r.volumeBalance({ gltHl: 70, hbtEndTotalHl: 75.5, packagedHl: {} });
assert.strictEqual(neg.cellarLossNegative, true);
assert.strictEqual(neg.remainderOk, false);     // nothing packaged: 100 % remainder
assert.strictEqual(r.volumeBalance({ gltHl: null, hbtEndTotalHl: 0 }).cellarLossHl, null);
assert.strictEqual(r.volumeBalance({ gltHl: 10 }).remainderShare, null);

// A split batch: no GLT volume, 25.5 hl in from splits
const sb = r.volumeBalance({ gltHl: null, incomingHl: 25.5, hbtEndTotalHl: 25, packagedHl: { can: 24.8 } });
assert.deepStrictEqual([sb.gltHl, sb.startHl, sb.cellarLossHl], [0, 25.5, 0.5]);
assert.strictEqual(sb.remainderHl.toFixed(1), '0.2');
assert.strictEqual(r.pieParts(sb)[1].share.toFixed(3), '0.973');   // share of 25.5 hl
assert.strictEqual(b.startHl, 80);

// Pie: parts with share of GLT; negatives count 0; slices only above 0
const parts = r.pieParts(b);
assert.deepStrictEqual(parts.map((p) => p.key), ['bottle', 'can', 'keg', 'splits', 'cellarLoss', 'remainder']);
assert.strictEqual(parts[3].hl, 4.5);
assert.strictEqual(parts[1].share.toFixed(3), '0.495');
assert.strictEqual(r.pieParts(neg)[4].hl, 0);
const slices = r.pieSlices(parts);
assert.strictEqual(slices.length, 6);
assert.ok(slices[0].d.startsWith('M100,100 L100.00,8.00 A92,92'));
assert.strictEqual(r.pieSlices([{ key: 'can', hl: 5, color: '#000' }])[0].d, 'M8,100 a92,92 0 1,0 184,0 a92,92 0 1,0 -184,0');
assert.deepStrictEqual(r.pieSlices([{ key: 'can', hl: 0 }]), []);

console.log('filling-report: all tests passed');
