// brew-calculations.js — shared brewing calculations (hop utilization, EBU,
// malt color). The one place for these formulas: recipe entry, recipe
// overview and both batch report generators (browser + Node) use this file.
// Tests: tests/brew-calculations.test.js.
//
// Browser: <script src="brew-calculations.js"></script> (classic script,
// functions become globals). Node: require('../brew-calculations.js').
//
// The formulas follow the original Excel recipe sheet (Moederdata.xlsm).

// --- Hop utilization -------------------------------------------------------
// Source: Moederdata.xlsm, sheet "EBU Berekening" (T2:AF27) and Recipe
// Sheet!K43/K64. Only for boil hop additions; dry hop has no boil time and
// gets no utilization/EBU. 0 min deliberately has utilization (whirlpool
// bitterness), as in the original.
// Utilization % per boil time (rows, minutes) and wort SG (columns). Lookup
// works like the VLOOKUP in Excel: exact boil time, and the largest SG column
// that is <= the SG of the wort. null = empty cell in the source table.
const HOP_SG_COLUMNS = [1.02, 1.03, 1.04, 1.05, 1.06, 1.07, 1.08, 1.09, 1.10, 1.11, 1.12, 1.13];
const HOP_UTILIZATION_TABLE = [
  { boilTimeMin: 0,   utilizationPct: [6.5, 6, 6, 5.5, 5, 3, 2.5, 2, 1.8, 1.7, 1.6, null] },
  { boilTimeMin: 5,   utilizationPct: [9.5, 9, 8, 7.5, 6, 3.5, 3, 2.8, 2.5, 2.4, 2.3, null] },
  { boilTimeMin: 10,  utilizationPct: [18, 16, 14, 11, 9, 7, 7, 6.5, 5, 4.8, 4.6, null] },
  { boilTimeMin: 15,  utilizationPct: [18, 17.5, 17, 15, 14, 12, 10, 9, 7, 6.5, 6.3, null] },
  { boilTimeMin: 20,  utilizationPct: [25, 23, 21, 20, 16, 14, 12, 11, 9, 8.5, 8.2, null] },
  { boilTimeMin: 25,  utilizationPct: [27.5, 26, 24.5, 23.68, 20, 17, 15, 14, 11, 10, 9.5, null] },
  { boilTimeMin: 30,  utilizationPct: [30, 28, 26, 24, 22, 20, 17, 16, 14, 13, 11, null] },
  { boilTimeMin: 35,  utilizationPct: [31, 29, 27, 25, 23, 21, 19, 17, 16, 15, 14.5, null] },
  { boilTimeMin: 40,  utilizationPct: [32, 30, 28, 26, 24, 22, 20, 19, 17, 16, 15, null] },
  { boilTimeMin: 45,  utilizationPct: [34, 32, 30, 27, 25, 24, 21, 20, 18, 17, 16, null] },
  { boilTimeMin: 50,  utilizationPct: [36, 34, 32, 28, 25, 25, 22, 21, 19, 18, 17, null] },
  { boilTimeMin: 55,  utilizationPct: [40, 37, 34, 29.5, 26, 25, 23, 22, 20, 19, 18, null] },
  { boilTimeMin: 60,  utilizationPct: [42, 39, 36, 31, 27.07, 26, 25, 23, 21, 20, 19, null] },
  { boilTimeMin: 65,  utilizationPct: [45, 41, 37, 33, 30, 28, 27, 25, 23, 21, 21, null] },
  { boilTimeMin: 70,  utilizationPct: [45, 42.5, 40, 35, 33, 32, 30, 27, 25, 23, 23, null] },
  { boilTimeMin: 75,  utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 80,  utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 90,  utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 95,  utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 100, utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 105, utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 110, utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 115, utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { boilTimeMin: 120, utilizationPct: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
];

// SG of the wort from the original extract (°P), as in Excel: only the first
// two characters of the value are used (e.g. 18.7 -> 18), then
// SG = 259 / (259 - °P), rounded to 2 decimals. null if not a number.
function hopWortSg(originalExtractPlato) {
  const plato = parseInt(String(originalExtractPlato).slice(0, 2), 10);
  if (Number.isNaN(plato)) return null;
  return Math.round((259 / (259 - plato)) * 100) / 100;
}

// Index of the largest SG column <= sg, or -1 if sg is below the first column.
function hopSgColumnIndex(sg) {
  let idx = -1;
  for (let i = 0; i < HOP_SG_COLUMNS.length; i++) {
    if (HOP_SG_COLUMNS[i] <= sg) idx = i;
  }
  return idx;
}

// Utilization % for a boil hop addition. null when the boil time is not in
// the table (exact match), the original extract is missing, or the table
// cell is empty.
function hopUtilizationPct(boilTimeMin, originalExtractPlato) {
  const sg = hopWortSg(originalExtractPlato);
  if (sg === null) return null;
  const col = hopSgColumnIndex(sg);
  if (col === -1) return null;
  const row = HOP_UTILIZATION_TABLE.find((r) => r.boilTimeMin === boilTimeMin);
  return row ? row.utilizationPct[col] : null;
}

// EBU of one hop addition. Excel: (Gram*1000) * (alpha/100) * (utilization/100)
// / volume in liters. The recipe stores the same raw "Gram" value as Excel
// (e.g. 5000), so the *1000 of the original stays.
function hopEbu(weightGram, alphaPct, boilTimeMin, originalExtractPlato, boilVolumeHl) {
  const utilizationPct = hopUtilizationPct(boilTimeMin, originalExtractPlato);
  if (utilizationPct === null || !boilVolumeHl || !weightGram || alphaPct == null) return null;
  const volumeLiter = boilVolumeHl * 100;
  return (weightGram * 1000) * (alphaPct / 100) * (utilizationPct / 100) / volumeLiter;
}

// --- Malt color --------------------------------------------------------------
// Calculated beer color (EBC) from the malt bill. Excel (Recipe Sheet!F30:F40):
// sum of (kg * EBC * 0.08) / brew volume (hl), + 1.75. malts: [{ kg, ebc }],
// missing values count as 0. null when there is no brew volume.
// Keep in sync with the SQL function public.product_sheet_calculated_color,
// which applies the same formula in the database (product sheet sync hash).
function maltColorEbc(malts, brewVolumeHl) {
  if (!brewVolumeHl) return null;
  const contribution = (malts || []).reduce(
    (sum, m) => sum + ((Number(m.kg) || 0) * (Number(m.ebc) || 0) * 0.08) / brewVolumeHl,
    0
  );
  return contribution + 1.75;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    HOP_SG_COLUMNS, HOP_UTILIZATION_TABLE,
    hopWortSg, hopSgColumnIndex, hopUtilizationPct, hopEbu, maltColorEbc,
  };
}
