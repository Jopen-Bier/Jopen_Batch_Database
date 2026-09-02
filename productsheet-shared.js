// ============================================================================
// productsheet-shared.js — gedeelde logica voor Product Sheets
//
// Product sheets worden GROTENDEELS live afgeleid uit het recept (specs,
// berekende kleur, allergenen, ingrediëntenlijst) i.p.v. apart opgeslagen.
// Deze functies zijn puur (geen Supabase-aanroepen) op één datalader na, en
// worden zowel door productsheet.html (weergave) als productsheet-vullen.js
// (xlsx-generatie) gebruikt -- één plek voor de logica, geen duplicatie.
//
// Vereist op de pagina: supabaseClient (uit config.js) al geladen.
// ============================================================================

// -- Turbidity: vaste ranges o.b.v. Trubidity (Lab), i.p.v. vrije tekst --
function psTurbidityLabel(troebelingLab) {
  const v = Number(troebelingLab);
  if (troebelingLab === null || troebelingLab === undefined || Number.isNaN(v)) return '';
  if (v <= 15) return 'Clear';
  if (v <= 50) return 'Light haze';
  if (v <= 100) return 'Medium haze';
  return 'Hazy';
}

// -- Calculated color: zelfde formule als Recipe-invoer/batchrapport --
// (kg × EBC × 0.08) per hoofdmout-regel, opgeteld, gedeeld door brouwsel_hl, +1.75
function psCalculatedColor(hoofdmoutRegels, brouwselHl) {
  if (!brouwselHl) return null;
  const som = (hoofdmoutRegels || []).reduce((acc, r) => {
    const kg = Number(r.hoeveelheid) || 0;
    const ebc = Number(r.kleur_ebc) || 0;
    return acc + kg * ebc * 0.08;
  }, 0);
  return Math.round((som / brouwselHl + 1.75) * 100) / 100;
}

// Rol -> label-categorie. Malt + Unmalted grains staan bewust samen onder 'malt'.
const PS_ROL_NAAR_CATEGORIE = {
  hoofdmout: 'malt',
  hopgift_kook: 'hop',
  dry_hop: 'hop',
  gist: 'gist',
  toegift_brouwerij: 'additief',
  toegift_kelder: 'additief',
};

// Eenheid -> gram, voor Order by size. Rate-eenheden (g/hl, ml/hl) worden
// vermenigvuldigd met brouwsel_hl. ml wordt voor nu 1:1 als gram behandeld
// (dichtheid ~1) tenzij het ingredient een dichtheid heeft.
function psNaarGrammen(hoeveelheid, eenheid, brouwselHl, dichtheid) {
  const h = Number(hoeveelheid);
  if (!h && h !== 0) return null;
  const dicht = Number(dichtheid) || 1;
  switch ((eenheid || '').trim()) {
    case 'kg': return h * 1000;
    case 'g': return h;
    case 'g/hl': return h * brouwselHl;
    case 'ml/hl': return h * brouwselHl * dicht;
    case 'ml': return h * dicht;
    case 'l': return h * 1000 * dicht;
    default: return h; // onbekende eenheid: geen conversie, beste gok
  }
}

/**
 * Berekent het volledige Ingredients-blok (Malt/Hop/Additief/Water/Gist) voor
 * de product sheet, volgens de in overleg vastgestelde regels:
 * - "Ingredient" (interne kolom) toont alles zoals in het recept, ongefilterd.
 * - "Name on the label" dedupliceert op ingredient_declaratie; ingrediënten
 *   met declaratie '-no declaration-' (of geen declaratie ingevuld) verschijnen
 *   daar niet.
 * - Hop declareert altijd generiek als "Hops" (alle hopgewicht samengeteld).
 * - Water is een vaste tekst (zit niet in recipe_ingredients) en krijgt altijd
 *   Order by size = 1.
 * - Order by size is een globale rangorde over alle gedeclareerde stoffen heen,
 *   op totaalgewicht (aflopend), Water uitgezonderd (altijd 1).
 *
 * `regels` = array van { rol, hoeveelheid, eenheid, naam (ingredient), declaratie,
 *   dichtheid } -- al plat getrokken vanuit recipe_ingredients + ingredients.
 */
