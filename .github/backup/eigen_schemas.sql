-- Geeft de schema's terug die van ONS zijn, als kommagescheiden lijst,
-- bv. "core,inventory,production,public,recipe".
--
-- Eén plek die bepaalt wat er in de backup gaat. Gebruikt door de
-- nachtelijke backup (welke schema's dumpen en tellen) en door de
-- restore-test (welke schema's tellen).
--
-- Werkt met een UITSLUITLIJST in plaats van een vaste lijst van eigen
-- schema's: een nieuw schema (bv. qa of sensory voor een nieuwe app) gaat
-- daardoor automatisch mee in de backup, zonder dat iemand eraan hoeft te
-- denken. Uitgesloten zijn alleen de schema's die Postgres of Supabase zelf
-- beheert; die bestaan in elk (nieuw) project al en geven bij een restore
-- alleen "must be owner of..."-fouten.

select coalesce(string_agg(nspname, ',' order by nspname), 'public')
from pg_namespace
where nspname not like 'pg\_%'
  and nspname not in (
    'information_schema',
    -- Supabase
    'auth', 'storage', 'realtime', '_realtime', 'extensions', 'graphql',
    'graphql_public', 'vault', 'pgsodium', 'pgsodium_masks', 'pgbouncer',
    'supabase_functions', 'supabase_migrations', 'net', 'cron', 'pgmq',
    '_analytics', 'pgtle'
  );
