-- Architecture clean-up, step 6: domain "core" in English.
-- Mapping: supabase/rename-map.json (approved by Jaap, 16-10-2026).
-- Tables stay in schema public (decision 16-10: PostgREST only embeds within
-- one schema).
--
-- Run by hand in the SQL Editor (the MCP connector cannot run destructive
-- DDL); registered in supabase_migrations.schema_migrations before the file
-- was pushed. Runs as one transaction: either everything or nothing.
--
-- Afterwards the frontend (config.js, nav.js, pages) and both Edge Functions
-- must be on the new names — they are deployed right after this script.

-- ---------------------------------------------------------------------------
-- 1. Remove the duplicate role text column (gebruikers.rol) and everything
--    that only existed to keep it in sync with role_id. Also two unused
--    functions: is_editor_of_hoger (never used; compared against
--    'head_brewer' while the role is called 'Head brewer') and
--    mag_bekijken_vergrendeld (used by no policy).
-- ---------------------------------------------------------------------------
drop trigger trg_gebruikers_sync_rol_role_id on public.gebruikers;
drop trigger trg_roles_sync_naam_naar_gebruikers on public.roles;
drop function public.gebruikers_sync_rol_role_id();
drop function public.roles_sync_naam_naar_gebruikers();
drop function public.is_editor_of_hoger();
drop function public.mag_bekijken_vergrendeld(text);

-- Old/duplicate policies on gebruikers (one of them reads the rol column).
drop policy "alleen admins mogen gebruikers bewerken" on public.gebruikers;
drop policy "ingelogde gebruikers mogen gebruikers lezen" on public.gebruikers;
drop policy select_authenticated on public.gebruikers;
drop policy admin_schrijft on public.gebruikers;

-- is_admin() still reads gebruikers.rol: switch it to role_id first
-- (old names here; it is rewritten with the new names in step 4).
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from gebruikers g join roles r on r.id = g.role_id
    where g.id = auth.uid() and g.actief and r.naam = 'admin'
  );
$$;

alter table public.gebruikers drop column rol;

-- ---------------------------------------------------------------------------
-- 2. Rename tables, columns, constraints and indexes.
-- ---------------------------------------------------------------------------
alter table public.gebruikers rename to users;
alter table public.users rename column naam to name;
alter table public.users rename column actief to is_active;
alter table public.users rename column aangemaakt_op to created_at;
alter table public.users rename column laatst_ingelogd to last_login_at;
alter table public.users rename constraint gebruikers_pkey to users_pkey;
alter table public.users rename constraint gebruikers_id_fkey to users_id_fkey;
alter table public.users rename constraint gebruikers_role_id_fkey to users_role_id_fkey;

alter table public.roles rename column naam to name;
alter table public.roles rename column is_systeemrol to is_system_role;
alter table public.roles rename column aangemaakt_op to created_at;
alter table public.roles rename constraint roles_naam_key to roles_name_key;

alter table public.permission_modules rename column naam to name;
alter table public.permission_modules rename column volgorde to sort_order;

alter table public.eenheden rename to units;
alter table public.units rename column aangemaakt_op to created_at;
alter table public.units rename constraint eenheden_pkey to units_pkey;
alter table public.units rename constraint eenheden_code_key to units_code_key;

alter table public.document_typen rename to document_types;
alter table public.document_types rename column aangemaakt_op to created_at;
alter table public.document_types rename constraint document_typen_pkey to document_types_pkey;
alter table public.document_types rename constraint document_typen_code_key to document_types_code_key;

-- ---------------------------------------------------------------------------
-- 3. Unit codes in English (stuks -> pcs). Only one recipe line uses it.
-- ---------------------------------------------------------------------------
update public.units set code = 'pcs',    label = 'Pieces'              where code = 'stuks';
update public.units set code = 'pcs/hl', label = 'Pieces / Hectoliter' where code = 'stuks/hl';
update public.recipe_ingredients set eenheid = 'pcs/hl' where eenheid = 'stuks/hl';
update public.recipe_ingredients set eenheid = 'pcs'    where eenheid = 'stuks';
update public.ingredients set eenheid = 'pcs' where eenheid = 'stuks';
update public.grondstof_lots set eenheid = 'pcs' where eenheid = 'stuks';
update public.voorraad_mutaties set ingevoerde_eenheid = 'pcs' where ingevoerde_eenheid = 'stuks';

-- ---------------------------------------------------------------------------
-- 4. Permission functions in English. ALTER ... RENAME keeps the function's
--    identity, so every RLS policy (incl. storage) keeps working; the bodies
--    are rewritten for the new table/column names.
-- ---------------------------------------------------------------------------
alter function public.huidige_role_id() rename to current_role_id;
alter function public.mag_bekijken(text) rename to can_view;
alter function public.mag_bewerken(text) rename to can_edit;
alter function public.mag_verwijderen(text) rename to can_delete;
alter function public.zet_laatst_ingelogd() rename to set_last_login;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from users u join roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active and r.name = 'admin'
  );
$$;

create or replace function public.current_role_id()
returns integer language sql stable security definer set search_path = public as $$
  select role_id from users where id = auth.uid() and is_active;
$$;

create or replace function public.can_view(p_module_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_view
  );
$$;

create or replace function public.can_edit(p_module_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_edit
  );
$$;

create or replace function public.can_delete(p_module_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_delete
  );
$$;

-- Not called by the app at the moment (last login comes from auth.users via
-- admin_get_last_logins); kept working for the column it maintains.
create or replace function public.set_last_login()
returns void language plpgsql security definer set search_path = public as $$
begin
  update users set last_login_at = now() where id = auth.uid();
end;
$$;

-- Output column changes name, so drop + create (grants re-applied below).
drop function public.admin_haal_laatste_logins();
create function public.admin_get_last_logins()
returns table (id uuid, last_login_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;
  return query select au.id, au.last_sign_in_at from auth.users au;
end;
$$;
revoke all on function public.admin_get_last_logins() from public;
grant execute on function public.admin_get_last_logins() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Policies: users gets one clean pair; the rest only get English names.
-- ---------------------------------------------------------------------------
create policy users_select on public.users
  for select to authenticated using (true);
create policy users_write_admin on public.users
  for all to authenticated using (is_admin()) with check (is_admin());

alter policy eenheden_select on public.units rename to units_select;
alter policy eenheden_insert on public.units rename to units_insert;
alter policy eenheden_update on public.units rename to units_update;
alter policy eenheden_delete on public.units rename to units_delete;

alter policy document_typen_select on public.document_types rename to document_types_select;
alter policy document_typen_insert on public.document_types rename to document_types_insert;
alter policy document_typen_update on public.document_types rename to document_types_update;
alter policy document_typen_delete on public.document_types rename to document_types_delete;

alter policy permission_modules_select_authenticated on public.permission_modules rename to permission_modules_select;
alter policy role_permissions_select_authenticated on public.role_permissions rename to role_permissions_select;
alter policy roles_select_authenticated on public.roles rename to roles_select;
