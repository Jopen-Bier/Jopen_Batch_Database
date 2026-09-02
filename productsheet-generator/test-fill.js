// test-fill.js — end-to-end test van de product sheet-generatie tegen de
// levende database, ZONDER browser. Laadt de daadwerkelijke browserbestanden
// (productsheet-shared.js, productsheet-xlsx-writer.js, productsheet-vullen.js)
// in een vm-context met een echte Supabase-client als `supabaseClient` en een
// in-memory `fetch`/`JSZip`, zodat dit precies dezelfde code test die ook in
// de browser draait -- geen aparte Node-herimplementatie die uit de pas kan
// gaan lopen (zelfde les als bij de batchrapport-generator).

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const JSZip = require('jszip');
const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = 'https://nrouqtxkeeoayqudkiud.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_ftz3c-3AVlRiYve4Y1V6fQ_hg_BdAm-';

async function main() {
  const supabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

  const sandbox = {
    supabaseClient,
    JSZip,
    console,
    fetch: async (url) => {
      // De browserbestanden fetchen het sjabloon relatief ('productsheet-generator/...');
      // hier lezen we het gewoon van schijf en doen alsof het een Response is.
      const bestand = path.join(__dirname, 'Product_Sheet_sjabloon.xlsx');
      const buffer = fs.readFileSync(bestand);
      return { ok: true, arrayBuffer: async () => buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength) };
    },
    window: {}, // psSlaOp checkt 'showSaveFilePicker' in window -- leeg object = altijd false, dus altijd de download-tak (die we hieronder overschrijven)
    URL: { createObjectURL: () => 'blob:test', revokeObjectURL: () => {} },
    document: { createElement: () => ({ click(){}, remove(){} }), body: { appendChild(){} } },
  };
  vm.createContext(sandbox);

  vm.runInContext(fs.readFileSync(path.join(__dirname, '../productsheet-shared.js'), 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../productsheet-xlsx-writer.js'), 'utf8'), sandbox);

  // psSlaOp uit productsheet-vullen.js zou normaal downloaden; voor de test
  // vangen we het resultaat af door 'm te overschrijven vóórdat we het
  // bestand laden (functie-declaraties in dezelfde vm-context overschrijven
  // elkaar gewoon op naam).
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../productsheet-vullen.js'), 'utf8'), sandbox);
  sandbox.PS_BASISPAD = ''; // fetch-mock hierboven negeert het pad toch, maar voor de duidelijkheid
  let opgeslagenBlob = null;
  let opgeslagenNaam = null;
  sandbox.psSlaOp = async (blob, naam) => { opgeslagenBlob = blob; opgeslagenNaam = naam; };

  // -- Stap 1: recept ophalen (Mooie Nel) --
  const { data: recipe, error: recErr } = await supabaseClient
    .from('recipes').select('id, naam, recipe_group_id').eq('id', 361).single();
  if (recErr) throw recErr;
  console.log(`Test tegen: ${recipe.naam} (recipe_group_id ${recipe.recipe_group_id})`);

  // -- Stap 2: live data + hash laden, exact zoals de pagina dat doet --
  const live = await vm.runInContext('psLaadReceptData', sandbox)(recipe.recipe_group_id);
  console.log('Calculated color:', live.calcColor, 'EBC');
  console.log('Turbidity:', live.turbidity);
  console.log('Allergenen:', live.allergenenTekst);
  console.log('Ingredients — Malt label:', live.ingredientenBlok.malt.label, '| ranks', live.ingredientenBlok.malt.ranks);
  console.log('Ingredients — Hop label:', live.ingredientenBlok.hop.label, '| ranks', live.ingredientenBlok.hop.ranks);
  console.log('Ingredients — Additief label:', JSON.stringify(live.ingredientenBlok.additief.label), '(leeg verwacht als alles -no declaration-)');

  // -- Stap 3: de volledige Update-flow, incl. echte database-schrijfacties --
  const gebruiker = { id: null, naam: 'Claude (testscript)' };
  const productSheetRow = await vm.runInContext('psUpdate', sandbox)(recipe.recipe_group_id, gebruiker);
  console.log('\nProduct sheet weggeschreven: id', productSheetRow.id, '— versie', productSheetRow.huidige_versie);

  // -- Stap 4: los downloaden (nieuwe, aparte Download-knop) --
  await vm.runInContext('psDownload', sandbox)(recipe.recipe_group_id, gebruiker);

  // -- Stap 4: gegenereerde xlsx wegschrijven naar schijf en cellen controleren --
  if (!opgeslagenBlob) throw new Error('Geen blob opgeslagen -- psSlaOp niet aangeroepen?');
  const arrayBuffer = await opgeslagenBlob.arrayBuffer();
  const outPath = path.join(__dirname, 'test-output.xlsx');
  fs.writeFileSync(outPath, Buffer.from(arrayBuffer));
  console.log(`\nGegenereerd bestand geschreven naar ${outPath} (${opgeslagenNaam})`);

  const zip = await JSZip.loadAsync(fs.readFileSync(outPath));
  const sheetXml = await zip.file('xl/worksheets/sheet1.xml').async('string');
  const checks = {
    E4: 'Mooie Nel', E5: 'American IPA',
    I10: 'Barley, Oats', I12: 'Hops', I13: '',
    E38: live.turbidity, E41: live.allergenenTekst,
  };
  console.log('\n-- Celcontrole in het gegenereerde bestand --');
  for (const [cel, verwacht] of Object.entries(checks)) {
    const m = sheetXml.match(new RegExp(`<c r="${cel}"[^>]*>([\\s\\S]*?)</c>`));
    const inhoud = m ? m[1] : '(leeg/self-closing)';
    console.log(`${cel}: verwacht "${verwacht}" — ruwe XML: ${inhoud.slice(0, 80)}`);
  }

  // -- Stap 5: sync-status opnieuw ophalen -- moet nu 'in_sync: true' zijn --
  const status = await vm.runInContext('psLaadSyncStatus', sandbox)(recipe.recipe_group_id);
  console.log('\nSync-status na Update:', status.in_sync ? 'IN SYNC (groen)' : 'OUT OF SYNC (rood)');
  if (!status.in_sync) throw new Error('FOUT: zou in sync moeten zijn direct na Update');

  console.log('\n✅ Test geslaagd.');
}

main().catch(e => {
  console.error('\n❌ Test gefaald:', e);
  process.exit(1);
});
