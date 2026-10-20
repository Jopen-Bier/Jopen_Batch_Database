# Decisions

Agreed with Jaap. Date = when decided. Do not change without asking.

## Scope and rollout
| Date | Decision |
|---|---|
| 07-10 | Batch report goes fully English (UI). Doubtful label translations go to Jaap first. |
| 08-10 | Mockup first; the team reviews the mockup before a phase is built. |
| 15-10 | Batch creation keeps the current Excel flow until the digital report has been tested, also administratively. |
| 19-10 | The 2026 batches are imported from their Excel reports, **after** all phases are built (phases.md, "Import 2026 batches"). Older batches are not. |
| 15-10 | **No pilot flag**: every batch gets the digital tabs, filled in voluntarily next to Excel. |
| 15-10 | Build in process order: foundation → navigation → Overview → Brewing → Fermentation log → Processing → Filling → Filling report → Splits. |
| 16-10 | Built with Claude Code, phase by phase, branch + PR; design stays in the chat. |

## Data model
| Date | Decision |
|---|---|
| 15-10 | **Initials** (paraaf) and operator come **from the login**: rows store `created_by` (uuid → `users`). Initials = first letter of first name + first letter of the last word of the name, stored in `users.initials` (filled by trigger, overridable). Every person who fills in data gets their own account (Jaap arranges this). |
| 15-10 | **Ingredient snapshot at batch creation**: recipe ingredients are copied to `batch_ingredients` when the batch is inserted (DB trigger, so `batchcreation.html` needs no change). Existing batches get their snapshot on first open (idempotent function). |
| 15-10 | Tank master list (`tanks`) with type, number, location, volume (list from Jaap, see `data-model.md`). |
| 19-10 | All HBTs are at WP; a CKT is a combi tank (fermentation and lagering). |
| 19-10 | Beer risk / beer status lists = the values in the existing recipes (already in `recipe-values.js`). |
| 19-10 | **Batch-level fields are columns on `batches`** (Time 0, GLT/LT, order picking complete, tasting, …) — no separate 1:1 table. |
| 19-10 | **One permission module for the whole batch report: `batches`** (renamed "Batches & batch reports"). All new batch tables use `can_view/can_edit/can_delete('batches')`. |
| 19-10 | **Stage of a batch is derived** in view `batch_stages`, never stored. `batches.status` stays `planned`/`completed`. |
| 19-10 | GLT / CKT is chosen on the brew day: `batches.glt_tank_id` built in phase 3 (not 4). |
| 19-10 | Brews needed = `brew_count` rounded up. A fractional brew count (3.33) is a dosing factor of a split batch (e.g. 130 hl ÷ 40 hl per brew), not physical brews; such batches get no brews. |
| 19-10 | "Pitched by" (`batches.yeast_pitched_by`) is a user; default the person who fills in "Pitched on". |
| 19-10 | Brewers get delete rights on batches (role matrix), consistent with edit (Jaap). |
| 19-10 | **Lots per batch ingredient come from `stock_movements`** (consumption booked on the batch). No separate lot table. Corrections after deviations are stock movements with `is_correction` (existing accounting sign-off). |
| 19-10 | HBT tables: `batch_hbts`, `hbt_readings`. `hbt`, `glt`, `lt`, `ckt` are kept as lowercase plant abbreviations. |
| 09-10 | Dry hop and cellar amounts in the recipe are batch totals. |
| 09-10 | Volume tolerance ±0.5 hl. HBT end value = its last reading. |

