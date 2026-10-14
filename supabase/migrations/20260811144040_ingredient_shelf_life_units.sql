-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Shelf life / Shelf life after opening worden een getal + eenheid-dropdown
-- (hours/days/weeks/months/years) i.p.v. vrije tekst. Kolommen stonden nog
-- op text en waren nog bij niemand ingevuld (deze sessie toegevoegd), dus
-- direct om te zetten zonder databehoud nodig.
alter table ingredients
  alter column houdbaarheid type numeric using null,
  alter column houdbaarheid_na_openen type numeric using null,
  add column if not exists houdbaarheid_eenheid text,
  add column if not exists houdbaarheid_na_openen_eenheid text,
  add constraint ingredients_houdbaarheid_eenheid_check
    check (houdbaarheid_eenheid is null or houdbaarheid_eenheid in ('hours','days','weeks','months','years')),
  add constraint ingredients_houdbaarheid_na_openen_eenheid_check
    check (houdbaarheid_na_openen_eenheid is null or houdbaarheid_na_openen_eenheid in ('hours','days','weeks','months','years'));
