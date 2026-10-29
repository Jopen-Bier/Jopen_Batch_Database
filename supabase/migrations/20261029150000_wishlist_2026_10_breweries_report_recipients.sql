-- Wishlist October 2026 (docs/wishlist-2026-10.md), part 2. Additive.
-- #18 Breweries: an editable list (Settings > Breweries) and the brewery of
--     a recipe (General tab). Readable by everyone logged in, edited with
--     settings rights, like the other reference lists.
-- #30 Report recipients: per user the reports they receive (Users page);
--     report_recipients() gives the e-mail addresses (auth.users) of the
--     active users on a report, for whoever may view batches.

create table if not exists public.breweries (
  id bigint generated always as identity primary key,
  name text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists breweries_name_key on public.breweries (lower(name));

alter table public.breweries enable row level security;
drop policy if exists breweries_select on public.breweries;
create policy breweries_select on public.breweries for select to authenticated using (true);
drop policy if exists breweries_insert on public.breweries;
create policy breweries_insert on public.breweries for insert to authenticated with check ((select can_edit('settings')));
drop policy if exists breweries_update on public.breweries;
create policy breweries_update on public.breweries for update to authenticated using ((select can_edit('settings'))) with check ((select can_edit('settings')));
drop policy if exists breweries_delete on public.breweries;
create policy breweries_delete on public.breweries for delete to authenticated using ((select can_delete('settings')));

alter table public.recipes add column if not exists brewery_id bigint
  constraint recipes_brewery_id_fkey references public.breweries(id);
create index if not exists idx_recipes_brewery_id on public.recipes (brewery_id);

alter table public.users add column if not exists report_subscriptions text[] not null default '{}';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'users_report_subscriptions_check') then
    alter table public.users add constraint users_report_subscriptions_check
      check (report_subscriptions <@ array['processing']::text[]);
  end if;
end $$;

create or replace function public.report_recipients(p_report text)
returns table(name text, email text)
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  if not can_view('batches') then
    raise exception 'Not authorized';
  end if;
  return query
    select u.name, au.email::text
    from users u join auth.users au on au.id = u.id
    where u.is_active and p_report = any (u.report_subscriptions) and au.email is not null
    order by u.name;
end;
$$;
revoke all on function public.report_recipients(text) from public;
grant execute on function public.report_recipients(text) to authenticated;
