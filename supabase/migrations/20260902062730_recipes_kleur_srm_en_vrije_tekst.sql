-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Colour picker: an SRM (Standard Reference Method) position on the
-- slider, plus an optional free-text note. The displayed band label
-- ("Ruby Brown" etc.) is always derived client-side from kleur_srm via a
-- shared lookup table rather than stored, so there's one source of truth
-- if the band thresholds ever need adjusting.
alter table recipes add column if not exists kleur_srm numeric;
alter table recipes add column if not exists kleur_vrije_tekst text;