## Fermentation / cellar
| Date | Decision |
|---|---|
| 08-10 | Fermentation log actions are **tags** managed in Settings (more will be added). |
| 08-10 | **Cellar plan from the recipe**, ticked off by action tags: the n-th time a tag appears in the log ticks off the n-th plan step with that tag. Steps are generated from recipe data by fixed rules (business-rules.md), editable in the recipe editor, snapshotted into the batch. |
| 08-10 | Days in the recipe count from **Time 0** = last brew in the tank. |
| 08-10 | Calculators (Nagardo, PGA/alginate, dealcoholisation/Nano Flavor) only show when the recipe has that ingredient/process. |
| 13-10 | Removing a tag from a log row asks for confirmation. |
| 20-10 | A tag can be put on one log entry more than once (several additions the same day). |
| 19-10 | Lagering starts when the cellar plan step "Cooling to [lagering temp]" is done; setting an LT does not count. |
| 19-10 | Sample to lab comes after the **last** cooling. |
| 19-10 | Cellar additions go to the cellar plan or to Processing **by keywords** in their timing; the timing texts are streamlined to standard values (business-rules.md). |
| 19-10 | No four-eyes check for Nagardo for now. |
| 20-10 | The order of the cellar plan and the timing values of cellar additions are managed in **Settings › Cellar plan** (drag and drop; "Apply order to the recipes"). Sample to lab always right after cooling to the lagering temperature; a cold dry hop at the lagering temperature comes after the sample. |
| 20-10 | Each cellar plan part has its own tag (Settings); the cooling before a cold dry hop uses the milestone tag "Cooling 16C". |
| 20-10 | The fermentation log always starts with the Time 0 measurement (GLT total from Brewing). |
| 20-10 | Recipe editor: Process steps block removed (values kept in the database), Cellar plan right after Additions Cellar; the recipe overview shows the cellar plan instead of the process steps. |
| 20-10 | Lists (All batches, Active batches) open a batch on the tab of its stage. |
| 20-10 | Timing of cellar additions = dropdown of standard values (review sheet approved, extra text moved to the note); new value "With warm dry hop". Recipe data fixes from the plan review (lagering temperatures, dry hop timings) done in the phase 4 migration. |
| 19-10 | The cellar plan regenerates from the recipe data on every recipe save; steps changed or added by hand are kept. The batch keeps the snapshot it got at creation. |

## Processing / filling
| Date | Decision |
|---|---|
| 20-10 | Minimum maturation is ticked automatically: days since lagering started ≥ the recipe lagering time. Labels Discharges / Interval (min) and Standpipe / Bottom valve stay as in the mockup. |
| 13-10 | Processing session = start measurements only (centrifuge in/out, start flow, start turbidity). Lagering block removed. Pasteurised-with / avg temp out / avg turbidity removed from the session. |
| 13-10 | Per HBT, operator enters averages: in-line O2, PU, turbidity, flow — **one set per HBT**, also when it was filled over two sessions. |
| 13-10 | HBT blocks stacked (full width). |
| 13-10 | HBT **release**: operator ticks "released" after the release e-mail (QA releasing directly in the app: maybe later). |
| 13-10 | Filling session has "HBT finished?"; all HBTs finished → batch moves to Filled. |
| 15-10 | Consumption block removed from Filling. Net contents, OEE and contents check removed earlier. |
| 15-10 | "Processing loss" is called **Cellar loss**. Volume balance shown as a pie chart. |
| 13-10 | Every row and input can be deleted; delete asks for confirmation, then a toast with Undo. |

## Splits / transfers
| Date | Decision |
|---|---|
| 13-10 | One **transfer** record links source and receiving batch; shown on Fermentation log, Processing and Filling report (same record). |
| 13-10 | A split to a new product (incl. barrel aging) always gets a **new sequential batch number** (never a suffix), 0 brews. The recipe must already exist. |
| 13-10 | Dosing of the new product's ingredients is on the **total volume** of the new batch. The **transfer moment** is when the volume counts. |
| 13-10 | Several source beers → one "base beer" line per source. No indicative specs. |

## Overview / ingredients
| Date | Decision |
|---|---|
| 13-10 | Everything on the Overview ingredient cards stays editable per batch (amounts, alpha, EBC, add/remove rows); the recipe stays unchanged. Deviations are listed with a required reason. |
| 13-10 | A stock return after a deviation always goes back to the **same lot**. |
| 13-10 | "Order picking complete" checkbox on the Overview; turns the Raw-material tile green. |

## Navigation
| Date | Decision |
|---|---|
| 14-10 | Home group "Batch reports" with three tiles in this order: Batch creation, Active batches, All batches. |
| 13-10 | Active batches: full-width blocks per stage (Raw material prep., Brewing, Cellar [Fermentation + Lagering], HBT, Filling, Filled), compact tiles sorted by **tank number**. Each tile always shows two status lines; an issue adds a red "!" badge plus a third line explaining it. |
| 13-10 | Stage rules: see business-rules.md. |
| 14-10 | All batches: table with batch number, name, version, status (stage), start date, end date. |
| 19-10 | All batches always shows all batches (no Active/Closed toggle); active batches are on Active batches. |

## Parked (do not build yet)
- Closing the filling report (Completed / Signed) and the "Entered in Mdrank"
  fields: wait for Jaap's talk with the admin.
- Stock booking from the batch report (corrections, lots chosen at batch
  creation).
