-- Suppliers become a fixed list (Settings > General > Suppliers), step 1 of
-- the Contracts work (Jaap, 10-11). Plain ASCII.
--
-- 1. Clean up the free-text supplier names on lots and ingredients
--    (supplier, supplier_2, supplier_3), as agreed with Jaap:
--      SBI/Sbi/SBi -> SBI, Barth Haas -> BarthHaas, hvb -> HVB,
--      weyermann -> Weyermann, lallemand -> Lallemand,
--      Brouw maatje -> Brouwmaatje, WHC -> WHC Labs,
--      YCH/Yakima -> Yakima Chief Hops, '-' -> empty,
--      'Dingemans or Steinbach' -> Dingemans (1) + Steinbach (2).
--    A supplier 2 or 3 that repeats an earlier one of the same ingredient
--    (and has no price) is cleared.
-- 2. public.suppliers holds every name left; readable by everyone logged in,
--    edited with settings rights, like the other reference lists.
-- 3. The supplier columns keep their text, but now reference
--    suppliers(name) with ON UPDATE CASCADE: only listed names can be
--    stored, and a rename in Settings applies everywhere. A supplier in use
--    cannot be deleted (only made inactive).
-- 4. lots gets order_date and order_number, filled on Book in material.

begin;

-- 1. Cleanup ---------------------------------------------------------------

create temporary table supplier_rename (old_name text primary key, new_name text) on commit drop;
insert into supplier_rename (old_name, new_name) values
  ('Sbi', 'SBI'), ('SBi', 'SBI'),
  ('Barth Haas', 'BarthHaas'),
  ('hvb', 'HVB'),
  ('weyermann', 'Weyermann'),
  ('lallemand', 'Lallemand'),
  ('Brouw maatje', 'Brouwmaatje'),
  ('WHC', 'WHC Labs'),
  ('YCH', 'Yakima Chief Hops'), ('Yakima', 'Yakima Chief Hops'),
  ('-', null);

update public.lots l set supplier = r.new_name
  from supplier_rename r where l.supplier = r.old_name;
update public.ingredients i set supplier = r.new_name
  from supplier_rename r where i.supplier = r.old_name;
update public.ingredients i set supplier_2 = r.new_name
  from supplier_rename r where i.supplier_2 = r.old_name;
update public.ingredients i set supplier_3 = r.new_name
  from supplier_rename r where i.supplier_3 = r.old_name;

update public.ingredients
  set supplier = 'Dingemans', supplier_2 = 'Steinbach'
  where supplier = 'Dingemans or Steinbach' and supplier_2 is null;

update public.ingredients set supplier_2 = null
  where supplier_2 = supplier and price_2 is null;
update public.ingredients set supplier_3 = null
  where (supplier_3 = supplier or supplier_3 = supplier_2) and price_3 is null;

-- 2. The list --------------------------------------------------------------

create table if not exists public.suppliers (
  id bigint generated always as identity primary key,
  name text not null constraint suppliers_name_check check (btrim(name) <> ''),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint suppliers_name_key unique (name)
);
create unique index if not exists suppliers_name_lower_key on public.suppliers (lower(name));

alter table public.suppliers enable row level security;
drop policy if exists suppliers_select on public.suppliers;
create policy suppliers_select on public.suppliers for select to authenticated using (true);
drop policy if exists suppliers_insert on public.suppliers;
create policy suppliers_insert on public.suppliers for insert to authenticated with check ((select can_edit('settings')));
drop policy if exists suppliers_update on public.suppliers;
create policy suppliers_update on public.suppliers for update to authenticated using ((select can_edit('settings'))) with check ((select can_edit('settings')));
drop policy if exists suppliers_delete on public.suppliers;
create policy suppliers_delete on public.suppliers for delete to authenticated using ((select can_delete('settings')));

insert into public.suppliers (name)
select distinct s from (
  select supplier s from public.lots
  union select supplier from public.ingredients
  union select supplier_2 from public.ingredients
  union select supplier_3 from public.ingredients
) x
where s is not null
on conflict (name) do nothing;

-- 3. Links -----------------------------------------------------------------

alter table public.lots
  add constraint lots_supplier_fkey foreign key (supplier) references public.suppliers (name) on update cascade;
alter table public.ingredients
  add constraint ingredients_supplier_fkey foreign key (supplier) references public.suppliers (name) on update cascade,
  add constraint ingredients_supplier_2_fkey foreign key (supplier_2) references public.suppliers (name) on update cascade,
  add constraint ingredients_supplier_3_fkey foreign key (supplier_3) references public.suppliers (name) on update cascade;
create index if not exists idx_lots_supplier on public.lots (supplier);

-- 4. Order fields on a book-in ---------------------------------------------

alter table public.lots
  add column if not exists order_date date,
  add column if not exists order_number text;
comment on column public.lots.order_date is 'Date the material was ordered (Book in material). Decides which contract a book-in counts against.';
comment on column public.lots.order_number is 'Order number at the supplier (Book in material).';

commit;
