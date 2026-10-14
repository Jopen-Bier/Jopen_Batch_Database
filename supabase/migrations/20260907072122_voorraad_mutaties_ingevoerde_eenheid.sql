-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Bewaart wat de operator daadwerkelijk invoerde (hoeveelheid + eenheid), los van
-- `hoeveelheid` die altijd in de eenheid van het lot staat en waarmee de voorraad
-- wordt bijgewerkt. Alleen relevant als er een eenheid-omrekening heeft plaatsgevonden;
-- blijft leeg als de operator gewoon in de lot-eenheid heeft geboekt.
alter table public.voorraad_mutaties
  add column if not exists ingevoerde_hoeveelheid numeric,
  add column if not exists ingevoerde_eenheid text;
