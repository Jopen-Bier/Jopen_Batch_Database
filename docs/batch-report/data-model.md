# Data model — batch report

Live schema checked 19-10-2026. **Check it again before writing a migration**
(`CLAUDE.md`). All objects live in `public`. Conventions: `ARCHITECTURE.md`
§3.2. Every new table gets `created_at timestamptz default now()`,
`created_by uuid default auth.uid() references users(id)`, `updated_at`,
`updated_by` and the `set_updated_at()` trigger, unless noted — these are not
repeated below. "Operator" / "Op." / initials in the UI = `created_by`
(joined to `users.initials`); there is no separate operator column unless a
second person must be recorded.

FKs to `batches(id)` use `on delete cascade` (a batch can be deleted in
`batchcreation.html`; its report rows go with it). Other FKs: no cascade.

## Existing tables used (do not duplicate their facts)
| Table | Used for |
|---|---|
| `batches` | batch number, name, recipe, brew count, status, yeast pitching (`yeast_*`), `order_picking_date`, `glt_empty` |
| `recipes` | name, version (`version_major`/`version_minor`), `location` (`wp`/`jk`) = brewhouse, `brew_volume_hl` |
| `recipe_ingredients` | `addition_type` (malt, boil_hop, dry_hop, brewhouse_addition, cellar_addition, yeast), `quantity`, `unit`, `timing` (dry hop: `warm`, `cold_16`, `cold_2`, …), `alpha_pct`, `color_ebc`, `hop_dosing_tank`, `all_in_first_brew` |
| `recipe_specs`, `recipe_fermentation`, `recipe_brewing_specs`, `recipe_packaging`, `recipe_process_steps`, `recipe_comments` | specs and targets shown read-only on the batch screens |
| `lots`, `stock_movements` | lots per batch ingredient = consumption on the batch (`batch_id`, `recipe_ingredient_id`, `off_recipe`, `is_correction`, accounting sign-off) |
| `users` | `name`, `role_id`; new `initials` |
| `permission_modules`, `role_permissions` | module `batches` |

Unused, empty columns on `batches` (0 rows filled): `operator`, `extract`,
`alcohol`, `bitterness`, `color`, `ph`, `total_final_volume`, `brew_date`.
Leave them alone (see open-questions).

---

## Phase 0 — foundation

### `tanks` (new)
| Column | Type | Notes |
|---|---|---|
| id | bigint identity PK | |
| code | text unique not null | as on the floor: `CKT1`, `GLT21`, `LT51`, `HBT14` |
| tank_type | text not null | check in (`ckt`,`glt`,`lt`,`hbt`) |
| number | integer not null | sort key (tank order in Active batches) |
| location | text not null | check in (`wp`,`jk`) |
| volume_hl | numeric not null | |
| is_active | boolean not null default true | inactive: hidden in dropdowns, kept in history |

Seed (from Jaap, 15-10):
- JK: CKT1–5 60 hl, CKT6 20, CKT7 30, CKT8 10.
- WP: LT11–12 10, LT13–14 20, LT15–16 30; GLT21–22 60, LT23–24 60,
  GLT25–28 60; GLT31–35 120; GLT41–45 120; LT51–58 180; GLT61–64 320;
  HBT11–12 30, HBT13 20, HBT14–15 60, HBT16–18 120. (52 tanks.)
- Confirmed 19-10: all HBTs at WP; a CKT is a combi tank (fermentation and
  lagering).

RLS: select for every logged-in user; insert/update/delete via `settings`.
No access for `anon`.

### `users.initials` (new column)
text, nullable. Trigger `set_user_initials()` before insert/update of `name`:
if `initials` is null → upper(first letter of first word + first letter of
last word), via `initials_from_name(name)`. Backfill existing users.
Single-word names get one letter; Jaap corrects by hand. Editable on
`gebruikers.html` (admin); saving an empty value regenerates them. On a
change of name, generated initials follow the new name, hand-typed ones stay.

### Permission module
`update permission_modules set name = 'Batches & batch reports' where module_key = 'batches'`.
No new module.

### `batch_audit_log` (new)
| Column | Type | Notes |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint | not an FK (row stays after the batch is deleted) |
| table_name | text not null | |
| row_id | text not null | |
| action | text not null | check in (`insert`,`update`,`delete`) |
| old_data / new_data | jsonb | |
| changed_by | uuid default auth.uid() | |
| changed_at | timestamptz default now() | |

