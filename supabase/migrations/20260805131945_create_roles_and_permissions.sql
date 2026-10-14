-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

create table if not exists public.roles (
  id bigint generated always as identity primary key,
  naam text not null unique,
  is_systeemrol boolean not null default false,
  aangemaakt_op timestamptz not null default now()
);

create table if not exists public.permission_modules (
  module_key text primary key,
  naam text not null,
  volgorde integer not null default 0
);

create table if not exists public.role_permissions (
  role_id bigint not null references public.roles(id) on delete cascade,
  module_key text not null references public.permission_modules(module_key) on delete cascade,
  can_view boolean not null default false,
  can_edit boolean not null default false,
  can_delete boolean not null default false,
  primary key (role_id, module_key)
);

insert into public.permission_modules (module_key, naam, volgorde) values
  ('recipes', 'Recipes', 1),
  ('ingredients', 'Ingredients', 2),
  ('batches', 'Batch Creation', 3),
  ('brewing_planning', 'Brewing Planning', 4),
  ('settings', 'Settings', 5),
  ('user_management', 'User Management', 6)
on conflict (module_key) do nothing;

insert into public.roles (naam, is_systeemrol) values
  ('admin', true), ('editor', true), ('viewer', true)
on conflict (naam) do nothing;

-- Seed permissions to match current real behaviour exactly, so nothing
-- changes for existing users until an admin actually edits the matrix.
insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, m.module_key,
  true,
  (r.naam in ('admin','editor')),
  (r.naam in ('admin','editor'))
from public.roles r cross join public.permission_modules m
where r.naam in ('admin','editor','viewer') and m.module_key in ('recipes','ingredients','batches','brewing_planning')
on conflict (role_id, module_key) do nothing;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, m.module_key, (r.naam = 'admin'), (r.naam = 'admin'), (r.naam = 'admin')
from public.roles r cross join public.permission_modules m
where m.module_key in ('settings','user_management')
on conflict (role_id, module_key) do nothing;

alter table public.roles enable row level security;
alter table public.permission_modules enable row level security;
alter table public.role_permissions enable row level security;

create policy roles_select_authenticated on public.roles for select using (true);
create policy roles_write_admin on public.roles for all using (is_admin()) with check (is_admin());

create policy permission_modules_select_authenticated on public.permission_modules for select using (true);

create policy role_permissions_select_authenticated on public.role_permissions for select using (true);
create policy role_permissions_write_admin on public.role_permissions for all using (is_admin()) with check (is_admin());
