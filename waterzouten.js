// ============================================================================
// waterzouten.js — rekenkern van de Water salts calculator (receptpagina).
//
// Pure functies, geen DOM en geen Supabase: ook in Node te testen
// (zie tests/waterzouten.test.js). Bronwater en caps komen uit de tabel
// water_settings (Settings › Water); de zoutfactoren staan hieronder vast.
//
// Volgorde (afgesproken met Jaap):
//   0. Natrium  -> Natrium Chloride (enige natriumbron), maar nooit zoveel dat
//                  chloride boven het (gecapte) Cl-doel komt.
//   1. Chloride -> rest uit Calcium Chloride (flakes).
//   2. Sulfaat  -> Calcium Sulfaat en/of Magnesium Sulfaat.
//   3. Calcium  -> Calcium Sulfaat tot het Ca-doel; resterend sulfaat uit
//                  Magnesium Sulfaat. Boven de Mg-cap neemt Calcium Sulfaat het
//                  over; boven de Ca-cap stopt Calcium Sulfaat (sulfaat blijft
//                  dan onder doel). Caps winnen altijd van de volgorde.
// Hoeveelheden per brouwsel worden op 10 g afgerond (bij splitsen: ⅔ mash en
// ⅓ boil elk apart); het resulterende profiel rekent met wat echt gewogen wordt.
// Zuiveringszout en andere toevoegingen worden bewust niet meegerekend.
// ============================================================================

// ppm (mg/L) per 1 g/hl (= 10 mg/L) van elk zout
const WZ_ZOUTEN = [
  { key: 'cacl', naam: 'Calcium Chloride', formule: 'CaCl₂·2H₂O (flakes)', levert: 'Cl + Ca', ionen: { ca: 2.726, cl: 4.792 } },
  { key: 'gips', naam: 'Calcium Sulfaat', formule: 'CaSO₄·2H₂O (gypsum)', levert: 'SO₄ + Ca', ionen: { ca: 2.328, so4: 5.579 } },
  { key: 'epsom', naam: 'Magnesium Sulfaat', formule: 'MgSO₄·7H₂O (Epsom)', levert: 'SO₄ + Mg', ionen: { mg: 0.986, so4: 3.897 } },
  { key: 'nacl', naam: 'Natrium Chloride', formule: 'NaCl', levert: 'Na + Cl', ionen: { na: 3.934, cl: 6.066 } },
];
const WZ_IONEN = ['ca', 'mg', 'na', 'cl', 'so4'];
const WZ_SPLIT_MASH = 2 / 3;

