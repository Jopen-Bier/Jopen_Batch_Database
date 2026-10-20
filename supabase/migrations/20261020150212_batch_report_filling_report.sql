-- Batch report, phase 7: Filling report (docs/batch-report/data-model.md).
-- Packaging master data (articles = SKUs, materials, bill of materials per
-- article; Settings) and per filling session the articles produced (book in)
-- and the materials used (book out). One transaction: either everything or
-- nothing.
--
-- Differences from data-model.md (reasons in the PR):
-- * Master data gets sort_order (Settings order) and the usual created_ /
--   updated_ columns; packaging_article_materials gets an id and unique
--   (article_id, material_id).
-- * Session articles / materials: unique per session (one row per article,
--   one per material); quantity may be empty while being entered; tied to the
--   same batch as their session (foreign key over both columns, cascade).
-- * Seed: the articles, materials and bill of materials of the mockup
--   FillingReport.dc.html (Jaap checks / completes them in Settings).
-- * Not created (parked, open-questions #8): filling_comment, Mdrank and
--   completed / signed columns on batches.

begin;

-- The texts below contain ·: stop when the script was not read as UTF-8.
do $$ begin
  if length('·') <> 1 or '·' <> chr(183) then
    raise exception 'This script was not read as UTF-8; nothing was changed';
  end if;
end $$;

-- 1. Packaging master data (Settings) ----------------------------------------

create table if not exists public.packaging_materials (
  id                    bigint generated always as identity primary key,
  code                  text not null unique check (code ~ '^[a-z0-9_]+$'),
  name                  text not null,
  unit                  text not null default 'pcs',
  mdrank_article_number text,
  sort_order            integer not null default 0,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.users(id),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.users(id)
);

create table if not exists public.packaging_articles (
  id                    bigint generated always as identity primary key,
  code                  text not null unique check (code ~ '^[a-z0-9_]+$'),
  name                  text not null,
  package_format        text not null check (package_format in ('bottle', 'can', 'keg')),
  liters_per_unit       numeric not null check (liters_per_unit > 0),
  ean                   text,
  mdrank_article_number text,
  sort_order            integer not null default 0,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now(),
  created_by            uuid default auth.uid() references public.users(id),
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.users(id)
);

-- Bill of materials: quantity of a material per article. A material in use
-- cannot be deleted (no cascade); deleting an article removes its BOM.
create table if not exists public.packaging_article_materials (
  id          bigint generated always as identity primary key,
  article_id  bigint not null references public.packaging_articles(id) on delete cascade,
  material_id bigint not null references public.packaging_materials(id),
  quantity    numeric not null check (quantity > 0),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid() references public.users(id),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.users(id),
  constraint packaging_article_materials_key unique (article_id, material_id)
);

create index if not exists idx_packaging_article_materials_material on public.packaging_article_materials (material_id);

-- 2. Per filling session: produced (book in) and used (book out) -------------

create table if not exists public.filling_session_articles (
  id                 bigint generated always as identity primary key,
  batch_id           bigint not null,
  filling_session_id bigint not null,
  article_id         bigint not null references public.packaging_articles(id),
  quantity           numeric check (quantity >= 0),
  created_at         timestamptz not null default now(),
  created_by         uuid default auth.uid() references public.users(id),
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.users(id),
  constraint filling_session_articles_key unique (filling_session_id, article_id),
  constraint filling_session_articles_session_fkey foreign key (filling_session_id, batch_id)
    references public.filling_sessions (id, batch_id) on delete cascade
);

create index if not exists idx_filling_session_articles_batch_id on public.filling_session_articles (batch_id);
create index if not exists idx_filling_session_articles_session on public.filling_session_articles (filling_session_id, batch_id);
create index if not exists idx_filling_session_articles_article on public.filling_session_articles (article_id);

create table if not exists public.filling_session_materials (
  id                 bigint generated always as identity primary key,
  batch_id           bigint not null,
  filling_session_id bigint not null,
  material_id        bigint not null references public.packaging_materials(id),
  quantity           numeric check (quantity >= 0),
  created_at         timestamptz not null default now(),
  created_by         uuid default auth.uid() references public.users(id),
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.users(id),
  constraint filling_session_materials_key unique (filling_session_id, material_id),
  constraint filling_session_materials_session_fkey foreign key (filling_session_id, batch_id)
    references public.filling_sessions (id, batch_id) on delete cascade
);

create index if not exists idx_filling_session_materials_batch_id on public.filling_session_materials (batch_id);
create index if not exists idx_filling_session_materials_session on public.filling_session_materials (filling_session_id, batch_id);
create index if not exists idx_filling_session_materials_material on public.filling_session_materials (material_id);

-- 3. Triggers, RLS, grants ---------------------------------------------------

do $$
declare
  t text;
begin
  -- Batch tables: updated_at, audit trail, module "batches".
  foreach t in array array['filling_session_articles', 'filling_session_materials'] loop
    execute format('drop trigger if exists trg_%1$s_updated_at on public.%1$I', t);
    execute format('create trigger trg_%1$s_updated_at before update on public.%1$I
                    for each row execute function public.set_updated_at()', t);
    execute format('drop trigger if exists trg_%1$s_audit on public.%1$I', t);
    execute format('create trigger trg_%1$s_audit after insert or update or delete on public.%1$I
                    for each row execute function public.log_batch_change()', t);

    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %1$s_select on public.%1$I', t);
    execute format('drop policy if exists %1$s_insert on public.%1$I', t);
    execute format('drop policy if exists %1$s_update on public.%1$I', t);
    execute format('drop policy if exists %1$s_delete on public.%1$I', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated using (can_view(''batches''))', t);
    execute format('create policy %1$s_insert on public.%1$I for insert to authenticated with check (can_edit(''batches''))', t);
    execute format('create policy %1$s_update on public.%1$I for update to authenticated using (can_edit(''batches'')) with check (can_edit(''batches''))', t);
    execute format('create policy %1$s_delete on public.%1$I for delete to authenticated using (can_delete(''batches''))', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;

  -- Master data: everyone logged in reads, Settings writes (as tanks and tags).
  foreach t in array array['packaging_materials', 'packaging_articles', 'packaging_article_materials'] loop
    execute format('drop trigger if exists trg_%1$s_updated_at on public.%1$I', t);
    execute format('create trigger trg_%1$s_updated_at before update on public.%1$I
                    for each row execute function public.set_updated_at()', t);

    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %1$s_select on public.%1$I', t);
    execute format('drop policy if exists %1$s_insert on public.%1$I', t);
    execute format('drop policy if exists %1$s_update on public.%1$I', t);
    execute format('drop policy if exists %1$s_delete on public.%1$I', t);
    execute format('create policy %1$s_select on public.%1$I for select to authenticated using (true)', t);
    execute format('create policy %1$s_insert on public.%1$I for insert to authenticated with check (can_edit(''settings''))', t);
    execute format('create policy %1$s_update on public.%1$I for update to authenticated using (can_edit(''settings'')) with check (can_edit(''settings''))', t);
    execute format('create policy %1$s_delete on public.%1$I for delete to authenticated using (can_delete(''settings''))', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- 4. Seed (mockup FillingReport.dc.html) --------------------------------------

insert into public.packaging_materials (code, name, sort_order)
values ('bottle_33', 'Bottle 33cl', 10),
       ('bottle_75', 'Bottle 75cl', 20),
       ('label_33_main', 'Sticker label 33cl · main', 30),
       ('label_33_neck', 'Sticker label 33cl · neck', 40),
       ('label_75_main', 'Sticker label 75cl · main', 50),
       ('label_75_neck', 'Sticker label 75cl · neck', 60),
       ('crown_cork', 'Crown cork', 70),
       ('cork', 'Cork', 80),
       ('muselet', 'Muselet', 90),
       ('box_24x33_printed', 'Outer box 24x33cl · printed', 100),
       ('box_24x33_blank', 'Outer box 24x33cl · blank', 110),
       ('box_12x33_printed', 'Outer box 12x33cl · printed', 120),
       ('box_12x33_blank', 'Outer box 12x33cl · blank', 130),
       ('box_6x75_printed', 'Outer box 6x75cl · printed', 140),
       ('box_6x75_blank', 'Outer box 6x75cl · blank', 150),
       ('can_33', 'Can 33cl', 160),
       ('can_44', 'Can 44cl', 170),
       ('can_lid', 'Can lid', 180),
       ('label_33_can', 'Sticker label 33cl can', 190),
       ('label_44_can', 'Sticker label 44cl can', 200),
       ('box_12x33_can', 'Outer box 12x33cl can · blank', 210),
       ('box_24x33_can', 'Outer box 24x33cl can · blank', 220),
       ('box_12x44_can', 'Outer box 12x44cl can · blank', 230),
       ('box_24x44_can', 'Outer box 24x44cl can · blank', 240),
       ('global_keg_20', 'Global Keg 20L', 250),
       ('jopen_keg_20', 'Jopen keg 20L', 260),
       ('jopen_keg_30', 'Jopen keg 30L', 270),
       ('jopen_keg_50', 'Jopen keg 50L', 280),
       ('keg_cap', 'Keg cap', 290),
       ('keykeg_cap', 'KeyKeg cap', 300),
       ('keykeg_20', 'KeyKeg 20L · empty', 310),
       ('keykeg_30', 'KeyKeg 30L · empty', 320)
on conflict (code) do nothing;

insert into public.packaging_articles (code, name, package_format, liters_per_unit, sort_order)
values ('box_24x33', 'Box 24x33cl', 'bottle', 7.92, 10),
       ('box_24x33_blank', 'Box 24x33cl · blank', 'bottle', 7.92, 20),
       ('box_12x33', 'Box 12x33cl', 'bottle', 3.96, 30),
       ('box_12x33_blank', 'Box 12x33cl · blank', 'bottle', 3.96, 40),
       ('box_6x75', 'Box 6x75cl', 'bottle', 4.5, 50),
       ('box_6x75_blank', 'Box 6x75cl · blank', 'bottle', 4.5, 60),
       ('crate_12x75_blank', 'Crate 12x75cl · blank', 'bottle', 9, 70),
       ('box_12x33_can', 'Box 12x33cl can', 'can', 3.96, 80),
       ('box_24x33_can', 'Box 24x33cl can', 'can', 7.92, 90),
       ('box_12x44_can', 'Box 12x44cl can', 'can', 5.28, 100),
       ('box_24x44_can', 'Box 24x44cl can', 'can', 10.56, 110),
       ('keykeg_20', '20L KeyKeg', 'keg', 20, 120),
       ('keykeg_30', '30L KeyKeg', 'keg', 30, 130),
       ('jopen_keg_20', '20L Jopen/KU keg', 'keg', 20, 140),
       ('jopen_keg_30', '30L Jopen keg', 'keg', 30, 150),
       ('jopen_keg_50', '50L Jopen keg', 'keg', 50, 160),
       ('global_keg_20', '20L Global Keg', 'keg', 20, 170),
       ('gbr_door_vrouwen_keg_20', '20L Gbr. Door Vrouwen keg', 'keg', 20, 180)
on conflict (code) do nothing;

insert into public.packaging_article_materials (article_id, material_id, quantity)
select a.id, m.id, v.quantity
from (values
  ('box_24x33', 'bottle_33', 24), ('box_24x33', 'label_33_main', 24), ('box_24x33', 'label_33_neck', 24),
  ('box_24x33', 'crown_cork', 24), ('box_24x33', 'box_24x33_printed', 1),
  ('box_24x33_blank', 'bottle_33', 24), ('box_24x33_blank', 'crown_cork', 24), ('box_24x33_blank', 'box_24x33_blank', 1),
  ('box_12x33', 'bottle_33', 12), ('box_12x33', 'label_33_main', 12), ('box_12x33', 'label_33_neck', 12),
  ('box_12x33', 'crown_cork', 12), ('box_12x33', 'box_12x33_printed', 1),
  ('box_12x33_blank', 'bottle_33', 12), ('box_12x33_blank', 'crown_cork', 12), ('box_12x33_blank', 'box_12x33_blank', 1),
  ('box_6x75', 'bottle_75', 6), ('box_6x75', 'label_75_main', 6), ('box_6x75', 'label_75_neck', 6),
  ('box_6x75', 'cork', 6), ('box_6x75', 'muselet', 6), ('box_6x75', 'box_6x75_printed', 1),
  ('box_6x75_blank', 'bottle_75', 6), ('box_6x75_blank', 'cork', 6), ('box_6x75_blank', 'muselet', 6), ('box_6x75_blank', 'box_6x75_blank', 1),
  ('crate_12x75_blank', 'bottle_75', 12), ('crate_12x75_blank', 'cork', 12), ('crate_12x75_blank', 'muselet', 12),
  ('box_12x33_can', 'can_33', 12), ('box_12x33_can', 'can_lid', 12), ('box_12x33_can', 'label_33_can', 12), ('box_12x33_can', 'box_12x33_can', 1),
  ('box_24x33_can', 'can_33', 24), ('box_24x33_can', 'can_lid', 24), ('box_24x33_can', 'label_33_can', 24), ('box_24x33_can', 'box_24x33_can', 1),
  ('box_12x44_can', 'can_44', 12), ('box_12x44_can', 'can_lid', 12), ('box_12x44_can', 'label_44_can', 12), ('box_12x44_can', 'box_12x44_can', 1),
  ('box_24x44_can', 'can_44', 24), ('box_24x44_can', 'can_lid', 24), ('box_24x44_can', 'label_44_can', 24), ('box_24x44_can', 'box_24x44_can', 1),
  ('keykeg_20', 'keykeg_20', 1), ('keykeg_20', 'keykeg_cap', 1),
  ('keykeg_30', 'keykeg_30', 1), ('keykeg_30', 'keykeg_cap', 1),
  ('jopen_keg_20', 'jopen_keg_20', 1), ('jopen_keg_20', 'keg_cap', 1),
  ('jopen_keg_30', 'jopen_keg_30', 1), ('jopen_keg_30', 'keg_cap', 1),
  ('jopen_keg_50', 'jopen_keg_50', 1), ('jopen_keg_50', 'keg_cap', 1),
  ('global_keg_20', 'global_keg_20', 1), ('global_keg_20', 'keg_cap', 1),
  ('gbr_door_vrouwen_keg_20', 'keg_cap', 1)
) as v(article_code, material_code, quantity)
join public.packaging_articles a on a.code = v.article_code
join public.packaging_materials m on m.code = v.material_code
on conflict (article_id, material_id) do nothing;

commit;
