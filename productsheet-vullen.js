// ============================================================================
// productsheet-vullen.js — client-side Product Sheet-generatie (browser)
//
// Vereist op de pagina (in deze volgorde, ná config.js):
//   <script src="https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js"></script>
//   <script src="productsheet-xlsx-writer.js"></script>
//   <script src="productsheet-shared.js"></script>
//   <script src="productsheet-vullen.js"></script>
// ============================================================================

const PS_BASISPAD = 'productsheet-generator/';

// Menselijk leesbare labels voor de changelog-diff.
const PS_SNAPSHOT_LABELS = {
  origineel_extract: 'Original extract', origineel_extract_tol: 'Original extract tolerance',
  rest_extract: 'Final extract', rest_extract_tol: 'Final extract tolerance',
  alcohol: 'Alcohol', alcohol_tol: 'Alcohol tolerance',
  bitterheid: 'Bitterness', bitterheid_tol: 'Bitterness tolerance',
  kleur_ebc: 'Color (EBC)', kleur_tol: 'Color tolerance',
  ph: 'pH', ph_tol: 'pH tolerance',
  troebeling_lab: 'Turbidity (lab)', troebeling_lab_tol: 'Turbidity tolerance',
  co2_fles: 'CO2 bottle', co2_fles_tol: 'CO2 bottle tolerance',
  co2_can: 'CO2 can', co2_can_tol: 'CO2 can tolerance',
  co2_fust: 'CO2 keg', co2_fust_tol: 'CO2 keg tolerance',
  headspace_o2: 'Headspace O2', headspace_o2_tol: 'Headspace O2 tolerance',
  dissolved_o2: 'Dissolved O2', dissolved_o2_tol: 'Dissolved O2 tolerance',
  turbidity_label: 'Turbidity', smaakomschrijving: 'Flavor description',
  smaak_keywords: 'Flavor keywords', kleur_vrije_tekst: 'Colour description',
  aanbevolen_schenktemperatuur: 'Recommended drinking temperature',
  allergenen_tekst: 'Allergies',
  ingredienten_malt_label: 'Malt (name on label)', ingredienten_hop_label: 'Hop (name on label)',
  ingredienten_additief_label: 'Additives (name on label)', ingredienten_gist_label: 'Yeast (name on label)',
};

/** Bouwt de vlakke snapshot die zowel vergeleken als bewaard wordt. */
function psBouwSnapshot(live, hash) {
  const s = live.specs;
  return {
    hash,
    origineel_extract: s.origineel_extract, origineel_extract_tol: s.origineel_extract_tol,
    rest_extract: s.rest_extract, rest_extract_tol: s.rest_extract_tol,
    alcohol: s.alcohol, alcohol_tol: s.alcohol_tol,
    bitterheid: s.bitterheid, bitterheid_tol: s.bitterheid_tol,
    kleur_ebc: live.calcColor, kleur_tol: s.kleur_tol,
    ph: s.ph, ph_tol: s.ph_tol,
    troebeling_lab: s.troebeling_lab, troebeling_lab_tol: s.troebeling_lab_tol,
    co2_fles: s.co2_fles, co2_fles_tol: s.co2_fles_tol,
    co2_can: s.co2_can, co2_can_tol: s.co2_can_tol,
    co2_fust: s.co2_fust, co2_fust_tol: s.co2_fust_tol,
    headspace_o2: s.headspace_o2, headspace_o2_tol: s.headspace_o2_tol,
    dissolved_o2: s.dissolved_o2, dissolved_o2_tol: s.dissolved_o2_tol,
    turbidity_label: live.turbidity,
    smaakomschrijving: live.recipe.smaakomschrijving,
    smaak_keywords: (live.recipe.smaak_keywords || []).join(', '),
    kleur_vrije_tekst: live.recipe.kleur_vrije_tekst,
    aanbevolen_schenktemperatuur: live.recipe.aanbevolen_schenktemperatuur,
    allergenen_tekst: live.allergenenTekst,
    ingredienten_malt_label: live.ingredientenBlok.malt.label,
    ingredienten_hop_label: live.ingredientenBlok.hop.label,
    ingredienten_additief_label: live.ingredientenBlok.additief.label,
    ingredienten_gist_label: live.ingredientenBlok.gist.label,
  };
}

