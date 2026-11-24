-- Security phase 5 (security review 19-11-2026, P2.1): two-factor
-- authentication (TOTP, an authenticator app), required per role.
--
-- roles.mfa_required: set per role on the User Roles page (decision Jaap,
-- 24-11-2026). On for admin, and admin can never switch it off (constraint),
-- so a stolen admin password alone never gives admin rights.
--
-- Enforcement is in the database, in the two helpers every policy goes
-- through, so it also holds for direct API calls, not only in the app:
--   mfa_satisfied() is true when the session is aal2 (code entered), or when
--   the user has no verified authenticator AND their role does not require
--   one. Someone who set up an authenticator therefore always needs the
--   code, even in a role that does not require it.
--   current_role_id() and is_admin() return nothing until mfa_satisfied(),
--   so can_view/can_edit/can_delete and every admin check deny until then.
-- The app sends such users to mfa.html (set up, or enter the code).
--
-- Idempotent. Rollback: docs/security/phase5-rollback.sql.

begin;

alter table public.roles add column if not exists mfa_required boolean not null default false;
update public.roles set mfa_required = true where name = 'admin' and not mfa_required;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'roles_admin_mfa_required') then
    alter table public.roles
      add constraint roles_admin_mfa_required check (name <> 'admin' or mfa_required);
  end if;
end $$;

create or replace function public.mfa_satisfied()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select auth.jwt() ->> 'aal'), 'aal1') = 'aal2'
      or (
        not exists (
          select 1 from auth.mfa_factors f
          where f.user_id = (select auth.uid()) and f.status = 'verified'
        )
        and not coalesce((
          select r.mfa_required
          from public.users u join public.roles r on r.id = u.role_id
          where u.id = (select auth.uid())
        ), false)
      );
$$;
revoke execute on function public.mfa_satisfied() from public, anon;
grant execute on function public.mfa_satisfied() to authenticated, service_role;

create or replace function public.current_role_id()
returns integer
language sql
stable
security definer
set search_path to 'public'
as $$
  select role_id from users where id = auth.uid() and is_active and mfa_satisfied();
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from users u join roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active and r.name = 'admin'
  ) and mfa_satisfied();
$$;

commit;
