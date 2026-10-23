// ============================================================================
// brewhouse-design.js — brewhouse design of a recipe (mash filter, WP
// brewhouse): from the grist and the targets to the volume and °P at the GLT
// and the load on the mash filter. Follows Brewcalc 1.00 (G.G. Bolink, sheet
// "Brewcalc", mash filter path, column brew1) cell by cell; cell references
// in the comments. Lauter tun, cooling, air and the cellar chain are left out
// (Jaap, 23-10). Test: tests/brewhouse-design.test.js (checked against the
// sheet's own values for Mooie Nel and a second grist).
//
// Browser: <script src="brewhouse-design.js">. Node: require('../brewhouse-design.js').
// ============================================================================

// House values of Brewcalc (the fixed values the brewers designed with).
const BREWHOUSE_DEFAULTS = {
  brewhouseLossPct: 1.5,      // O38: % of the grist kg below the lab extract
  waterGristRatio: 2.6,       // P42: l/kg
  mashInTemp: 52,             // P45: °C
  rinseWaterHl: 0.5,          // P55
  rinseWaterTemp: 85,         // O55
  maltVolumeLPerKg: 0.7,      // P52: volume of malt in water
  spentGrainsDryMatter: 0.25, // O83
  evaporationPct: 2,          // O88: % of the volume at the end of boiling
  hopCorrection: 3,           // O99: factor on the whirlpool loss (hops)
  whirlpoolLossPct: 2,        // P99: standard whirlpool loss
  precoolTemp: 85,            // O98: °C
  dilutionWaterTemp: 78,      // O104: °C
  coolTemp: 20,               // O106: °C
  chambers: 27,               // the maximum and the most efficient (Jaap, 23-10)
};

// Mash filter (Meura Hybrid): chamber area 0.9409 m² (O72), load per chamber
// 32–38 kg malt equivalent, nominal 35 (B75).
const CHAMBER_AREA_M2 = (1.2 - 0.23) * (1.2 - 0.23);
const CHAMBER_LOAD = { min: 32, nominal: 35, max: 38 };

// --- Densities, as in the sheet --------------------------------------------
/** Extract °P → g/100 ml (w/v), e.g. O90. */
function platoToWv(p) {
  return ((0.0000188792 * p + 0.003646886) * p + 1.001077) * p - 0.01223565;
}
/** Second w/v formula of the sheet, used for the main wort (O76). */
function platoToWvMainWort(p) {
  return 0.99894 * p + 3.77 * p * p / 1000 + 1.6682 * p ** 3 / 100000;
}
/** g/100 ml → °P (N87). */
function wvToPlato(x) {
  return 0.0000106385 * x ** 3 - 0.003679009 * x * x + 0.9991461 * x + 0.0114127;
}
/** Density of water kg/m³ at t °C (L94). */
function waterDensity(t) {
  return -0.0000001 * t ** 4 + 0.00004 * t ** 3 - 0.0078 * t * t + 0.0596 * t + 999.88;
}
/** kg water per hl at t °C, the mash form (K42). */
function waterKgPerHl(t) {
  return (-0.0034 * t * t - 0.0862 * t + 1000.906) / 10;
}

/**
 * The design of one brew.
 * grist: [{ kg, labYield (0–1, e.g. 0.81), meFactor (malt equivalent, 1 for
 *   malt, < 1 for flakes / raw grain), kettle: true for sugar / syrup added
 *   in the kettle (no mash, no filter load), dryMatter (kettle, 0–1) }]
 * options: { castPlato, transferPlato, chambers, ...BREWHOUSE_DEFAULTS }
 *   castPlato = °P at casting (P90 = P91), transferPlato = °P to the GLT (P103).
 */