Generic trigger function `log_batch_change()` (security definer, fixed
`search_path`), attached AFTER INSERT/UPDATE/DELETE to every new batch table
(each phase attaches its own tables). `batch_id` = `NEW/OLD.batch_id`, or via
the parent for child tables (pass the lookup as a trigger argument, or give
child tables a `batch_id` column too — preferred: every batch table has
`batch_id`). Built (phase 0): every batch table has `batch_id`; `row_id` =
the `id` column, or for a composite key the columns passed as trigger
arguments joined with `:` (`log_batch_change('entry_id', 'tag_id')`);
updates that change nothing are not logged. RLS: select
`can_view('batches')`; no insert/update/delete policies (trigger only).

### View `batch_stages` (new, `security_invoker = true`)
One row per batch: `batch_id`, `stage`, `start_date`, `end_date`, plus the
fields Active batches needs. Stage logic in business-rules.md. **Phase 0
version**: `planned` → `raw`, `completed` → `closed` (the process tables do
not exist yet); each later phase extends the view. `start_date` / `end_date`
are `date` (start = brew 1 mash-in, local date) — keep the type when the view
is replaced (`create or replace view` cannot change a column type).

---

## Phase 2 — Overview

### `batches` (new columns)
| Column | Type | Notes |
|---|---|---|
| order_picking_completed_at | timestamptz | null = not complete; set when the checkbox is ticked |
| order_picking_completed_by | uuid → users | |

### `batch_ingredients` (new) — snapshot of the recipe
| Column | Type | Notes |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | cascade |
| recipe_ingredient_id | bigint → recipe_ingredients | on delete set null; trace only (see below) |
| ingredient_id | bigint → ingredients | empty only for recipe lines without ingredient (copied with their note) |
| is_added | boolean not null default false | **true = added in this batch**; then ingredient_id is required (check) |
| addition_type | text not null | same values as `recipe_ingredients.addition_type` (+ `base_beer` in phase 8) |
| timing | text | copied |
| unit | text | copied |
| sort_order | integer | |
| recipe_quantity | numeric | frozen at snapshot; null for added rows |
| quantity | numeric | batch value (editable) |
| recipe_alpha_pct / alpha_pct | numeric | hops |
| recipe_color_ebc / color_ebc | numeric | malt |
| hop_dosing_tank | integer | copied |
| all_in_first_brew | boolean | copied |
| is_removed | boolean not null default false | soft delete: removal stays visible as a deviation |
| deviation_reason | text | required in the UI as soon as the row deviates |
| note | text | copied from the recipe line |

Built (phase 2), different from the first design: "Added" is its own column
(`is_added`), and the batch keeps its own frozen recipe values. (At the time
`recept-invoer.html` re-inserted every recipe line on save; since PR #7 lines
keep their id via `save_recipe_ingredients()`, so the trace survives a recipe
save and is only cleared when the line itself is deleted.) 51 recipe lines (19-10) have no ingredient (blend notes and
similar); they are copied with their `note`, hence `ingredient_id` nullable.

Function `snapshot_batch_ingredients(p_batch_id bigint)` — inserts from
`recipe_ingredients` of the batch's recipe **only if the batch has no rows
yet** (idempotent). Called by an AFTER INSERT trigger on `batches`, and by the
page on first open. Migration backfills all batches with status `planned`.

Lots (read-only on the Overview): `stock_movements` where `batch_id` = batch
and `movement_type = 'consumption'`, joined to `lots` (lot code) and matched
to the batch ingredient by ingredient **group** (`ingredients.ingredient_group_id`,
so another version of the same ingredient still matches). No stock movement
uses `recipe_ingredient_id` (19-10). Open: add `stock_movements.batch_ingredient_id` for
exact matching of added rows (open-questions).

---

## Phase 3 — Brewing

### `batches` (new column)
`brewhouse_recipe_number` text — "Recipe number Braukon". (The brewhouse
software recipe *name* stays in `recipe_brewing_specs.brewhouse_recipe_name_wp/_jk`.)

Built (phase 3): `glt_tank_id` (→ `tanks`) is added here instead of phase 4 —
the GLT / CKT is chosen on the brew day and Active batches sorts by tank.
`batch_stages` gets extra columns `brews_planned` (= `brew_count` rounded
up), `brews_started`, `brews_ended`, `last_brew_ended_at`.

