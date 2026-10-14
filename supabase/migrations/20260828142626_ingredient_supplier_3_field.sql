-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Derde leverancier op de ingredient-kaart, zelfde patroon als leverancier_2/prijs_2/eenheid_prijs_2.
-- Alleen naam-veld gevuld vanuit de raw materials import sheet; prijs/eenheid_prijs erbij
-- voor consistentie met #1/#2, voorlopig leeg (sheet heeft geen kostprijs per supplier 3).
ALTER TABLE ingredients
  ADD COLUMN IF NOT EXISTS leverancier_3 text,
  ADD COLUMN IF NOT EXISTS prijs_3 numeric,
  ADD COLUMN IF NOT EXISTS eenheid_prijs_3 text;
