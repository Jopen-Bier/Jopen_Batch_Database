/**
 * xlsx-direct.js
 * -----------------------------------------------------------------------
 * Schrijft waarden/formules rechtstreeks in de ruwe sheet-XML van een xlsx-
 * bestand, via JSZip, zonder ExcelJS te gebruiken om het hele werkboek in
 * te laden/op te slaan.
 *
 * WAAROM: ExcelJS bleek bij het opslaan meerdere dingen kapot te maken die
 * niets met onze eigen wijzigingen te maken hadden -- rij/cel-mismatches,
 * een verminkte Print Area, een foute sheetPr-elementvolgorde, en (het
 * zwaarste) een complete herbouw/deduplicatie van de stijlentabel (cellXfs
 * ging van 2209 naar 1147 unieke stijlen), waarbij cellen soms de kleur van
 * een "buurstijl" kregen i.p.v. hun eigen kleur. Al deze problemen
 * verdwijnen als we ExcelJS's volledige save-cyclus vermijden en alleen de
 * specifieke cellen aanpassen die we echt moeten invullen, met de rest van
 * het bestand (incl. de hele stijlentabel) volledig ongemoeid.
 *
 * AANNAME (geverifieerd voor dit sjabloon): elke cel die we invullen bestaat
 * al als element in de sheet-XML (leeg, met een stijl -- ooit een formule
 * met "Data!"/"Batch #"!/"EBU Berekening"!-verwijzing die we hebben
 * leeggemaakt). We hoeven dus nooit nieuwe cellen in te voegen, alleen
 * bestaande te vervangen. Als een cel toch ontbreekt, gooit setCelWaarde
 * een duidelijke fout i.p.v. stilzwijgend niets te doen.
 * -----------------------------------------------------------------------
 */

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
function kolomNummerNaarLetter(num) {
  let letters = '';
  while (num > 0) {
    const rest = (num - 1) % 26;
    letters = String.fromCharCode(65 + rest) + letters;
    num = Math.floor((num - 1) / 26);
  }
  return letters;
}
function ontleedCelRef(ref) {
  const m = ref.match(/^([A-Z]+)(\d+)$/);
  return { col: kolomLetterNaarNummer(m[1]), row: Number(m[2]) };
}

