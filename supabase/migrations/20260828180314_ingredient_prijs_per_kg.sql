-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Losstaand van de bestaande prijs/eenheid_prijs_1 (die de doseereenheid van het recept volgt,
-- bv. €/g of €/hl), komt er een altijd-in-€/kg veld bij zodat de ingredient-kaart twee prijzen
-- naast/onder elkaar kan tonen ter vergelijking. Alleen zinvol/gevuld voor ingrediënten waar een
-- kg-kostprijs bekend is (niet elk ingrediënt wordt per kg ingekocht).
ALTER TABLE ingredients
  ADD COLUMN IF NOT EXISTS prijs_per_kg numeric;

COMMENT ON COLUMN ingredients.prijs_per_kg IS 'Prijs per kg, los van prijs/eenheid_prijs_1 (die de doseereenheid volgt). Voor vergelijkbaarheid op de ingredient-kaart.';
