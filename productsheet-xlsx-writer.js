// ============================================================================
// productsheet-xlsx-writer.js — lichte browser-writer voor het Product Sheet-
// sjabloon, zelfde principe als batchrapport-generator/xlsx-direct.js
// (rechtstreeks in de ruwe sheet-XML schrijven via JSZip, i.p.v. ExcelJS'
// volledige load/save-cyclus, om dezelfde stijlentabel-corruptie te
// vermijden). Dit sjabloon heeft een vaste rij-layout (geen dynamische
// ingrediëntregels zoals het batchrapport), dus voegRijenToe() en de
// StylesManager-randlogica zijn hier niet nodig -- alleen setCelWaarde().
//
// Vereist op de pagina:
//   <script src="https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js"></script>
//   <script src="productsheet-xlsx-writer.js"></script>
// ============================================================================

function psXmlEscape(tekst) {
  return String(tekst)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/\r?\n/g, ' ');
}

class ProductSheetXlsxWriter {
  constructor(zip) {
    this.zip = zip;
    this.sheetXmlPerBestand = {};
    this.sheetNaarBestand = null;
  }

  async init() {
    const workbookXml = await this.zip.file('xl/workbook.xml').async('string');
    const relsXml = await this.zip.file('xl/_rels/workbook.xml.rels').async('string');

    const sheetEntries = [...workbookXml.matchAll(/<sheet\b([^>]*)\/>/g)]
      .map(m => {
        const attrs = m[1];
        const naam = attrs.match(/name="([^"]+)"/);
        const rId = attrs.match(/r:id="(rId\d+)"/);
        return naam && rId ? { naam: naam[1], rId: rId[1] } : null;
      })
      .filter(Boolean);
    const relMap = {};
    for (const m of relsXml.matchAll(/<Relationship\b([^>]*)\/>/g)) {
      const attrs = m[1];
      const id = attrs.match(/Id="(rId\d+)"/);
      const target = attrs.match(/Target="([^"]+)"/);
      if (id && target) relMap[id[1]] = target[1];
    }

    this.sheetNaarBestand = {};
    for (const { naam, rId } of sheetEntries) {
      const target = relMap[rId];
      if (target) {
        this.sheetNaarBestand[naam] = target.startsWith('/') ? target.slice(1) : 'xl/' + target;
      }
    }
  }

  async _laadSheetXml(sheetNaam) {
    const bestand = this.sheetNaarBestand[sheetNaam];
    if (!bestand) throw new Error(`Onbekend tabblad: ${sheetNaam}`);
    if (!this.sheetXmlPerBestand[bestand]) {
      this.sheetXmlPerBestand[bestand] = await this.zip.file(bestand).async('string');
    }
    return bestand;
  }

  /**
   * Vervangt de inhoud van cel `sheetCel` (bv. "Product description!E10")
   * door `waarde`, met behoud van de bestaande stijl. null/undefined/'' ->
   * lege cel. number/numerieke string -> echt getal. { formula } -> formule.
   * Andere strings -> inlineStr (geen shared-strings-tabel nodig).
   */
  async setCelWaarde(sheetCel, waarde) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    let xml = this.sheetXmlPerBestand[bestand];

    const cellPattern = new RegExp(`<c r="${cel}"([^>]*?)(?:/>|>([\\s\\S]*?)</c>)`);
    const match = xml.match(cellPattern);
    if (!match) {
      throw new Error(`Cel ${sheetCel} bestaat niet in het sjabloon (kan niet invoegen, alleen vervangen)`);
    }
    const attrsRuw = match[1];
    const sMatch = attrsRuw.match(/\bs="(\d+)"/);
    const sAttr = sMatch ? ` s="${sMatch[1]}"` : '';

    let nieuweCel;
    if (waarde === null || waarde === undefined || waarde === '') {
      nieuweCel = `<c r="${cel}"${sAttr}/>`;
    } else if (typeof waarde === 'object' && waarde.formula) {
      nieuweCel = `<c r="${cel}"${sAttr}><f>${psXmlEscape(waarde.formula)}</f></c>`;
    } else if (typeof waarde === 'number') {
      nieuweCel = `<c r="${cel}"${sAttr}><v>${waarde}</v></c>`;
    } else {
      const num = Number(waarde);
      if (typeof waarde !== 'string' && !Number.isNaN(num)) {
        nieuweCel = `<c r="${cel}"${sAttr}><v>${num}</v></c>`;
      } else if (typeof waarde === 'string' && waarde.trim() !== '' && !Number.isNaN(Number(waarde))) {
        nieuweCel = `<c r="${cel}"${sAttr}><v>${Number(waarde)}</v></c>`;
      } else {
        nieuweCel = `<c r="${cel}"${sAttr} t="inlineStr"><is><t xml:space="preserve">${psXmlEscape(waarde)}</t></is></c>`;
      }
    }

    this.sheetXmlPerBestand[bestand] = xml.replace(cellPattern, () => nieuweCel);
  }

  async finalize() {
    for (const [bestand, xml] of Object.entries(this.sheetXmlPerBestand)) {
      this.zip.file(bestand, xml);
    }
    return this.zip;
  }
}
