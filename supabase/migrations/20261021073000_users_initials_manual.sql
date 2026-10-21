-- Users: initials are typed by hand, no longer generated from the name
-- (Jaap, 21-10). The generated ones clashed with the initials used on the
-- floor (Bohdan Saveliev got BS, which is Bart Stelleman; Matthijs van der
-- Geest got MG instead of MVG). Initials link the 2026 Excel batch reports to
-- users, so one initial = one person: unique, ignoring case.
-- Drops trigger trg_users_initials and functions set_user_initials() and
-- initials_from_name() (nothing else uses them; no cascade). Sets the two
-- initials still wrong, then adds the unique index. Plain ASCII.

begin;

drop trigger if exists trg_users_initials on public.users;
drop function if exists public.set_user_initials();
drop function if exists public.initials_from_name(text);

update public.users set initials = 'BS1'
where name = 'Bohdan Saveliev' and initials = 'BS';
update public.users set initials = 'MVG'
where name = 'Matthijs van der Geest' and initials = 'MG';

-- Empty text is no initials.
update public.users set initials = null where btrim(initials) = '';

create unique index if not exists users_initials_key
  on public.users (upper(initials)) where initials is not null;

commit;
