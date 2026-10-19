-- Batch report, phase 2: Overview (docs/batch-report/data-model.md).
-- Order picking complete on batches, and the ingredient snapshot per batch
-- (batch_ingredients) with its snapshot function, the trigger for new
-- batches and the backfill of the planned batches.
-- Additive only, idempotent. One transaction: either everything or nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * is_added marks rows added in this batch. recipe_ingredient_id is only a
--   trace: recept-invoer.html deletes and re-inserts all recipe lines on
--   every save, so the link is lost (set null) after the next recipe save.
-- * ingredient_id may be empty: 51 recipe lines have no ingredient (notes
--   such as a blend with another beer); they are copied with their note.

begin;

-- 1. Order picking complete ---------------------------------------------

alter table public.batches add column if not exists order_picking_completed_at timestamptz;
alter table public.batches add column if not exists order_picking_completed_by uuid references public.users(id);

-- 2. Ingredient snapshot per batch ---------------------------------------

create table if not exists public.batch_ingredients (
  id                   bigint generated always as identity primary key,
  batch_id             bigint not null references public.batches(id) on delete cascade,
  recipe_ingredient_id bigint references public.recipe_ingredients(id) on delete set null,
  ingredient_id        bigint references public.ingredients(id),
  is_added             boolean not null default false,
  addition_type        text not null check (addition_type in
                         ('malt', 'boil_hop', 'dry_hop', 'brewhouse_addition', 'cellar_addition', 'yeast')),
  timing               text,
  unit                 text,
  sort_order           integer,
  recipe_quantity      numeric,
  quantity             numeric,
  recipe_alpha_pct     numeric,
  alpha_pct            numeric,
  recipe_color_ebc     numeric,
  color_ebc            numeric,
  hop_dosing_tank      integer,
  all_in_first_brew    boolean not null default false,
  note                 text,
  is_removed           boolean not null default false,
  deviation_reason     text,
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid() references public.users(id),
  updated_at           timestamptz not null default now(),
  updated_by           uuid references public.users(id),
  -- a row added in the batch is always a real ingredient
  constraint batch_ingredients_added_has_ingredient check (not is_added or ingredient_id is not null)
);

create index if not exists idx_batch_ingredients_batch_id             on public.batch_ingredients (batch_id);
create index if not exists idx_batch_ingredients_recipe_ingredient_id on public.batch_ingredients (recipe_ingredient_id);
create index if not exists idx_batch_ingredients_ingredient_id        on public.batch_ingredients (ingredient_id);

drop trigger if exists trg_batch_ingredients_updated_at on public.batch_ingredients;
create trigger trg_batch_ingredients_updated_at
  before update on public.batch_ingredients
  for each row execute function public.set_updated_at();

drop trigger if exists trg_batch_ingredients_audit on public.batch_ingredients;
create trigger trg_batch_ingredients_audit
  after insert or update or delete on public.batch_ingredients
  for each row execute function public.log_batch_change();

alter table public.batch_ingredients enable row level security;

drop policy if exists batch_ingredients_select on public.batch_ingredients;
drop policy if exists batch_ingredients_insert on public.batch_ingredients;
drop policy if exists batch_ingredients_update on public.batch_ingredients;
drop policy if exists batch_ingredients_delete on public.batch_ingredients;
create policy batch_ingredients_select on public.batch_ingredients for select to authenticated using (can_view('batches'));
create policy batch_ingredients_insert on public.batch_ingredients for insert to authenticated with check (can_edit('batches'));
create policy batch_ingredients_update on public.batch_ingredients for update to authenticated using (can_edit('batches')) with check (can_edit('batches'));
create policy batch_ingredients_delete on public.batch_ingredients for delete to authenticated using (can_delete('batches'));

revoke all on public.batch_ingredients from anon;

-- 3. Snapshot function -----------------------------------------------------

-- Copies the recipe lines of the batch's recipe into batch_ingredients, only
-- when the batch has no rows yet. Returns the number of rows created (0 when
-- the snapshot already existed). Called by the trigger on new batches and by
-- batch-overview.html when an older batch is opened for the first time; runs
-- as definer so a view-only user opening a batch still gets its snapshot.
create or replace function public.snapshot_batch_ingredients(p_batch_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if auth.uid() is not null and not can_view('batches') then
    raise exception 'no access to batches' using errcode = '42501';
  end if;

  -- two users opening the same batch at once must not both copy
  perform pg_advisory_xact_lock(hashtext('snapshot_batch_ingredients'), p_batch_id::integer);

  if exists (select 1 from batch_ingredients where batch_id = p_batch_id) then
    return 0;
  end if;

  insert into batch_ingredients (
    batch_id, recipe_ingredient_id, ingredient_id, addition_type, timing, unit, sort_order,
    recipe_quantity, quantity, recipe_alpha_pct, alpha_pct, recipe_color_ebc, color_ebc,
    hop_dosing_tank, all_in_first_brew, note)
  select b.id, ri.id, ri.ingredient_id, ri.addition_type, ri.timing, ri.unit, ri.sort_order,
         ri.quantity, ri.quantity, ri.alpha_pct, ri.alpha_pct, ri.color_ebc, ri.color_ebc,
         ri.hop_dosing_tank, ri.all_in_first_brew, ri.note
  from batches b
  join recipe_ingredients ri on ri.recipe_id = b.recipe_id
  where b.id = p_batch_id
  order by ri.addition_type, ri.sort_order, ri.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.snapshot_batch_ingredients(bigint) from public, anon;
grant execute on function public.snapshot_batch_ingredients(bigint) to authenticated;

-- 4. Snapshot for every new batch (batchcreation.html needs no change) -----

create or replace function public.snapshot_new_batch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform snapshot_batch_ingredients(new.id);
  return null;
end;
$$;

revoke execute on function public.snapshot_new_batch() from public, anon, authenticated;

drop trigger if exists trg_batches_snapshot_ingredients on public.batches;
create trigger trg_batches_snapshot_ingredients
  after insert on public.batches
  for each row execute function public.snapshot_new_batch();

-- 5. Backfill: every planned batch -----------------------------------------

select public.snapshot_batch_ingredients(b.id)
from public.batches b
where b.status = 'planned'
order by b.id;

commit;
