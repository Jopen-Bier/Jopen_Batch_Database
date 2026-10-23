-- Statistics becomes Analytics (Jaap, 23-10): the permission module is renamed
-- all the way (key 'statistics' -> 'analytics', name 'Analytics'). Analytics
-- only shows data, so every role gets view and nobody gets edit or delete.
-- role_permissions.module_key has no ON UPDATE CASCADE: add the new module,
-- move the rows, then remove the old module. Idempotent. Plain ASCII.

begin;

insert into public.permission_modules (module_key, name, sort_order)
select 'analytics', 'Analytics', coalesce((select sort_order from public.permission_modules where module_key = 'statistics'), 10)
where not exists (select 1 from public.permission_modules where module_key = 'analytics');

-- Move existing rows that have no 'analytics' row yet.
update public.role_permissions rp set module_key = 'analytics'
where rp.module_key = 'statistics'
  and not exists (select 1 from public.role_permissions x where x.role_id = rp.role_id and x.module_key = 'analytics');

-- A row for every role, view for all, edit / delete for none.
insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, 'analytics', true, false, false from public.roles r
where not exists (select 1 from public.role_permissions x where x.role_id = r.id and x.module_key = 'analytics');

update public.role_permissions set can_view = true, can_edit = false, can_delete = false
where module_key = 'analytics';

delete from public.role_permissions where module_key = 'statistics';
delete from public.permission_modules where module_key = 'statistics';

commit;
