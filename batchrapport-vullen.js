// ============================================================================
// batchrapport-vullen.js — client-side batchrapport-generatie (browser)
//
// Schrijft rechtstreeks in de ruwe sheet-XML (via JSZip), i.p.v. via ExcelJS'
// volledige load/save-cyclus. ExcelJS bleek zelf meerdere dingen te breken
// die niets met onze eigen wijzigingen te maken hadden: rij/cel-mismatches,
// een verminkte Print Area, een foute sheetPr-elementvolgorde, en een
// herbouwde/gedupliceerde stijlentabel. Door alleen de specifieke cellen te
// vervangen die we moeten invullen (altijd cellen die al bestaan in het
// sjabloon, nooit invoegen) en de rest van het bestand -- incl. de hele
// stijlentabel -- ongemoeid te laten, kunnen die problemen niet meer
// optreden. Zie generate-batchrapport.js (Node-versie) voor dezelfde aanpak.
//
// Vereist op de pagina:
//   <script src="https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js"></script>
//   <script src="batchrapport-vullen.js"></script>
// (JSZip global moet dus al bestaan; ExcelJS is hier niet meer nodig)
//
// LET OP (onderhoud): de hop-rendement-tabel en bepaalHopRendement/bepaalHopEbu
// staan op MEERDERE plekken gedupliceerd (hier, generate-batchrapport.js,
// recept-invoer.html, receptoverzicht.html). Wijzig je de tabel/formule,
// doe dat overal.
// ============================================================================

const HOP_SG_BUCKETS = [1.02, 1.03, 1.04, 1.05, 1.06, 1.07, 1.08, 1.09, 1.10, 1.11, 1.12, 1.13];
const HOP_RENDEMENT_TABEL = [
  { kooktijd: 0,   rendement: [6.5, 6, 6, 5.5, 5, 3, 2.5, 2, 1.8, 1.7, 1.6, null] },
  { kooktijd: 5,   rendement: [9.5, 9, 8, 7.5, 6, 3.5, 3, 2.8, 2.5, 2.4, 2.3, null] },
  { kooktijd: 10,  rendement: [18, 16, 14, 11, 9, 7, 7, 6.5, 5, 4.8, 4.6, null] },
  { kooktijd: 15,  rendement: [18, 17.5, 17, 15, 14, 12, 10, 9, 7, 6.5, 6.3, null] },
  { kooktijd: 20,  rendement: [25, 23, 21, 20, 16, 14, 12, 11, 9, 8.5, 8.2, null] },
  { kooktijd: 25,  rendement: [27.5, 26, 24.5, 23.68, 20, 17, 15, 14, 11, 10, 9.5, null] },
  { kooktijd: 30,  rendement: [30, 28, 26, 24, 22, 20, 17, 16, 14, 13, 11, null] },
  { kooktijd: 35,  rendement: [31, 29, 27, 25, 23, 21, 19, 17, 16, 15, 14.5, null] },
  { kooktijd: 40,  rendement: [32, 30, 28, 26, 24, 22, 20, 19, 17, 16, 15, null] },
  { kooktijd: 45,  rendement: [34, 32, 30, 27, 25, 24, 21, 20, 18, 17, 16, null] },
  { kooktijd: 50,  rendement: [36, 34, 32, 28, 25, 25, 22, 21, 19, 18, 17, null] },
  { kooktijd: 55,  rendement: [40, 37, 34, 29.5, 26, 25, 23, 22, 20, 19, 18, null] },
  { kooktijd: 60,  rendement: [42, 39, 36, 31, 27.07, 26, 25, 23, 21, 20, 19, null] },
  { kooktijd: 65,  rendement: [45, 41, 37, 33, 30, 28, 27, 25, 23, 21, 21, null] },
  { kooktijd: 70,  rendement: [45, 42.5, 40, 35, 33, 32, 30, 27, 25, 23, 23, null] },
  { kooktijd: 75,  rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 80,  rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 90,  rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 95,  rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 100, rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 105, rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 110, rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 115, rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
  { kooktijd: 120, rendement: [null, 44, 42, 38, 36, 35, 33, 30, 27, 25, 25, null] },
];
function bepaalHopSgBucket(og) {
  const p = parseInt(String(og).slice(0, 2), 10);
  if (Number.isNaN(p)) return null;
  return Math.round((259 / (259 - p)) * 100) / 100;
}
function bepaalHopSgKolomIndex(sgBucket) {
  let idx = -1;
  for (let i = 0; i < HOP_SG_BUCKETS.length; i++) if (HOP_SG_BUCKETS[i] <= sgBucket) idx = i;
  return idx;
}
function bepaalHopRendement(kooktijd, og) {
  const sgBucket = bepaalHopSgBucket(og);
  if (sgBucket === null) return null;
  const kolomIdx = bepaalHopSgKolomIndex(sgBucket);
  if (kolomIdx === -1) return null;
  const rij = HOP_RENDEMENT_TABEL.find(r => r.kooktijd === kooktijd);
  return rij ? rij.rendement[kolomIdx] : null;
}
function bepaalHopEbu(gewichtGram, alphaPct, kooktijd, og, volumeKookHl) {
  const rendementPct = bepaalHopRendement(kooktijd, og);
  if (rendementPct === null || !volumeKookHl || !gewichtGram || alphaPct == null) return null;
  const volumeLiter = volumeKookHl * 100;
  return (gewichtGram * 1000) * (alphaPct / 100) * (rendementPct / 100) / volumeLiter;
}

// ---------------------------------------------------------------------------
// Directe XML-schrijver (zie xlsx-direct.js voor de uitgebreide toelichting)
// ---------------------------------------------------------------------------
function xmlEscape(tekst) {
  return String(tekst)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/\r?\n/g, ' ');
}
function kolomLetterNaarNummer(letters) {
  let num = 0;
  for (const ch of letters) num = num * 26 + (ch.charCodeAt(0) - 64);
  return num;
}
function ontleedCelRef(ref) {
  const m = ref.match(/^([A-Z]+)(\d+)$/);
  return { col: kolomLetterNaarNummer(m[1]), row: Number(m[2]) };
}

class XlsxDirectWriter {
  constructor(zip) {
    this.zip = zip;
    this.sheetXmlPerBestand = {};
    this.sheetNaarBestand = null;
    this._mergesPerBestand = {};
  }

