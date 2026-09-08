// voorraad-forecast.js
// Gedeelde verbruiks-berekening op basis van brew_planning, gebruikt door zowel
// verbruiksprognose.html (Consumption Forecast) als voorraad-overzicht.html (Stock
// overview). Voorheen stond deze logica alleen in verbruiksprognose.html; nu gedeeld
// zodat beide pagina's altijd exact hetzelfde getal voor dezelfde week laten zien.
//
// Kernfunctie: vfBerekenVerbruik(supabaseClient, periodes) waarbij periodes een array
// is van {jaar, vanWeek, totWeek} (meestal 1 entry, 2 bij een jaargrens-overschrijding
// voor de vooruitkijk-projectie in Stock overview). Retourneert per rol EN per
// ingrediënt (samengevoegd over rollen) het verbruik, inclusief een per-week-breakdown
// zodat een voorraadprojectie ("loopt leeg in week X") mogelijk is.

function vfNaarWeergaveRol(rol) {
  if (rol === 'hopgift_kook' || rol === 'dry_hop') return 'hops';
  return rol || 'overig';
}

const VF_EENHEID_SYNONIEMEN = {
  kilogram: 'kg', kilo: 'kg', gr: 'g', gram: 'g', grams: 'g',
  liter: 'l', litre: 'l', milliliter: 'ml', millilitre: 'ml',
};
function vfCanoniekeEenheid(waarde) {
  const e = (waarde || '').trim().toLowerCase();
  return VF_EENHEID_SYNONIEMEN[e] || e;
}

// Supabase/PostgREST beperkt elk antwoord standaard tot 1000 rijen -- zelfde
// paginerings-patroon als elders in de app (ingredienten.html, receptoverzicht.html).
async function vfHaalAlleRijenOp(query) {
  const PAGINA = 1000;
  let vanaf = 0;
  let alles = [];
  while (true) {
    const { data, error } = await query.range(vanaf, vanaf + PAGINA - 1);
    if (error) return { data: null, error };
    alles = alles.concat(data || []);
    if (!data || data.length < PAGINA) break;
    vanaf += PAGINA;
  }
  return { data: alles, error: null };
}

function vfWeekSleutel(jaar, week) { return `${jaar}-W${String(week).padStart(2, '0')}`; }

