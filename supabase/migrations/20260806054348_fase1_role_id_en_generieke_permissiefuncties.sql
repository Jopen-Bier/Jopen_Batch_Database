-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- 1. Stabiele FK naast het bestaande tekstveld (rol blijft bestaan, niets breekt)
alter table gebruikers
  add column if not exists role_id integer references roles(id);

-- Backfill: rol-tekst komt vandaag exact overeen met roles.naam
update gebruikers g
set role_id = r.id
from roles r
where g.rol = r.naam
  and g.role_id is null;

-- 2. Generieke permissiefuncties: geen enkele rolnaam meer in RLS-policies straks,
-- alles loopt via role_permissions. Admin heeft altijd overal toegang (bypass),
-- ongeacht wat er in de matrix staat.
create or replace function huidige_role_id()
returns integer
language sql
security definer
stable
as $$
  select role_id from public.gebruikers
  where id = auth.uid() and actief = true;
$$;

create or replace function mag_bekijken(p_module_key text)
returns boolean
language sql
security definer
stable
as $$
  select is_admin() or exists (
    select 1 from public.role_permissions rp
    where rp.role_id = huidige_role_id()
      and rp.module_key = p_module_key
      and rp.can_view = true
  );
$$;

create or replace function mag_bewerken(p_module_key text)
returns boolean
language sql
security definer
stable
as $$
  select is_admin() or exists (
    select 1 from public.role_permissions rp
    where rp.role_id = huidige_role_id()
      and rp.module_key = p_module_key
      and rp.can_edit = true
  );
$$;

create or replace function mag_verwijderen(p_module_key text)
returns boolean
language sql
security definer
stable
as $$
  select is_admin() or exists (
    select 1 from public.role_permissions rp
    where rp.role_id = huidige_role_id()
      and rp.module_key = p_module_key
      and rp.can_delete = true
  );
$$;

-- User Management / Role Management: bewust NIET matrix-gestuurd, blijft hardcoded
-- admin-only, ook al zou er ooit per ongeluk een andere waarde in role_permissions
-- voor deze twee module_keys terechtkomen.
create or replace function mag_bekijken_vergrendeld(p_module_key text)
returns boolean
language sql
security definer
stable
as $$
  select is_admin();
$$;

-- 3. Drie lege, nog-niet-geconfigureerde rollen voor later gebruik. Overal op
-- "geen rechten" gezet (veiligste default) totdat jij ze in rollen.html instelt
-- en (voorlopig via mij) een echte naam geeft.
insert into roles (naam, is_systeemrol)
values ('Nieuwe rol 1', false), ('Nieuwe rol 2', false), ('Nieuwe rol 3', false)
on conflict do nothing;

insert into role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, pm.module_key, false, false, false
from roles r
cross join permission_modules pm
where r.naam in ('Nieuwe rol 1', 'Nieuwe rol 2', 'Nieuwe rol 3')
on conflict do nothing;
