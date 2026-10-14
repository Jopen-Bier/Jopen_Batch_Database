-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Recommended drinking temperature, in the General card next to the
-- flavour description/keywords/colour block. The visual colour-assessment
-- tool (DraughtLab-style slider, SRM-ish named steps) is explicitly
-- deferred -- no column for it yet, more reference screenshots incoming.
alter table recipes add column if not exists aanbevolen_schenktemperatuur numeric;
