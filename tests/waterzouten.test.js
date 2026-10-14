// node tests/waterzouten.test.js
const assert = require('assert');
const { wzBereken } = require('../waterzouten.js');
const bron = { ca: 21.3, mg: 3.3, na: 24.5, cl: 28.7, so4: 17.7, alkalinity: 65.3 };
const caps = { ca: 300, mg: 30, cl: 400, so4: 600 };
const g = (r, k) => r.zouten.find((z) => z.key === k);
const p = (r, k) => r.profiel.find((x) => x.key === k);

// 1. Braubeviale Barth Haas (40 hl), split: zelfde als mockup
let r = wzBereken({ bron, caps, hl: 40, split: true, doel: { ca: 60, mg: 7, na: 24, cl: 60, so4: 84, ratio: 0.7 } });
assert.deepStrictEqual([g(r, 'cacl').mash, g(r, 'cacl').boil], [170, 90]);
assert.deepStrictEqual([g(r, 'gips').mash, g(r, 'gips').boil], [240, 120]);
assert.deepStrictEqual([g(r, 'epsom').mash, g(r, 'epsom').boil], [110, 60]);
assert.strictEqual(g(r, 'nacl').perBrouwsel, 0);
['cl', 'so4', 'ca', 'mg', 'na'].forEach((k) => assert.strictEqual(p(r, k).status, 'ok', k));
assert.strictEqual(p(r, 'ratio').status, 'ok');

// 2. Zonder split: één hoeveelheid, afgerond op 10 g
r = wzBereken({ bron, caps, hl: 40, split: false, doel: { ca: 60, mg: 7, na: 24, cl: 60, so4: 84 } });
assert.deepStrictEqual(r.zouten.map((z) => z.perBrouwsel), [260, 360, 170, 0]);
r.zouten.forEach((z) => assert.strictEqual(z.perBrouwsel % 10, 0));

// 3. Nonnetje IPA (60 hl, Na 60): NaCl levert Na, calcium blijft onder doel
r = wzBereken({ bron, caps, hl: 60, split: false, doel: { ca: 118, mg: 7, na: 60, cl: 167, so4: 84, ratio: 2 } });
assert.deepStrictEqual(r.zouten.map((z) => z.perBrouwsel), [1050, 710, 0, 540]);
assert.strictEqual(p(r, 'ca').status, 'below');
assert.ok(r.meldingen.some((m) => m.startsWith('Calcium ends')));

// 4. Mg-cap: Hop to be square
r = wzBereken({ bron, caps, hl: 40, split: false, doel: { ca: 96.5, mg: 7, na: 60, cl: 74, so4: 293, ratio: 0.25 } });
assert.ok(p(r, 'mg').resultaat <= 30.5);
assert.strictEqual(p(r, 'so4').status, 'ok');
assert.strictEqual(p(r, 'na').status, 'below');

// 5. Caps: doelen boven de cap
r = wzBereken({ bron, caps, hl: 40, split: false, doel: { ca: 350, mg: 7, na: 60, cl: 450, so4: 700 } });
assert.strictEqual(p(r, 'cl').status, 'cap');
assert.strictEqual(p(r, 'ca').status, 'cap');
assert.ok(p(r, 'ca').resultaat <= 302 && p(r, 'cl').resultaat <= 402);

// 6. Leeg doel en brouwsel 0 geven geen fouten
r = wzBereken({ bron, caps, hl: 0, split: true, doel: {} });
r.zouten.forEach((z) => assert.strictEqual(z.perBrouwsel, 0));
assert.strictEqual(p(r, 'cl').status, 'none');

console.log('waterzouten: alle tests geslaagd');