`yeast_pitched_by` is text and empty in all rows → change to uuid → users in
this phase (pitched by = chosen user, default the logged-in user).

### `batch_brews` (new) — one row per brew
| Column | Type | UI label |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | |
| brew_number | integer not null | unique (batch_id, brew_number) |
| software_order_number | text | Order no. software |
| brewer_id | uuid → users | Brewer |
| mash_in_started_at | timestamptz | Start mashing — brew 1 sets the start date and stage Brewing |
| mash_water_hl | numeric | Mash water |
| mash_in_ph | numeric | pH after mashing-in |
| mash_acid_l | numeric | Acid correction (UI may show ml) |
| mash_corrected_ph | numeric | pH after correction |
| is_iodine_test_ok | boolean | Iodine test OK? |
| has_mash_schedule_deviation | boolean | Deviation from mash schedule? |
| first_wort_extract | numeric | Plato first wort (°P) |
| last_runnings_extract | numeric | Extract last runnings (°P) |
| cumulative_sparge_volume_hl | numeric | WP only |
| last_runnings_ph | numeric | WP only |
| first_wort_volume_hl | numeric | First runnings — JK only |
| sparge_water_hl | numeric | JK only |
| sparge_runnings_hl | numeric | JK only |
| lauter_time_min | numeric | Filtration time |
| boil_start_ph | numeric | |
| boil_start_extract | numeric | |
| boil_start_volume_hl | numeric | Volume start boil (80 °C) |
| boil_acid_l | numeric | Acid correction (boil) |
| boil_acid_ph_note | text | pH after acid correction / time |
| boil_time_min | numeric | Total boil time |
| boil_end_extract | numeric | |
| extra_addition | text | |
| whirlpool_volume_hl | numeric | |
| whirlpool_extract | numeric | |
| whirlpool_ph | numeric | |
| whirlpool_rest_min | numeric | Actual rest time |
| aeration_ppm | numeric | |
| water_addition_hl | numeric | |
| brew_volume_hl | numeric | Volume brew |
| brewing_ended_at | timestamptz | End of brewing — last brew → stage Fermentation, default Time 0 |
| process_pause | text | JK only (hh:mm) |
| is_aeration_filter_steamed | boolean | JK only |
| is_wort_line_sterilized | boolean | JK only |
| ckt_cip_program | text | JK only; check in (`lo-de`,`lo-zu-de`,`lo-de-hw`,`lo-zu-de-hw`) |
| spent_grain_bin | text | JK only |

Calculated (not stored): evaporation, volume to GLT, extract to GLT, GLT
total, total brewing time (business-rules.md).

### `batch_brew_comments` (new)
`id`, `batch_id`, `brew_number` (null = all brews), `comment_time time`,
`comment text not null`. Operator = `created_by`.

---

## Phase 4 — Fermentation log

### `batches` (new columns)
| Column | Type | Notes |
|---|---|---|
| time_zero | timestamptz | "Time 0 · last brew in tank"; empty = `brewing_ended_at` of the last brew (`batch_stages.time_zero` gives the value in use), editable |
| glt_tank_id | bigint → tanks | fermentation tank (GLT or CKT) — **built in phase 3** |
| lt_tank_id | bigint → tanks | lager tank when pushed over; null = stays in GLT |

### `cellar_action_tags` (new)
`id`, `code text unique` (e.g. `cooling`, `dryhopping`, `sample_lab`),
`label text`, `is_milestone boolean` (can tick off a plan step),
`sort_order`, `is_active`. Seed: 24h purge, Purge, Spunding, Dry warm*,
Dryhopping*, Tasting, Cooling*, Addition*, Pump start, Pump stop, Transfer,
Transport, Processing, Sample to lab*, Blending, Other (* = milestone; see
mockup `Settings.dc.html`). RLS: select all logged-in; write via `settings`.

