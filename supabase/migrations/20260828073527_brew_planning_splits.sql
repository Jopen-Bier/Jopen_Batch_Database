-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Splitsingen van een gepland brouwsel: een bier dat na het brouwen (deels)
-- versneden/geblend wordt tot een ander product (bv. Non Basis -> Non
-- Alcohol IPA), met het hl-volume van elke splitsing. Meerdere rijen per
-- brew_planning_id mogelijk. Zelfde rechtenmodel als brew_planning zelf.
create table if not exists public.brew_planning_splits (
  id uuid primary key default gen_random_uuid(),
  brew_planning_id uuid not null references public.brew_planning(id) on delete cascade,
  recipe_id bigint not null references public.recipes(id),
  recipe_group_id uuid,
  hl numeric not null,
  sort_order integer not null default 0,
  aangemaakt_op timestamptz not null default now()
);

create index if not exists brew_planning_splits_brew_planning_id_idx
  on public.brew_planning_splits(brew_planning_id);

alter table public.brew_planning_splits enable row level security;

create policy brew_planning_splits_select on public.brew_planning_splits
  for select using (mag_bekijken('brewing_planning'::text));

create policy brew_planning_splits_insert on public.brew_planning_splits
  for insert with check (mag_bewerken('brewing_planning'::text));

create policy brew_planning_splits_update on public.brew_planning_splits
  for update using (mag_bewerken('brewing_planning'::text)) with check (mag_bewerken('brewing_planning'::text));

create policy brew_planning_splits_delete on public.brew_planning_splits
  for delete using (mag_verwijderen('brewing_planning'::text));