function wzGetal(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * @param {object} p
 *   bron:  { ca, mg, na, cl, so4, alkalinity }   (ppm)
 *   caps:  { ca, mg, cl, so4 }                    (ppm)
 *   doel:  { ca, mg, na, cl, so4, ratio }         (ppm; leeg = geen doel)
 *   hl:    brouwselgrootte
 *   split: true = ⅔ mash / ⅓ boil
 * @returns resultaat-object (zie onderaan)
 */
function wzBereken(p) {
  const B = {}; WZ_IONEN.forEach((k) => { B[k] = wzGetal(p.bron[k]) ?? 0; });
  const alk = wzGetal(p.bron.alkalinity);
  const CAP = { ca: wzGetal(p.caps.ca) ?? Infinity, mg: wzGetal(p.caps.mg) ?? Infinity, cl: wzGetal(p.caps.cl) ?? Infinity, so4: wzGetal(p.caps.so4) ?? Infinity };
  const D = {}; ['ca', 'mg', 'na', 'cl', 'so4', 'ratio'].forEach((k) => { D[k] = wzGetal(p.doel[k]); });
  const hl = wzGetal(p.hl) ?? 0;
  const F = {}; WZ_ZOUTEN.forEach((z) => { F[z.key] = z.ionen; });

  // Gecapt rekendoel; een leeg doel = bronwater (er hoeft niets bij).
  const T = {
    ca: Math.min(D.ca ?? B.ca, CAP.ca),
    cl: Math.min(D.cl ?? B.cl, CAP.cl),
    so4: Math.min(D.so4 ?? B.so4, CAP.so4),
    na: D.na ?? B.na,
  };

  // 0. natrium -> NaCl, begrensd door het Cl-doel
  const naclVoorNa = Math.max(0, (T.na - B.na) / F.nacl.na);
  const naclMaxCl = Math.max(0, (T.cl - B.cl) / F.nacl.cl);
  const nacl = Math.min(naclVoorNa, naclMaxCl);
  const naGeknepen = naclVoorNa > naclMaxCl + 1e-9;
  // 1. resterend chloride -> CaCl2
  const cacl = Math.max(0, (T.cl - B.cl - nacl * F.nacl.cl) / F.cacl.cl);
  const caNaCl = B.ca + cacl * F.cacl.ca;
  // 2./3. sulfaat -> gips en/of epsom
  const dS = Math.max(0, T.so4 - B.so4);
  const dCa = T.ca - caNaCl;
  let gips, epsom;
  if (dCa <= 0) { gips = 0; epsom = dS / F.epsom.so4; }
  else if (dCa >= dS * F.gips.ca / F.gips.so4) { gips = dS / F.gips.so4; epsom = 0; }
  else { gips = dCa / F.gips.ca; epsom = (dS - gips * F.gips.so4) / F.epsom.so4; }
  let mgGeknepen = false;
  if (B.mg + epsom * F.epsom.mg > CAP.mg) {
    epsom = Math.max(0, (CAP.mg - B.mg) / F.epsom.mg);
    gips = Math.max(0, (dS - epsom * F.epsom.so4) / F.gips.so4);
    mgGeknepen = true;
  }
  let caGeknepen = false;
  if (caNaCl + gips * F.gips.ca > CAP.ca + 1e-9) {
    gips = Math.max(0, (CAP.ca - caNaCl) / F.gips.ca);
    caGeknepen = true;
  }

  // Afronden op 10 g per brouwsel (bij splitsen elk deel apart).
  const exact = { cacl, gips, epsom, nacl };
  const rond10 = (g) => Math.round(g / 10) * 10;
  const zouten = WZ_ZOUTEN.map((z) => {
    const totaalExact = hl > 0 ? exact[z.key] * hl : 0;
    const totaal = rond10(totaalExact);
    const mash = p.split ? rond10(totaal * WZ_SPLIT_MASH) : totaal;
    const boil = p.split ? rond10(totaal * (1 - WZ_SPLIT_MASH)) : 0;
    const gewogen = mash + boil;
    return {
      key: z.key, naam: z.naam, formule: z.formule, levert: z.levert,
      perBrouwsel: gewogen, mash, boil,
      gphl: hl > 0 ? gewogen / hl : 0,
      gphlMash: hl > 0 ? mash / hl : 0,
      gphlBoil: hl > 0 ? boil / hl : 0,
    };
  });

  // Resulterend profiel met de echt gewogen hoeveelheden
  const R = Object.assign({}, B);
  zouten.forEach((z) => {
    const ionen = F[z.key];
    Object.keys(ionen).forEach((ion) => { R[ion] += z.gphl * ionen[ion]; });
  });
  const ratio = R.so4 > 0 ? R.cl / R.so4 : null;
  const ratioDoel = D.ratio !== null ? D.ratio : (D.cl !== null && D.so4 ? D.cl / D.so4 : null);

  const meldingen = [];
  const capNaam = { ca: 'Calcium', cl: 'Chloride', so4: 'Sulfate', mg: 'Magnesium' };
  ['ca', 'cl', 'so4', 'mg'].forEach((k) => {
    if (D[k] !== null && D[k] > CAP[k]) meldingen.push(`${capNaam[k]} target ${Math.round(D[k])} ppm is above the cap of ${CAP[k]} ppm (Settings › Water); calculated to ${CAP[k]}.`);
  });
  if (D.cl !== null && D.cl < B.cl) meldingen.push(`Chloride target is below the source water (${Math.round(B.cl)} ppm): salts cannot lower it.`);
  if (D.so4 !== null && D.so4 < B.so4) meldingen.push(`Sulfate target is below the source water (${Math.round(B.so4)} ppm): salts cannot lower it.`);
  if (D.na !== null && D.na < B.na - 1) meldingen.push(`Sodium target is below the source water (${Math.round(B.na)} ppm): salts cannot lower it.`);
  if (naGeknepen) meldingen.push('Sodium stays below target: more Natrium Chloride would push chloride over its target (chloride comes first).');
  if (dCa < 0) meldingen.push(`Calcium Chloride alone already brings calcium to ${Math.round(caNaCl)} ppm, above the target. No Calcium Sulfaat; sulfate comes from Magnesium Sulfaat.`);
  if (mgGeknepen && !caGeknepen) meldingen.push(`Magnesium is capped at ${CAP.mg} ppm. The rest of the sulfate comes from Calcium Sulfaat, so calcium ends above target.`);
  if (caGeknepen && !mgGeknepen) meldingen.push(`Calcium is capped at ${CAP.ca} ppm: less Calcium Sulfaat, so sulfate ends below target.`);
  if (mgGeknepen && caGeknepen) meldingen.push(`Magnesium (${CAP.mg} ppm) and calcium (${CAP.ca} ppm) are both at their cap, so no more sulfate can be added.`);
  if (D.ca !== null && T.ca - R.ca > 3 && !(dCa < 0) && !caGeknepen) meldingen.push(`Calcium ends ${Math.round(T.ca - R.ca)} ppm below target: chloride and sulfate are already at target, so no more calcium salt can be added.`);

  // Statusregels per ion (dezelfde toleranties als in de mockup)
  const TOL = { cl: 3, so4: 3, ca: 3, mg: 2, na: 3 };
  const PRIO = { cl: '1st', so4: '2nd', ca: '3rd', na: '4th', mg: '' };
  const LABEL = { cl: 'Chloride', so4: 'Sulfate', ca: 'Calcium', mg: 'Magnesium', na: 'Sodium' };
  const profiel = ['cl', 'so4', 'ca', 'mg', 'na'].map((k) => {
    let status;
    if (D[k] === null) status = 'none';
    else if (CAP[k] !== undefined && D[k] > CAP[k] && Math.abs(R[k] - CAP[k]) <= TOL[k]) status = 'cap';
    else if (Math.abs(R[k] - D[k]) <= TOL[k]) status = 'ok';
    else status = R[k] > D[k] ? 'above' : 'below';
    return { key: k, label: LABEL[k], prio: PRIO[k], bron: B[k], plus: R[k] - B[k], resultaat: R[k], doel: D[k], status, afwijking: D[k] === null ? null : R[k] - D[k] };
  });
  profiel.push({ key: 'alk', label: 'Alkalinity', prio: '', bron: alk, plus: 0, resultaat: alk, doel: null, status: 'unchanged', afwijking: null });
  let ratioStatus = 'none';
  if (ratio !== null && ratioDoel !== null) {
    const tol = Math.max(Math.abs(ratioDoel) * 0.1, 0.05);
    ratioStatus = Math.abs(ratio - ratioDoel) <= tol ? 'ok' : (ratio > ratioDoel ? 'above' : 'below');
  }
  profiel.push({ key: 'ratio', label: 'Ratio Cl : SO₄', prio: 'control', bron: B.so4 > 0 ? B.cl / B.so4 : null, plus: null, resultaat: ratio, doel: ratioDoel, status: ratioStatus, afwijking: null, ratioUitRecept: D.ratio !== null });

  return { zouten, profiel, resultaat: R, meldingen, ratio, ratioDoel, hl, split: !!p.split };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { wzBereken, WZ_ZOUTEN };
}
