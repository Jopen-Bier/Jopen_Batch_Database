const fs = require('fs');
const JSZip = require('jszip');
const { XlsxDirectWriter, StylesManager } = require('./xlsx-direct');
const {
  vulScalaireVelden, vulWpKerkVelden, vulReceptnaamKruisVelden, vulIngredientRijen, vulRevisies,
  vulFormaten, vulHopRendementEnEbu, zetHopGroepRanden, vulDryHopGlTotalen, voegOverloopRijenToe,
} = require('./generate-batchrapport');

async function test() {
  const bundel = {
    recipes: { naam: 'Testbier IPA', bierstijl: 'IPA', locatie: 'Waarderpolder', brouwsel_hl: 60, status: 'actief' },
    recipe_specificaties: { origineel_extract: 16, origineel_extract_tol: '0.5', alcohol: 6.5, alcohol_tol: 0.3, kleur: 20, kleur_tol: 2, ph: 4.2 },
    recipe_fermentatie: { pitching_temp: 18, main_ferm_temp: 20, bier_risico: 'Standaard', bier_status: 'Standaard' },
    recipe_brouwspecificaties: {
      volume_kook: 62, verwacht_extract_begin_kook: 14, beluchting: 8,
      recept_naam_software: 'BH_TestbierIPA_60hl', naam_special_bin: 'SB_TestbierIPA',
      stort_special_bin_kg: null, maischwater: 120, eindvolume_brouwsel: 60,
      sparging_1e: 30, eerste_afloop: 30, sparging_2e: 15, spoelwater: 15,
      sparging_3e: null, spoel_afloop: null, sparging_4e: null, totaal_gefiltreerd_volume: 60,
      kamers_mashfilter: null, lauterfactor: 1.02, walsenmolen: 'walsenmolen A',
      volume_water_additie_terugkoeling: null,
      inmaischen_zuur_l: 2.5, inmaischen_tannines_l: 1.1, koken_zuur_l: 0.8, inline_sparge_zuur_l: 0.4,
    },
    recipe_water: { ca: 80, mg: 10, na: 15, cl: 60, so4: 120, ratio_cl_so4: 0.5, alkalinity: 40 },
    recipe_verpakking: { tht_fles_maanden: 6, formaten: ['24x33cl', '20L keykeg'] },
    recipe_processtappen: { comment_verwerken: 'Test processopmerking', dry_hop_comment_warm: 'warm comment test' },
    recipe_comments: { comments: ['Testcomment recept'] },
    recipe_ingredients: [
      { rol: 'hopgift_kook', volgorde: 1, ingredient_id: 1, alpha_pct: 12.8, hoeveelheid: 5000, tijdstip: '45', hdt: 1 },
      { rol: 'hopgift_kook', volgorde: 2, ingredient_id: 2, alpha_pct: 24.5, hoeveelheid: 5000, tijdstip: '0', hdt: null },
      { rol: 'hopgift_kook', volgorde: 3, ingredient_id: 7, alpha_pct: 10, hoeveelheid: 1000, tijdstip: '45', hdt: 1 },
      { rol: 'dry_hop', volgorde: 1, ingredient_id: 3, hoeveelheid: 7500, tijdstip: 'cold_16' },
      { rol: 'dry_hop', volgorde: 5, ingredient_id: 4, hoeveelheid: 2500, tijdstip: 'cold_16' },
      { rol: 'dry_hop', volgorde: 2, ingredient_id: 2, hoeveelheid: 3000, tijdstip: 'cold_8' },
      { rol: 'dry_hop', volgorde: 3, ingredient_id: 7, hoeveelheid: 1500, tijdstip: 'warm' },
      { rol: 'dry_hop', volgorde: 4, ingredient_id: 1, hoeveelheid: 500, tijdstip: '0c' },
      { rol: 'hoofdmout', volgorde: 1, ingredient_id: 4, hoeveelheid: 800, kleur_ebc: 5 },
      { rol: 'hoofdmout', volgorde: 2, ingredient_id: 5, hoeveelheid: 100, kleur_ebc: 900 },
      { rol: 'gist', volgorde: 1, ingredient_id: 6, hoeveelheid: 2 },
      { rol: 'toegift_brouwerij', volgorde: 1, ingredient_id: 8, hoeveelheid: 11, eenheid: 'g/hl', tijdstip: 'mash', alles_in_brouwsel_1: false },
      { rol: 'toegift_brouwerij', volgorde: 2, ingredient_id: 9, hoeveelheid: 5, eenheid: 'g/hl', tijdstip: 'kook', alles_in_brouwsel_1: true },
    ],
    recipe_revisies: [
      { versie_major: 2, versie_minor: 0, datum: '2026-01-15', door: 'Jaap', wijziging: 'Major revision test' },
    ],
    ingredientNaam: new Map([
      [1, 'Magnum'], [2, 'Citra CRYO'], [3, 'Cascade'], [4, 'Pilsmout'], [5, 'Chocolate malt'], [6, 'US-05'], [7, 'Saaz'],
      [8, 'Calcium Chloride'], [9, 'Protafloc'],
    ]),
    batch: { batchnummer: 99999, aantal_brouwsels: 3 },
  };

  const templateBuffer = fs.readFileSync('./Batchrapport_sjabloon.xlsx');
  const zip = await JSZip.loadAsync(templateBuffer);
  const writer = new XlsxDirectWriter(zip);
  await writer.init();
  const stylesManager = new StylesManager(zip);
  await stylesManager.init();

  const overloop = await voegOverloopRijenToe(writer, bundel);

  await vulScalaireVelden(writer, bundel, true, overloop.verschuifCel);
  await vulWpKerkVelden(writer, bundel, true);
  await vulReceptnaamKruisVelden(writer, bundel, true);
  await vulIngredientRijen(writer, bundel, overloop, stylesManager);
  await vulRevisies(writer, bundel, overloop.verschuifCel);
  await vulFormaten(writer, bundel);
  await vulHopRendementEnEbu(writer, bundel, overloop);
  await zetHopGroepRanden(writer, stylesManager, bundel, overloop);
  await vulDryHopGlTotalen(writer, stylesManager, bundel, overloop);

  await writer.setCelWaarde('Recept-voorblad!K3', bundel.batch.batchnummer);
  await writer.setCelWaarde('Recept-voorblad!Q1', 'WP ' + bundel.recipes.naam);

  stylesManager.finalize();
  await writer.finalize();
  const outBuffer = await zip.generateAsync({ type: 'nodebuffer' });
  fs.writeFileSync('./output/TEST-batch.xlsx', outBuffer);
  console.log('Testbestand geschreven: ./output/TEST-batch.xlsx');

  // Meteen een paar cellen terug uitlezen ter controle
  const ExcelJS = require('exceljs');
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.readFile('./output/TEST-batch.xlsx');
  const ws = wb.getWorksheet('Recept-voorblad');
  const wsB = wb.getWorksheet('Brouwen');
  console.log('C3 (naam bier):', ws.getCell('C3').value);
  console.log('F12 (origineel extract spec):', ws.getCell('F12').value);
  console.log('E12 (tolerantie, was string "0.5" -- moet nu getal 0.5 zijn):', ws.getCell('E12').value, typeof ws.getCell('E12').value);
  console.log('A43 (hop 1 naam):', ws.getCell('A43').value);
  console.log('D43 (hop 1 alpha):', ws.getCell('D43').value);
  console.log('I43 (hop 1 rendement):', ws.getCell('I43').value);
  console.log('K43 (hop 1 EBU):', ws.getCell('K43').value);
  console.log('K64 (totale bitterheid):', ws.getCell('K64').value);
  console.log('A30 (mout 1 naam):', ws.getCell('A30').value);
  console.log('D30 (mout 1 kg):', ws.getCell('D30').value);
  console.log('F40 (calculated color bijdrage-som, live formule):', ws.getCell('F40').value);
  console.log('M40 (calculated color, live formule):', ws.getCell('M40').value);
  console.log('Brouwen!F8 (WP -> moet live formule zijn):', wsB.getCell('F8').value);
  console.log('Brouwen!F9 (WP -> recept_naam_software):', wsB.getCell('F9').value);
  console.log('Brouwen!F11 (altijd naam_special_bin):', wsB.getCell('F11').value);
  console.log('Brouwen!M36 (Automatic dosing):', wsB.getCell('M36').value);
  console.log('Brouwen!N8 (Gewenste stamwort, moet 16 zijn):', wsB.getCell('N8').value);
  // Nieuw: witregel tussen Hop boil-toevoegmomenten (i.p.v. dikke lijn per
  // groep). Testrecept: Magnum(45)+Saaz(45) -> witregel -> Citra CRYO(0).
  console.log('A43 (Magnum, 45 min):', ws.getCell('A43').value);
  console.log('A44 (Saaz, 45 min):', ws.getCell('A44').value);
  console.log('A45 (moet LEEG zijn -- witregel):', ws.getCell('A45').value);
  console.log('A46 (Citra CRYO, 0 min):', ws.getCell('A46').value);
  // Dry hop: sorteervolgorde moet Warm, Cold 16 (x2, zelfde groep), Cold 8,
  // Cold 0 zijn (warm eerst, dan cold aflopend op temperatuur), en
  // Timing-tekst geformatteerd als 'Warm' resp. 'Cold - N°C' (ook voor de
  // gemigreerde legacy '0c').
  console.log('A58 (dry hop 1, moet Warm-ingrediënt zijn):', ws.getCell('A58').value);
  console.log('G58 (moet "Warm" zijn):', ws.getCell('G58').value);
  console.log('A59 (dry hop 2, eerste van de cold_16-groep):', ws.getCell('A59').value);
  console.log('G59 (moet "Cold - 16°C" zijn):', ws.getCell('G59').value);
  console.log('A60 (dry hop 3, tweede van de cold_16-groep):', ws.getCell('A60').value);
  console.log('G60 (moet ook "Cold - 16°C" zijn):', ws.getCell('G60').value);
  console.log('A61 (dry hop 4, moet cold_8-ingrediënt zijn):', ws.getCell('A61').value);
  console.log('G61 (moet "Cold - 8°C" zijn):', ws.getCell('G61').value);
  console.log('A62 (dry hop 5, moet legacy 0c-ingrediënt zijn):', ws.getCell('A62').value);
  console.log('G62 (legacy \'0c\', moet "Cold - 0°C" zijn):', ws.getCell('G62').value);
  // g/l-totalen per toevoegmoment (vervangt de oude vaste J58/J61-formules):
  // J58 = Warm alleen (1500g / (60hl*100) = 0.25), geen samenvoeging.
  // J59 = Cold-16°C, SAMENGEVOEGDE groep van 2 rijen (7500+2500=10000g /
  // 6000 = 1.6667), J60 hoort bij deze samenvoeging en moet zelf leeg zijn.
  // J61 = Cold-8°C alleen (3000/6000=0.5). J62 = Cold-0°C alleen
  // (500/6000=0.0833). J63 = ongebruikt slot, moet leeg + neutraal zijn.
  console.log('J58 (Warm-totaal, moet 0.25 zijn):', ws.getCell('J58').value, 'fill:', JSON.stringify(ws.getCell('J58').fill));
  console.log('J59 (Cold-16-totaal, moet 1.6667 zijn):', ws.getCell('J59').value, 'fill:', JSON.stringify(ws.getCell('J59').fill));
  console.log('J59 samengevoegd met J60?:', ws.getCell('J59').isMerged, '-> master:', ws.getCell('J59').master && ws.getCell('J59').master.address);
  console.log('J60 (hoort bij J59-samenvoeging, moet zelf LEEG zijn):', ws.getCell('J60').value);
  console.log('J61 (Cold-8-totaal, moet 0.5 zijn, GEEN samenvoeging):', ws.getCell('J61').value, 'isMerged:', ws.getCell('J61').isMerged);
  console.log('J62 (Cold-0-totaal, moet 0.0833 zijn):', ws.getCell('J62').value);
  console.log('J63 (ongebruikt, moet LEEG zijn):', ws.getCell('J63').value, 'fill:', JSON.stringify(ws.getCell('J63').fill));
  // "All in brew 1?" -- Additions Brewing, rij 75 (normaal, x1) en rij 76
  // (alles_in_brouwsel_1: true, batch.aantal_brouwsels=3 -> x3 + '*' + notitie in Q).
  console.log('G75 (Calcium Chloride, normaal: 11 g/hl x 60hl x1 = 660.0 g, GEEN *):', ws.getCell('G75').value);
  console.log('Q75 (moet LEEG zijn):', ws.getCell('Q75').value);
  console.log('G76 (Protafloc, all-in-brew-1: 5 g/hl x 60hl x3 brouwsels = 900.0 g, MET *):', ws.getCell('G76').value);
  console.log('G76 font (moet underline: single hebben):', JSON.stringify(ws.getCell('G76').font));
  console.log('G75 font (ongewijzigd, geen underline):', JSON.stringify(ws.getCell('G75').font));
  console.log('Q76 (moet de uitlegregel bevatten):', ws.getCell('Q76').value);
  console.log('Q76 font color (moet theme 1 zijn, niet theme 0/wit):', JSON.stringify(ws.getCell('Q76').font));
  console.log('Q75 font color (ongewijzigd, leeg dus stijl maakt niet uit):', JSON.stringify(ws.getCell('Q75').font));
  console.log('A43 border (moet GEEN dikke rand):', JSON.stringify(ws.getCell('A43').border));
  console.log('A44 border (moet WEL dikke rand -- laatste van groep 45min, vlak boven witregel):', JSON.stringify(ws.getCell('A44').border));
  console.log('A45 border (witregel, geen dikke rand):', JSON.stringify(ws.getCell('A45').border));
  console.log('A46 border (moet WEL dikke rand -- laatste rij Hop boil):', JSON.stringify(ws.getCell('A46').border));
  // Amerikaanse datumnotatie (numFmtId 166, m/d/yyyy) mag nergens meer
  // voorkomen -- moet overal d/mm/yy (numFmtId 171) zijn.
  console.log('Recept-voorblad!K7 numFmt (moet d/mm/yy zijn, GEEN m/d/yyyy):', ws.getCell('K7').numFmt);
  const wsBrouwen = wb.getWorksheet('Brouwen');
  console.log('Brouwen!N5 numFmt (moet d/mm/yy zijn, GEEN m/d/yyyy):', wsBrouwen.getCell('N5').numFmt);
  console.log('Brouwen!N50 numFmt (moet d/mm/yy zijn, GEEN m/d/yyyy):', wsBrouwen.getCell('N50').numFmt);
  const wsGistkaart = wb.getWorksheet('Gistkaart Invoer');
  console.log('Gistkaart Invoer!H4 numFmt (TODAY(), moet d/mm/yy zijn):', wsGistkaart.getCell('H4').numFmt);
}

test().catch(e => { console.error(e); process.exit(1); });
