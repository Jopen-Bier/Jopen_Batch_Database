-- Wishlist October 2026 (docs/wishlist-2026-10.md): new nullable columns.
-- #14 flow and turbidity per HBT reading (Processing).
-- #17 recipe boil time (target for the brew log "Total boil time").
-- #11 actual wort cooling temperature per brew (setpoint: recipe pitching_temp).
-- #28 filling checks signed by operators chosen from a list; the existing
--     booleans stay and are set together with the names by the page.
-- #22 brews on the first brewing day, once per batch: used by the yeast and
--     the zinc sulphate calculator on Brewing.
-- Additive only; existing RLS policies of these tables cover the columns.

alter table public.hbt_readings add column if not exists flow_hl_h numeric;
alter table public.hbt_readings add column if not exists turbidity_ebc numeric;

alter table public.recipe_brewing_specs add column if not exists boil_time_min numeric;

alter table public.batch_brews add column if not exists wort_cooling_temp_c numeric;

alter table public.filling_sessions add column if not exists first_package_checked_by uuid
  constraint filling_sessions_first_package_checked_by_fkey references public.users(id);
alter table public.filling_sessions add column if not exists first_package_checked_by_2 uuid
  constraint filling_sessions_first_package_checked_by_2_fkey references public.users(id);
alter table public.filling_sessions add column if not exists fill_tube_checked_first_by uuid
  constraint filling_sessions_fill_tube_checked_first_by_fkey references public.users(id);
alter table public.filling_sessions add column if not exists fill_tube_checked_end_by uuid
  constraint filling_sessions_fill_tube_checked_end_by_fkey references public.users(id);
alter table public.filling_sessions add column if not exists burst_bottles_controlled_by uuid
  constraint filling_sessions_burst_bottles_controlled_by_fkey references public.users(id);

alter table public.batches add column if not exists first_day_brew_count integer;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'batches_first_day_brew_count_check') then
    alter table public.batches add constraint batches_first_day_brew_count_check check (first_day_brew_count > 0);
  end if;
end $$;