  /**
   * Als `sheetCel` een niet-ankercel is binnen een samengevoegd bereik, geeft
   * dit de ankercel (linksboven) terug. Anders gewoon de cel zelf. Zie
   * xlsx-direct.js voor de uitgebreide toelichting.
   */
  async haalMergeAnker(sheetCel) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    if (!this._mergesPerBestand[bestand]) {
      const xml = this.sheetXmlPerBestand[bestand];
      const merges = [];
      const m = xml.match(/<mergeCells count="\d+">([\s\S]*?)<\/mergeCells>/);
      if (m) {
        for (const refMatch of m[1].matchAll(/ref="([^"]+)"/g)) {
          const [a, b] = refMatch[1].split(':');
          const p1 = ontleedCelRef(a);
          const p2 = b ? ontleedCelRef(b) : p1;
          merges.push({ c1: Math.min(p1.col, p2.col), r1: Math.min(p1.row, p2.row), c2: Math.max(p1.col, p2.col), r2: Math.max(p1.row, p2.row) });
        }
      }
      this._mergesPerBestand[bestand] = merges;
    }
    const { col, row } = ontleedCelRef(cel);
    for (const mr of this._mergesPerBestand[bestand]) {
      if (col >= mr.c1 && col <= mr.c2 && row >= mr.r1 && row <= mr.r2) {
        if (col === mr.c1 && row === mr.r1) return sheetCel;
        return `${sheetNaam}!${kolomNummerNaarLetter(mr.c1)}${mr.r1}`;
      }
    }
    return sheetCel;
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
        this.sheetNaarBestand[naam] = target.startsWith('/')
          ? target.slice(1)
          : 'xl/' + target;
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
      nieuweCel = `<c r="${cel}"${sAttr}><f>${xmlEscape(waarde.formula)}</f></c>`;
    } else if (typeof waarde === 'number') {
      nieuweCel = `<c r="${cel}"${sAttr}><v>${waarde}</v></c>`;
    } else if (typeof waarde === 'string' && waarde.trim() !== '' && !Number.isNaN(Number(waarde))) {
      // Postgres 'numeric'-kolommen komen als string terug (bv "0.5") --
      // als echt getal schrijven, anders behandelt Excel het als tekst.
      nieuweCel = `<c r="${cel}"${sAttr}><v>${Number(waarde)}</v></c>`;
    } else {
      nieuweCel = `<c r="${cel}"${sAttr} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(waarde)}</t></is></c>`;
    }

    this.sheetXmlPerBestand[bestand] = xml.replace(cellPattern, () => nieuweCel);
  }

  async haalStijlIndexOp(sheetCel) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    const xml = this.sheetXmlPerBestand[bestand];
    const match = xml.match(new RegExp(`<c r="${cel}"([^>]*?)(?:/>|>)`));
    if (!match) throw new Error(`Cel ${sheetCel} niet gevonden`);
    const sMatch = match[1].match(/\bs="(\d+)"/);
    return sMatch ? Number(sMatch[1]) : 0;
  }

  async zetStijlIndex(sheetCel, nieuweIndex) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    let xml = this.sheetXmlPerBestand[bestand];
    const cellPattern = new RegExp(`<c r="${cel}"([^>]*?)(/>|>([\\s\\S]*?)</c>)`);
    const match = xml.match(cellPattern);
    if (!match) throw new Error(`Cel ${sheetCel} niet gevonden`);
    let attrs = match[1];
    if (/\bs="\d+"/.test(attrs)) attrs = attrs.replace(/\bs="\d+"/, `s="${nieuweIndex}"`);
    else attrs = ` s="${nieuweIndex}"` + attrs;
    this.sheetXmlPerBestand[bestand] = xml.replace(cellPattern, () => `<c r="${cel}"${attrs}${match[2]}`);
  }

  async celBestaat(sheetCel) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    const xml = this.sheetXmlPerBestand[bestand];
    return new RegExp(`<c r="${cel}"[^>]*(?:/>|>)`).test(xml);
  }

  async zetOfMaakCelStijl(sheetCel, stijlIdx) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    if (await this.celBestaat(sheetCel)) {
      await this.zetStijlIndex(sheetCel, stijlIdx);
      return;
    }
    let xml = this.sheetXmlPerBestand[bestand];
    const { col, row } = ontleedCelRef(cel);
    const rowPattern = new RegExp(`(<row [^>]*r="${row}"[^>]*>)([\\s\\S]*?)(</row>)`);
    const rowMatch = xml.match(rowPattern);
    if (!rowMatch) throw new Error(`Rij ${row} bestaat niet in ${sheetNaam}`);
    const inhoud = rowMatch[2];
    const nieuweCel = `<c r="${cel}" s="${stijlIdx}"/>`;
    let invoegPositie = inhoud.length;
    for (const m of inhoud.matchAll(/<c r="([A-Z]+)(\d+)"/g)) {
      if (kolomLetterNaarNummer(m[1]) > col) { invoegPositie = m.index; break; }
    }
    const nieuweInhoud = inhoud.slice(0, invoegPositie) + nieuweCel + inhoud.slice(invoegPositie);
    this.sheetXmlPerBestand[bestand] = xml.replace(rowPattern, `$1${nieuweInhoud}$3`);
  }

  /**
   * Voegt `aantal` nieuwe (lege) rijen in vóór `voorRij` op tabblad
   * `sheetNaam`, met de stijl/kolomindeling/samenvoegingen van `sjabloonRij`
   * gekopieerd. Zie xlsx-direct.js (Node-versie) voor de volledige
   * toelichting -- deze methode is bewust identiek.
   */
  async voegRijenToe(sheetNaam, voorRij, aantal, sjabloonRij) {
    if (!aantal || aantal <= 0) return;
    const bestand = await this._laadSheetXml(sheetNaam);
    let xml = this.sheetXmlPerBestand[bestand];

    const formuleVerwijzingPatroon = new RegExp(
      `((?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ ]*))!)?(\\$?)([A-Z]+)(\\$?)(\\d+)`, 'g'
    );
    function verschuifFormuleTekst(tekst) {
      return tekst.replace(formuleVerwijzingPatroon, (heleMatch, prefixVolledig, gequoteNaam, kaleNaam, dollarKol, kol, dollarRij, rijStr) => {
        const andereSheet = gequoteNaam || kaleNaam;
        if (andereSheet && andereSheet !== sheetNaam) return heleMatch;
        const rij = Number(rijStr);
        if (rij < voorRij) return heleMatch;
        return `${prefixVolledig || ''}${dollarKol}${kol}${dollarRij}${rij + aantal}`;
      });
    }
    function verschuifFormulesInInhoud(inhoud) {
      return inhoud.replace(/<f>([\s\S]*?)<\/f>/g, (heleMatch, formule) => `<f>${verschuifFormuleTekst(formule)}</f>`);
    }

    const rowRegex = /<row r="(\d+)"([^>]*)>([\s\S]*?)<\/row>/g;
    const rijen = [];
    let m;
    while ((m = rowRegex.exec(xml)) !== null) {
      rijen.push({ rij: Number(m[1]), attrs: m[2], inhoud: m[3] });
    }
    const sjabloon = rijen.find(r => r.rij === sjabloonRij);
    if (!sjabloon) throw new Error(`Sjabloonrij ${sjabloonRij} niet gevonden op ${sheetNaam}`);

    function verschuifCellenInRij(inhoud, nieuweRij) {
      return inhoud.replace(/<c r="([A-Z]+)\d+"/g, (_, kol) => `<c r="${kol}${nieuweRij}"`);
    }

    function verschuifSjabloonFormule(tekst, vanRij, naarRij) {
      const patroon = /((?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ ]*))!)?(\$?)([A-Z]+)(\$?)(\d+)/g;
      return tekst.replace(patroon, (heleMatch, prefixVolledig, gequoteNaam, kaleNaam, dollarKol, kol, dollarRij, rijStr) => {
        if (gequoteNaam || kaleNaam) return heleMatch;
        const rij = Number(rijStr);
        if (rij === vanRij) return `${dollarKol}${kol}${dollarRij}${naarRij}`;
        if (rij >= voorRij) return `${dollarKol}${kol}${dollarRij}${rij + aantal}`;
        return heleMatch;
      });
    }
    function verschuifSjabloonInhoud(inhoud, vanRij, naarRij) {
      const metCellenVerschoven = verschuifCellenInRij(inhoud, naarRij);
      return metCellenVerschoven.replace(/<f>([\s\S]*?)<\/f>/g, (heleMatch, formule) =>
        `<f>${verschuifSjabloonFormule(formule, vanRij, naarRij)}</f>`);
    }

    const nieuweRijen = [];
    for (const r of rijen) {
      if (r.rij < voorRij) {
        nieuweRijen.push(r);
      } else {
        nieuweRijen.push({ rij: r.rij + aantal, attrs: r.attrs, inhoud: verschuifCellenInRij(r.inhoud, r.rij + aantal) });
      }
    }
    const invoegIdx = nieuweRijen.findIndex(r => r.rij >= voorRij + aantal) === -1
      ? nieuweRijen.length
      : nieuweRijen.findIndex(r => r.rij === voorRij + aantal);
    const ingevoegd = [];
    for (let i = 0; i < aantal; i++) {
      const nieuweRijNr = voorRij + i;
      ingevoegd.push({
        rij: nieuweRijNr, attrs: sjabloon.attrs,
        inhoud: verschuifSjabloonInhoud(sjabloon.inhoud, sjabloonRij, nieuweRijNr),
        _nieuw: true,
      });
    }
    nieuweRijen.splice(invoegIdx, 0, ...ingevoegd);
    nieuweRijen.sort((a, b) => a.rij - b.rij);

    for (const r of nieuweRijen) {
      if (r._nieuw) continue;
      r.inhoud = verschuifFormulesInInhoud(r.inhoud);
    }

    const nieuweSheetDataInhoud = nieuweRijen
      .map(r => `<row r="${r.rij}"${r.attrs}>${r.inhoud}</row>`)
      .join('');
    xml = xml.replace(/<sheetData>[\s\S]*?<\/sheetData>/, `<sheetData>${nieuweSheetDataInhoud}</sheetData>`);

    const mergeBlockMatch = xml.match(/<mergeCells count="(\d+)">([\s\S]*?)<\/mergeCells>/);
    if (mergeBlockMatch) {
      const merges = [...mergeBlockMatch[2].matchAll(/<mergeCell ref="([^"]+)"\/>/g)].map(mm => mm[1]);
      const parseRef = (ref) => {
        const [a, b] = ref.split(':');
        const pa = ontleedCelRef(a), pb = b ? ontleedCelRef(b) : pa;
        return { c1: pa.col, r1: pa.row, c2: pb.col, r2: pb.row };
      };
      const sjabloonMerges = merges.filter(ref => {
        const { r1, r2 } = parseRef(ref);
        return r1 === sjabloonRij && r2 === sjabloonRij;
      });
      const nieuweMerges = [];
      for (const ref of merges) {
        const { c1, r1, c2, r2 } = parseRef(ref);
        if (r1 >= voorRij) {
          nieuweMerges.push(`${kolomNummerNaarLetter(c1)}${r1 + aantal}:${kolomNummerNaarLetter(c2)}${r2 + aantal}`);
        } else {
          nieuweMerges.push(ref);
        }
      }
      for (let i = 0; i < aantal; i++) {
        const nieuweRijNr = voorRij + i;
        for (const ref of sjabloonMerges) {
          const { c1, c2 } = parseRef(ref);
          nieuweMerges.push(`${kolomNummerNaarLetter(c1)}${nieuweRijNr}:${kolomNummerNaarLetter(c2)}${nieuweRijNr}`);
        }
      }
      xml = xml.replace(
        /<mergeCells count="\d+">[\s\S]*?<\/mergeCells>/,
        `<mergeCells count="${nieuweMerges.length}">${nieuweMerges.map(r => `<mergeCell ref="${r}"/>`).join('')}</mergeCells>`
      );
    }

    xml = xml.replace(/<dimension ref="([A-Z]+)(\d+):([A-Z]+)(\d+)"\/>/, (_, c1, r1, c2, r2) => {
      const nieuweR2 = Number(r2) >= voorRij ? Number(r2) + aantal : Number(r2);
      return `<dimension ref="${c1}${r1}:${c2}${nieuweR2}"/>`;
    });

    this.sheetXmlPerBestand[bestand] = xml;

    await this._verschuifPrintArea(sheetNaam, voorRij, aantal);

    for (const [andereSheetNaam, andereBestand] of Object.entries(this.sheetNaarBestand)) {
      if (andereSheetNaam === sheetNaam) continue;
      await this._laadSheetXml(andereSheetNaam);
      let andereXml = this.sheetXmlPerBestand[andereBestand];
      const patroon = new RegExp(`('?${sheetNaam}'?!)(\\$?)([A-Z]+)(\\$?)(\\d+)`, 'g');
      andereXml = andereXml.replace(patroon, (heleMatch, prefix, dollarKol, kol, dollarRij, rijStr) => {
        const rij = Number(rijStr);
        if (rij < voorRij) return heleMatch;
        return `${prefix}${dollarKol}${kol}${dollarRij}${rij + aantal}`;
      });
      this.sheetXmlPerBestand[andereBestand] = andereXml;
    }
  }

  async _verschuifPrintArea(sheetNaam, voorRij, aantal) {
    if (!this._workbookXml) {
      this._workbookXml = await this.zip.file('xl/workbook.xml').async('string');
    }
    const patroon = new RegExp(`('${sheetNaam}'!\\$[A-Z]+\\$\\d+:\\$[A-Z]+\\$)(\\d+)`);
    const match = this._workbookXml.match(patroon);
    if (match) {
      const eindRij = Number(match[2]);
      if (eindRij >= voorRij) {
        this._workbookXml = this._workbookXml.replace(patroon, `$1${eindRij + aantal}`);
        this._workbookXmlGewijzigd = true;
      }
    }
  }

  async finalize() {
    for (const [bestand, xml] of Object.entries(this.sheetXmlPerBestand)) {
      this.zip.file(bestand, xml);
    }
    if (this._workbookXmlGewijzigd) {
      this.zip.file('xl/workbook.xml', this._workbookXml);
    }
    return this.zip;
  }
}

