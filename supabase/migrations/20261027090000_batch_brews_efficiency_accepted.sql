-- Brewhouse efficiency outside 70-100% stays a data check (Jaap, 27-10), but a
-- brew that is checked and right (e.g. a high-gravity brew at 60%) can be
-- marked as good with a reason. It then counts again and leaves the warning
-- list. Who may mark: whoever may edit batches (existing batch_brews policies).
-- Additive: three nullable columns, a check, an index. Plain ASCII.

alter table public.batch_brews add column if not exists efficiency_accepted_at timestamptz;
alter table public.batch_brews add column if not exists efficiency_accepted_by uuid references public.users(id);
alter table public.batch_brews add column if not exists efficiency_accepted_reason text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'batch_brews_efficiency_accepted_check') then
    alter table public.batch_brews add constraint batch_brews_efficiency_accepted_check check (
      (efficiency_accepted_at is null and efficiency_accepted_by is null and efficiency_accepted_reason is null)
      or (efficiency_accepted_at is not null and efficiency_accepted_by is not null and nullif(btrim(efficiency_accepted_reason), '') is not null)
    );
  end if;
end $$;

create index if not exists idx_batch_brews_efficiency_accepted_by on public.batch_brews (efficiency_accepted_by);
