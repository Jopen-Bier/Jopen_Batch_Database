-- Batch report: tick off additions per brew and per HBT (Jaap, 22-10).
-- Brewing tab: "Additions brewers" gets a column per brew with a tick box;
-- Processing tab: the processing additions get a column per HBT. A tick is
-- one row in batch_dosing_checks (who and when); untick deletes it.
-- Named "dosing" because batch_ingredients.is_added already means "line
-- added to the batch versus the recipe".
-- batch_brews and batch_ingredients get unique (id, batch_id) so a check is
-- tied to a brew / HBT / ingredient line of its own batch (foreign keys over
-- both columns, as batch_hbts). Additive. Plain ASCII.

begin;

-- 1. Keys over (id, batch_id) ---------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'batch_brews_id_batch_key') then
    alter table public.batch_brews add constraint batch_brews_id_batch_key unique (id, batch_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'batch_ingredients_id_batch_key') then
    alter table public.batch_ingredients add constraint batch_ingredients_id_batch_key unique (id, batch_id);
  end if;
end $$;

-- 2. Ticks ------------------------------------------------------------------------

-- One row per (addition line, brew) or (addition line, HBT): exactly one of
-- batch_brew_id / batch_hbt_id. Deleting the line, the brew or the HBT
-- deletes its ticks.
create table if not exists public.batch_dosing_checks (
  id                  bigint generated always as identity primary key,
  batch_id            bigint not null references public.batches(id) on delete cascade,
  batch_ingredient_id bigint not null,
  batch_brew_id       bigint,
  batch_hbt_id        bigint,
  checked_at          timestamptz not null default now(),
  checked_by          uuid default auth.uid() references public.users(id),
  constraint batch_dosing_checks_one_target check (num_nonnulls(batch_brew_id, batch_hbt_id) = 1),
  constraint batch_dosing_checks_ingredient_fkey foreign key (batch_ingredient_id, batch_id)
    references public.batch_ingredients (id, batch_id) on delete cascade,
  constraint batch_dosing_checks_brew_fkey foreign key (batch_brew_id, batch_id)
    references public.batch_brews (id, batch_id) on delete cascade,
  constraint batch_dosing_checks_hbt_fkey foreign key (batch_hbt_id, batch_id)
    references public.batch_hbts (id, batch_id) on delete cascade,
  constraint batch_dosing_checks_brew_key unique (batch_ingredient_id, batch_brew_id),
  constraint batch_dosing_checks_hbt_key unique (batch_ingredient_id, batch_hbt_id)
);

create index if not exists idx_batch_dosing_checks_batch_id on public.batch_dosing_checks (batch_id);
create index if not exists idx_batch_dosing_checks_brew on public.batch_dosing_checks (batch_brew_id, batch_id);
create index if not exists idx_batch_dosing_checks_hbt on public.batch_dosing_checks (batch_hbt_id, batch_id);
create index if not exists idx_batch_dosing_checks_checked_by on public.batch_dosing_checks (checked_by);

drop trigger if exists trg_batch_dosing_checks_audit on public.batch_dosing_checks;
create trigger trg_batch_dosing_checks_audit after insert or update or delete on public.batch_dosing_checks
  for each row execute function public.log_batch_change();

-- RLS module "batches"; permission checked once per query (see
-- 20261023120000_rls_permission_checks_once). Untick = delete: edit rights,
-- as ticking.
alter table public.batch_dosing_checks enable row level security;
drop policy if exists batch_dosing_checks_select on public.batch_dosing_checks;
drop policy if exists batch_dosing_checks_insert on public.batch_dosing_checks;
drop policy if exists batch_dosing_checks_delete on public.batch_dosing_checks;
create policy batch_dosing_checks_select on public.batch_dosing_checks for select to authenticated using ((select can_view('batches')));
create policy batch_dosing_checks_insert on public.batch_dosing_checks for insert to authenticated with check ((select can_edit('batches')));
create policy batch_dosing_checks_delete on public.batch_dosing_checks for delete to authenticated using ((select can_edit('batches')));
revoke all on public.batch_dosing_checks from anon;

commit;