/** Genereert leesbare changelog-tekst uit het verschil tussen twee snapshots. */
function psDiffSnapshots(oud, nieuw) {
  if (!oud) return 'Eerste generatie vanuit levende receptdata.';
  const regels = [];
  Object.keys(nieuw).forEach(key => {
    if (key === 'hash') return;
    const oudeWaarde = oud[key] ?? null;
    const nieuweWaarde = nieuw[key] ?? null;
    if (String(oudeWaarde) !== String(nieuweWaarde)) {
      const label = PS_SNAPSHOT_LABELS[key] || key;
      regels.push(`${label}: ${oudeWaarde ?? '—'} → ${nieuweWaarde ?? '—'}`);
    }
  });
  return regels.length > 0 ? regels.join('; ') : 'Geen inhoudelijke wijziging t.o.v. vorige versie (opnieuw gegenereerd).';
}

/** Vult alle cellen van het sjabloon o.b.v. live data + de handmatige product_sheets-velden. */
async function psSchrijfXlsx(writer, live, productSheetRow, snapshot) {
  const SHEET = 'Product description';
  const set = (cel, waarde) => writer.setCelWaarde(`${SHEET}!${cel}`, waarde);

  // General
  await set('E4', live.recipe.naam);
  await set('E5', live.recipe.bierstijl);

  // Ingredients
  const blok = live.ingredientenBlok;
  await set('E10', blok.malt.ingredient); await set('I10', blok.malt.label); await set('N10', blok.malt.ranks);
  await set('E12', blok.hop.ingredient); await set('I12', blok.hop.label); await set('N12', blok.hop.ranks);
  await set('E13', blok.additief.ingredient); await set('I13', blok.additief.label); await set('N13', blok.additief.ranks);
  await set('E14', blok.water.ingredient); await set('I14', blok.water.label); await set('N14', blok.water.ranks);
  await set('E15', blok.gist.ingredient); await set('I15', blok.gist.label); await set('N15', blok.gist.ranks);

  // Eindproduct specificatie (live uit recipe_specificaties)
  const s = live.specs;
  await set('E19', '°P'); await set('F19', s.origineel_extract_tol); await set('G19', s.origineel_extract);
  await set('E20', '°P'); await set('F20', s.rest_extract_tol); await set('G20', s.rest_extract);
  await set('E21', 'v/v%'); await set('F21', s.alcohol_tol); await set('G21', s.alcohol);
  await set('E22', 'EBU'); await set('F22', s.bitterheid_tol); await set('G22', s.bitterheid);
  await set('E23', 'EBC'); await set('F23', s.kleur_tol); await set('G23', live.calcColor);
  await set('F24', s.ph_tol); await set('G24', s.ph);
  await set('E25', 'EBC'); await set('F25', s.troebeling_lab_tol); await set('G25', s.troebeling_lab);

  await set('L19', 'EBC'); await set('M19', s.troebeling_lab_tol); await set('N19', s.troebeling_lab);
  await set('L20', 'g/l'); await set('M20', s.co2_fles_tol); await set('N20', s.co2_fles);
  await set('L21', 'g/l'); await set('M21', s.co2_can_tol); await set('N21', s.co2_can);
  await set('L22', 'ppb'); await set('M22', s.co2_fust_tol); await set('N22', s.co2_fust);
  await set('L23', 'ppb'); await set('M23', s.headspace_o2_tol); await set('N23', s.headspace_o2);
  await set('L24', 'ppb'); await set('M24', s.dissolved_o2_tol); await set('N24', s.dissolved_o2);

  // Flavor Description (nu live vanuit het recept)
  await set('E27', live.recipe.smaakomschrijving || '');

  // Label and product information
  await set('E34', { formula: 'G21' });
  await set('E35', { formula: 'G19' });
  await set('E36', { formula: 'ROUND(G23,0)' });
  await set('E39', { formula: 'G22' });
  await set('E37', live.recipe.kleur_vrije_tekst || '');
  await set('E38', live.turbidity);
  await set('E41', live.allergenenTekst);
  await set('E42', live.recipe.aanbevolen_schenktemperatuur ?? '');
  await set('E44', (live.recipe.smaak_keywords || []).join(', '));

  // Handmatige velden (product_sheets)
  const p = productSheetRow || {};
  await set('E48', p.vat_gerijpt_hl ?? '-');
  await set('E49', p.vat_type ?? '-');
  await set('E50', p.vat_dagen ?? '-');
  await set('E59', p.energie_kj ?? '');
  await set('E60', p.energie_kcal ?? '');
  await set('E61', p.vet_g ?? '');
  await set('E62', p.koolhydraten_g ?? '');
  await set('E63', p.eiwit_g ?? '');
  await set('E64', p.zout_g ?? '');

  // Versieblok
  await set('E66', String(p.huidige_versie ?? 1));
  await set('E67', { text: `${live.recipe.versie_major ?? 1}.${live.recipe.versie_minor ?? 0}` });
  await set('E69', p._writtenByNaam || '');
  await set('E70', psFormatteerDatumDDMMJJJJ(p._datum));
  await set('E72', p._changelog || '');
}

