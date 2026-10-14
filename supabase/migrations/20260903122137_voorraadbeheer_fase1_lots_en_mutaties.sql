-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Fase Voorraadbeheer: grondstof_lots (ontvangst) + voorraad_mutaties (ledger)

create table if not exists public.grondstof_lots (
  id bigint generated always as identity primary key,
  ingredient_id bigint not null references public.ingredients(id),
  leverancier text,
  lotcode text,
  ontvangstdatum date not null default current_date,
  hoeveelheid_ontvangen numeric not null,
  eenheid text,
  aantal_colli text,
  locatie text,
  ontvangstcontrole boolean not null default false,
  ingangscontrole boolean not null default false,
  tht_datum date,
  alpha_pct numeric,
  status text not null default 'actief' check (status in ('actief','leeg','afgesloten')),
  document_pad text,
  notitie text,
  aangemaakt_door uuid references auth.users(id),
  aangemaakt_op timestamptz not null default now()
);

create index if not exists idx_grondstof_lots_ingredient on public.grondstof_lots(ingredient_id);
create index if not exists idx_grondstof_lots_status on public.grondstof_lots(status);

create table if not exists public.voorraad_mutaties (
  id bigint generated always as identity primary key,
  lot_id bigint references public.grondstof_lots(id),
  type text not null check (type in ('ontvangst','reservering','uitboeking','correctie')),
  hoeveelheid numeric not null,
  batch_id bigint references public.batches(id),
  recipe_ingredient_id bigint references public.recipe_ingredients(id),
  notitie text,
  geboekt_in_boekhouding boolean not null default false,
  geboekt_door uuid references auth.users(id),
  geboekt_op timestamptz,
  aangemaakt_door uuid references auth.users(id),
  aangemaakt_op timestamptz not null default now()
);

create index if not exists idx_voorraad_mutaties_lot on public.voorraad_mutaties(lot_id);
create index if not exists idx_voorraad_mutaties_batch on public.voorraad_mutaties(batch_id);
create index if not exists idx_voorraad_mutaties_type on public.voorraad_mutaties(type);

-- Permissiemodule + matrix-seed (view voor iedereen, edit voor admin/head brewer/brewer, delete admin-only)
insert into public.permission_modules (module_key, naam, volgorde)
values ('inventory', 'Inventory', 9)
on conflict (module_key) do nothing;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, 'inventory',
  true as can_view,
  (r.naam in ('admin','Head brewer','Brewer')) as can_edit,
  (r.naam = 'admin') as can_delete
from public.roles r
where r.naam not like 'Nieuwe rol%'
on conflict (role_id, module_key) do nothing;

insert into public.role_permissions (role_id, module_key, can_view, can_edit, can_delete)
select r.id, 'inventory', false, false, false
from public.roles r
where r.naam like 'Nieuwe rol%'
on conflict (role_id, module_key) do nothing;

-- RLS
alter table public.grondstof_lots enable row level security;
alter table public.voorraad_mutaties enable row level security;

create policy grondstof_lots_select on public.grondstof_lots
  for select using (mag_bekijken('inventory'::text));
create policy grondstof_lots_insert on public.grondstof_lots
  for insert with check (mag_bewerken('inventory'::text));
create policy grondstof_lots_update on public.grondstof_lots
  for update using (mag_bewerken('inventory'::text)) with check (mag_bewerken('inventory'::text));
create policy grondstof_lots_delete on public.grondstof_lots
  for delete using (mag_verwijderen('inventory'::text));

create policy voorraad_mutaties_select on public.voorraad_mutaties
  for select using (mag_bekijken('inventory'::text));
create policy voorraad_mutaties_insert on public.voorraad_mutaties
  for insert with check (mag_bewerken('inventory'::text));
create policy voorraad_mutaties_update on public.voorraad_mutaties
  for update using (mag_bewerken('inventory'::text)) with check (mag_bewerken('inventory'::text));
create policy voorraad_mutaties_delete on public.voorraad_mutaties
  for delete using (mag_verwijderen('inventory'::text));