function psBerekenIngredientenBlok(regels, brouwselHl) {
  const perCategorie = { malt: [], hop: [], gist: [], additief: [] };
  (regels || []).forEach(r => {
    const cat = PS_ROL_NAAR_CATEGORIE[r.rol];
    if (cat) perCategorie[cat].push(r);
  });

  // "Ingredient"-kolom: unieke interne namen zoals in het recept, in volgorde van eerste voorkomen.
  function ingredientKolom(lijst) {
    const gezien = [];
    lijst.forEach(r => { if (r.naam && !gezien.includes(r.naam)) gezien.push(r.naam); });
    return gezien.join(', ');
  }

  // Declaraties dedupliceren + gewichten optellen (categorie 'hop' wordt altijd
  // samengevoegd tot de ene declaratie 'Hops').
  const totalenPerDeclaratie = {}; // declaratie -> { gram, categorie }
  Object.entries(perCategorie).forEach(([cat, lijst]) => {
    lijst.forEach(r => {
      let decl = (r.declaratie || '').trim();
      if (cat === 'hop') decl = 'Hops';
      if (!decl || decl === '-no declaration-') return; // niets te declareren
      const gram = psNaarGrammen(r.hoeveelheid, r.eenheid, brouwselHl, r.dichtheid);
      if (gram === null) return;
      if (!totalenPerDeclaratie[decl]) totalenPerDeclaratie[decl] = { gram: 0, categorie: cat };
      totalenPerDeclaratie[decl].gram += gram;
    });
  });

  // Globale rangorde (Water vast op 1, rest aflopend op gewicht, bij gelijk gewicht alfabetisch).
  const gerangschikt = Object.entries(totalenPerDeclaratie)
    .sort((a, b) => (b[1].gram - a[1].gram) || a[0].localeCompare(b[0]));
  const rank = {};
  let r = 2;
  gerangschikt.forEach(([decl]) => { rank[decl] = r++; });

  function labelKolomEnRanks(cat) {
    const items = gerangschikt.filter(([, v]) => v.categorie === cat);
    return {
      label: items.map(([decl]) => decl).join(', '),
      ranks: items.map(([decl]) => rank[decl]).join(', '),
    };
  }

  const malt = labelKolomEnRanks('malt');
  const hop = labelKolomEnRanks('hop');
  const additief = labelKolomEnRanks('additief');
  const gist = labelKolomEnRanks('gist');

  return {
    malt: { ingredient: ingredientKolom(perCategorie.malt), label: malt.label, ranks: malt.ranks },
    hop: { ingredient: ingredientKolom(perCategorie.hop), label: hop.label, ranks: hop.ranks },
    additief: { ingredient: ingredientKolom(perCategorie.additief), label: additief.label, ranks: additief.ranks },
    water: { ingredient: 'Brewing Water', label: 'Water', ranks: '1' },
    gist: { ingredient: ingredientKolom(perCategorie.gist), label: gist.label, ranks: gist.ranks },
  };
}

/**
 * Allergenen-tekst: "Allergeen (Declaratie A, Declaratie B), Allergeen2 (...)"
 * o.b.v. ingredients.allergenen (jsonb-array per ingrediënt) + de declaratie
 * die bij dat ingrediënt hoort. Ingrediënten zonder declaratie of met
 * '-no declaration-' worden hier bewust WEL meegeteld voor het allergeen zelf
 * (een allergeen kan wettelijk relevant zijn ook als de stof zelf niet als
 * ingrediënt gedeclareerd hoeft te worden) -- maar zonder herkenbare naam
 * gebruiken we dan de interne ingrediëntnaam als noodgreep.
 */
function psBerekenAllergenen(regels) {
  const perAllergeen = {}; // allergeen -> Set(declaraties/namen)
  (regels || []).forEach(r => {
    let allergenen = r.allergenen;
    if (!allergenen) return;
    if (typeof allergenen === 'string') {
      try { allergenen = JSON.parse(allergenen); } catch (e) { allergenen = []; }
    }
    if (!Array.isArray(allergenen) || allergenen.length === 0) return;
    const naamOpLabel = (r.declaratie && r.declaratie !== '-no declaration-') ? r.declaratie : r.naam;
    allergenen.forEach(a => {
      const key = String(a).trim();
      if (!key) return;
      if (!perAllergeen[key]) perAllergeen[key] = new Set();
      if (naamOpLabel) perAllergeen[key].add(naamOpLabel);
    });
  });
  const namen = Object.keys(perAllergeen).sort();
  if (namen.length === 0) return '';
  return namen.map(a => {
    const bronnen = [...perAllergeen[a]].sort().join(', ');
    const label = a.charAt(0).toUpperCase() + a.slice(1);
    return bronnen ? `${label} (${bronnen})` : label;
  }).join(', ');
}