/** "2026-09-02" -> "02-09-2026". Geeft de invoer ongewijzigd terug als het geen (herkenbare) datum is. */
function psFormatteerDatumDDMMJJJJ(isoDatum) {
  if (!isoDatum) return '';
  const m = String(isoDatum).match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return isoDatum;
  const [, jaar, maand, dag] = m;
  return `${dag}-${maand}-${jaar}`;
}

/**
 * Update-knop: laadt live data, vergelijkt met de opgeslagen snapshot, en --
 * alleen als er daadwerkelijk iets label-relevants gewijzigd is -- bumpt de
 * versie, schrijft een revisie-rij en werkt product_sheets bij. Raakt de
 * download NIET aan; dat is de losse Download-knop (psDownload).
 */
async function psUpdate(recipeGroupId, gebruiker) {
  const live = await psLaadReceptData(recipeGroupId);
  const hash = await psHuidigeHash(recipeGroupId);
  const nieuweSnapshot = psBouwSnapshot(live, hash);

  let { data: bestaande, error: bestErr } = await supabaseClient
    .from('product_sheets').select('*').eq('recipe_group_id', recipeGroupId).maybeSingle();
  if (bestErr) throw bestErr;

  let productSheetRow = bestaande;
  const wasNietInSync = !bestaande || !bestaande.sync_snapshot || bestaande.sync_snapshot.hash !== hash;

  if (!bestaande) {
    // Zou hier eigenlijk al moeten bestaan (aangemaakt via "Create Product
    // Sheet"), maar defensief: alsnog aanmaken i.p.v. te falen.
    const { data: nieuw, error: insErr } = await supabaseClient
      .from('product_sheets')
      .insert({ recipe_group_id: recipeGroupId, huidige_versie: 1, aangemaakt_door: gebruiker?.id })
      .select().single();
    if (insErr) throw insErr;
    productSheetRow = nieuw;
  }

  if (!wasNietInSync) {
    // Al in sync: niets te doen, geen nieuwe revisie/versie nodig.
    return productSheetRow;
  }

  const oudeSnapshot = productSheetRow.sync_snapshot;
  const nieuweVersie = (productSheetRow.huidige_versie || 1) + (oudeSnapshot ? 1 : 0);
  const changelog = psDiffSnapshots(oudeSnapshot, nieuweSnapshot);

  const { data: bijgewerkt, error: updErr } = await supabaseClient
    .from('product_sheets')
    .update({
      huidige_versie: nieuweVersie,
      sync_snapshot: nieuweSnapshot,
      bijgewerkt_obv_versie_major: live.recipe.versie_major,
      bijgewerkt_obv_versie_minor: live.recipe.versie_minor,
      bijgewerkt_op: new Date().toISOString(),
      bijgewerkt_door: gebruiker?.id,
    })
    .eq('id', productSheetRow.id)
    .select().single();
  if (updErr) throw updErr;
  productSheetRow = bijgewerkt;

  const { error: revErr } = await supabaseClient.from('product_sheet_revisies').insert({
    product_sheet_id: productSheetRow.id,
    versie: nieuweVersie,
    recipe_versie_major: live.recipe.versie_major,
    recipe_versie_minor: live.recipe.versie_minor,
    door: gebruiker?.naam || '',
    wijzigingen: changelog,
  });
  if (revErr) throw revErr;

  return productSheetRow;
}

