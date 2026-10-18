-- Drop the empty, unused table hop_utilization_curve (agreed with Jaap,
-- 18-10-2026). It never had rows and nothing reads it; the hop utilization
-- table that is actually used lives in brew-calculations.js (it depends on
-- boil time and wort SG, which this table could not hold). Its own RLS
-- policies go with it. No CASCADE: nothing depends on it (checked 18-10).
drop table public.hop_utilization_curve;
