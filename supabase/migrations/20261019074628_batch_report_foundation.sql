-- Batch report, phase 0: foundation (docs/batch-report/data-model.md).
-- Tanks master list, user initials, permission module name, audit log for
-- the batch tables of later phases, and the skeleton of view batch_stages.
-- Additive only, idempotent. One transaction: either everything or nothing.

begin;

-- 1. Tanks ---------------------------------------------------------------

create table if not exists public.tanks (
  id         bigint generated always as identity primary key,
  code       text not null unique,
  tank_type  text not null check (tank_type in ('ckt', 'glt', 'lt', 'hbt')),
  number     integer not null,
  location   text not null check (location in ('wp', 'jk')),
  volume_hl  numeric not null check (volume_hl > 0),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references public.users(id),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users(id)
);

drop trigger if exists trg_tanks_updated_at on public.tanks;
create trigger trg_tanks_updated_at
  before update on public.tanks
  for each row execute function public.set_updated_at();

alter table public.tanks enable row level security;

drop policy if exists tanks_select on public.tanks;
drop policy if exists tanks_insert on public.tanks;
drop policy if exists tanks_update on public.tanks;
drop policy if exists tanks_delete on public.tanks;
create policy tanks_select on public.tanks for select to authenticated using (true);
create policy tanks_insert on public.tanks for insert to authenticated with check (can_edit('settings'));
create policy tanks_update on public.tanks for update to authenticated using (can_edit('settings')) with check (can_edit('settings'));
create policy tanks_delete on public.tanks for delete to authenticated using (can_delete('settings'));

revoke all on public.tanks from anon;

-- Seed: list from Jaap, 15-10 (52 tanks). Assumptions to confirm: all HBTs
-- at WP; a CKT serves both fermentation and lagering.
insert into public.tanks (code, tank_type, number, location, volume_hl)
select upper(t.tank_type) || n, t.tank_type, n, t.location, t.volume_hl
from (values
  -- tank_type, location, first, last, volume_hl
  ('ckt', 'jk',  1,  5,  60),
  ('ckt', 'jk',  6,  6,  20),
  ('ckt', 'jk',  7,  7,  30),
  ('ckt', 'jk',  8,  8,  10),
  ('lt',  'wp', 11, 12,  10),
  ('lt',  'wp', 13, 14,  20),
  ('lt',  'wp', 15, 16,  30),
  ('glt', 'wp', 21, 22,  60),
  ('lt',  'wp', 23, 24,  60),
  ('glt', 'wp', 25, 28,  60),
  ('glt', 'wp', 31, 35, 120),
  ('glt', 'wp', 41, 45, 120),
  ('lt',  'wp', 51, 58, 180),
  ('glt', 'wp', 61, 64, 320),
  ('hbt', 'wp', 11, 12,  30),
  ('hbt', 'wp', 13, 13,  20),
  ('hbt', 'wp', 14, 15,  60),
  ('hbt', 'wp', 16, 18, 120)
) as t(tank_type, location, first_number, last_number, volume_hl)
cross join lateral generate_series(t.first_number, t.last_number) as n
on conflict (code) do nothing;

-- 2. User initials -------------------------------------------------------

alter table public.users add column if not exists initials text;

-- First letter of the first word + first letter of the last word, upper case.
-- A single-word name gives one letter.
create or replace function public.initials_from_name(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(upper(
    left(w[1], 1) ||
    case when cardinality(w) > 1 then left(w[cardinality(w)], 1) else '' end
  ), '')
  from regexp_split_to_array(btrim(coalesce(p_name, '')), '\s+') as w
$$;

-- Empty initials are filled from the name. Initials typed by hand are kept;
-- generated ones follow a change of name.
create or replace function public.set_user_initials()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.initials := nullif(btrim(new.initials), '');
  if tg_op = 'UPDATE'
     and new.name is distinct from old.name
     and new.initials is not distinct from old.initials
     and old.initials is not distinct from initials_from_name(old.name) then
    new.initials := null;
  end if;
  if new.initials is null then
    new.initials := initials_from_name(new.name);
  end if;
  return new;
end;
$$;

revoke execute on function public.set_user_initials() from public, anon, authenticated;

drop trigger if exists trg_users_initials on public.users;
create trigger trg_users_initials
  before insert or update of name, initials on public.users
  for each row execute function public.set_user_initials();

update public.users
set initials = initials_from_name(name)
where initials is null;

-- 3. Permission module name ----------------------------------------------

update public.permission_modules
set name = 'Batches & batch reports'
where module_key = 'batches';

-- 4. Audit log for batch tables -----------------------------------------

-- batch_id is deliberately not a foreign key: the log stays after the batch
-- is deleted.
create table if not exists public.batch_audit_log (
  id         bigint generated always as identity primary key,
  batch_id   bigint,
  table_name text not null,
  row_id     text not null,
  action     text not null check (action in ('insert', 'update', 'delete')),
  old_data   jsonb,
  new_data   jsonb,
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now()
);

create index if not exists idx_batch_audit_log_batch_id
  on public.batch_audit_log (batch_id, changed_at);

alter table public.batch_audit_log enable row level security;

-- Read only; rows are written by log_batch_change() alone.
drop policy if exists batch_audit_log_select on public.batch_audit_log;
create policy batch_audit_log_select on public.batch_audit_log
  for select to authenticated using (can_view('batches'));

revoke all on public.batch_audit_log from anon;
revoke insert, update, delete, truncate on public.batch_audit_log from authenticated;

-- Generic AFTER INSERT/UPDATE/DELETE trigger for every batch table (each
-- phase attaches its own tables). The table must have a batch_id column.
-- row_id = the "id" column, or the columns named as trigger arguments for a
-- composite key, joined with ':'
-- (e.g. ... execute function log_batch_change('entry_id', 'tag_id')).
-- Updates that change nothing are not logged.
create or replace function public.log_batch_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old    jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new    jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_row_id text;
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;

  if tg_nargs = 0 then
    v_row_id := v_row ->> 'id';
  else
    select string_agg(v_row ->> k, ':' order by ord)
    into v_row_id
    from unnest(tg_argv) with ordinality as a(k, ord);
  end if;

  insert into batch_audit_log (batch_id, table_name, row_id, action, old_data, new_data)
  values ((v_row ->> 'batch_id')::bigint, tg_table_name, v_row_id, lower(tg_op), v_old, v_new);

  return null;
end;
$$;

revoke execute on function public.log_batch_change() from public, anon, authenticated;

-- 5. Stage of a batch ----------------------------------------------------

-- Phase 0 version: the process tables do not exist yet, so only
-- completed -> closed, everything else -> raw. Each later phase extends it
-- (business-rules.md, "Stage of a batch").
create or replace view public.batch_stages
with (security_invoker = true)
as
select
  b.id as batch_id,
  case when b.status = 'completed' then 'closed' else 'raw' end as stage,
  null::date as start_date,
  null::date as end_date
from public.batches b;

revoke all on public.batch_stages from anon;
grant select on public.batch_stages to authenticated;

commit;
