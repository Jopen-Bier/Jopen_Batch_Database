const fs = require('fs');
const JSZip = require('jszip');
const { XlsxDirectWriter, StylesManager } = require('./xlsx-direct');
const {
  vulScalaireVelden, vulWpKerkVelden, vulReceptnaamKruisVelden, vulIngredientRijen, vulRevisies,
  vulFormaten, vulHopRendementEnEbu, zetHopGroepRanden, voegOverloopRijenToe,
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
      { rol: 'dry_hop', volgorde: 1, ingredient_id: 3, hoeveelheid: 7500, tijdstip: '16c' },
      { rol: 'hoofdmout', volgorde: 1, ingredient_id: 4, hoeveelheid: 800, kleur_ebc: 5 },
      { rol: 'hoofdmout', volgorde: 2, ingredient_id: 5, hoeveelheid: 100, kleur_ebc: 900 },
      { rol: 'gist', volgorde: 1, ingredient_id: 6, hoeveelheid: 2 },
    ],
    recipe_revisies: [
      { versie_major: 2, versie_minor: 0, datum: '2026-01-15', door: 'Jaap', wijziging: 'Major revision test' },
    ],
    ingredientNaam: new Map([
      [1, 'Magnum'], [2, 'Citra CRYO'], [3, 'Cascade'], [4, 'Pilsmout'], [5, 'Chocolate malt'], [6, 'US-05'], [7, 'Saaz'],
    ]),
    batch: { batchnummer: 99999 },
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
  await vulIngredientRijen(writer, bundel, overloop);
  await vulRevisies(writer, bundel, overloop.verschuifCel);
  await vulFormaten(writer, bundel);
  await vulHopRendementEnEbu(writer, bundel, overloop);
  await zetHopGroepRanden(writer, stylesManager, bundel, overloop);

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
  console.log('A43 border (moet GEEN dikke rand):', JSON.stringify(ws.getCell('A43').border));
  console.log('A44 border (moet WEL dikke rand -- laatste van groep 45min, vlak boven witregel):', JSON.stringify(ws.getCell('A44').border));
  console.log('A45 border (witregel, geen dikke rand):', JSON.stringify(ws.getCell('A45').border));
  console.log('A46 border (moet WEL dikke rand -- laatste rij Hop boil):', JSON.stringify(ws.getCell('A46').border));
}

test().catch(e => { console.error(e); process.exit(1); });
