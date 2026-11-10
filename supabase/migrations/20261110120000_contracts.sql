-- Contracts (Inventory > Contracts), step 2 (Jaap, 10-11). Additive. Plain ASCII.
--
-- A contract is with one supplier (contract number, start and end date,
-- note) and has lines: ingredient, contracted amount + unit, price per unit.
-- A book-in (lots) counts against one contract line: on insert, a trigger
-- picks it automatically, as agreed for now:
--   same supplier, same ingredient (any version), contract started on the
--   order date (else the received date), unit convertible (g/kg, ml/l, pcs);
--   the oldest line that still has an open amount, else the newest started
--   line (more than contracted may be ordered; open then goes below 0).
-- The end date is not checked yet (contracts that end with an open amount
-- are a later question). Booked and open amounts are computed in the view
-- contract_line_status, never stored. Book-ins from before this change stay
-- unlinked. Rights: the inventory module, like lots.

begin;

create table if not exists public.contracts (
  id bigint generated always as identity primary key,
  supplier text not null references public.suppliers (name) on update cascade,
  contract_number text,
  start_date date not null,
  end_date date not null,
  note text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references public.users (id),
  constraint contracts_period_check check (end_date >= start_date)
);
create index if not exists idx_contracts_supplier on public.contracts (supplier);

create table if not exists public.contract_lines (
  id bigint generated always as identity primary key,
  contract_id bigint not null references public.contracts (id) on delete cascade,
  ingredient_id bigint not null references public.ingredients (id),
  quantity numeric not null constraint contract_lines_quantity_check check (quantity > 0),
  unit text not null constraint contract_lines_unit_check check (unit in ('g', 'kg', 'ml', 'l', 'pcs')),
  price numeric constraint contract_lines_price_check check (price >= 0),
  created_at timestamptz not null default now(),
  constraint contract_lines_key unique (contract_id, ingredient_id)
);
create index if not exists idx_contract_lines_ingredient on public.contract_lines (ingredient_id);
comment on column public.contract_lines.price is 'Price per unit of the line (e.g. EUR per kg).';

alter table public.lots add column if not exists contract_line_id bigint
  constraint lots_contract_line_id_fkey references public.contract_lines (id);
create index if not exists idx_lots_contract_line on public.lots (contract_line_id);
comment on column public.lots.contract_line_id is 'Contract line this book-in counts against; set on insert by lots_pick_contract_line().';

do $$
declare t text;
begin
  foreach t in array array['contracts', 'contract_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select can_view(''inventory'')))', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select can_edit(''inventory'')))', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select can_edit(''inventory''))) with check ((select can_edit(''inventory'')))', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select can_delete(''inventory'')))', t || '_delete', t);
  end loop;
end $$;

-- q in unit p_from expressed in p_to; null when the units do not convert.
create or replace function public.convert_quantity(q numeric, p_from text, p_to text)
returns numeric language sql immutable set search_path to 'public' as $$
  select case
    when p_from = p_to then q
    when p_from = 'g' and p_to = 'kg' then q / 1000
    when p_from = 'kg' and p_to = 'g' then q * 1000
    when p_from = 'ml' and p_to = 'l' then q / 1000
    when p_from = 'l' and p_to = 'ml' then q * 1000
  end;
$$;

create or replace view public.contract_line_status with (security_invoker = true) as
select cl.id, cl.contract_id, cl.ingredient_id, i.ingredient_group_id, cl.quantity, cl.unit, cl.price,
       c.supplier, c.contract_number, c.start_date, c.end_date,
       coalesce(sum(public.convert_quantity(l.quantity_received, coalesce(l.unit, cl.unit), cl.unit)), 0) as booked,
       cl.quantity - coalesce(sum(public.convert_quantity(l.quantity_received, coalesce(l.unit, cl.unit), cl.unit)), 0) as open,
       count(l.id) as book_ins
from public.contract_lines cl
join public.contracts c on c.id = cl.contract_id
join public.ingredients i on i.id = cl.ingredient_id
left join public.lots l on l.contract_line_id = cl.id
group by cl.id, i.ingredient_group_id, c.id;

-- The contract line a book-in counts against (rule in the header), or null.
create or replace function public.pick_contract_line(p_supplier text, p_ingredient_id bigint, p_date date, p_unit text)
returns bigint language sql stable set search_path to 'public' as $$
  with candidates as (
    select s.id, s.open, s.start_date
    from contract_line_status s
    join ingredients i on i.id = p_ingredient_id
    where s.supplier = p_supplier
      and s.ingredient_group_id = i.ingredient_group_id
      and s.start_date <= coalesce(p_date, current_date)
      and convert_quantity(1, coalesce(p_unit, s.unit), s.unit) is not null
  )
  select coalesce(
    (select id from candidates where open > 0 order by start_date, id limit 1),
    (select id from candidates order by start_date desc, id desc limit 1));
$$;
grant execute on function public.pick_contract_line(text, bigint, date, text) to authenticated;

create or replace function public.lots_pick_contract_line()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.contract_line_id is null and new.supplier is not null then
    new.contract_line_id := pick_contract_line(new.supplier, new.ingredient_id,
      coalesce(new.order_date, new.received_date), new.unit);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_lots_pick_contract_line on public.lots;
create trigger trg_lots_pick_contract_line before insert on public.lots
  for each row execute function public.lots_pick_contract_line();

commit;
