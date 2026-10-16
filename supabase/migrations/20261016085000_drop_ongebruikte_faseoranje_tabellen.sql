-- Architectuur-opschoning, stap 1: opruimen.
--
-- Uitgevoerd op 2026-10-16 door Jaap via de Supabase SQL Editor (de connector
-- kon geen destructieve migraties uitvoeren). Dit bestand legt vast wat er is
-- gedraaid, zodat repo en database gelijk blijven.
--
-- Wat er weg is:
--   - 13 lege batch_*-tabellen uit het eerste Fase Oranje-concept (een
--     letterlijke vertaling van de Excel). Fase Oranje krijgt een nieuw
--     datamodel op basis van de mockup.
--   - verpakkingsartikelen, verpakkingsmaterialen, recipe_maisch_stappen
--     (leeg, nergens gebruikt).
--   - genereer_batchnummer() en de standaardwaarde op batches.batchnummer.
--     Die werd nooit gebruikt (batch_jaar_teller was leeg): batchcreation.html
--     stuurt het nummer altijd zelf mee. Hij zou bovendien een nummer in de
--     verkeerde vorm maken (26001 i.p.v. de reeks 20000-26351). Zonder
--     standaardwaarde is een batchnummer nu verplicht; ontbreekt het, dan
--     faalt de insert duidelijk.
--
-- Bewust zonder CASCADE: een onverwachte afhankelijkheid laat de migratie
-- falen in plaats van stil meer te verwijderen. (Zo kwam de standaardwaarde
-- op batchnummer ook boven.)

alter table public.batches alter column batchnummer drop default;
drop function public.genereer_batchnummer();
drop table public.batch_afvul_metingen, public.batch_afvul_regels, public.batch_afvul_sessies,
  public.batch_afvullijnen, public.batch_brouwsels, public.batch_gistkaart_metingen,
  public.batch_hbt_eindwaarden, public.batch_hbt_vullingen, public.batch_ingredient_lotnummers,
  public.batch_jaar_teller, public.batch_processtappen_uitvoering, public.batch_verbruik_materialen,
  public.batch_verwerking_sessies, public.verpakkingsartikelen, public.verpakkingsmaterialen,
  public.recipe_maisch_stappen;
