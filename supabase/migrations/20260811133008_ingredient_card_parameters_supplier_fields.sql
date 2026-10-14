-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Ingredient card restructuring: General / Supplier information / Parameters
-- blocks. Bestaande leverancier/prijs worden hergebruikt als Supplier #1 /
-- Price #1 (geen kolomwijziging nodig, alleen UI-herlabeling); alle overige
-- velden hieronder zijn nieuw.
alter table ingredients
  add column if not exists leverancier_2 text,
  add column if not exists prijs_2 numeric,
  -- "Per unit" bij elke prijs (bv. "kg", "L", "25kg zak") t.b.v. toekomstige
  -- prijs-per-standaardeenheid-berekeningen. Voor beide prijzen toegevoegd
  -- voor consistentie, ook al werd dit voor prijs #2 niet expliciet genoemd.
  add column if not exists eenheid_prijs_1 text,
  add column if not exists eenheid_prijs_2 text,
  add column if not exists kleur_ebc numeric,
  -- 14 EU-gereguleerde allergenen, opgeslagen als array van korte sleutels
  -- (zie EU_ALLERGENEN-constante in ingredienten.html voor de exacte lijst
  -- en weergavelabels).
  add column if not exists allergenen jsonb not null default '[]'::jsonb,
  add column if not exists ingredient_declaratie text,
  add column if not exists bewaartemperatuur text,
  add column if not exists houdbaarheid text,
  add column if not exists houdbaarheid_na_openen text,
  add column if not exists dichtheid numeric,
  add column if not exists alcohol_pct numeric;
