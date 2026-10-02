-- Minimale nabootsing van een leeg Supabase-project, ALLEEN voor de
-- restore-controle in GitHub Actions (een kale Postgres 17-container).
--
-- Een echt Supabase-project heeft dit allemaal al; daar is dit bestand niet
-- nodig (en ook niet bedoeld). Het zorgt ervoor dat de public-dump terug te
-- zetten is: RLS-policies verwijzen naar de rollen anon/authenticated en naar
-- auth.uid()/auth.jwt(), en foreign keys verwijzen naar auth.users.
--
-- De tabellen auth.users en auth.identities zelf komen NIET hier vandaan,
-- maar uit de auth-dump (jopen_auth_<datum>.dump), die vóór de public-dump
-- wordt teruggezet.

do $$
begin
  create role anon nologin;
exception when duplicate_object then null;
end $$;
do $$
begin
  create role authenticated nologin;
exception when duplicate_object then null;
end $$;
do $$
begin
  create role service_role nologin;
exception when duplicate_object then null;
end $$;

create schema if not exists auth;
create schema if not exists extensions;
create schema if not exists storage;

create or replace function auth.uid() returns uuid language sql stable as
$f$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;

create or replace function auth.role() returns text language sql stable as
$f$ select current_setting('request.jwt.claim.role', true) $f$;

create or replace function auth.email() returns text language sql stable as
$f$ select current_setting('request.jwt.claim.email', true) $f$;

create or replace function auth.jwt() returns jsonb language sql stable as
$f$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $f$;

-- Extensies die Supabase standaard aan heeft. De huidige dump heeft ze niet
-- nodig (gen_random_uuid() zit in Postgres zelf), maar mocht een functie of
-- default er later naar verwijzen, dan staan ze klaar. Ontbreekt een
-- extensie in de container, dan is dat geen reden om af te breken.
do $$
begin
  create extension if not exists pgcrypto schema extensions;
exception when others then
  raise notice 'Extensie pgcrypto niet beschikbaar: %', sqlerrm;
end $$;
do $$
begin
  create extension if not exists "uuid-ossp" schema extensions;
exception when others then
  raise notice 'Extensie uuid-ossp niet beschikbaar: %', sqlerrm;
end $$;