class StylesManager {
  constructor(zip) {
    this.zip = zip;
    this.xml = null;
  }

  async init() {
    this.xml = await this.zip.file('xl/styles.xml').async('string');
  }

  _haalSectie(naam) {
    const m = this.xml.match(new RegExp(`<${naam} count="(\\d+)">([\\s\\S]*?)</${naam}>`));
    if (!m) return null;
    return { count: Number(m[1]), inhoud: m[2], volledigeMatch: m[0] };
  }

  _splitsElementen(inhoud, tagNaam) {
    const elementen = [];
    const re = new RegExp(`<${tagNaam}(?:[^>]*?/>|[^>]*?>[\\s\\S]*?</${tagNaam}>)`, 'g');
    let m;
    while ((m = re.exec(inhoud)) !== null) elementen.push(m[0]);
    return elementen;
  }

  wisBovenrand(sourceStyleIdx) {
    const cellXfsSectie = this._haalSectie('cellXfs');
    const xfs = this._splitsElementen(cellXfsSectie.inhoud, 'xf');
    const bronXf = xfs[sourceStyleIdx];
    if (!bronXf) throw new Error(`Stijlindex ${sourceStyleIdx} bestaat niet`);
    const borderIdMatch = bronXf.match(/borderId="(\d+)"/);
    const bronBorderId = borderIdMatch ? Number(borderIdMatch[1]) : 0;

    const bordersSectie = this._haalSectie('borders');
    const borders = this._splitsElementen(bordersSectie.inhoud, 'border');
    const bronBorder = borders[bronBorderId] || '<border><left/><right/><top/><bottom/><diagonal/></border>';

    const nieuweBorderRuw = bronBorder.replace(
      /<top[^>]*\/>|<top[^>]*>[\s\S]*?<\/top>/,
      '<top/>'
    ).replace(/^<border[^>]*>/, '<border>');
    const openTagMatch = bronBorder.match(/^<border([^>]*)>/);
    const nieuweBorder = openTagMatch
      ? nieuweBorderRuw.replace('<border>', `<border${openTagMatch[1]}>`)
      : nieuweBorderRuw;

    let nieuweBorderId = borders.findIndex(b => b === nieuweBorder);
    let bordersGewijzigd = false;
    if (nieuweBorderId === -1) {
      borders.push(nieuweBorder);
      nieuweBorderId = borders.length - 1;
      bordersGewijzigd = true;
    }

    const nieuweXf = bronXf.replace(/borderId="\d+"/, `borderId="${nieuweBorderId}"`);
    let nieuweXfIdx = xfs.findIndex(x => x === nieuweXf);
    let xfsGewijzigd = false;
    if (nieuweXfIdx === -1) {
      xfs.push(nieuweXf);
      nieuweXfIdx = xfs.length - 1;
      xfsGewijzigd = true;
    }

    if (bordersGewijzigd) {
      const nieuweInhoud = borders.join('');
      this.xml = this.xml.replace(bordersSectie.volledigeMatch, `<borders count="${borders.length}">${nieuweInhoud}</borders>`);
    }
    if (xfsGewijzigd) {
      const nieuweInhoud = xfs.join('');
      this.xml = this.xml.replace(cellXfsSectie.volledigeMatch, `<cellXfs count="${xfs.length}">${nieuweInhoud}</cellXfs>`);
    }
    return nieuweXfIdx;
  }

