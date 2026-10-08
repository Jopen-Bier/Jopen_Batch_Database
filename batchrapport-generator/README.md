# Batchrapport-generator

Genereert een gevuld batchrapport (.xlsx) voor één batch: haalt het gekoppelde
recept + alle sub-tabellen op uit Supabase, plakt de waarden op de juiste plek
in `Batchrapport_sjabloon.xlsx`, herberekent Hop-rendement/EBU, en laat alle
overige formules in het sjabloon met rust.

## Architectuur (belangrijk!)

Dit schrijft **rechtstreeks in de ruwe sheet-XML** (via JSZip, zie
`xlsx-direct.js`) — geen ExcelJS meer voor het genereren zelf. Reden: ExcelJS'
eigen load/save-cyclus bleek zelf meerdere dingen te breken die niets met onze
wijzigingen te maken hadden — rij/cel-mismatches, een verminkte Print Area
(bekende bug exceljs/exceljs#664), een foute `sheetPr`-elementvolgorde, en een
herbouwde stijlentabel. Door alleen de specifieke cellen te vervangen die we
moeten invullen (altijd cellen die al in het sjabloon bestaan, zie hieronder)
en de rest van het bestand — incl. de hele stijlentabel — volledig ongemoeid
te laten, kunnen die problemen niet meer optreden.

`xlsx-direct.js` bevat twee klassen:
- `XlsxDirectWriter` — vervangt de inhoud van een cel (`setCelWaarde`), met
  behoud van diens bestaande stijl-index.
- `StylesManager` — voegt een nieuwe stijl toe die identiek is aan een
  bestaande, maar met een andere onderrand (voor de hop-groep-scheidings-
  lijnen), en dedupliceert daarbij zelf tegen de bestaande stijlentabel.

**Belangrijke aanname:** elke cel die we invullen bestaat al als element in de
sheet-XML (leeg, met een stijl). Er wordt dus nooit een cel ingevoegd, alleen
vervangen. Als een gemapte cel ooit niet bestaat, gooit het script een
duidelijke fout — dat is dan een teken dat het sjabloon of de mapping-CSV is
gewijzigd zonder de andere bij te werken.

ExcelJS staat nog wel als dependency (gebruikt in `test-fill.js` om de output
achteraf terug te lezen en te controleren, puur voor verificatie — niet voor
het genereren zelf).

## Installatie

```
npm install
```

## Gebruik

```
SUPABASE_URL=https://xxxx.supabase.co \
SUPABASE_SERVICE_ROLE_KEY=<service_role key, NIET de publishable/anon key> \
node generate-batchrapport.js <batchnummer>
```

Output: `./output/<batchnummer> <naam> v<versie> <WP/Kerk-prefix>.xlsx`

**Waarom de service_role key en niet de anon key uit `config.js`?** Dit script
draait server-side/lokaal, niet in de browser, en moet alle receptdata kunnen
lezen ongeacht RLS-policies. Gebruik deze key nooit in een frontend-bestand.

## Testen zonder Supabase

```
npm test
```

Vult het sjabloon met verzonnen testdata (`test-fill.js`) — controleert o.a.
dat cellen hun stijl behouden, dat de hop-groep-scheidingslijnen op de juiste
plek komen, en leest de output terug met ExcelJS om waardes te verifiëren.

## Wat er gebeurt

1. `batches`-tabel opzoeken op batchnummer → `recipe_id`
2. Recept + alle sub-tabellen ophalen (`recipe_specificaties`, `recipe_fermentatie`,
   `recipe_brouwspecificaties`, `recipe_water`, `recipe_verpakking`,
   `recipe_processtappen`, `recipe_comments`, `recipe_ingredients`, laatste 4
   `recipe_revisies`)
3. Sjabloon inladen als zip, cellen vervangen via `XlsxDirectWriter` op basis
   van de mappings in `./data/`:
   - `scalar_field_map.json` — losse spec/tolerantie/brouwspecificatie/verpakking/
     water/comments-velden
   - `ingredient_field_map.json` — genummerde ingrediënt-slots (Hop 1-15, Mout
     1-10, Dry Hop 1-6, Toegiften Brouwers/Kelder, Gist)
   - `revisie_field_map.json` — laatste 4 revisies
   - `formaten_field_map.json` — verpakkingsformaat-checkboxen
   - vestigingsafhankelijke (WP/Kerk) velden apart in de code (`WP_KERK_VELDEN`)
   - F8/F9/F11/N8 in Brew Sheet: aparte kruislogica (`vulReceptnaamKruisVelden`)
4. Hop-rendement%/EBU per hopgift + Calculated total EBU herberekend (zelfde
   logica als `recept-invoer.html`) en als waarde geplakt
5. Dikke scheidingslijnen tussen hop-groepen via `StylesManager`
6. Batchnummer + vestiging weggeschreven, bestandsnaam volgens de
   oorspronkelijke VBA-formule, opgeslagen als nieuw bestand

## Onderhoud

De hop-rendement-tabel en `bepaalHopRendement`/`bepaalHopEbu`-logica staan
**gedupliceerd** op drie plekken: hier, in `recept-invoer.html` en in
`receptoverzicht.html` (en indirect in `../batchrapport-vullen.js`, de
browser-versie van dit script). Verander je de tabel of formule, doe dat
overal.

Als het recept-schema wijzigt (nieuwe/hernoemde velden), moet
`../batchrapport_cel_mapping.csv` opnieuw gegenereerd worden en de JSON-
bestanden in `./data/` opnieuw afgeleid.

