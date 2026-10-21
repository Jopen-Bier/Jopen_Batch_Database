-- Brewing: a brew can be started and finished by different people (Jaap,
-- 21-10; the Excel brew sheet already had a second name next to the brewer).
-- brewer_id stays and becomes "Brewer start"; brewer_end_id is "Brewer end".
-- Additive, nothing existing changes. RLS and the audit trigger are on the
-- table and cover the new column. Plain ASCII.

begin;

alter table public.batch_brews
  add column if not exists brewer_end_id uuid references public.users(id);

comment on column public.batch_brews.brewer_id is 'Brewer start';
comment on column public.batch_brews.brewer_end_id is 'Brewer end';

commit;