  voegOnderrandToe(sourceStyleIdx, stijl = 'medium') {
    const cellXfsSectie = this._haalSectie('cellXfs');
    const xfs = this._splitsElementen(cellXfsSectie.inhoud, 'xf');
    const bronXf = xfs[sourceStyleIdx];
    if (!bronXf) throw new Error(`Stijlindex ${sourceStyleIdx} bestaat niet`);
    const borderIdMatch = bronXf.match(/borderId="(\d+)"/);
    const bronBorderId = borderIdMatch ? Number(borderIdMatch[1]) : 0;

    const bordersSectie = this._haalSectie('borders');
    const borders = this._splitsElementen(bordersSectie.inhoud, 'border');
    const bronBorder = borders[bronBorderId] || '<border><left/><right/><top/><bottom/><diagonal/></border>';

    const nieuweBorderRuw = bronBorder.replace(
      /<bottom[^>]*\/>|<bottom[^>]*>[\s\S]*?<\/bottom>/,
      `<bottom style="${stijl}"><color rgb="FF000000"/></bottom>`
    ).replace(/^<border[^>]*>/, '<border>');
    const openTagMatch = bronBorder.match(/^<border([^>]*)>/);
    const nieuweBorder = openTagMatch
      ? nieuweBorderRuw.replace('<border>', `<border${openTagMatch[1]}>`)
      : nieuweBorderRuw;

    let nieuweBorderId = borders.findIndex(b => b === nieuweBorder);
    let bordersGewijzigd = false;
    if (nieuweBorderId === -1) {
      borders.push(nieuweBorder);
      nieuweBorderId = borders.length - 1;
      bordersGewijzigd = true;
    }

    const nieuweXf = bronXf.replace(/borderId="\d+"/, `borderId="${nieuweBorderId}"`);
    let nieuweXfIdx = xfs.findIndex(x => x === nieuweXf);
    let xfsGewijzigd = false;
    if (nieuweXfIdx === -1) {
      xfs.push(nieuweXf);
      nieuweXfIdx = xfs.length - 1;
      xfsGewijzigd = true;
    }

    if (bordersGewijzigd) {
      this.xml = this.xml.replace(
        bordersSectie.volledigeMatch,
        `<borders count="${borders.length}">${borders.join('')}</borders>`
      );
    }
    if (xfsGewijzigd) {
      this.xml = this.xml.replace(
        cellXfsSectie.volledigeMatch,
        `<cellXfs count="${xfs.length}">${xfs.join('')}</cellXfs>`
      );
    }

    return nieuweXfIdx;
  }

  finalize() {
    this.zip.file('xl/styles.xml', this.xml);
  }
}

// ---------------------------------------------------------------------------
// Sjabloon vullen
// ---------------------------------------------------------------------------
const BR_BASISPAD = 'batchrapport-generator/';

async function brFetchJson(pad) {
  const res = await fetch(BR_BASISPAD + pad, { cache: 'no-store' });
  if (!res.ok) throw new Error(`Kon ${pad} niet ophalen (${res.status})`);
  return res.json();
}

