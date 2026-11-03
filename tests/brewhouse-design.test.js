// node tests/brewhouse-design.test.js
// Reference values: Brewcalc 1.00 - Mooie Nel.xlsm, sheet Brewcalc, cached
// results of column brew1 (P) and brew3 (AB), mash filter path.
const assert = require('assert');
const d = require('../brewhouse-design.js');

// The sheet's loss is % of the grist kg; the module's is % of the lab extract.
const sheetLoss = (pctOfGrist, kg, labKg) => pctOfGrist * kg / labKg;

const near = (actual, expected, tol, label) =>
  assert.ok(Math.abs(actual - expected) <= tol, `${label}: ${actual} vs ${expected}`);

function check(result, expected, label) {
  Object.entries(expected).forEach(([key, value]) => near(result[key], value, 1e-6 * Math.max(1, Math.abs(value)), `${label} ${key}`));
}

// brew1: 830 kg Pale Ale malt + 117 kg oat flakes, 15.5 °P, chambers as the sheet (load 35)
const brew1 = [{ kg: 830, labYield: 0.81, meFactor: 1 }, { kg: 117, labYield: 0.55, meFactor: 0.75 }];
const o1 = { castPlato: 15.5, transferPlato: 15.5, chambers: 917.75 / 35, brewhouseLossPct: sheetLoss(1.5, 947, 736.65) };
check(d.brewhouseDesign(brew1, o1), {
  labExtractKg: 736.65, extractKg: 722.445, meKg: 917.75, loadPerChamber: 35,
  mashWaterHl: 24.622, firstWortPlato: 23.25718910781737, mashTransferHl: 31.693006160164277,
  spargeBrewcalcHl: 24.29861777591115, boilStartHl: 46.67478561113997, boilStartPlato: 15.213633598210459,
  evaporationHl: 0.9151918747282346, boilEndHl: 45.75959373641173, castColdHl: 43.915157136671525,
  castHotHl: 45.7681544961843, wpLossHl: 2.746089269771058, extractAfterWpKg: 679.0983,
  toGltHl: 41.280247708471244, spentGrainsKg: 746.7,
}, 'brew1');
// Dilution water (P104) is a circular reference in the sheet; its cached values
// (0.037 / 0.539 hl) are an unsettled Excel iteration. Settled: no dilution when
// casting and transfer °P are equal (a trace when cooling below 20 °C).
assert.strictEqual(d.brewhouseDesign(brew1, o1).dilutionHl, 0, 'brew1 dilution');

// brew3: Pils 385, Pale Ale 390, wheat malt 75, barley flakes 50; 15 °P, 2 % loss, hop factor 2, mash-in 67 °C, cool 18 °C
const brew3 = [{ kg: 385, labYield: 0.81 }, { kg: 390, labYield: 0.81 }, { kg: 75, labYield: 0.81, meFactor: 0.7 }, { kg: 50, labYield: 0.55, meFactor: 0.85 }];
const o3 = { castPlato: 15, transferPlato: 15, chambers: 870 / 35, brewhouseLossPct: sheetLoss(2, 900, 716), hopCorrection: 2, mashInTemp: 67, coolTemp: 18 };
check(d.brewhouseDesign(brew3, o3), {
  labExtractKg: 716, extractKg: 698, meKg: 870, mashWaterHl: 23.4, firstWortPlato: 23.796141882329064,
  mashTransferHl: 30.11971252566735, spargeBrewcalcHl: 25.1690212743616, boilStartHl: 46.69270110508525,
  boilStartPlato: 14.72232610293842, boilEndHl: 45.777157946162006, castColdHl: 43.91475190426432,
  castHotHl: 45.78572199186804, wpLossHl: 1.8314288796747216, extractAfterWpKg: 670.08,
  toGltHl: 42.17473284867133, spentGrainsKg: 664,
}, 'brew3');
near(d.brewhouseDesign(brew3, o3).dilutionHl, 0.017, 0.001, 'brew3 dilution (cooling to 18 °C)');

// 27 chambers (default): the load follows from the grist
const at27 = d.brewhouseDesign(brew1, { castPlato: 15.5, transferPlato: 15.5 });
assert.strictEqual(at27.chambers, 27);
near(at27.loadPerChamber, 917.75 / 27, 1e-9, 'load at 27');
assert.strictEqual(at27.loadOk, true);
assert.strictEqual(d.brewhouseDesign([{ kg: 700, labYield: 0.81 }], { castPlato: 15.5, transferPlato: 15.5 }).loadOk, false, '25.9 kg per chamber is too low');

// dilution: casting higher than the transfer °P gives more hl
const hg = d.brewhouseDesign(brew1, { castPlato: 16.5, transferPlato: 15.5 });
assert.ok(hg.dilutionHl > 2 && Math.abs(hg.toGltHl - at27.toGltHl) < 1e-9, 'same extract, same hl at the GLT');

// grist factor: scale to 40 hl at the GLT
const f = d.gristFactorForVolume(brew1, { castPlato: 15.5, transferPlato: 15.5 }, 40);
near(d.brewhouseDesign(brew1.map((g) => ({ ...g, kg: g.kg * f })), { castPlato: 15.5, transferPlato: 15.5 }).toGltHl, 40, 1e-6, 'factor to 40 hl');

// default 7 % of the lab extract: Mooie Nel v12.1 (895 kg) close to its real ~39 hl
const nel = [{ kg: 405, labYield: 0.82 }, { kg: 380, labYield: 0.82 }, { kg: 85, labYield: 0.75, meFactor: 0.75 }, { kg: 25, labYield: 0.8, meFactor: 0.85 }];
const nelR = d.brewhouseDesign(nel, { castPlato: 15, transferPlato: 15, evaporationPct: 4, mashInTemp: 65, waterGristRatio: 2.85 });
near(nelR.extractKg, 727.45 * 0.93, 1e-6, 'Mooie Nel extract');
assert.ok(nelR.toGltHl > 38.5 && nelR.toGltHl < 40.5, String(nelR.toGltHl));   // real brews 36.8-40.8 hl
// sparge water from the water balance: Mooie Nel brew logs 25.7 hl mash water, 20.4 hl sparge
near(nelR.mashWaterHl, 25.5, 0.01, 'Mooie Nel mash water');
near(nelR.spargeWaterHl, 20.4, 1, 'Mooie Nel sparge (water balance)');

// kettle sugar: no mash or filter loss, no filter load
const withSugar = d.brewhouseDesign([...brew1, { kg: 100, labYield: 1, kettle: true }], { castPlato: 15.5, transferPlato: 15.5 });
near(withSugar.extractKg - at27.extractKg, 100, 1e-9, 'sugar extract');
near(withSugar.meKg, at27.meKg, 1e-9, 'sugar no load');

// densities
near(d.platoToWv(15.5), 16.4509259924, 1e-9, 'w/v 15.5');
near(d.waterDensity(20), 998.256, 1e-9, 'water 20 °C');

console.log('brewhouse-design: all tests passed');
