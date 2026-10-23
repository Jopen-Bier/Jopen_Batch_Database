-- batch_volume_balance: the volume balance of the Filling report per batch,
-- for Recipe analytics > Losses (one query for all batches instead of
-- loading every batch's brews, HBT readings, transfers and bookings).
-- Same rules as filling-report.js volumeBalance() + batch-brews.js
-- brewCalculations() + processing.js hbtEnd() (business-rules.md, "Filling
-- report - volume balance"); tests/recipe-losses.test.js pins the JS side,
-- the column names here are what recipe-losses.js reads.
--   glt_hl            sum of volume to GLT (brew volume + water addition) of
--                     brews with a brew volume and a whirlpool extract
--   incoming_hl       beer received from splits (batch_stages)
--   splits_before_hl  transfers out from a tank that is not one of the
--                     batch's HBTs (from GLT / LT)
--   in_hbt_hl         sum of the HBT end values (last reading with a level)
--   splits_after_hl   transfers out from one of the batch's HBTs
--   *_hl per package  filling_session_articles count x litres per article
-- Losses are derived from these in recipe-losses.js. Additive (new view).
-- security_invoker: readers see only batches their role may view.

create or replace view public.batch_volume_balance
with (security_invoker = true)
as
with glt as (
  select bb.batch_id, sum(bb.brew_volume_hl + coalesce(bb.water_addition_hl, 0)) as glt_hl
  from public.batch_brews bb
  where bb.brew_volume_hl is not null and bb.whirlpool_extract is not null
    and bb.brew_volume_hl + coalesce(bb.water_addition_hl, 0) <> 0
  group by bb.batch_id
),
hbt_end as (
  select h.batch_id, h.tank_id,
    (select r.level_hl from public.hbt_readings r
     where r.batch_hbt_id = h.id and r.level_hl is not null
     order by r.sort_order desc, r.id desc limit 1) as end_hl
  from public.batch_hbts h
),
hbt as (
  select batch_id, sum(coalesce(end_hl, 0)) as in_hbt_hl,
    count(*) filter (where end_hl is null)::int as hbts_without_level
  from hbt_end group by batch_id
),
transfers as (
  select t.batch_id,
    coalesce(sum(t.volume_hl) filter (where not exists (
      select 1 from public.batch_hbts h where h.batch_id = t.batch_id and h.tank_id = t.from_tank_id)), 0) as splits_before_hl,
    coalesce(sum(t.volume_hl) filter (where exists (
      select 1 from public.batch_hbts h where h.batch_id = t.batch_id and h.tank_id = t.from_tank_id)), 0) as splits_after_hl
  from public.batch_transfers t group by t.batch_id
),
packaged as (
  select a.batch_id,
    coalesce(sum(a.quantity * pa.liters_per_unit) filter (where pa.package_format = 'bottle'), 0) / 100 as bottle_hl,
    coalesce(sum(a.quantity * pa.liters_per_unit) filter (where pa.package_format = 'can'), 0) / 100 as can_hl,
    coalesce(sum(a.quantity * pa.liters_per_unit) filter (where pa.package_format = 'keg'), 0) / 100 as keg_hl,
    coalesce(sum(a.quantity * pa.liters_per_unit) filter (where pa.package_format = 'tank'), 0) / 100 as tank_hl
  from public.filling_session_articles a
  join public.packaging_articles pa on pa.id = a.article_id
  group by a.batch_id
)
select
  b.id as batch_id,
  b.batch_number,
  b.recipe_id,
  r.recipe_group_id,
  s.stage,
  b.brew_count,
  case when b.batch_number ~ '^[0-9]{5}$' then 2000 + left(b.batch_number, 2)::int
       else extract(year from b.created_at)::int end as batch_year,
  glt.glt_hl,
  coalesce(s.incoming_volume_hl, 0) as incoming_hl,
  coalesce(tr.splits_before_hl, 0) as splits_before_hl,
  coalesce(hbt.in_hbt_hl, 0) as in_hbt_hl,
  coalesce(hbt.hbts_without_level, 0) as hbts_without_level,
  coalesce(tr.splits_after_hl, 0) as splits_after_hl,
  coalesce(pk.bottle_hl, 0) as bottle_hl,
  coalesce(pk.can_hl, 0) as can_hl,
  coalesce(pk.keg_hl, 0) as keg_hl,
  coalesce(pk.tank_hl, 0) as tank_hl
from public.batches b
join public.recipes r on r.id = b.recipe_id
join public.batch_stages s on s.batch_id = b.id
left join glt on glt.batch_id = b.id
left join hbt on hbt.batch_id = b.id
left join transfers tr on tr.batch_id = b.id
left join packaged pk on pk.batch_id = b.id;

grant select on public.batch_volume_balance to authenticated;