/**
 * Download-knop: haalt de actuele receptdata en de huidige product_sheets-rij
 * op en genereert/downloadt de xlsx -- raakt de database NIET aan. Werkt dus
 * ook gewoon als het al in sync is (gewoon een herdownload van de huidige versie).
 */
async function psDownload(recipeGroupId, gebruiker) {
  const live = await psLaadReceptData(recipeGroupId);
  const { data: productSheetRow, error } = await supabaseClient
    .from('product_sheets').select('*').eq('recipe_group_id', recipeGroupId).single();
  if (error) throw error;

  const { data: laatsteRevisie } = await supabaseClient
    .from('product_sheet_revisies').select('*')
    .eq('product_sheet_id', productSheetRow.id)
    .order('versie', { ascending: false }).limit(1).maybeSingle();

  productSheetRow._writtenByNaam = laatsteRevisie ? laatsteRevisie.door : (gebruiker?.naam || '');
  productSheetRow._datum = laatsteRevisie ? laatsteRevisie.datum : ((productSheetRow.bijgewerkt_op || '').slice(0, 10) || new Date().toISOString().slice(0, 10));
  productSheetRow._changelog = laatsteRevisie ? laatsteRevisie.wijzigingen : '';

  await psGenereerEnDownload(live, productSheetRow);
  return productSheetRow;
}

/** Vult het sjabloon met de gegeven data en start de download, zonder de database aan te raken. */
async function psGenereerEnDownload(live, productSheetRow) {
  const res = await fetch(PS_BASISPAD + 'Product_Sheet_sjabloon.xlsx', { cache: 'no-store' });
  if (!res.ok) throw new Error(`Kon sjabloon niet ophalen (${res.status})`);
  const templateBuffer = await res.arrayBuffer();

  const zip = await JSZip.loadAsync(templateBuffer);
  const writer = new ProductSheetXlsxWriter(zip);
  await writer.init();

  await psSchrijfXlsx(writer, live, productSheetRow);

  await writer.finalize();
  const blob = await zip.generateAsync({ type: 'blob' });

  const versie = productSheetRow.huidige_versie ?? 1;
  const bestandsnaam = `${live.recipe.naam} Product Sheet v${versie}.xlsx`;
  await psSlaOp(blob, bestandsnaam);
}

/** Zelfde opslaan-patroon als batchrapport-vullen.js (showSaveFilePicker met fallback). */
async function psSlaOp(blob, bestandsnaam) {
  if ('showSaveFilePicker' in window) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName: bestandsnaam,
        types: [{ description: 'Excel Workbook', accept: { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['.xlsx'] } }],
      });
      const stream = await handle.createWritable();
      await stream.write(blob);
      await stream.close();
      return;
    } catch (err) {
      if (err && err.name === 'AbortError') return;
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
