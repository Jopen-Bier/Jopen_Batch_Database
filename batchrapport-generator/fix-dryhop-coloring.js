// Eenmalig script: repareert twee dingen in Batchrapport_sjabloon.xlsx die
// stuk gingen door de nieuwe dry hop "Cold - N°C"-tekst (i.p.v. de oude vaste
// "16c"/"0c"-waarden):
//
// 1. ECHTE FUNCTIONELE BUG: de g/l-berekening in J58/J61
//    (SUMIF(...,"16C",...)) matchte exact op de tekst "16C" -- "Cold - 16°C"
//    bevat dat niet meer (i.v.m. het °-teken en de nieuwe opmaak), dus de som
//    werd stilzwijgend 0. Fix: wildcard "Cold*" i.p.v. het exacte "16C".
// 2. COSMETISCH: de conditional formatting op G58:I63 die Warm/Cold een
//    kleur geeft zocht ook naar de losse tekst "16C" of "koud" -- matcht nu
//    niet meer op "Cold - 16°C" e.d. Fix: zoekterm naar "Cold" (contains,
//    dus ongeacht welke temperatuur).
//
// NIET aangeraakt: de losse conditional-formatting-regels op de J-cellen
// zelf (J58/J59/J60/J61/J62:J63, met formules als G58="@16C") -- die
// controleren op de letterlijke tekst "@16C", wat nooit overeenkwam met de
// oude dropdown-waarde "16c" ook al. Lijken al van vóór deze sessie kapot/
// ongebruikt te zijn, dus buiten scope voor deze reparatie.
//
// Draai eenmalig met: node fix-dryhop-coloring.js
const fs = require('fs');
const path = require('path');
const JSZip = require('jszip');

const TEMPLATE_PATH = path.join(__dirname, 'Batchrapport_sjabloon.xlsx');

// [zoek, vervang, verwacht_aantal] -- het verwachte aantal is een
// veiligheidscheck: als het niet klopt, stopt het script i.p.v. blind te
// vervangen (zodat we nooit per ongeluk iets buiten de dry-hop-rijen raken).
const VERVANGINGEN = [
  ['SUMIF(G58:I60,"16C",E58:F60)', 'SUMIF(G58:I60,"Cold*",E58:F60)', 1],
  ['SUMIF(G61:I63,"16C",E61:F63)', 'SUMIF(G61:I63,"Cold*",E61:F63)', 1],
  ['SEARCH("koud",G58)', 'SEARCH("Cold",G58)', 1],
  ['SEARCH("16C",G59)', 'SEARCH("Cold",G59)', 1],
  ['SEARCH("16C",G61)', 'SEARCH("Cold",G61)', 1],
  ['SEARCH("16C",G62)', 'SEARCH("Cold",G62)', 1],
  ['text="koud"', 'text="Cold"', 1],
  ['text="16C"', 'text="Cold"', 3], // G59:I60, G61:I61, G62:I63 -- alle drie identiek, allemaal bedoeld voor hetzelfde
];

async function main() {
  const buffer = fs.readFileSync(TEMPLATE_PATH);
  const zip = await JSZip.loadAsync(buffer);

  let xml = await zip.file('xl/worksheets/sheet1.xml').async('string');

  for (const [zoek, vervang, verwacht] of VERVANGINGEN) {
    const aantal = xml.split(zoek).length - 1;
    if (aantal !== verwacht) {
      throw new Error(`Onverwacht aantal treffers voor ${JSON.stringify(zoek)}: gevonden ${aantal}, verwacht ${verwacht}. Gestopt zonder iets te wijzigen.`);
    }
    xml = xml.split(zoek).join(vervang);
  }

  zip.file('xl/worksheets/sheet1.xml', xml);

  const nieuweBuffer = await zip.generateAsync({
    type: 'nodebuffer',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
  });
  fs.writeFileSync(TEMPLATE_PATH, nieuweBuffer);
  console.log(`Klaar. ${VERVANGINGEN.length} vervangingen toegepast, sjabloon overschreven (${nieuweBuffer.length} bytes).`);
}

main().catch(e => { console.error(e); process.exit(1); });
