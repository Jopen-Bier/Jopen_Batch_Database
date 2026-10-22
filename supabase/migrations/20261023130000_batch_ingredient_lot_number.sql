-- Lot numbers in the batch report (Jaap, 23-10): typed in by hand per
-- ingredient on the Overview, as in the Excel batch report. The link to the
-- stock module (lots, stock_movements) comes later; until then a lot booked
-- out in stock only shows as the placeholder. Additive. Plain ASCII.

alter table public.batch_ingredients add column if not exists lot_number text;
