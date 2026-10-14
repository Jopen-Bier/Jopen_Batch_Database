-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Losse referentieprijs per kg op de ingredient-kaart, naast de bestaande prijs-per-
-- doseereenheid (prijs/eenheid_prijs_1). Bedoeld om twee prijzen naast elkaar te kunnen
-- tonen zodat prijzen makkelijker "in het hoofd" te vergelijken zijn, ongeacht de
-- doseereenheid van het ingrediënt.
ALTER TABLE ingredients
  ADD COLUMN IF NOT EXISTS prijs_per_kg numeric;
