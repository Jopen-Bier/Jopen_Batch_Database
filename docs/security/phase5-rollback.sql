-- Rollback for supabase/migrations/20261124150000_mfa_per_role.sql.
-- NOT a migration: run by hand in the SQL Editor only if MFA enforcement
-- locks people out, then fix forward. Restores the helpers exactly as they
-- were on 24-11-2026; the column, constraint and mfa_satisfied() stay (unused).

begin;

create or replace function public.current_role_id()
returns integer
language sql
stable
security definer
set search_path to 'public'
as $$
  select role_id from users where id = auth.uid() and is_active;
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
  );
$$;

commit;
