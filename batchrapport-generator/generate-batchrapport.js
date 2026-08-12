#!/usr/bin/env node
/**
 * generate-batchrapport.js
 * -----------------------------------------------------------------------
 * Genereert een gevuld batchrapport (.xlsx) voor één batch uit de `batches`-
 * tabel: haalt het gekoppelde recept + alle sub-tabellen op uit Supabase,
 * plakt de waarden op de juiste plek in Batchrapport_sjabloon.xlsx (via de
 * mapping-bestanden in ./data), herberekent Hop-rendement/EBU en laat alle
 * overige formules in het sjabloon met rust.
 *
 * Schrijft rechtstreeks in de ruwe sheet-XML (zie xlsx-direct.js) i.p.v. via
 * ExcelJS' load/save-cyclus -- die bleek zelf meerdere dingen te breken die
 * niets met onze eigen wijzigingen te maken hadden (rij/cel-mismatches, een
 * verminkte Print Area, een foute sheetPr-elementvolgorde, een herbouwde
 * stijlentabel). Door alleen de specifieke cellen te vervangen die we echt
 * moeten invullen, en de rest van het bestand volledig ongemoeid te laten,
 * kunnen die problemen niet meer optreden.
 *
 * Gebruik:
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node generate-batchrapport.js <batchnummer>
 *
 * LET OP: gebruik hier de service_role key (niet de publishable/anon key uit
 * config.js), dit script draait server-side/lokaal en moet buiten RLS om alle
 * receptdata kunnen lezen. Nooit deze key in een browser/frontend gebruiken.
 *
 * Output: ./output/<batchnummer> <naam> v<versie> <WP/prefix>.xlsx
 * -----------------------------------------------------------------------
 */

const path = require('path');
const fs = require('fs');
const JSZip = require('jszip');
const { createClient } = require('@supabase/supabase-js');
const { XlsxDirectWriter, StylesManager } = require('./xlsx-direct');

const SCALAR_MAP = require('./data/scalar_field_map.json');
const INGREDIENT_MAP = require('./data/ingredient_field_map.json');
const REVISIE_MAP = require('./data/revisie_field_map.json');
const FORMATEN_MAP = require('./data/formaten_field_map.json');

const TEMPLATE_PATH = path.join(__dirname, 'Batchrapport_sjabloon.xlsx');
const OUTPUT_DIR = path.join(__dirname, 'output');

