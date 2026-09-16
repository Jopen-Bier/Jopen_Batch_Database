// Eenmalig script: repareert de cellen in Batchrapport_sjabloon.xlsx die
// numFmtId 166 (hardgecodeerd 'm/d/yyyy', Amerikaans) gebruiken. Dit was
// een puur sjabloon-stijlprobleem (geen JS-generatiecode betrokken) --
// numFmtId 171 ('d/mm/yy;@', Europees) bestond al in hetzelfde sjabloon
// en wordt hier hergebruikt in plaats van een nieuw formaat te verzinnen.
//
// Draai eenmalig met: node fix-american-dates.js
// Overschrijft Batchrapport_sjabloon.xlsx in place.
const fs = require('fs');
const JSZip = require('jszip');
const { XlsxDirectWriter, StylesManager } = require('./xlsx-direct.js');

const TEMPLATE_PATH = require('path').join(__dirname, 'Batchrapport_sjabloon.xlsx');

// Alle cellen die vooraf zijn opgespoord met numFmtId 166 (zie sessie-analyse).
const CELLEN = [
  'Recept-voorblad!K7',
  'Brouwen!N5', 'Brouwen!N50', 'Brouwen!M57', 'Brouwen!M58', 'Brouwen!M59',
  'Brouwen!M60', 'Brouwen!M61', 'Brouwen!M62', 'Brouwen!M63', 'Brouwen!M64', 'Brouwen!M65',
  'Gistkaart Invoer!H4',
  'Verwerking!S6', 'Verwerking!S7', 'Verwerking!S8', 'Verwerking!S9',
  'Verwerking!D14', 'Verwerking!D15', 'Verwerking!D16',
  'Afvulverslag!D99',
];

const EUROPEES_NUMFMT_ID = 171; // 'd/mm/yy;@', al aanwezig in het sjabloon

async function main() {
  const buffer = fs.readFileSync(TEMPLATE_PATH);
  const zip = await JSZip.loadAsync(buffer);

  const writer = new XlsxDirectWriter(zip);
  await writer.init();
  const stylesManager = new StylesManager(zip);
  await stylesManager.init();

  const resultaten = [];
  for (const cel of CELLEN) {
    const huidigeStijl = await writer.haalStijlIndexOp(cel);
    const nieuweStijl = stylesManager.vervangNumFmt(huidigeStijl, EUROPEES_NUMFMT_ID);
    await writer.zetOfMaakCelStijl(cel, nieuweStijl);
    resultaten.push({ cel, huidigeStijl, nieuweStijl });
  }

  stylesManager.finalize();
  await writer.finalize();

  const nieuweBuffer = await zip.generateAsync({
    type: 'nodebuffer',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
  });
  fs.writeFileSync(TEMPLATE_PATH, nieuweBuffer);

  console.log(`Klaar. ${resultaten.length} cellen aangepast, sjabloon overschreven (${nieuweBuffer.length} bytes).`);
  console.table(resultaten);
}

main().catch(e => { console.error(e); process.exit(1); });