/**
 * Haalt alle live receptdata op die nodig is voor een product sheet: het
 * nieuwste recept binnen de recipe_group (ongeacht status, zelfde
 * resolutieregel als brew_planning), specs, en de platgetrokken
 * ingrediëntregels (incl. declaratie/allergenen/dichtheid vanuit ingredients).
 */
async function psLaadReceptData(recipeGroupId) {
  const { data: recepten, error: recErr } = await supabaseClient
    .from('recipes')
    .select('id, naam, bierstijl, versie_major, versie_minor, brouwsel_hl, smaakomschrijving, smaak_keywords, kleur_vrije_tekst, aanbevolen_schenktemperatuur')
    .eq('recipe_group_id', recipeGroupId)
    .order('versie_major', { ascending: false })
    .order('versie_minor', { ascending: false })
    .limit(1);
  if (recErr) throw recErr;
  if (!recepten || recepten.length === 0) throw new Error('Geen recept gevonden voor deze receptgroep.');
  const recipe = recepten[0];

  const [{ data: specs, error: specsErr }, { data: ingredientRegels, error: ingErr }] = await Promise.all([
    supabaseClient.from('recipe_specificaties').select('*').eq('recipe_id', recipe.id).maybeSingle(),
    supabaseClient.from('recipe_ingredients')
      .select('rol, hoeveelheid, eenheid, ingredients(naam, ingredient_declaratie, allergenen, dichtheid)')
      .eq('recipe_id', recipe.id),
  ]);
  if (specsErr) throw specsErr;
  if (ingErr) throw ingErr;

  const regels = (ingredientRegels || []).map(r => ({
    rol: r.rol,
    hoeveelheid: r.hoeveelheid,
    eenheid: r.eenheid,
    naam: r.ingredients ? r.ingredients.naam : null,
    declaratie: r.ingredients ? r.ingredients.ingredient_declaratie : null,
    allergenen: r.ingredients ? r.ingredients.allergenen : null,
    dichtheid: r.ingredients ? r.ingredients.dichtheid : null,
  }));

  // Ook hoofdmout-regels apart voor de Calculated color-berekening.
  const { data: moutRegels, error: moutErr } = await supabaseClient
    .from('recipe_ingredients')
    .select('hoeveelheid, kleur_ebc')
    .eq('recipe_id', recipe.id)
    .eq('rol', 'hoofdmout');
  if (moutErr) throw moutErr;

  const s = specs || {};
  const calcColor = psCalculatedColor(moutRegels || [], recipe.brouwsel_hl);
  const ingredientenBlok = psBerekenIngredientenBlok(regels, recipe.brouwsel_hl);
  const allergenenTekst = psBerekenAllergenen(regels);
  const turbidity = psTurbidityLabel(s.troebeling_lab);

  return { recipe, specs: s, calcColor, ingredientenBlok, allergenenTekst, turbidity };
}

/**
 * Bouwt de snapshot die vergeleken wordt met de live hash uit
 * product_sheet_relevant_hash() in de database -- via RPC opgehaald zodat de
 * hash-logica maar op één plek (SQL) hoeft te staan.
 */
async function psHuidigeHash(recipeGroupId) {
  const { data, error } = await supabaseClient.rpc('product_sheet_relevant_hash', { p_recipe_group_id: recipeGroupId });
  if (error) throw error;
  return data;
}

/** Sync-status voor één receptgroep via de product_sheet_status-view. */
async function psLaadSyncStatus(recipeGroupId) {
  const { data, error } = await supabaseClient
    .from('product_sheet_status')
    .select('*')
    .eq('recipe_group_id', recipeGroupId)
    .maybeSingle();
  if (error) throw error;
  return data; // null = nog geen product sheet
}
