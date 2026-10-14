-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Price per kg moet per leverancier kunnen verschillen (elke leverancier heeft zijn eigen tarief).
-- Bestaande prijs_per_kg blijft ongewijzigd staan als het #1-veld.
ALTER TABLE ingredients
  ADD COLUMN IF NOT EXISTS prijs_per_kg_2 numeric,
  ADD COLUMN IF NOT EXISTS prijs_per_kg_3 numeric;

COMMENT ON COLUMN ingredients.prijs_per_kg IS 'Prijs per kg voor Supplier #1, los van prijs/eenheid_prijs_1 (die de doseereenheid volgt).';
COMMENT ON COLUMN ingredients.prijs_per_kg_2 IS 'Prijs per kg voor Supplier #2.';
COMMENT ON COLUMN ingredients.prijs_per_kg_3 IS 'Prijs per kg voor Supplier #3.';