async function haalBatchDataOpBrowser(supabase, batchnummer) {
  const { data: batch, error: batchErr } = await supabase
    .from('batches').select('*').eq('batchnummer', batchnummer).single();
  if (batchErr || !batch) throw new Error(`Batch ${batchnummer} niet gevonden: ${batchErr?.message || ''}`);

  const recipeId = batch.recipe_id;
  const [recipe, specs, ferm, brouw, water, verpakking, processtappen, comments, ingredients, revisies, alleIngredienten] =
    await Promise.all([
      supabase.from('recipes').select('*').eq('id', recipeId).single(),
      supabase.from('recipe_specificaties').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_fermentatie').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_brouwspecificaties').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_water').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_verpakking').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_processtappen').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_comments').select('*').eq('recipe_id', recipeId).maybeSingle(),
      supabase.from('recipe_ingredients').select('*').eq('recipe_id', recipeId).order('rol').order('volgorde'),
      supabase.from('recipe_revisies').select('*').eq('recipe_id', recipeId)
        .order('versie_major', { ascending: false }).order('versie_minor', { ascending: false }).order('id', { ascending: false })
        .limit(4),
      supabase.from('ingredients').select('id, naam'),
    ]);

  if (recipe.error || !recipe.data) throw new Error(`Recept ${recipeId} niet gevonden: ${recipe.error?.message || ''}`);

  const ingredientNaam = new Map((alleIngredienten.data || []).map(i => [i.id, i.naam]));

  return {
    batch,
    recipes: recipe.data,
    recipe_specificaties: specs.data || {},
    recipe_fermentatie: ferm.data || {},
    recipe_brouwspecificaties: brouw.data || {},
    recipe_water: water.data || {},
    recipe_verpakking: verpakking.data || {},
    recipe_processtappen: processtappen.data || {},
    recipe_comments: comments.data || {},
    recipe_ingredients: ingredients.data || [],
    recipe_revisies: revisies.data || [],
    ingredientNaam,
  };
}

// ---------------------------------------------------------------------------
// Rij-overloop Malt & Grains / Hops (boil + dry) / Toegiften Brouwerij/Kelder
// ---------------------------------------------------------------------------
// Het sjabloon heeft van origine een vast aantal sloten per blok. Een
// recept kan er inmiddels meer hebben. Volgorde van boven naar beneden in
// het sjabloon (belangrijk: elke latere constante moet met de cumulatieve
// verschuiving van alle blokken ERBOVEN rekening houden):
//   Malt & grains (30-39) -> Hops boil (43-57) -> Dry hop (58-63) ->
//   [vaste tussenliggende rijen 64-72, o.a. Hop totaal gewicht] ->
//   Toegiften Brouwerij (73-82) -> Toegiften Kelder (89-93)
const RIJ_MOUT_EERSTE = 30;
const RIJ_MOUT_LAATSTE = 39;      // = eerste + 10 sloten - 1
const RIJ_MOUT_SJABLOON = 35;
const RIJ_HOP_EERSTE = 43;
const RIJ_HOP_LAATSTE = 57;       // = eerste + 15 sloten - 1
const RIJ_HOP_SJABLOON = 50;
const RIJ_DRYHOP_EERSTE = 58;
const RIJ_DRYHOP_LAATSTE = 63;    // = eerste + 6 sloten - 1
const RIJ_DRYHOP_SJABLOON = 60;
const RIJ_BROUWHUIS_EERSTE = 75;
const RIJ_BROUWHUIS_LAATSTE = 84;   // = eerste + 10 sloten - 1
const RIJ_BROUWHUIS_SJABLOON = 80;  // "gewone" middenrij, voor het kopiëren van nieuwe rijen
const RIJ_KELDER_EERSTE = 91;
const RIJ_KELDER_LAATSTE = 95;      // = eerste + 5 sloten - 1
const RIJ_KELDER_SJABLOON = 92;     // "gewone" middenrij

/**
 * Voegt zo nodig extra rijen toe aan Recept-voorblad voor recepten met meer
 * regels dan een van de vaste blokken (Malt & grains, Hops boil, Dry hop,
 * Toegiften Brouwerij, Toegiften Kelder) van origine aankan, en levert
 * {n0..n2, verschuifRij, verschuifCel} -- een functie die voor ELKE andere
 * Recept-voorblad-cel (Gist, Water, Revisiehistorie, enz.) de juiste,
 * mogelijk verschoven rij teruggeeft. Moet als allereerste worden
 * aangeroepen, vóór alle andere writer.setCelWaarde-aanroepen op dit
 * tabblad.
 */
// Bouwt de fysieke rij-indeling van de Hop boil-tabel: de gesorteerde
// hopgiften met een extra `null` (= lege, witte scheidingsrij) ingevoegd
// tussen twee opeenvolgende regels met een ANDER toevoegmoment (tijdstip).
// Zie generate-batchrapport.js voor dezelfde logica (Node-pad) -- deze twee
// moeten in sync blijven.
function bouwHopKookLayout(bundel) {
  const hopRijen = sorteerHopgiften(bundel.recipe_ingredients.filter(r => r.rol === 'hopgift_kook'), 'hopgift_kook');
  const layout = [];
  for (let i = 0; i < hopRijen.length; i++) {
    layout.push(hopRijen[i]);
    const volgende = hopRijen[i + 1];
    if (volgende && String(volgende.tijdstip) !== String(hopRijen[i].tijdstip)) {
      layout.push(null);
    }
  }
  return layout;
}

async function brVoegOverloopRijenToe(writer, bundel) {
  const moutAantal = bundel.recipe_ingredients.filter(r => r.rol === 'hoofdmout').length;
  const hopAantal = bouwHopKookLayout(bundel).length;
  const dryHopAantal = bundel.recipe_ingredients.filter(r => r.rol === 'dry_hop').length;
  const brouwhuisAantal = bundel.recipe_ingredients.filter(r => r.rol === 'toegift_brouwerij').length;
  const kelderAantal = bundel.recipe_ingredients.filter(r => r.rol === 'toegift_kelder').length;

  const n0 = Math.max(0, moutAantal - (RIJ_MOUT_LAATSTE - RIJ_MOUT_EERSTE + 1));
  const nHop = Math.max(0, hopAantal - (RIJ_HOP_LAATSTE - RIJ_HOP_EERSTE + 1));
  const nDryHop = Math.max(0, dryHopAantal - (RIJ_DRYHOP_LAATSTE - RIJ_DRYHOP_EERSTE + 1));
  const n1 = Math.max(0, brouwhuisAantal - (RIJ_BROUWHUIS_LAATSTE - RIJ_BROUWHUIS_EERSTE + 1));
  const n2 = Math.max(0, kelderAantal - (RIJ_KELDER_LAATSTE - RIJ_KELDER_EERSTE + 1));

  // Volgorde is belangrijk: van boven naar beneden, elk volgend inzetpunt
  // ligt zelf al verschoven door alle blokken erboven.
  if (n0 > 0) {
    await writer.voegRijenToe('Recept-voorblad', RIJ_MOUT_LAATSTE, n0, RIJ_MOUT_SJABLOON);
  }
  if (nHop > 0) {
    await writer.voegRijenToe('Recept-voorblad', RIJ_HOP_LAATSTE + n0, nHop, RIJ_HOP_SJABLOON + n0);
  }
  if (nDryHop > 0) {
    await writer.voegRijenToe('Recept-voorblad', RIJ_DRYHOP_LAATSTE + n0 + nHop, nDryHop, RIJ_DRYHOP_SJABLOON + n0 + nHop);
  }
  if (n1 > 0) {
    await writer.voegRijenToe('Recept-voorblad', RIJ_BROUWHUIS_LAATSTE + n0 + nHop + nDryHop, n1, RIJ_BROUWHUIS_SJABLOON + n0 + nHop + nDryHop);
  }
  if (n2 > 0) {
    await writer.voegRijenToe('Recept-voorblad', RIJ_KELDER_LAATSTE + n0 + nHop + nDryHop + n1, n2, RIJ_KELDER_SJABLOON + n0 + nHop + nDryHop + n1);
  }

  const verschuifRij = (origineleRij) => {
    let r = origineleRij;
    if (origineleRij >= RIJ_MOUT_LAATSTE) r += n0;
    if (origineleRij >= RIJ_HOP_LAATSTE) r += nHop;
    if (origineleRij >= RIJ_DRYHOP_LAATSTE) r += nDryHop;
    if (origineleRij >= RIJ_BROUWHUIS_LAATSTE) r += n1;
    if (origineleRij >= RIJ_KELDER_LAATSTE) r += n2;
    return r;
  };
  const verschuifCel = (sheetCel) => {
    const [sheetNaam, cel] = sheetCel.split('!');
    if (sheetNaam !== 'Recept-voorblad') return sheetCel;
    const m = cel.match(/^([A-Z]+)(\d+)$/);
    if (!m) return sheetCel;
    return `${sheetNaam}!${m[1]}${verschuifRij(Number(m[2]))}`;
  };

  return { n0, nHop, nDryHop, n1, n2, verschuifRij, verschuifCel };
}