function brewhouseDesign(grist, options) {
  const o = { ...BREWHOUSE_DEFAULTS, ...options };
  const mash = grist.filter((g) => !g.kettle);
  const kettle = grist.filter((g) => g.kettle);
  const sum = (rows, f) => rows.reduce((s, g) => s + f(g), 0);

  // Raw materials (rows 12–38)
  const mashKg = sum(mash, (g) => g.kg);                                   // P49
  const allKg = mashKg + sum(kettle, (g) => g.kg);
  const labExtractMashKg = sum(mash, (g) => g.kg * g.labYield);            // K31
  const labExtractKg = labExtractMashKg + sum(kettle, (g) => g.kg * g.labYield);   // K37
  const loss = o.brewhouseLossPct / 100;
  const extractMashKg = labExtractMashKg - loss * mashKg;                  // L31
  const extractKg = labExtractKg - loss * allKg;                           // L37
  const meKg = sum(mash, (g) => g.kg * (g.meFactor ?? 1));                 // N32

  // Mash filter (rows 70–84): the chambers are chosen, the load follows
  const chambers = o.chambers;
  const loadPerChamber = chambers ? meKg / chambers : null;                // P75
  const filterAreaM2 = CHAMBER_AREA_M2 * chambers;                         // P72
  const filterVolumeHl = filterAreaM2 * 0.0483 * 10;                       // P73
  const loadPerM2 = filterAreaM2 ? meKg / filterAreaM2 : null;             // P74

  // Mashing (rows 40–55)
  const mashWaterHl = mashKg * o.waterGristRatio / 100;                    // L42
  const mashWaterKg = waterKgPerHl(o.mashInTemp) * mashWaterHl;            // K42 + K55
  const mashTotalHl = (mashWaterHl - o.rinseWaterHl + o.maltVolumeLPerKg * mashKg / 100) * 988 / 974;   // P54
  const mashTransferHl = mashTotalHl + o.rinseWaterHl;                     // P57 = P71

  // Boiling (rows 85–94)
  const kettleVolumeHl = sum(kettle, (g) => g.kg / (g.dryMatter ?? 1) / (g.syrup ? 126.8 : 150.7));   // O89
  const boilEndHl = 1.042 * extractKg / platoToWv(o.castPlato);             // P89 (hot)
  const evaporationHl = boilEndHl * o.evaporationPct / 100;                // P88
  const boilStartHl = boilEndHl + evaporationHl - kettleVolumeHl;          // P86 (lautered wort)
  const boilStartPlato = wvToPlato(extractMashKg / (boilStartHl / 1.042)); // P87
  const castColdHl = extractKg / platoToWv(o.castPlato) * waterDensity(20) / waterDensity(o.coolTemp);   // P93
  const castHotHl = waterDensity(o.coolTemp) / waterDensity(100) * castColdHl;   // O93

  // Main wort and sparging in the filter (rows 76–82)
  const firstWortPlato = labExtractMashKg / (mashWaterKg + labExtractMashKg) * 100;   // P76
  const mainWortHl = extractMashKg / platoToWvMainWort(firstWortPlato) * 998.2 / 974.3;   // P77
  const spentGrainsKg = (mashKg * (1 - 0.04) - extractMashKg) / o.spentGrainsDryMatter;   // P83
  const pressedMainHl = 0.25 * chambers;                                   // P78
  const pressedSpargeHl = 0.5 * chambers + chambers / 10;                  // P80
  const filteredMainHl = mainWortHl - spentGrainsKg / 100 - pressedMainHl < mashTransferHl - filterVolumeHl
    ? mainWortHl - spentGrainsKg / 100 - pressedSpargeHl
    : mashTransferHl - filterVolumeHl;                                     // O78
  const lauteredCorrHl = boilStartHl * 1.0259 / 1.0437;                    // O86
  const spargeVolumeHl = lauteredCorrHl - pressedMainHl - filteredMainHl - pressedSpargeHl;   // O80
  const spargeWaterHl = spargeVolumeHl + pressedMainHl;                    // P82

  // Whirlpool and dilution (rows 96–106)
  const wpLossFraction = o.hopCorrection * o.whirlpoolLossPct / 100;
  const wpLossHl = wpLossFraction * castHotHl;                             // P100
  const afterWpHl = waterDensity(100) / waterDensity(o.precoolTemp) * castHotHl * (1 - wpLossFraction);   // P101
  const extractAfterWpKg = extractKg * (1 - wpLossFraction);               // P102
  const toGltHl = extractAfterWpKg / platoToWv(o.transferPlato);           // P106 (cold)
  // P105 depends on its own temperature (O105): a few rounds settle it, as Excel's iteration
  let mixTemp = o.precoolTemp, hotHl = toGltHl;
  for (let i = 0; i < 20; i++) {
    hotHl = toGltHl * waterDensity(o.coolTemp) / waterDensity(mixTemp);   // P105
    const dil = Math.max(0, hotHl - afterWpHl);
    mixTemp = (dil * o.dilutionWaterTemp + afterWpHl * o.precoolTemp) / hotHl;   // O105
  }
  const dilutionHl = hotHl - afterWpHl < 0.01 ? 0 : hotHl - afterWpHl;     // P104

  return {
    mashKg, allKg, meKg, labExtractKg, extractKg, extractMashKg,
    chambers, loadPerChamber, loadPerM2, loadOk: loadPerChamber !== null && loadPerChamber >= CHAMBER_LOAD.min && loadPerChamber <= CHAMBER_LOAD.max,
    mashWaterHl, mashTransferHl, firstWortPlato, spargeWaterHl, spentGrainsKg,
    boilStartHl, boilStartPlato, evaporationHl, boilEndHl, castColdHl, castHotHl,
    wpLossHl, extractAfterWpKg, dilutionHl, toGltHl,
  };
}

/**
 * Scale the grist (same shares) so the brew gives targetHl at the GLT — the
 * "factor" of Brewcalc (P11), worked out instead of tried. Returns the factor;
 * brewhouseDesign is linear in the grist up to the fixed rinse water, so a few
 * rounds of the secant method settle it.
 */
function gristFactorForVolume(grist, options, targetHl) {
  const at = (f) => brewhouseDesign(grist.map((g) => ({ ...g, kg: g.kg * f })), options).toGltHl;
  let f = targetHl / at(1);
  for (let i = 0; i < 5; i++) f *= targetHl / at(f);
  return f;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BREWHOUSE_DEFAULTS, CHAMBER_AREA_M2, CHAMBER_LOAD,
    platoToWv, platoToWvMainWort, wvToPlato, waterDensity, waterKgPerHl,
    brewhouseDesign, gristFactorForVolume,
  };
}