async function vfBerekenVerbruik(supabaseClient, periodes) {
  if (!periodes || periodes.length === 0) {
    return { perRol: {}, perIngredient: {}, aantalBrouwsels: 0, aantalRecepten: 0 };
  }

  // 1. Geplande brouwsels in alle opgegeven periodes (incl. week_number, nodig voor
  // de per-week-breakdown; incl. id, nodig om de bijbehorende splits op te zoeken).
  let planning = [];
  for (const { jaar, vanWeek, totWeek } of periodes) {
    const { data, error } = await supabaseClient
      .from('brew_planning')
      .select('id, recipe_id, aantal_brouwsels, iso_year, week_number')
      .eq('iso_year', jaar)
      .gte('week_number', vanWeek)
      .lte('week_number', totWeek);
    if (error) return { error };
    planning = planning.concat(data || []);
  }
  if (planning.length === 0) {
    return { perRol: {}, perIngredient: {}, aantalBrouwsels: 0, aantalRecepten: 0 };
  }

  const brouwselsPerRecept = {};
  const weekPerPlanningId = {};
  planning.forEach(p => {
    brouwselsPerRecept[p.recipe_id] = (brouwselsPerRecept[p.recipe_id] || 0) + Number(p.aantal_brouwsels);
    weekPerPlanningId[p.id] = vfWeekSleutel(p.iso_year, p.week_number);
  });

  // 1b. Splits: het DOELrecept van een split heeft vaak eigen extra ingrediënten die
  // nergens anders in de prognose voorkomen omdat dat recept nooit direct gebrouwen
  // wordt. Apart meegeteld, geschaald op het daadwerkelijke split-volume, toegeschreven
  // aan de week van het brouwsel waar de split bij hoort.
  const { data: splits, error: splitErr } = await vfHaalAlleRijenOp(
    supabaseClient.from('brew_planning_splits').select('brew_planning_id, recipe_id, hl').in('brew_planning_id', planning.map(p => p.id))
  );
  if (splitErr) return { error: splitErr };
  const splitHlPerRecept = {};
  const splitWeekPerRecept = {}; // recipe_id -> [{week, hl}]
  (splits || []).forEach(s => {
    splitHlPerRecept[s.recipe_id] = (splitHlPerRecept[s.recipe_id] || 0) + Number(s.hl || 0);
    const week = weekPerPlanningId[s.brew_planning_id];
    (splitWeekPerRecept[s.recipe_id] = splitWeekPerRecept[s.recipe_id] || []).push({ week, hl: Number(s.hl || 0) });
  });

  const receptIds = [...new Set([
    ...Object.keys(brouwselsPerRecept).map(Number),
    ...Object.keys(splitHlPerRecept).map(Number),
  ])];

  // 2. Receptregels (ingrediënten) van al die recepten in één keer ophalen.
  const { data: ingredientRegels, error: ingErr } = await vfHaalAlleRijenOp(
    supabaseClient.from('recipe_ingredients').select('recipe_id, rol, ingredient_id, hoeveelheid, eenheid').in('recipe_id', receptIds)
  );
  if (ingErr) return { error: ingErr };

  // 3. Namen van recepten (+ brouwsel_hl) en ingrediënten erbij.
  const [{ data: recepten }, { data: ingredienten }] = await Promise.all([
    supabaseClient.from('recipes').select('id, naam, brouwsel_hl').in('id', receptIds),
    supabaseClient.from('ingredients').select('id, naam, eenheid').in(
      'id', [...new Set((ingredientRegels || []).map(r => r.ingredient_id).filter(x => x != null))]
    ),
  ]);
  const receptNaamMap = {};
  const receptBrouwselHlMap = {};
  (recepten || []).forEach(r => {
    receptNaamMap[r.id] = r.naam;
    receptBrouwselHlMap[r.id] = r.brouwsel_hl !== null && r.brouwsel_hl !== undefined ? Number(r.brouwsel_hl) : null;
  });
  const ingredientNaamMap = {};
  const ingredientEenheidMap = {};
  (ingredienten || []).forEach(i => {
    ingredientNaamMap[i.id] = i.naam;
    ingredientEenheidMap[i.id] = i.eenheid || '';
  });

  // Welke week(en) een brouwsel van een recept valt -- nodig voor de niet-split-bijdrage.
  const wekenPerRecept = {}; // recipe_id -> [{week, brouwsels}]
  planning.forEach(p => {
    (wekenPerRecept[p.recipe_id] = wekenPerRecept[p.recipe_id] || []).push({
      week: vfWeekSleutel(p.iso_year, p.week_number), brouwsels: Number(p.aantal_brouwsels),
    });
  });

  // 4. Optellen: per rol -> per ingredient+eenheid -> totaal + per-recept + per-week.
  const perRol = {};
  function voegBijdrageToe(rol, ingredientId, eenheid, bijdrage, receptLabel, week, missing) {
    if (!perRol[rol]) perRol[rol] = {};
    const key = `${ingredientId}|${vfCanoniekeEenheid(eenheid)}`;
    if (!perRol[rol][key]) {
      perRol[rol][key] = {
        ingredientId, naam: ingredientNaamMap[ingredientId] || `#${ingredientId}`, eenheid,
        totaal: 0, perRecept: {}, perWeek: {}, missingBrouwselHl: false,
      };
    }
    if (missing) { perRol[rol][key].missingBrouwselHl = true; return; }
    perRol[rol][key].totaal += bijdrage;
    perRol[rol][key].perRecept[receptLabel] = (perRol[rol][key].perRecept[receptLabel] || 0) + bijdrage;
    if (week) perRol[rol][key].perWeek[week] = (perRol[rol][key].perWeek[week] || 0) + bijdrage;
  }

  (ingredientRegels || []).forEach(regel => {
    if (regel.ingredient_id == null || regel.hoeveelheid == null) return;
    const brouwsels = brouwselsPerRecept[regel.recipe_id] || 0;
    const splitHl = splitHlPerRecept[regel.recipe_id] || 0;
    if (brouwsels === 0 && splitHl === 0) return;

    const rol = vfNaarWeergaveRol(regel.rol);
    const effectieveEenheid = (regel.eenheid && regel.eenheid.trim() !== '')
      ? regel.eenheid : (ingredientEenheidMap[regel.ingredient_id] || '');
    const isTarief = effectieveEenheid.endsWith('/hl') || effectieveEenheid.endsWith('/l');
    const weergaveEenheid = isTarief ? effectieveEenheid.split('/')[0] : effectieveEenheid;
    const receptNaam = receptNaamMap[regel.recipe_id] || `#${regel.recipe_id}`;

    if (brouwsels > 0) {
      (wekenPerRecept[regel.recipe_id] || []).forEach(({ week, brouwsels: brouwselsInWeek }) => {
        if (isTarief) {
          const brouwselHl = receptBrouwselHlMap[regel.recipe_id];
          if (brouwselHl === null || brouwselHl === undefined) {
            voegBijdrageToe(rol, regel.ingredient_id, weergaveEenheid, 0, receptNaam, week, true);
          } else {
            const factor = effectieveEenheid.endsWith('/hl') ? brouwselHl : brouwselHl * 100;
            voegBijdrageToe(rol, regel.ingredient_id, weergaveEenheid, Number(regel.hoeveelheid) * factor * brouwselsInWeek, receptNaam, week);
          }
        } else {
          voegBijdrageToe(rol, regel.ingredient_id, weergaveEenheid, Number(regel.hoeveelheid) * brouwselsInWeek, receptNaam, week);
        }
      });
    }

    if (splitHl > 0 && isTarief) {
      (splitWeekPerRecept[regel.recipe_id] || []).forEach(({ week, hl }) => {
        const factor = effectieveEenheid.endsWith('/hl') ? hl : hl * 100;
        voegBijdrageToe(rol, regel.ingredient_id, weergaveEenheid, Number(regel.hoeveelheid) * factor, `${receptNaam} (via split)`, week);
      });
    }
  });

  // Markeer ingrediënten die (na normalisatie/terugval) alsnog met meerdere
  // verschillende eenheden in dezelfde rol voorkomen -- puur ter signalering.
  Object.values(perRol).forEach(ingredientenVanRol => {
    const perIngredient = {};
    Object.values(ingredientenVanRol).forEach(r => { (perIngredient[r.ingredientId] = perIngredient[r.ingredientId] || []).push(r); });
    Object.values(perIngredient).forEach(rijen => { if (rijen.length > 1) rijen.forEach(r => { r.mixedUnits = true; }); });
  });

  // Vlakke weergave per ingrediënt+eenheid, samengevoegd over alle rollen (voor Stock
  // overview, die niet in Malt/Hops/etc-categorieën denkt maar gewoon per grondstof).
  const perIngredient = {};
  Object.values(perRol).forEach(ingredientenVanRol => {
    Object.entries(ingredientenVanRol).forEach(([key, r]) => {
      if (!perIngredient[key]) {
        perIngredient[key] = { ingredientId: r.ingredientId, naam: r.naam, eenheid: r.eenheid, totaal: 0, perWeek: {} };
      }
      perIngredient[key].totaal += r.totaal;
      Object.entries(r.perWeek).forEach(([week, hoeveelheid]) => {
        perIngredient[key].perWeek[week] = (perIngredient[key].perWeek[week] || 0) + hoeveelheid;
      });
    });
  });

  return {
    perRol, perIngredient,
    aantalBrouwsels: Object.values(brouwselsPerRecept).reduce((a, b) => a + b, 0),
    aantalRecepten: Object.keys(brouwselsPerRecept).length,
  };
}

