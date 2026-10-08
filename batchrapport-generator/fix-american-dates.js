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
  'Recipe Sheet!K7',
  'Brew Sheet!N5', 'Brew Sheet!N50', 'Brew Sheet!M57', 'Brew Sheet!M58', 'Brew Sheet!M59',
  'Brew Sheet!M60', 'Brew Sheet!M61', 'Brew Sheet!M62', 'Brew Sheet!M63', 'Brew Sheet!M64', 'Brew Sheet!M65',
  'Fermentation Chart!H4',
  'Processing!S6', 'Processing!S7', 'Processing!S8', 'Processing!S9',
  'Processing!D14', 'Processing!D15', 'Processing!D16',
  'Filling Report!D99',
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