### `recipe_cellar_steps` (new)
| Column | Type | Notes |
|---|---|---|
| id | bigint identity PK | |
| recipe_id | bigint not null → recipes | cascade; copied along with a new recipe version |
| sort_order | integer not null | |
| tag_id | bigint not null → cellar_action_tags | |
| title | text not null | "Cooling to 16 °C" |
| description | text | "What": hops/amounts/instruction |
| trigger_type | text not null | check in (`extract`,`day`,`after_previous`,`temperature`) |
| trigger_value | numeric | °P / day from Time 0 / °C |
| trigger_tol | numeric | ± tolerance |
| planned_day | numeric | day from Time 0: the trigger for `day`, else indicative ("~day 3"); required for `day` |
| recipe_ingredient_ids | bigint[] not null default '{}' | linked dry hop / cellar addition lines |
| starts_lagering | boolean not null default false | true on "Cooling to [lagering temp]" |
| is_generated | boolean not null default true | false once edited by hand (regeneration leaves it alone) |
| generated_key | text | which generated step this is (unique per recipe); null for steps added by hand |

Function `generate_recipe_cellar_steps(p_recipe_id)` implements the rules in
business-rules.md; `save_recipe_cellar_steps(p_recipe_id, p_steps jsonb)`
saves the editor's plan (as `save_recipe_ingredients`) and then regenerates.
Helpers `tolerance_value(text)` and `cellar_addition_timing(text)`. Backfill
for active recipes. RLS via `recipes`.

### `batch_cellar_steps` (new) — snapshot per batch
Same columns as `recipe_cellar_steps` minus `is_generated`/`generated_key`,
with `batch_id` instead of `recipe_id` and `recipe_cellar_step_id`
(traceability). Filled by `snapshot_batch_cellar_steps(p_batch_id)` (batch
insert trigger next to `snapshot_batch_ingredients`, backfill of planned
batches, and on opening the tab). Done-status is **derived** (business-rules);
`batch_stages` adds `time_zero`, `cellar_steps_total`, `cellar_steps_done`,
`next_cellar_step`, `lagering_started_at`.

### `fermentation_log_entries` (new)
| Column | Type | Notes |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | |
| measured_at | timestamptz not null | Date + Time |
| extract | numeric | °P ("Plato") |
| temp_high / temp_low | numeric | °C |
| ph | numeric | |
| comment | text | |

Day (since Time 0), °P decrease and hours are calculated.

### `fermentation_log_entry_tags` (new)
`entry_id → fermentation_log_entries` (cascade), `tag_id → cellar_action_tags`,
PK (entry_id, tag_id), `batch_id` (for RLS/audit; foreign key
(entry_id, batch_id) so it is always the batch of the entry).

### `batch_transfers` (new — created here, full flow in phase 8)
| Column | Type | Notes |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | source batch |
| from_tank_id | bigint → tanks | GLT/LT/HBT of the source batch |
| destination | text not null | check in (`batch`,`discard`) |
| to_batch_id | bigint → batches | required when destination = `batch` |
| volume_hl | numeric not null | |
| transferred_at | timestamptz not null | counts on both batches from this moment |
| reason | text | required for discard |
| comment | text | |

---

## Phase 5 — Processing

### `batches` (new columns)
| Column | Type | UI |
|---|---|---|
| cellar_additions_done | boolean not null default false | Check before processing · Cellar adds completed |
| tasting_comment | text | Comments tasting |
| tasting_result | text | check in (`go`,`no_go`) — Go / Not go |

(`glt_empty` already exists — "GLT empty?".)

### `processing_sessions` (new)
| Column | Type | UI |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | |
| session_number | integer not null | tabs |
| started_by / ended_by | uuid → users | Operator start / end |
| processing_date | date | sets stage HBT |
| start_time / end_time | time | duration calculated |
| tank_id | bigint → tanks | Processed from (G)LT |
| outlet | text | check in (`standpipe`,`bottom_valve`) |
| discharge_count | integer | Discharges |
| discharge_interval_min | numeric | Interval (min) |
| centrifuge_in_time | time | Start measurements · Centrifuge in |
| centrifuge_in_o2_ppb / centrifuge_in_co2_gl | numeric | |
| centrifuge_out_time | time | Centrifuge out |
| centrifuge_out_o2_ppb / centrifuge_out_co2_gl | numeric | |
| start_flow_hl_h | numeric | Start flow |
| start_turbidity_ebc | numeric | Start turbidity |

### `processing_comments` (new)
`id`, `batch_id`, `comment_time time`, `comment text not null`.