// ---------------------------------------------------------------------------
// Hop rendement (utilization) & EBU — exact dezelfde tabel/logica als
// recept-invoer.html / receptoverzicht.html (1-op-1 uit Moederdata.xlsm,
// EBU Berekening!T2:AF27 + Recept-voorblad!K43). Bewust hier gedupliceerd
// i.p.v. gedeeld via een <script>-bestand, omdat dit script in Node draait
// en de webpagina's in de browser — zie qua onderhoud: als de tabel ooit
// verandert, moet dat op ALLE drie plekken (hier, batchrapport-vullen.js,
// en de twee HTML-bestanden).
// ---------------------------------------------------------------------------
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
// Supabase ophalen
// ---------------------------------------------------------------------------
async function haalBatchDataOp(supabase, batchnummer) {
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
// Rij-overloop Malt & grains / Hops (boil + dry) / Toegiften Brouwerij/Kelder
// ---------------------------------------------------------------------------
// Zie batchrapport-vullen.js voor de volledige toelichting -- deze functie
// is bewust identiek aan de browser-tegenhanger.
const RIJ_MOUT_EERSTE = 30;
const RIJ_MOUT_LAATSTE = 39;
const RIJ_MOUT_SJABLOON = 35;
const RIJ_HOP_EERSTE = 43;
const RIJ_HOP_LAATSTE = 57;
const RIJ_HOP_SJABLOON = 50;
const RIJ_DRYHOP_EERSTE = 58;
const RIJ_DRYHOP_LAATSTE = 63;
const RIJ_DRYHOP_SJABLOON = 60;
const RIJ_BROUWHUIS_EERSTE = 75;
const RIJ_BROUWHUIS_LAATSTE = 84;
const RIJ_BROUWHUIS_SJABLOON = 80;
const RIJ_KELDER_EERSTE = 91;
const RIJ_KELDER_LAATSTE = 95;
const RIJ_KELDER_SJABLOON = 92;

// Bouwt de fysieke rij-indeling van de Hop boil-tabel: de gesorteerde
// hopgiften met een extra `null` (= lege, witte scheidingsrij) ingevoegd
// tussen twee opeenvolgende regels met een ANDER toevoegmoment (tijdstip).
// Deze witregel maakt de vroegere dikke-lijn-per-groep overbodig binnen
// Hop boil (zie zetHopGroepRanden) en telt mee als extra fysieke rij voor
// de rij-overloop-berekening hieronder. Nooit een scheidingsrij ná de
// laatste groep (dat is de overgang naar Dry hop, ongewijzigd).
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

async function voegOverloopRijenToe(writer, bundel) {
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

// ---------------------------------------------------------------------------
// Sjabloon vullen — alles via writer.setCelWaarde() (behoudt bestaande stijl)
// ---------------------------------------------------------------------------
async function vulScalaireVelden(writer, bundel, isWP, verschuifCel) {
  for (const veld of SCALAR_MAP) {
    if (veld.wp_only && !isWP) continue;
    const [tabel, kolom] = veld.db_veld.split('.');
    const bron = bundel[tabel];
    if (!bron) { console.warn(`Onbekende tabel in mapping: ${tabel} (${veld.key})`); continue; }
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
async function vulWpKerkVelden(writer, bundel, isWP) {
  const bron = bundel.recipe_brouwspecificaties;
  for (const v of WP_KERK_VELDEN) {
    await writer.setCelWaarde(v.cel, bron[isWP ? v.wp : v.kerk]);
  }
}

// F8/F9/F11 in Brouwen wisselen van betekenis per vestiging:
// - F8: WP -> live formule (Aantal brouwsels * Eindvolume brouwsel). Kerk -> Receptnaam Software.
// - F9: WP -> Receptnaam Software. Kerk -> Naam special bin storting.
// - F11: altijd -> Naam special bin storting.
// N8 (Gewenste stamwort) = Origineel extract + Stamwort correctie brouwhuis.
async function vulReceptnaamKruisVelden(writer, bundel, isWP) {
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

// Zelfde sortering als sorteerHopHerbsRegels() in recept-invoer.html.
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

async function vulIngredientRijen(writer, bundel, overloop) {
  const { n0, nHop, nDryHop, n1, verschuifCel } = overloop;
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

    const cellenPerRij = INGREDIENT_MAP[rol];
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

async function vulRevisies(writer, bundel, verschuifCel) {
  for (let i = 0; i < bundel.recipe_revisies.length; i++) {
    const rv = bundel.recipe_revisies[i];
    const cellen = REVISIE_MAP[String(i + 1)];
    if (!cellen) continue;
    if (cellen.versienummer) await writer.setCelWaarde(verschuifCel(cellen.versienummer), `${rv.versie_major}.${rv.versie_minor}`);
    if (cellen.datum) await writer.setCelWaarde(verschuifCel(cellen.datum), rv.datum);
    if (cellen.door) await writer.setCelWaarde(verschuifCel(cellen.door), rv.door);
    if (cellen.wijziging) await writer.setCelWaarde(verschuifCel(cellen.wijziging), rv.wijziging);
  }
}

async function vulFormaten(writer, bundel) {
  const gekozen = new Set(bundel.recipe_verpakking.formaten || []);
  for (const [naam, cel] of Object.entries(FORMATEN_MAP)) {
    await writer.setCelWaarde(cel, gekozen.has(naam) ? 'X' : null);
  }
}

// Rendement%/EBU per hopgift (Recept-voorblad!I43:I57 / K43:K57) + Calculated
// total EBU (K64).
// - Rendement% (kolom I) blijft een GEPLAKTE waarde: die komt uit de JS-
//   lookuptabel die het verwijderde EBU Berekening-tabblad vervangt, er is
//   geen live Excel-lookup-equivalent meer in het sjabloon.
// - EBU (kolom K) is weer een ECHTE Excel-formule (gewicht × alpha% ×
//   rendement% / kookvolume, incl. de *1000-factor), i.p.v. een geplakt getal.
//   Reden: de operator vult tijdens/na het brouwen soms het werkelijke gewicht
//   in kolom E bij (verschil t.o.v. het receptplan) — met een geplakt getal
//   bleef de EBU dan het oude, geplande cijfer tonen i.p.v. mee te rekenen.
//   Rendement% (I) en volume ('Brouwen'!F16) worden hierbij als celverwijzing
//   gebruikt, niet opnieuw als los getal geplakt.
async function vulHopRendementEnEbu(writer, bundel, overloop) {
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

// Randen in de Hops and Herbs-tabel (Recept-voorblad, rijen 43-63):
// - Standaard een stippellijn onder elke rij (ook de nog ongebruikte
//   hopslots), zodat losse toevoegingen binnen hetzelfde moment duidelijk
//   maar licht gescheiden zijn.
// - Hop boil: tussen twee verschillende toevoegmomenten zit een echte lege,
//   witte rij (zie bouwHopKookLayout) EN een dikke lijn op de laatste rij
//   van elk toevoegmoment (dus vlak boven elke witregel, plus op de allerlaatste
//   rij van de hele Hop boil-tabel, de overgang naar Dry hop) -- witregel en
//   dikke lijn samen maken een ander toevoegmoment extra duidelijk.
// - Dry hop: ongewijzigd, een dikke lijn onder de laatste rij van elk
//   daadwerkelijk toevoegmoment (overschrijft de stippellijn op die ene rij).
// Kolommen 1-16 (A t/m P, de Print Area-breedte). Veel cellen in deze tabel
// zijn samengevoegd (bv. A43:C43) -- alleen de ankercel bestaat echt als
// element, dus we lossen elke kolompositie eerst op naar zijn ankercel en
// ontdubbelen per rij (anders proberen we dezelfde cel meerdere keren aan
// te passen, wat de laatst-gezette stijl gewoon overschrijft maar onnodig
// werk is).
async function zetHopGroepRanden(writer, stylesManager, bundel, overloop) {
  const { n0, nHop, nDryHop } = overloop;
  const hopEersteRij = RIJ_HOP_EERSTE + n0;
  const dryHopEersteRij = RIJ_DRYHOP_EERSTE + n0 + nHop;
  const dryHopLaatsteRij = RIJ_DRYHOP_LAATSTE + n0 + nHop + nDryHop;

  async function zetRandOpRij(rijNr, kolomVan, kolomTot, stijl) {
    for (let col = kolomVan; col <= kolomTot; col++) {
      const kolomLetter = kolomNummerNaarLetter(col);
      const sheetCel = `Recept-voorblad!${kolomLetter}${rijNr}`;
      try {
        let basisStijl;
        if (await writer.celBestaat(sheetCel)) {
          basisStijl = await writer.haalStijlIndexOp(sheetCel);
        } else {
          // Cel bestaat niet als eigen element (bv. binnen een samengevoegd
          // bereik zoals A43:C43 -- alleen A43 bestaat echt). Gebruik de
          // stijl van de ankercel als basis, en maak deze cel alsnog aan
          // zodat hij zijn EIGEN rand krijgt: anders toont Excel voor deze
          // positie geen rand, ook al hoort de cel bij de samenvoeging, en
          // loopt de lijn niet door over de hele breedte.
          const anker = await writer.haalMergeAnker(sheetCel);
          basisStijl = await writer.haalStijlIndexOp(anker);
        }
        // Bovenrand wissen (behalve de allereerste rij van de tabel, die
        // vormt de bovenrand van het hele blok): anders bepaalt Excel zelf
        // welke van twee concurrerende rand-specificaties (onze onderrand
        // op de rij erboven vs. de oude "hair"-bovenrand hier) wint.
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

  // Basis: stippellijn onder elke rij in het volledige tabelbereik (ook de
  // nog ongebruikte hopslots).
  for (let rij = hopEersteRij; rij <= dryHopLaatsteRij; rij++) {
    await zetRandOpRij(rij, 1, 16, 'dotted');
  }

  // Overschrijf met een dikke lijn op de laatste rij van elk daadwerkelijk
  // toevoegmoment.
  async function dikkeRandenVoorBlok(rijen, startRij) {
    for (let i = 0; i < rijen.length; i++) {
      const huidige = rijen[i];
      const volgende = rijen[i + 1];
      const laatsteVanGroep = !volgende || volgende.tijdstip !== huidige.tijdstip;
      if (!laatsteVanGroep) continue;
      await zetRandOpRij(startRij + i, 1, 16, 'medium');
    }
  }

  // Hop boil: dikke lijn op de laatste rij van elk toevoegmoment (dus vlak
  // boven elke witte scheidingsrij uit bouwHopKookLayout), plus op de
  // allerlaatste rij van de hele Hop boil-tabel (overgang naar Dry hop).
  // Loopt over de fysieke layout (incl. de null-scheidingsrijen) zodat de
  // rijnummers kloppen ook als er al eerder scheidingsrijen zijn geweest.
  const hopLayout = bouwHopKookLayout(bundel);
  for (let i = 0; i < hopLayout.length; i++) {
    if (hopLayout[i] === null) continue;
    const laatsteVanGroep = i === hopLayout.length - 1 || hopLayout[i + 1] === null;
    if (!laatsteVanGroep) continue;
    await zetRandOpRij(hopEersteRij + i, 1, 16, 'medium');
  }

  // Dry hop: ongewijzigd, dikke lijn per toevoegmoment.
  const dryHopRijen = sorteerHopgiften(bundel.recipe_ingredients.filter(r => r.rol === 'dry_hop'), 'dry_hop');
  await dikkeRandenVoorBlok(dryHopRijen, dryHopEersteRij);
}

// ---------------------------------------------------------------------------
// Hoofdlogica
// ---------------------------------------------------------------------------
async function genereerBatchrapportBuffer(bundel) {
  const naam = bundel.recipes.naam || '';
  const locatie = (bundel.recipes.locatie || '').toLowerCase();
  const isWP = locatie.includes('waarderpolder');
  const vestigingsPrefix = isWP ? 'WP' : 'JK';

  const templateBuffer = fs.readFileSync(TEMPLATE_PATH);
  const zip = await JSZip.loadAsync(templateBuffer);

  const writer = new XlsxDirectWriter(zip);
  await writer.init();
  const stylesManager = new StylesManager(zip);
  await stylesManager.init();

  const overloop = await voegOverloopRijenToe(writer, bundel);

  await vulScalaireVelden(writer, bundel, isWP, overloop.verschuifCel);
  await vulWpKerkVelden(writer, bundel, isWP);
  await vulReceptnaamKruisVelden(writer, bundel, isWP);
  await vulIngredientRijen(writer, bundel, overloop);
  await vulRevisies(writer, bundel, overloop.verschuifCel);
  await vulFormaten(writer, bundel);
  await vulHopRendementEnEbu(writer, bundel, overloop);
  await zetHopGroepRanden(writer, stylesManager, bundel, overloop);

  await writer.setCelWaarde('Recept-voorblad!H3', 'Batch nr.:');
  await writer.setCelWaarde('Recept-voorblad!K3', bundel.batch.batchnummer);
  // Fallback naar 1 (niet null/blank): elke "Totaal gram"-cel op dit tabblad
  // is E-kolom * G7, dus een lege G7 zet stilzwijgend ALLE hoptotalen op 0
  // i.p.v. gewoon de waarde van 1 brouwsel te tonen. Zie ook batchrapport-vullen.js.
  await writer.setCelWaarde('Recept-voorblad!G7', bundel.batch.aantal_brouwsels ?? 1);
  await writer.setCelWaarde('Recept-voorblad!Q1', `${vestigingsPrefix} ${naam}`);

  stylesManager.finalize();
  await writer.finalize();
  const buffer = await zip.generateAsync({ type: 'nodebuffer' });

  const laatsteRevisie = bundel.recipe_revisies[0];
  const versienummer = laatsteRevisie
    ? `${laatsteRevisie.versie_major}.${laatsteRevisie.versie_minor}`
    : `${bundel.recipes.versie_major ?? 1}.${bundel.recipes.versie_minor ?? 0}`;
  const bestandsnaam = `${bundel.batch.batchnummer} ${naam} v${versienummer} ${vestigingsPrefix}.xlsx`;

  return { buffer, bestandsnaam };
}

async function main() {
  const batchnummer = Number(process.argv[2]);
  if (!batchnummer) {
    console.error('Gebruik: node generate-batchrapport.js <batchnummer>');
    process.exit(1);
  }
  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!SUPABASE_URL || !SUPABASE_KEY) {
    console.error('SUPABASE_URL en SUPABASE_SERVICE_ROLE_KEY moeten als env-var gezet zijn.');
    process.exit(1);
  }
  const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

  console.log(`Batch ${batchnummer} ophalen...`);
  const bundel = await haalBatchDataOp(supabase, batchnummer);

  console.log('Batchrapport genereren...');
  const { buffer, bestandsnaam } = await genereerBatchrapportBuffer(bundel);

  if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const outputPath = path.join(OUTPUT_DIR, bestandsnaam);
  fs.writeFileSync(outputPath, buffer);
  console.log(`Klaar: ${outputPath}`);
}

if (require.main === module) {
  main().catch(err => {
    console.error('Fout tijdens genereren:', err.message);
    process.exit(1);
  });
}

module.exports = {
  bepaalHopRendement, bepaalHopEbu, vulScalaireVelden, vulWpKerkVelden, vulReceptnaamKruisVelden,
  vulIngredientRijen, vulRevisies, vulFormaten, vulHopRendementEnEbu, zetHopGroepRanden,
  voegOverloopRijenToe, genereerBatchrapportBuffer, haalBatchDataOp,
};
