# Supabase-migraties

Deze map wordt gevolgd door Supabase's GitHub-integratie: bij een merge naar
`main` worden nieuwe bestanden hierin **automatisch op productie uitgevoerd**.
Dat is dus geen "plak in de SQL Editor en kijk zelf mee" meer, maar een echte
productie-wijziging zodra dit gepusht wordt.

## Afspraak (vastgelegd 29 juli 2026)
- **Additief en veilig** (nieuwe kolom met `IF NOT EXISTS`, nieuwe tabel,
  nieuwe policy, nieuwe index): mag zonder expliciet akkoord gecommit en
  gepusht worden, wel altijd duidelijk gemeld wat er verandert.
- **Destructief of onomkeerbaar** (`DROP TABLE`/`DROP COLUMN`, data die
  overschreven wordt, constraints die bestaande rijen kunnen laten falen):
  **nooit** zomaar pushen. Eerst expliciet voorleggen wat er gaat gebeuren en
  op akkoord wachten, ook als het voor de hand lijkt te liggen.

## Belangrijk: ook rechtstreeks uitgevoerde migraties hier vastleggen
Supabase's GitHub-integratie weigert **alle** nieuwe migraties zodra de
database een migratieversie kent die niet als bestand in deze map staat
("Remote migration versions not found in local migrations directory").
Wordt een migratie toch rechtstreeks uitgevoerd (MCP `apply_migration` of de
SQL Editor), zet dan direct een bestand met **exact dezelfde versie en naam**
(zie `supabase_migrations.schema_migrations`) in deze map. Op 14 oktober 2026
zijn de 50 ontbrekende migraties zo uit de database overgenomen, en is
`20260918072509_…` hernoemd naar de geregistreerde versie `20260918072457_…`.

## Conventie
- Bestandsnaam: `YYYYMMDDHHMMSS_korte_beschrijving.sql` (UTC-timestamp,
  oplopend/chronologisch — dat bepaalt de uitvoervolgorde).
- Elke migratie is **idempotent**: gebruik `IF NOT EXISTS`,
  `DROP POLICY IF EXISTS` + opnieuw aanmaken, `DO $$ ... IF NOT EXISTS ... $$`
  voor constraints, enz. Zo kan een migratie geen kwaad als een deel ervan
  handmatig al eens is uitgevoerd (zoals bij `batches` het geval was).
- Nooit een al-gepushte migratie achteraf aanpassen — een correctie wordt een
  nieuw, volgend bestand.

## Bestaande migraties
- `20260729091304_create_batches_table.sql` — de `batches`-tabel voor Batch
  Creation. Legt de bestaande (al op productie aanwezige) eindtoestand vast;
  dit is de eerste via deze map getrackte migratie, het schema van vóór deze
  datum (recepten, ingrediënten, gebruikers, enz.) is niet met terugwerkende
  kracht hierin opgenomen.
- `20260729133833_ph_maische_start_koken_naar_tekst.sql` — pH-kolommen van
  `numeric` naar `text` (bereikwaarden zoals "5,4 - 5,5" konden anders niet
  opgeslagen worden).
- `20260729134446_batches_delete_admin_policy.sql` — DELETE-policy op
  `batches`, alleen voor admins.
- `20260730173801_create_brouwplanning_en_capaciteit.sql` — Fase Geel,
  jaarplanning: `brew_plan_group`-enum (jk/wp_60hl/wp_120hl/wp_320hl),
  `brew_capacity` (wekelijks max aantal brouwsels, twee niveaus: jk en wp-totaal)
  en `brew_planning` (geplande brouwsels per week/groep/recept). RLS staat nu
  bewust open voor elke ingelogde gebruiker (geen rolonderscheid) — dat volgt
  later via een rollen-rechtenscherm.
- `20260730173855_create_brew_planning_geschiedenis.sql` — automatische
  wijzigingslog op `brew_planning` via trigger (`brew_planning_geschiedenis`
  + leesbare view `brew_planning_wijzigingen`), zodat later te herleiden is
  hoe vaak/wanneer de planning nog wordt bijgesteld.
- `20260730191029_recipes_kleur_kolom.sql` — vrij tekstveld `kleur` op
  `recipes`, gevuld via een ronde kleurenselectie in `recept-invoer.html`,
  gebruikt om geplande brouwsels in `brouwplanning.html` sneller herkenbaar
  te maken.
- `20260730194612_create_eenheden_tabel.sql` — `eenheden`-tabel, beheerbaar
  via Settings → Units. Eerste stap richting het vervangen van het vrije
  tekstveld "Unit" op receptregels door een vaste keuzelijst — die omzetting
  zelf moet nog gebeuren.
- `20260731094745_recipes_delete_policy.sql` — DELETE-policy op `recipes`
  voor editor/admin, nodig voor de nieuwe Delete-knop op de receptkaart.
  Let op: geen `ON DELETE CASCADE` toegevoegd op eventuele gerelateerde
  tabellen — als een recept al in gebruik is (batches, brew_planning, etc.)
  kan de DELETE alsnog stuklopen op een foreign-key-constraint; dat is
  bewust niet stilzwijgend opgelost.
- `20260805120000_ingredients_versiebeheer.sql` — versiebeheer voor
  `ingredients` (`versie_major`/`versie_minor`/`ingredient_group_id`,
  zelfde vorm als recipes), een aparte `versie_status`-kolom
  ('huidig'/'gearchiveerd', bewust losstaand van de operationele
  actief/inactief/uitgefaseerd-status), `aangemaakt_op`/`gewijzigd_op`
  (met trigger die `gewijzigd_op` automatisch bijwerkt) en een nieuwe
  `ingredient_revisies`-tabel (één-op-één qua vorm met `recipe_revisies`).
- `20260805140000_ingredients_delete_policy.sql` — DELETE-policy op
  `ingredients` voor editor/admin, zelfde patroon als de recipes-variant.
- `20260805140500_gebruikers_laatst_ingelogd.sql` — `laatst_ingelogd`-kolom
  op `gebruikers` + een SECURITY DEFINER-functie `zet_laatst_ingelogd()`
  die login.html na een geslaagde login aanroept (schrijft alleen de eigen
  rij weg, dus geen brede UPDATE-policy nodig).
- `20260805160000_batches_aantal_brouwsels.sql` — `aantal_brouwsels`-kolom
  op `batches`. De generatiescripts schreven dit veld al naar
  Recept-voorblad!G7, maar de kolom en het invoerveld op Batch Creation
  ontbraken nog.
