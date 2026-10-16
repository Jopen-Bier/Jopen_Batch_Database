-- Telt rijen per tabel en geeft één JSON-object terug, bv.
--   {"auth.identities": 20, "auth.users": 20, "public.batches": 327, ...,
--    "_fk_naar_auth_users": 9}
--
-- Wordt gedraaid tegen productie (vóór en ná de dump) en tegen de
-- teruggezette kopie, zodat die met elkaar vergeleken kunnen worden.
-- "_fk_naar_auth_users" telt de foreign keys vanuit onze schema's naar
-- auth.users: als die na een restore ontbreken, is de koppeling met de
-- gebruikers kapot.
--
-- Verwacht de psql-variabele "eigen": de kommagescheiden lijst schema's uit
-- eigen_schemas.sql, bv.
--   psql ... -v eigen="public,core" -f tel_rijen.sql
-- In de nachtelijke backup is dat de lijst van PRODUCTIE, ook bij het tellen
-- van de teruggezette kopie: ontbreekt daar een schema, dan ontbreken die
-- tabellen en wordt de run rood.

select json_object_agg(sleutel, aantal order by sleutel)
from (
  select t.table_schema || '.' || t.table_name as sleutel,
         (xpath('/row/c/text()',
                query_to_xml(format('select count(*) as c from %I.%I',
                                    t.table_schema, t.table_name),
                             false, true, '')))[1]::text::bigint as aantal
  from information_schema.tables t
  where t.table_type = 'BASE TABLE'
    and (t.table_schema = any (string_to_array(:'eigen', ','))
         or (t.table_schema = 'auth' and t.table_name in ('users', 'identities')))
  union all
  select '_fk_naar_auth_users',
         count(*)
  from pg_constraint c
  join pg_namespace n on n.oid = c.connamespace
  where c.contype = 'f'
    and n.nspname = any (string_to_array(:'eigen', ','))
    and c.confrelid = to_regclass('auth.users')
) x;