async function brVulScalaireVelden(writer, bundel, isWP, scalarMap, verschuifCel) {
  for (const veld of scalarMap) {
    if (veld.wp_only && !isWP) continue;
    const [tabel, kolom] = veld.db_veld.split('.');
    const bron = bundel[tabel];
    if (!bron) continue;
    const waarde = bron[kolom];
    for (const loc of veld.locaties) await writer.setCelWaarde(verschuifCel(loc), waarde);
  }
}

const WP_KERK_VELDEN = [
  { cel: 'Brouwen!F10', wp: 'stort_special_bin_kg', kerk: 'maischwater' },
  { cel: 'Brouwen!F18', wp: 'volume_water_additie_terugkoeling', kerk: 'eindvolume_brouwsel' },
  { cel: 'Brouwen!N17', wp: 'sparging_1e', kerk: 'eerste_afloop' },
  { cel: 'Brouwen!N18', wp: 'sparging_2e', kerk: 'spoelwater' },
  { cel: 'Brouwen!N19', wp: 'sparging_3e', kerk: 'spoel_afloop' },
  { cel: 'Brouwen!N20', wp: 'sparging_4e', kerk: 'totaal_gefiltreerd_volume' },
  { cel: 'Brouwen!I22', wp: 'kamers_mashfilter', kerk: 'lauterfactor' },
  { cel: 'Recept-voorblad!K9', wp: 'kamers_mashfilter', kerk: 'walsenmolen' },
];
async function brVulWpKerkVelden(writer, bundel, isWP) {
  const bron = bundel.recipe_brouwspecificaties;
  for (const v of WP_KERK_VELDEN) await writer.setCelWaarde(v.cel, bron[isWP ? v.wp : v.kerk]);
}

async function brVulReceptnaamKruisVelden(writer, bundel, isWP) {
  const bron = bundel.recipe_brouwspecificaties;
  if (isWP) {
    await writer.setCelWaarde('Brouwen!F8', { formula: "'Recept-voorblad'!G7*Brouwen!F19" });
    await writer.setCelWaarde('Brouwen!F9', bron.recept_naam_software ?? null);
  } else {
    await writer.setCelWaarde('Brouwen!F8', bron.recept_naam_software ?? null);
    await writer.setCelWaarde('Brouwen!F9', bron.naam_special_bin ?? null);
  }
  await writer.setCelWaarde('Brouwen!F11', bron.naam_special_bin ?? null);

  const origineelExtract = bundel.recipe_specificaties.origineel_extract;
  const stamwortCorrectie = bron.stamwort_correctie_brouwhuis;
  if (origineelExtract !== null && origineelExtract !== undefined) {
    await writer.setCelWaarde('Brouwen!N8', Number(origineelExtract) + (stamwortCorrectie ? Number(stamwortCorrectie) : 0));
  }
}

const DRY_HOP_VOLGORDE = ['warm', '16c', '0c'];
function sorteerHopgiften(rijen, rol) {
  if (rol === 'hopgift_kook') {
    return [...rijen].sort((a, b) => (parseFloat(b.tijdstip) || -Infinity) - (parseFloat(a.tijdstip) || -Infinity));
  }
  if (rol === 'dry_hop') {
    return [...rijen].sort((a, b) => DRY_HOP_VOLGORDE.indexOf(a.tijdstip) - DRY_HOP_VOLGORDE.indexOf(b.tijdstip));
  }
  return rijen;
}

