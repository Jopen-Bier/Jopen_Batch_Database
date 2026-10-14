-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- short_name is niet meer nodig: recipes.locatie is nu voor alle recepten
-- gevuld, en de recepten waar short_name echte extra informatie t.o.v. naam
-- bevatte (SPLIT/needs update/OUD/(Bird)/DO NOT USE/batchgrootte enz.) zijn
-- verwerkt in naam zelf. Alle applicatiecode is al aangepast om short_name
-- niet meer te lezen of schrijven (commit b99b0cd).
alter table recipes drop column if exists short_name;
