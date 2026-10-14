-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

alter table public.gebruikers drop constraint gebruikers_rol_check;

update public.gebruikers set rol = 'head_brewer' where rol = 'editor';
update public.roles set naam = 'head_brewer' where naam = 'editor';

alter table public.gebruikers add constraint gebruikers_rol_check
  check (rol = any (array['admin','head_brewer','brewer','planner','qa','viewer']));

insert into public.roles (naam, is_systeemrol) values
  ('brewer', true), ('planner', true), ('qa', true)
on conflict (naam) do nothing;

insert into public.permission_modules (module_key, naam, volgorde) values
  ('role_management', 'Role Management', 7)
on conflict (module_key) do nothing;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, 'role_management', (r.naam = 'admin'), (r.naam = 'admin'), (r.naam = 'admin')
from public.roles r
on conflict (role_id, module_key) do update set
  can_view = excluded.can_view, can_edit = excluded.can_edit, can_delete = excluded.can_delete;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, m.module_key,
  case
    when r.naam = 'brewer' and m.module_key in ('recipes','ingredients','brewing_planning') then true
    when r.naam = 'brewer' and m.module_key = 'batches' then true
    when r.naam = 'planner' and m.module_key in ('recipes','ingredients','batches','brewing_planning') then true
    when r.naam = 'qa' and m.module_key in ('recipes','ingredients','batches','brewing_planning') then true
    else false
  end as can_view,
  case
    when r.naam = 'brewer' and m.module_key = 'batches' then true
    when r.naam = 'planner' and m.module_key = 'brewing_planning' then true
    when r.naam = 'qa' and m.module_key = 'batches' then true
    else false
  end as can_edit,
  false as can_delete
from public.roles r cross join public.permission_modules m
where r.naam in ('brewer','planner','qa')
  and m.module_key not in ('user_management','role_management')
on conflict (role_id, module_key) do nothing;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, m.module_key, false, false, false
from public.roles r cross join public.permission_modules m
where r.naam in ('brewer','planner','qa') and m.module_key in ('user_management','role_management')
on conflict (role_id, module_key) do nothing;