async function brVulIngredientRijen(writer, bundel, ingredientMap, overloop) {
  const { n0, nHop, nDryHop, n1, verschuifCel } = overloop;
  // Elke rol met een variabel aantal regels krijgt (i.t.t. de vaste-slot-
  // rollen als Gist) geen sloten uit het JSON-veldenbestand meer, maar een
  // rechtstreeks berekende rij -- want bij overloop bestaan de extra rijen
  // pas na brVoegOverloopRijenToe(). "eersteRij + i" geeft ook zonder
  // overloop precies hetzelfde resultaat als de oude vaste sloten-mapping
  // (zie de toelichting bij brVoegOverloopRijenToe).
  const dynamischeBlokken = {
    hoofdmout: {
      eersteRij: RIJ_MOUT_EERSTE, vasteSloten: RIJ_MOUT_LAATSTE - RIJ_MOUT_EERSTE + 1,
      kolommen: { naam: 'A', hoeveelheid: 'D', kleur_ebc: 'E' },
    },
    hopgift_kook: {
      eersteRij: RIJ_HOP_EERSTE + n0, vasteSloten: RIJ_HOP_LAATSTE - RIJ_HOP_EERSTE + 1,
      kolommen: { naam: 'A', hdt: 'Q', alpha_pct: 'D', hoeveelheid: 'E', tijdstip: 'G' },
    },
    dry_hop: {
      eersteRij: RIJ_DRYHOP_EERSTE + n0 + nHop, vasteSloten: RIJ_DRYHOP_LAATSTE - RIJ_DRYHOP_EERSTE + 1,
      kolommen: { naam: 'A', hoeveelheid: 'E', tijdstip: 'G' },
    },
    toegift_brouwerij: {
      eersteRij: RIJ_BROUWHUIS_EERSTE + n0 + nHop + nDryHop, vasteSloten: RIJ_BROUWHUIS_LAATSTE - RIJ_BROUWHUIS_EERSTE + 1,
      kolommen: { naam: 'A', hoeveelheid: 'E', tijdstip: 'I' },
    },
    toegift_kelder: {
      eersteRij: RIJ_KELDER_EERSTE + n0 + nHop + nDryHop + n1, vasteSloten: RIJ_KELDER_LAATSTE - RIJ_KELDER_EERSTE + 1,
      kolommen: { naam: 'A', hoeveelheid: 'E', tijdstip: 'I' },
    },
  };

  const rollen = ['hopgift_kook', 'dry_hop', 'hoofdmout', 'toegift_brouwerij', 'toegift_kelder', 'gist'];
  for (const rol of rollen) {
    const ongesorteerd = bundel.recipe_ingredients.filter(r => r.rol === rol);
    const rijen = rol === 'hopgift_kook'
      ? bouwHopKookLayout(bundel)
      : (rol === 'dry_hop'
        ? sorteerHopgiften(ongesorteerd, rol)
        : ongesorteerd.sort((a, b) => (a.volgorde ?? 0) - (b.volgorde ?? 0)));

    if (dynamischeBlokken[rol]) {
      const { eersteRij, vasteSloten, kolommen } = dynamischeBlokken[rol];
      // Ook als er minder regels zijn dan het oorspronkelijke aantal sloten,
      // blijven we tot dat oorspronkelijke aantal doorlopen om eventuele
      // restjes van een vorige generatie/sjabloonwaarde leeg te maken.
      const totaalRijen = Math.max(rijen.length, vasteSloten);
      for (let i = 0; i < totaalRijen; i++) {
        const rij = eersteRij + i;
        const regel = rijen[i];
        for (const attr in kolommen) {
          const cel = `Recept-voorblad!${kolommen[attr]}${rij}`;
          if (!regel) { await writer.setCelWaarde(cel, null); continue; }
          const waarde = attr === 'naam'
            ? (bundel.ingredientNaam.get(regel.ingredient_id) || regel.notitie || null)
            : regel[attr];
          await writer.setCelWaarde(cel, waarde);
        }
      }
      continue;
    }

    const cellenPerRij = ingredientMap[rol];
    if (!cellenPerRij) continue;
    const slots = Object.keys(cellenPerRij).sort((a, b) => Number(a) - Number(b));
    for (let i = 0; i < slots.length; i++) {
      const regel = rijen[i];
      const cellen = cellenPerRij[slots[i]];
      if (!regel) {
        for (const attr in cellen) await writer.setCelWaarde(verschuifCel(cellen[attr]), null);
        continue;
      }
      for (const attr in cellen) {
        const waarde = attr === 'naam'
          ? (bundel.ingredientNaam.get(regel.ingredient_id) || regel.notitie || null)
          : regel[attr];
        await writer.setCelWaarde(verschuifCel(cellen[attr]), waarde);
      }
    }
  }
}

async function brVulRevisies(writer, bundel, revisieMap, verschuifCel) {
  for (let i = 0; i < bundel.recipe_revisies.length; i++) {
    const rv = bundel.recipe_revisies[i];
    const cellen = revisieMap[String(i + 1)];
    if (!cellen) continue;
    if (cellen.versienummer) await writer.setCelWaarde(verschuifCel(cellen.versienummer), `${rv.versie_major}.${rv.versie_minor}`);
    if (cellen.datum) await writer.setCelWaarde(verschuifCel(cellen.datum), rv.datum);
    if (cellen.door) await writer.setCelWaarde(verschuifCel(cellen.door), rv.door);
    if (cellen.wijziging) await writer.setCelWaarde(verschuifCel(cellen.wijziging), rv.wijziging);
  }
}

async function brVulFormaten(writer, bundel, formatenMap) {
  const gekozen = new Set(bundel.recipe_verpakking.formaten || []);
  for (const [naam, cel] of Object.entries(formatenMap)) {
    await writer.setCelWaarde(cel, gekozen.has(naam) ? 'X' : null);
  }
}

// Rendement% (kolom I) blijft een geplakte waarde (JS-lookuptabel, geen live
// Excel-equivalent meer). EBU (kolom K) is weer een ECHTE Excel-formule i.p.v.
// een geplakt getal, zodat als de operator na generatie het werkelijke gewicht
// in kolom E aanpast, de EBU in Excel zelf meerekent. Zie generate-batchrapport.js
// voor dezelfde logica (Node-pad) — deze twee moeten in sync blijven.
async function brVulHopRendementEnEbu(writer, bundel, overloop) {
  const { n0, verschuifCel } = overloop;
  const og = bundel.recipe_specificaties.origineel_extract;
  const hopRijen = bouwHopKookLayout(bundel);

  const eersteRij = RIJ_HOP_EERSTE + n0;
  const vasteSloten = RIJ_HOP_LAATSTE - RIJ_HOP_EERSTE + 1;
  const totaalRijen = Math.max(hopRijen.length, vasteSloten);

  for (let i = 0; i < totaalRijen; i++) {
    const rij = eersteRij + i;
    const regel = hopRijen[i];
    if (!regel) {
      await writer.setCelWaarde(`Recept-voorblad!I${rij}`, null);
      await writer.setCelWaarde(`Recept-voorblad!K${rij}`, null);
      continue;
    }
    const kooktijd = regel.tijdstip !== null && regel.tijdstip !== undefined && regel.tijdstip !== ''
      ? Number(regel.tijdstip) : null;
    const rendement = (kooktijd !== null && og) ? bepaalHopRendement(kooktijd, og) : null;

    await writer.setCelWaarde(`Recept-voorblad!I${rij}`, rendement !== null ? Number(rendement.toFixed(1)) : null);
    if (rendement !== null) {
      await writer.setCelWaarde(`Recept-voorblad!K${rij}`, {
        formula: `(E${rij}*1000)*(D${rij}/100)*(I${rij}/100)/('Brouwen'!$F$16*100)`,
      });
    } else {
      await writer.setCelWaarde(`Recept-voorblad!K${rij}`, null);
    }
  }
  const laatsteRij = eersteRij + totaalRijen - 1;
  await writer.setCelWaarde(verschuifCel('Recept-voorblad!K64'), {
    formula: `SUM(K${eersteRij}:K${laatsteRij})`,
  });
}

function kolomNummerNaarLetter(num) {
  let letters = '';
  while (num > 0) {
    const rest = (num - 1) % 26;
    letters = String.fromCharCode(65 + rest) + letters;
    num = Math.floor((num - 1) / 26);
  }
  return letters;
}