### `batch_hbts` (new) — one row per HBT used by the batch
| Column | Type | UI |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | |
| tank_id | bigint not null → tanks | unique (batch_id, tank_id) |
| intended_formats | text[] | values `bottle`,`can`,`keg` — Intended for |
| avg_inline_o2_ppb | numeric | Avg. in-line O2 |
| avg_pu | numeric | Avg. PU |
| avg_turbidity_ebc | numeric | Avg. turbidity |
| avg_flow_hl_h | numeric | Avg. flow |
| released_at | timestamptz | null = not released |
| released_by | uuid → users | |
| sort_order | integer | |

### `hbt_readings` (new)
| Column | Type | UI |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null | |
| batch_hbt_id | bigint not null → batch_hbts | cascade |
| processing_session_id | bigint → processing_sessions | Session (an HBT can span sessions) |
| sort_order | integer not null | last row = end value |
| level_hl / o2_ppb / co2_gl | numeric | |
| co2_target | text | check in (`bottle`,`can`,`keg`) |
| comment | text | |

---

## Phase 6 — Filling

### `filling_sessions` (new)
| Column | Type | UI |
|---|---|---|
| id | bigint identity PK | |
| batch_id | bigint not null → batches | |
| session_number | integer not null | |
| filling_date | date | first filling input → stage Filling |
| batch_hbt_id | bigint → batch_hbts | HBT |
| package_format | text | check in (`bottle`,`can`,`keg`) |
| volume_hl | numeric | |
| start_time / end_time | time | |
| sampled_by | uuid → users | Sampled by (Filled by = `created_by`) |
| is_first_package_checked | boolean | First package check (two operators) |
| is_fill_tube_checked_first | boolean | Fill tube detection · first package |
| is_fill_tube_checked_end | boolean | Fill tube detection · end of batch |
| are_burst_bottles_controlled | boolean | bottle only |
| is_hbt_finished | boolean not null default false | HBT finished? |

### `filling_measurements` (new)
`id`, `batch_id`, `filling_session_id` (cascade), `measured_time time`,
`tpo_ppb`, `hso_ppb`, `do_ppb`, `headspace_volume`, `pressure_bar`,
`temp_c`, `co2_gl` (bottle/can, 20 °C), `keg_co2_gl`, `keg_o2_ppb`.

---

## Phase 7 — Filling report
Master data (RLS: select all logged-in, write via `settings`):
- `packaging_articles`: `id`, `code` unique, `name`, `package_format`,
  `liters_per_unit`, `ean`, `mdrank_article_number`, `is_active`.
- `packaging_materials`: `id`, `code` unique, `name`, `unit`,
  `mdrank_article_number`, `is_active`.
- `packaging_article_materials` (BOM): `article_id`, `material_id`,
  `quantity` (per article). Box 24x33 = with labels, BLANCO = without.

Per filling session:
- `filling_session_articles`: `id`, `batch_id`, `filling_session_id`,
  `article_id`, `quantity`.
- `filling_session_materials`: `id`, `batch_id`, `filling_session_id`,
  `material_id`, `quantity` (used, booked out).

Parked columns on `batches` (do not create until Jaap decides):
`filling_comment`, `mdrank_entered_by`, `mdrank_entered_at`,
`filling_report_completed_by/_at`, `filling_report_signed_by/_at`.

---

## Phase 8 — Splits
`batch_transfers` exists (phase 4). Adds: base beer in recipes and batches
(`addition_type = 'base_beer'`), "new batch from split" (next sequential
batch number, brew count 0). How a base beer line references the source beer
is open (open-questions).

---

## RLS summary
| Tables | select | insert / update | delete |
|---|---|---|---|
| all batch tables above (`batch_*`, `fermentation_*`, `processing_*`, `hbt_readings`, `filling_*`) | `can_view('batches')` | `can_edit('batches')` | `can_delete('batches')` |
| `batch_audit_log` | `can_view('batches')` | trigger only | none |
| `tanks`, `cellar_action_tags`, `packaging_*` | every logged-in user | `can_edit('settings')` | `can_delete('settings')` |
| `recipe_cellar_steps` | `can_view('recipes')` | `can_edit('recipes')` | `can_delete('recipes')` |

Split `FOR ALL` into separate insert/update/delete policies (advisor fix of
18-10). DELETE must be allowed wherever EDIT is, per role.