class XlsxDirectWriter {
  constructor(zip) {
    this.zip = zip;
    this.sheetXmlPerBestand = {}; // 'xl/worksheets/sheet1.xml' -> xml-string (gecached, wordt aan het eind teruggeschreven)
    this.sheetNaarBestand = null; // 'Recept-voorblad' -> 'xl/worksheets/sheet1.xml'
    this._mergesPerBestand = {}; // 'xl/worksheets/sheet1.xml' -> [{c1,r1,c2,r2}, ...]
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
      const target = relMap[rId]; // bv. 'worksheets/sheet1.xml'
      if (target) {
        this.sheetNaarBestand[naam] = target.startsWith('/')
          ? target.slice(1)           // absoluut pad, al t.o.v. package-root
          : 'xl/' + target;           // relatief t.o.v. xl/_rels/../  (dus xl/)
      }
    }
  }

  /**
   * Als `sheetCel` een niet-ankercel is binnen een samengevoegd bereik (bv.
   * B43 binnen A43:C43), geeft dit de ankercel (linksboven, bv. A43) terug.
   * Anders gewoon de cel zelf. Nodig omdat alleen de ankercel echt bestaat
   * als element in de sheet-XML -- de rest van een samenvoeging heeft geen
   * eigen `<c>`, dus geen eigen stijl om aan te passen.
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
        if (col === mr.c1 && row === mr.r1) return sheetCel; // is zelf al de anker
        return `${sheetNaam}!${kolomNummerNaarLetter(mr.c1)}${mr.r1}`;
      }
    }
    return sheetCel;
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
   * Vervangt de inhoud van cel `sheetCel` (bv. "Recept-voorblad!F12") door
   * `waarde`, met behoud van de bestaande stijl (`s="..."`-attribuut).
   * - null/undefined -> lege cel (zelfsluitend, stijl blijft staan)
   * - number -> numerieke cel
   * - string -> inlineStr-cel (geen shared-strings-tabel nodig)
   * - { formula: '...' } -> formule-cel (geen cache-waarde, Excel herberekent bij openen)
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
    const attrsRuw = match[1]; // bv. ' s="1222" t="n"'
    const sMatch = attrsRuw.match(/\bs="(\d+)"/);
    const sAttr = sMatch ? ` s="${sMatch[1]}"` : '';

    let nieuweCel;
    if (waarde === null || waarde === undefined || waarde === '') {
      nieuweCel = `<c r="${cel}"${sAttr}/>`;
    } else if (typeof waarde === 'object' && waarde.formula) {
      nieuweCel = `<c r="${cel}"${sAttr}><f>${xmlEscape(waarde.formula)}</f></c>`;
    } else if (typeof waarde === 'number') {
      nieuweCel = `<c r="${cel}"${sAttr}><v>${waarde}</v></c>`;
    } else {
      const num = Number(waarde);
      if (typeof waarde !== 'string' && !Number.isNaN(num)) {
        nieuweCel = `<c r="${cel}"${sAttr}><v>${num}</v></c>`;
      } else if (typeof waarde === 'string' && waarde.trim() !== '' && !Number.isNaN(Number(waarde))) {
        // Postgres 'numeric'-kolommen komen als string terug (bv "0.5") --
        // als echt getal schrijven, anders behandelt Excel het als tekst.
        nieuweCel = `<c r="${cel}"${sAttr}><v>${Number(waarde)}</v></c>`;
      } else {
        nieuweCel = `<c r="${cel}"${sAttr} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(waarde)}</t></is></c>`;
      }
    }

    this.sheetXmlPerBestand[bestand] = xml.replace(cellPattern, () => nieuweCel);
  }

  /** Huidige `s="..."`-waarde van een cel opvragen (voor de border-helper). */
  async haalStijlIndexOp(sheetCel) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    const xml = this.sheetXmlPerBestand[bestand];
    const match = xml.match(new RegExp(`<c r="${cel}"([^>]*?)(?:/>|>)`));
    if (!match) throw new Error(`Cel ${sheetCel} niet gevonden`);
    const sMatch = match[1].match(/\bs="(\d+)"/);
    return sMatch ? Number(sMatch[1]) : 0;
  }

  /** Wijst cel `sheetCel` een ander (bestaand) stijlindex toe. */
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

  /** Of een cel al als element bestaat in de sheet-XML. */
  async celBestaat(sheetCel) {
    const [sheetNaam, cel] = sheetCel.split('!');
    const bestand = await this._laadSheetXml(sheetNaam);
    const xml = this.sheetXmlPerBestand[bestand];
    return new RegExp(`<c r="${cel}"[^>]*(?:/>|>)`).test(xml);
  }

  /**
   * Zet cel `sheetCel` op stijlindex `stijlIdx` -- maakt de cel aan (leeg,
   * met deze stijl) als hij nog niet bestaat. Nodig voor cellen binnen een
   * samengevoegd bereik die geen eigen element hebben: zonder eigen element
   * toont Excel voor DIE positie geen rand, ook al hoort de cel wel bij de
   * samenvoeging (alleen de ankercel netjes gerand krijgen is dus niet
   * genoeg om een doorlopende lijn over de hele breedte van de samenvoeging
   * te tonen).
   */
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
   * gekopieerd. Alles wat op of na `voorRij` stond (rijen, samenvoegingen,
   * formules bínnen `sheetNaam` die naar deze rijen verwijzen, en
   * kruisverwijzingen vanuit ANDERE tabbladen) schuift `aantal` plekken op.
   * Bedoeld voor blokken met een oorspronkelijk vast aantal sloten (Malt &
   * grains, Hops, Toegiften Brouwerij/Kelder) die nu meer regels kunnen
   * bevatten dan het sjabloon van origine had.
   *
   * Voor formules bínnen `sheetNaam` zelf: een kale celverwijzing (zonder
   * "Andertabblad!"-voorvoegsel) hoort altijd bij `sheetNaam` zelf en
   * schuift dus mee zodra de rij ≥ `voorRij` is -- ook als de formule
   * toevallig een bereik is dat over `voorRij` heen loopt (bv.
   * `SUM(D30:D39)` invoegen vóór rij 39 wordt correct `SUM(D30:D42)` i.p.v.
   * dat het hele bereik in zijn geheel verschuift). Een celverwijzing MET
   * een ander tabblad ervoor (bv. `Brouwen!$F$16`) wordt met rust gelaten.
   */
  async voegRijenToe(sheetNaam, voorRij, aantal, sjabloonRij) {
    if (!aantal || aantal <= 0) return;
    const bestand = await this._laadSheetXml(sheetNaam);
    let xml = this.sheetXmlPerBestand[bestand];

    // Formules bínnen dit tabblad: kale celverwijzingen (geen sheet-prefix,
    // of expliciet 'sheetNaam'! zelf) schuiven mee; verwijzingen naar een
    // ANDER tabblad blijven onaangeroerd.
    const formuleVerwijzingPatroon = new RegExp(
      `((?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ ]*))!)?(\\$?)([A-Z]+)(\\$?)(\\d+)`, 'g'
    );
    function verschuifFormuleTekst(tekst) {
      return tekst.replace(formuleVerwijzingPatroon, (heleMatch, prefixVolledig, gequoteNaam, kaleNaam, dollarKol, kol, dollarRij, rijStr) => {
        const andereSheet = gequoteNaam || kaleNaam;
        if (andereSheet && andereSheet !== sheetNaam) return heleMatch; // ander tabblad, met rust laten
        const rij = Number(rijStr);
        if (rij < voorRij) return heleMatch;
        return `${prefixVolledig || ''}${dollarKol}${kol}${dollarRij}${rij + aantal}`;
      });
    }
    function verschuifFormulesInInhoud(inhoud) {
      return inhoud.replace(/<f>([\s\S]*?)<\/f>/g, (heleMatch, formule) => `<f>${verschuifFormuleTekst(formule)}</f>`);
    }

    // --- 1. Alle <row>-elementen ontleden ---
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

    // Voor GEKOPIEERDE sjabloonrijen: een kale (niet-$) rijverwijzing die
    // precies naar de sjabloonrij zelf verwijst (bv. "D35" in sjabloonrij 35)
    // is een zelfverwijzing van die rij naar zichzelf, en moet meeschuiven
    // naar de nieuwe rij (D39, D40, ...) -- net als Excel's normale "kopieer
    // rij" gedrag met relatieve referenties. Verwijzingen naar een ANDERE
    // rij (bv. het absolute "$D$40" dat naar de totaalrij van het blok
    // wijst) volgen gewoon de normale drempel-verschuiving -- ook al hebben
    // ze een $, want die rij verplaatst in dit bestand ECHT fysiek, dus elke
    // verwijzing ernaartoe moet meeschuiven, los van wat $ ooit betekende in
    // Excels eigen kopieer/plak-semantiek. Alleen een verwijzing met een
    // expliciet ANDER sheet-voorvoegsel blijft met rust.
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
    // Nieuwe, gekopieerde rijen invoegen op de juiste plek (oplopend op rijnummer)
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

    // Formules bínnen dit tabblad (bv. SUM(D30:D39)) kunnen in ELKE
    // BESTAANDE rij voorkomen, niet alleen in rijen die zelf verschuiven --
    // dus deze stap is los van de rij-verschuiving hierboven. Gekopieerde
    // rijen (_nieuw) slaan we hier bewust over, zie toelichting hierboven.
    for (const r of nieuweRijen) {
      if (r._nieuw) continue;
      r.inhoud = verschuifFormulesInInhoud(r.inhoud);
    }

    const nieuweSheetDataInhoud = nieuweRijen
      .map(r => `<row r="${r.rij}"${r.attrs}>${r.inhoud}</row>`)
      .join('');
    xml = xml.replace(/<sheetData>[\s\S]*?<\/sheetData>/, `<sheetData>${nieuweSheetDataInhoud}</sheetData>`);

    // --- 2. mergeCells: bestaande verschuiven, sjabloonrij-merges dupliceren ---
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

    // --- 3. <dimension> ophogen ---
    xml = xml.replace(/<dimension ref="([A-Z]+)(\d+):([A-Z]+)(\d+)"\/>/, (_, c1, r1, c2, r2) => {
      const nieuweR2 = Number(r2) >= voorRij ? Number(r2) + aantal : Number(r2);
      return `<dimension ref="${c1}${r1}:${c2}${nieuweR2}"/>`;
    });

    this.sheetXmlPerBestand[bestand] = xml;

    // --- 4. Print_Area (workbook.xml) ophogen ---
    await this._verschuifPrintArea(sheetNaam, voorRij, aantal);

    // --- 5. Kruisverwijzingen vanuit ANDERE tabbladen verschuiven ---
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

  /** Schrijft alle gewijzigde sheet-XML terug in de zip en levert de zip. */
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

/**
 * Beheert xl/styles.xml rechtstreeks, voor het toevoegen van een dikke
 * onderrand aan een cel zonder de rest van diens stijl (kleur, lettertype,
 * andere randen) aan te raken. Zoekt eerst of een passende stijl al bestaat
 * (dedupliceert zelf, netjes), voegt anders een nieuwe <border>/<xf> toe
 * -- bestaande stijlen/indexen blijven onaangeroerd.
 */
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
    // Splitst een reeks <tag ...>...</tag> of <tag .../> elementen op het top-niveau.
    const elementen = [];
    const re = new RegExp(`<${tagNaam}(?:[^>]*?/>|[^>]*?>[\\s\\S]*?</${tagNaam}>)`, 'g');
    let m;
    while ((m = re.exec(inhoud)) !== null) elementen.push(m[0]);
    return elementen;
  }

  /**
   * Geeft de stijlindex terug voor "dezelfde stijl als sourceStyleIdx, maar
   * met een dikke zwarte onderrand" (overige randen ongewijzigd).
   */
  /**
   * Geeft de stijlindex terug voor "dezelfde stijl als sourceStyleIdx, maar
   * met een andere onderrand" (overige randen ongewijzigd). `stijl` is een
   * OOXML-randstijl, bv. "medium" (toevoegmoment-grens) of "dotted" (basis-
   * scheiding tussen losse rijen).
   */
  /**
   * Als voegOnderrandToe, maar dan voor de bovenrand -- gebruikt om de
   * oorspronkelijke "hair"-bovenrand weg te halen zodat die niet in
   * conflict komt met de onderrand die we op de rij erboven zetten (Excel
   * kiest anders zelf welke van de twee concurrerende randspecificaties
   * wint, wat niet per se is wat we bedoelen).
   */
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

    // Nieuwe border: kopieer left/right/top/diagonal, vervang bottom
    const nieuweBorder = bronBorder.replace(
      /<bottom[^>]*\/>|<bottom[^>]*>[\s\S]*?<\/bottom>/,
      `<bottom style="${stijl}"><color rgb="FF000000"/></bottom>`
    ).replace(/^<border[^>]*>/, '<border>'); // eventuele diagonalUp/Down-attributen negeren we hier niet, laten we intact via de originele opening-tag hieronder
    // (bovenstaande vervanging van de opening-tag ongedaan maken als bronBorder attributen had)
    const openTagMatch = bronBorder.match(/^<border([^>]*)>/);
    const finaleNieuweBorder = openTagMatch
      ? nieuweBorder.replace('<border>', `<border${openTagMatch[1]}>`)
      : nieuweBorder;

    let nieuweBorderId = borders.findIndex(b => b === finaleNieuweBorder);
    let bordersGewijzigd = false;
    if (nieuweBorderId === -1) {
      borders.push(finaleNieuweBorder);
      nieuweBorderId = borders.length - 1;
      bordersGewijzigd = true;
    }

    // Nieuwe xf: kopieer bronXf maar met de nieuwe borderId
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
      this.xml = this.xml.replace(
        bordersSectie.volledigeMatch,
        `<borders count="${borders.length}">${nieuweInhoud}</borders>`
      );
    }
    if (xfsGewijzigd) {
      // cellXfsSectie.volledigeMatch is nog gebaseerd op de OUDE xml-string;
      // na een eventuele borders-wijziging is die nog steeds geldig omdat
      // <borders> vóór <cellXfs> staat en de tekst van cellXfs zelf niet
      // is aangeraakt door de vervanging hierboven.
      const nieuweInhoud = xfs.join('');
      this.xml = this.xml.replace(
        cellXfsSectie.volledigeMatch,
        `<cellXfs count="${xfs.length}">${nieuweInhoud}</cellXfs>`
      );
    }

    return nieuweXfIdx;
  }

  /**
   * Geeft de stijlindex terug voor "dezelfde stijl als sourceStyleIdx, maar
   * met leesbare (theme 1 / zwarte) tekstkleur i.p.v. wat er nu staat"
   * (fill/border/alignment ongewijzigd). Nodig voor kolom Q op de Additions
   * Brewing-rijen: die cellen stonden van origine op theme="0" (wit-op-wit,
   * kolom Q valt buiten de Print Area en was nooit bedoeld om zichtbaar te
   * zijn) -- onze "All in brew 1?"-notitie moet daar nu wél leesbaar staan.
   */
  voegLeesbareFontKleurToe(sourceStyleIdx) {
    const cellXfsSectie = this._haalSectie('cellXfs');
    const xfs = this._splitsElementen(cellXfsSectie.inhoud, 'xf');
    const bronXf = xfs[sourceStyleIdx];
    if (!bronXf) throw new Error(`Stijlindex ${sourceStyleIdx} bestaat niet`);
    const fontIdMatch = bronXf.match(/fontId="(\d+)"/);
    const bronFontId = fontIdMatch ? Number(fontIdMatch[1]) : 0;

    const fontsSectie = this._haalSectie('fonts');
    const fonts = this._splitsElementen(fontsSectie.inhoud, 'font');
    const bronFont = fonts[bronFontId] || '<font></font>';

    // Nieuw font: kopieer alles, vervang alleen <color .../> door theme 1
    // (standaard "Text 1" -- zwart, zelfde als andere gewone tekstcellen
    // in dit sjabloon, zie bv. de Ratio/Timing-kolommen op dezelfde rij).
    const nieuwFontMetKleur = /<color[^/]*\/>/.test(bronFont)
      ? bronFont.replace(/<color[^/]*\/>/, '<color theme="1"/>')
      : bronFont.replace('</font>', '<color theme="1"/></font>');

    let nieuweFontId = fonts.findIndex(f => f === nieuwFontMetKleur);
    let fontsGewijzigd = false;
    if (nieuweFontId === -1) {
      fonts.push(nieuwFontMetKleur);
      nieuweFontId = fonts.length - 1;
      fontsGewijzigd = true;
    }

    const nieuweXf = bronXf.replace(/fontId="\d+"/, `fontId="${nieuweFontId}"`);
    let nieuweXfIdx = xfs.findIndex(x => x === nieuweXf);
    let xfsGewijzigd = false;
    if (nieuweXfIdx === -1) {
      xfs.push(nieuweXf);
      nieuweXfIdx = xfs.length - 1;
      xfsGewijzigd = true;
    }

    if (fontsGewijzigd) {
      const nieuweInhoud = fonts.join('');
      this.xml = this.xml.replace(
        fontsSectie.volledigeMatch,
        `<fonts count="${fonts.length}">${nieuweInhoud}</fonts>`
      );
    }
    if (xfsGewijzigd) {
      const nieuweInhoud = xfs.join('');
      this.xml = this.xml.replace(
        cellXfsSectie.volledigeMatch,
        `<cellXfs count="${xfs.length}">${nieuweInhoud}</cellXfs>`
      );
    }

    return nieuweXfIdx;
  }

  /**
   * Geeft de stijlindex terug voor "dezelfde stijl als sourceStyleIdx, maar
   * met een enkele onderstreping" (fill/border/kleur/alignment ongewijzigd).
   * Gebruikt om het berekende batch-totaal in kolom G extra te laten
   * opvallen bij "All in brew 1?". Zelfde volgorde-conventie als de 5
   * bestaande onderstreepte fonts in dit sjabloon: <u val="single"/> als
   * laatste element vóór </font>. Idempotent als de bronfont al onderstreept is.
   */
  voegOnderstrepingToe(sourceStyleIdx) {
    const cellXfsSectie = this._haalSectie('cellXfs');
    const xfs = this._splitsElementen(cellXfsSectie.inhoud, 'xf');
    const bronXf = xfs[sourceStyleIdx];
    if (!bronXf) throw new Error(`Stijlindex ${sourceStyleIdx} bestaat niet`);
    const fontIdMatch = bronXf.match(/fontId="(\d+)"/);
    const bronFontId = fontIdMatch ? Number(fontIdMatch[1]) : 0;

    const fontsSectie = this._haalSectie('fonts');
    const fonts = this._splitsElementen(fontsSectie.inhoud, 'font');
    const bronFont = fonts[bronFontId] || '<font></font>';

    const nieuwFontMetOnderstreping = /<u[^/]*\/>/.test(bronFont)
      ? bronFont
      : bronFont.replace('</font>', '<u val="single"/></font>');

    let nieuweFontId = fonts.findIndex(f => f === nieuwFontMetOnderstreping);
    let fontsGewijzigd = false;
    if (nieuweFontId === -1) {
      fonts.push(nieuwFontMetOnderstreping);
      nieuweFontId = fonts.length - 1;
      fontsGewijzigd = true;
    }

    const nieuweXf = bronXf.replace(/fontId="\d+"/, `fontId="${nieuweFontId}"`);
    let nieuweXfIdx = xfs.findIndex(x => x === nieuweXf);
    let xfsGewijzigd = false;
    if (nieuweXfIdx === -1) {
      xfs.push(nieuweXf);
      nieuweXfIdx = xfs.length - 1;
      xfsGewijzigd = true;
    }

    if (fontsGewijzigd) {
      const nieuweInhoud = fonts.join('');
      this.xml = this.xml.replace(
        fontsSectie.volledigeMatch,
        `<fonts count="${fonts.length}">${nieuweInhoud}</fonts>`
      );
    }
    if (xfsGewijzigd) {
      const nieuweInhoud = xfs.join('');
      this.xml = this.xml.replace(
        cellXfsSectie.volledigeMatch,
        `<cellXfs count="${xfs.length}">${nieuweInhoud}</cellXfs>`
      );
    }

    return nieuweXfIdx;
  }

  finalize() {
    this.zip.file('xl/styles.xml', this.xml);
  }
}

module.exports = { XlsxDirectWriter, xmlEscape, StylesManager };