async function brZetHopGroepRanden(writer, stylesManager, bundel, overloop) {
  const { n0, nHop, nDryHop } = overloop;
  const hopEersteRij = RIJ_HOP_EERSTE + n0;
  const dryHopEersteRij = RIJ_DRYHOP_EERSTE + n0 + nHop;
  const dryHopLaatsteRij = RIJ_DRYHOP_LAATSTE + n0 + nHop + nDryHop;

  async function zetRandOpRij(rijNr, kolomVan, kolomTot, stijl) {
    for (let col = kolomVan; col <= kolomTot; col++) {
      const sheetCel = `Recept-voorblad!${kolomNummerNaarLetter(col)}${rijNr}`;
      try {
        let basisStijl;
        if (await writer.celBestaat(sheetCel)) {
          basisStijl = await writer.haalStijlIndexOp(sheetCel);
        } else {
          const anker = await writer.haalMergeAnker(sheetCel);
          basisStijl = await writer.haalStijlIndexOp(anker);
        }
        if (rijNr !== hopEersteRij) {
          basisStijl = stylesManager.wisBovenrand(basisStijl);
        }
        const nieuweStijl = stylesManager.voegOnderrandToe(basisStijl, stijl);
        await writer.zetOfMaakCelStijl(sheetCel, nieuweStijl);
      } catch (e) {
        // onbekende/niet-bestaande cel of rij -- overslaan
      }
    }
  }

  for (let rij = hopEersteRij; rij <= dryHopLaatsteRij; rij++) {
    await zetRandOpRij(rij, 1, 16, 'dotted');
  }

  async function dikkeRandenVoorBlok(rijen, startRij) {
    for (let i = 0; i < rijen.length; i++) {
      const huidige = rijen[i];
      const volgende = rijen[i + 1];
      const laatsteVanGroep = !volgende || volgende.tijdstip !== huidige.tijdstip;
      if (!laatsteVanGroep) continue;
      await zetRandOpRij(startRij + i, 1, 16, 'medium');
    }
  }

  // Hop boil: geen dikke lijn meer per intern groepgrens -- dat is nu een
  // echte witte scheidingsrij (bouwHopKookLayout). Alleen de laatste rij
  // van de hele Hop boil-tabel (overgang naar Dry hop) krijgt nog een
  // dikke lijn.
  const hopLayout = bouwHopKookLayout(bundel);
  if (hopLayout.length > 0) {
    await zetRandOpRij(hopEersteRij + hopLayout.length - 1, 1, 16, 'medium');
  }

  const dryHopRijen = sorteerHopgiften(bundel.recipe_ingredients.filter(r => r.rol === 'dry_hop'), 'dry_hop');
  await dikkeRandenVoorBlok(dryHopRijen, dryHopEersteRij);
}

/**
 * Genereert het batchrapport voor het gegeven batchnummer en start meteen
 * een download in de browser.
 */
async function genereerEnDownloadBatchrapport(supabase, batchnummer) {
  const [scalarMap, ingredientMap, revisieMap, formatenMap, templateBuffer] = await Promise.all([
    brFetchJson('data/scalar_field_map.json'),
    brFetchJson('data/ingredient_field_map.json'),
    brFetchJson('data/revisie_field_map.json'),
    brFetchJson('data/formaten_field_map.json'),
    fetch(BR_BASISPAD + 'Batchrapport_sjabloon.xlsx', { cache: 'no-store' }).then(r => {
      if (!r.ok) throw new Error(`Kon sjabloon niet ophalen (${r.status})`);
      return r.arrayBuffer();
    }),
  ]);

  const bundel = await haalBatchDataOpBrowser(supabase, batchnummer);

  const naam = bundel.recipes.naam || '';
  const locatie = (bundel.recipes.locatie || '').toLowerCase();
  const isWP = locatie.includes('waarderpolder');
  const vestigingsPrefix = isWP ? 'WP' : 'JK';

  const zip = await JSZip.loadAsync(templateBuffer);
  const writer = new XlsxDirectWriter(zip);
  await writer.init();
  const stylesManager = new StylesManager(zip);
  await stylesManager.init();

  // Moet als allereerste, vóór alle andere schrijfacties op Recept-voorblad:
  // recepten met meer dan 10 Toegiften Brouwerij- en/of 5 Toegiften Kelder-
  // regels krijgen hier zo nodig extra rijen, en alle latere writer.setCelWaarde-
  // aanroepen op dit tabblad moeten via verschuifCel() de eventueel verschoven
  // rij gebruiken (Gist, Water, Revisiehistorie zitten allemaal ná deze blokken).
  const overloop = await brVoegOverloopRijenToe(writer, bundel);

  await brVulScalaireVelden(writer, bundel, isWP, scalarMap, overloop.verschuifCel);
  await brVulWpKerkVelden(writer, bundel, isWP);
  await brVulReceptnaamKruisVelden(writer, bundel, isWP);
  await brVulIngredientRijen(writer, bundel, ingredientMap, overloop);
  await brVulRevisies(writer, bundel, revisieMap, overloop.verschuifCel);
  await brVulFormaten(writer, bundel, formatenMap);
  await brVulHopRendementEnEbu(writer, bundel, overloop);
  await brZetHopGroepRanden(writer, stylesManager, bundel, overloop);

  await writer.setCelWaarde('Recept-voorblad!K3', bundel.batch.batchnummer);
  // Fallback naar 1 (niet null/blank): elke "Totaal gram"-cel op dit tabblad
  // is E-kolom * G7, dus een lege G7 zet stilzwijgend ALLE hoptotalen op 0
  // i.p.v. gewoon de waarde van 1 brouwsel te tonen. Zie ook generate-batchrapport.js.
  await writer.setCelWaarde('Recept-voorblad!G7', bundel.batch.aantal_brouwsels ?? 1);
  await writer.setCelWaarde('Recept-voorblad!Q1', `${vestigingsPrefix} ${naam}`);

  stylesManager.finalize();
  await writer.finalize();
  const blob = await zip.generateAsync({ type: 'blob' });

  const laatsteRevisie = bundel.recipe_revisies[0];
  const versienummer = laatsteRevisie
    ? `${laatsteRevisie.versie_major}.${laatsteRevisie.versie_minor}`
    : `${bundel.recipes.versie_major ?? 1}.${bundel.recipes.versie_minor ?? 0}`;
  const bestandsnaam = `${bundel.batch.batchnummer} ${naam} v${versienummer} ${vestigingsPrefix}.xlsx`;

  await slaBatchrapportOp(blob, bestandsnaam);
}

/**
 * Slaat het gegenereerde batchrapport op. Gebruikt waar mogelijk de File
 * System Access API (showSaveFilePicker) zodat de gebruiker zelf een map
 * kiest via de normale OS-dialoog, i.p.v. dat het rapport altijd in de
 * standaard downloadmap belandt. Chrome/Edge ondersteunen dit; Firefox en
 * Safari niet -- die vallen automatisch terug op de oude download-aanpak.
 */
async function slaBatchrapportOp(blob, bestandsnaam) {
  if ('showSaveFilePicker' in window) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: bestandsnaam,
        types: [{
          description: 'Excel Workbook',
          accept: { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['.xlsx'] },
        }],
      });
      const schrijfbareStream = await handle.createWritable();
      await schrijfbareStream.write(blob);
      await schrijfbareStream.close();
      return;
    } catch (err) {
      // Gebruiker annuleerde de dialoog (AbortError) -- geen fout, gewoon niets doen.
      if (err && err.name === 'AbortError') return;
      // Iets anders ging mis (bv. rechten): val terug op gewone download i.p.v. helemaal niets opleveren.
      console.warn('showSaveFilePicker mislukt, val terug op download:', err);
    }
  }

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = bestandsnaam;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
