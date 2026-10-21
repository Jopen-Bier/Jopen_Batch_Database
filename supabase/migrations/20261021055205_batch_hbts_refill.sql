-- Batch report, phase 8 follow-up (Jaap, 21-10): the same HBT can be used
-- more than once on one batch (processing over several days: the tank is
-- filled, emptied and filled again). One batch_hbts row per fill, each with
-- its own readings and end value; the pages name a refilled tank with the
-- day it was filled ("HBT16 . 01-10").
-- Drops the uniqueness per (batch, tank) and keeps a plain index on
-- (batch_id, tank_id) for the lookups the unique index served. Nothing
-- references the dropped constraint (foreign keys use (id, batch_id)).
-- Plain ASCII.

begin;

alter table public.batch_hbts drop constraint if exists batch_hbts_batch_tank_key;
create index if not exists idx_batch_hbts_batch_tank on public.batch_hbts (batch_id, tank_id);

commit;