// Bouwt de periodes-array voor "vanaf nu, N weken vooruit", desnoods over een
// jaargrens heen (max 2 periodes: rest van het huidige jaar + begin van het
// volgende). Gebruikt door Stock overview voor de "loopt leeg op"-projectie.
function vfIsoWeekVanVandaag() {
  const nu = new Date();
  const d = new Date(Date.UTC(nu.getFullYear(), nu.getMonth(), nu.getDate()));
  const dayNr = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - dayNr + 3);
  const firstThursday = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const week = 1 + Math.round(((d - firstThursday) / 86400000 - 3 + ((firstThursday.getUTCDay() + 6) % 7)) / 7);
  return { jaar: d.getUTCFullYear(), week };
}
function vfIsoWeeksInJaar(jaar) {
  const d = new Date(Date.UTC(jaar, 0, 1));
  const dow = d.getUTCDay() || 7;
  const isLeap = (jaar % 4 === 0 && jaar % 100 !== 0) || jaar % 400 === 0;
  return dow === 4 || (dow === 3 && isLeap) ? 53 : 52;
}
function vfVooruitkijkPeriodes(weksVooruit) {
  const { jaar, week } = vfIsoWeekVanVandaag();
  const weeksInJaar = vfIsoWeeksInJaar(jaar);
  const totWeek = week + weksVooruit;
  if (totWeek <= weeksInJaar) {
    return [{ jaar, vanWeek: week, totWeek }];
  }
  return [
    { jaar, vanWeek: week, totWeek: weeksInJaar },
    { jaar: jaar + 1, vanWeek: 1, totWeek: totWeek - weeksInJaar },
  ];
}

// Loopt de per-week-verbruiksreeks van een ingrediënt chronologisch af en geeft de
// eerste week terug waarin de cumulatieve voorraad onder 0 zou komen, of null als dat
// niet gebeurt binnen de meegegeven periodes. `startJaar/startWeek` = vandaag.
function vfLoopVoorraadVooruit(huidigeVoorraad, perWeek) {
  const weken = Object.keys(perWeek).sort(); // 'YYYY-Www' sorteert correct chronologisch
  let resterend = huidigeVoorraad;
  for (const week of weken) {
    resterend -= perWeek[week];
    if (resterend < 0) return week;
  }
  return null;
}
