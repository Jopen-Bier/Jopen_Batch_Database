# Business rules and calculations

Put shared calculations in a module with a Node test (pattern
`brew-calculations.js`), e.g. `batch-report-calculations.js`. Reuse
`brew-calculations.js` for EBU and malt colour, `recipe-values.js` for value
lists and labels.

## Stage of a batch (view `batch_stages`)
Evaluated top-down, first match wins:

| Stage | Rule |
|---|---|
| `closed` | `batches.status = 'completed'` (history), or both filling report checks ticked: `filling_report_checked_at` and `mdrank_processed_at` (23-10), or all three documents uploaded on the Filling report: production order, filling order, filling report (23-10, `20261023140000_close_by_documents`) |
| `filled` | the batch has ≥1 `batch_hbts` and every one has a filling session with `is_hbt_finished`; or a transfer out has `empties_tank` ("Tank empty: this was the whole batch", 23-10) |
| `filling` | a `filling_sessions` row has `filling_date` (as HBT starts with the processing date) |
| `hbt` | a `processing_sessions` row has `processing_date` (also without brews, e.g. a split batch) |
| `barrel` | a log entry has the tag `to_barrels` ("To barrels"), until Processing has a date (23-10) |
| `lagering` | brewed (as fermentation) and lagering started: the earliest of the cellar-plan step with `starts_lagering`, the first log tag Cooling 16C or Cooling, `batches.lagering_started_at` ("Start lagering now", beer that arrives cold), and for a batch without brews of its own its first incoming transfer (23-10) |
| `fermentation` | number of brews with `brewing_ended_at` ≥ `batches.brew_count` rounded up (brew counts such as 3.33 occur); or, for a batch without started brews (a split batch), from its first incoming transfer (phase 8) |
| `brewing` | a brew has `mash_in_started_at` |
| `raw` | otherwise (batch report exists, not brewed yet) |

UI labels: Raw material preparation · Brewing · Fermentation · Lagering ·
On barrels · HBT · Filling · Filled · Closed. Active batches shows Fermentation and
Lagering as two rows of one "Cellar" block, and On barrels as its own block
under Filled.

- **Start date** = earliest `mash_in_started_at` of the batch; a split batch
  (no brew started): its first incoming transfer. Its Time 0 is that moment
  too, unless `batches.time_zero` is set.
- **End date** = the later of the two filling report checks. Empty for
  historical `completed` batches.

## HBT fills
One `batch_hbts` row = one fill of the tank, from empty to empty. Filling it
over more days is the same row with more filling sessions; the last session
ticks "HBT finished". A new row with the same tank only after that (26278).
Processing warns when "+ Add HBT" picks a tank whose fill is not finished.

## Transfer to another tank (Fermentation log)
The tag "Transfer" asks the tank the beer goes to (it becomes the batch's
LT), volume, O2 and CO2: `batch_tank_moves`, linked to the log entry's tag.
A split to another batch stays the Split / transfer popup (`batch_transfers`).

## Initials
Typed by hand on the Users page (required on the invite form), unique
ignoring case; no longer generated from the name (21-10).

## Ingredient snapshot and deviations
- Snapshot copies every `recipe_ingredients` row of the batch's recipe into
  `batch_ingredients` (`recipe_quantity = quantity = recipe value`, same for
  alpha/EBC). Only when the batch has none yet.
- A row **deviates** when: `quantity` ≠ `recipe_quantity`, or
  `recipe_ingredient_id` is null (added), or `is_removed`.
  Alpha/EBC differences are highlighted (amber) but are not stock
  deviations.
- Δ batch total per row, per unit (`batch-ingredients.js`, `amountBasis`):
  - malt: (quantity − recipe_quantity) × brew_count (kg/brew)
  - boil hops: × brew_count (g/brew); dry hops: batch total (g)
  - per hl (`g/hl`, `ml/hl`, `kg/hl`, `l/hl`, …): × total volume hl
    (brew volume × brew count)
  - per litre (`g/l`, `ml/l`, `mg/l`, `ppm` = mg/l): × total volume hl × 100
  - per brew (`g/brew`): × brew_count
  - other absolute units (`g`, `kg`, `l`, `hl`) on additions and yeast:
    batch total; no unit: no batch amount
- A row added in the batch shows under "Changes vs recipe" once it has an
  amount. Added and then removed = no change.
- Inventory effect text: order picking not complete → "Picking list updated";
  complete → positive Δ "Extra issue · <lot>", negative "Return to same lot ·
  <lot>". (Booking these movements is parked.)
- A reason is required for every deviating row (UI blocks leaving it empty
  with an amber field; not a DB constraint).

## EBU and colour (Overview)
Use `brew-calculations.js` with the **batch** values (`alpha_pct`,
`quantity`, `color_ebc`), original extract from `recipe_specs` and boil
volume from `recipe_brewing_specs`. Same formulas as `recept-invoer.html`.
EBU total compared with `recipe_specs.bitterness` ± `bitterness_tol`.

## Additions ticked per brew / per HBT (Jaap, 22-10)
- Brewing tab, **Additions brewers**: a column per brew of the batch (Brew
  1, Brew 2 …, appears when a brew is added) with a tick box per addition
  line; a line "all in the first brew" has a box in Brew 1 only ("—"
  elsewhere). Processing: a column per HBT (refilled tank: "HBT16 · 01-10").
- A tick = a `batch_dosing_checks` row (who, when: the box's tooltip);
  untick deletes it. Edit rights for both. Deleting the addition line, the
  brew or the HBT deletes its ticks. Module `dosing-checks.js` (+ test);
  saving in `batch-report-cards.js` (`createDosingChecks`).
- `batch_ingredients.is_added` is something else: a line added to the batch
  versus the recipe.

## Brewing (per brew, grey/calculated)
- Evaporation % = (boil_end_extract − boil_start_extract) /
  boil_start_extract × 100 (extract-based, as in the mockup; compare with
  `recipe_brewing_specs` desired evaporation).
- Volume to GLT = brew_volume_hl + water_addition_hl.
- Extract to GLT = whirlpool_extract × brew_volume_hl / (brew_volume_hl +
  water_addition_hl).
- GLT total (running): volume = Σ volume to GLT; extract = volume-weighted
  mean of extract to GLT. No GLT pH: a pH cannot be averaged over brews
  (Jaap, 23-10); each brew keeps its own whirlpool pH.
- Total brewing time = brewing_ended_at − mash_in_started_at (minus pause, JK).
- **GLT total becomes the first fermentation log measurement** (extract)
  at Time 0 — offer it, do not duplicate it silently.
- Result per brew vs recipe: °P at GLT vs `recipe_specs.original_extract` ±
  tol; hl at GLT vs `recipes.brew_volume_hl` ± 0.5.
- **GLT total in spec** (Jaap, 23-10, the most important parameter): total
  extract vs `recipe_specs.original_extract` ± tol; total volume vs brews so
  far × `recipes.brew_volume_hl` ± 0.5 hl per brew. Shown as a verdict badge
  in the head of the Result card and per value in the total row.

## Time 0 and days
- Time 0 default = `brewing_ended_at` of the last brew; editable. Empty
  `batches.time_zero` means the default; `batch_stages.time_zero` gives the
  value in use.
- Day of an entry = (measured_at − time_zero) in days, 1 decimal.
- **The first measurement is always at Time 0** (Jaap, 20-10): added when the
  Fermentation log opens for an editor and the log has nothing at or before
  Time 0, with the GLT total of the brews (volume-weighted extract °P, no pH;
  comment "Time 0 · GLT total … hl"). It moves along when Time 0 changes
  and cannot be deleted.
- Recipe days (`recipe_process_steps.dry_hop_1_day`, `cellar_addition_day`)
  count from Time 0.

## Cellar plan generation (recipe → `recipe_cellar_steps`)
Function `generate_recipe_cellar_steps(recipe_id, reset_order)`, run on every
recipe save (after the plan the editor shows is saved by
`save_recipe_cellar_steps`). The **order comes from Settings › Cellar plan**
(`cellar_plan_parts`, drag and drop). Default order:

Each part has a **tag** (Settings, column Tag): the action tag that ticks
its step off. Defaults: Dry warm → Dry warm; Cold dry hop → "Cooling 16C"
for the cooling (the dry hop step stays Dryhopping); Cooling to lagering
temperature → Cooling; Sample to lab → Sample to lab; Dry hop at lagering
temperature → Dryhopping; timing values → Addition.

| # | Part | Generates |
|---|---|---|
| 1 | Dry warm (fixed) | if the recipe has `dry_hop` lines with timing `warm`: trigger extract = `recipe_fermentation.dry_hop_warm_extract_1` ± tol, indicative day = `dry_hop_1_day`; tag `dry_warm`; links the warm lines |
| 2 | With warm dry hop (timing) | one Addition step per cellar addition with this timing |
| 3 | During fermentation (timing) | idem |
| 4 | Cold dry hop above lagering temperature (fixed) | per `cold_X` with X > lagering temp (warmest first): "Cooling to X °C" (tag `cooling`; trigger final extract ± tol for the first cooling, else after previous) and "Dryhopping @X °C" (tag `dryhopping`, links the lines). Dry hops **without** timing get "Dryhopping · timing not set" here |
| 5 | After cold dry hop (timing) | Addition steps |
| 6 | Cooling to lagering temperature (fixed) | always; `recipe_fermentation.lagering_temp`; tag `cooling`; `starts_lagering` |
| 7 | Sample to lab (fixed) | always; tag `sample_lab` (decision #4: after the last cooling) |
| 8 | Dry hop at lagering temperature (fixed) | per `cold_X` with X ≤ lagering temp (e.g. `cold_2` at 2 °C): "Dryhopping @X °C" |
| 9 | Lagering (timing, on addition day) | Addition steps on `cellar_addition_day` |
| 10 | After de-alcoholisation (timing) | Addition steps |
| — | Processing, Inlet centrifuge, After centrifuge, HBT (timing, shows on Processing) | not in the plan |

Cellar additions whose timing is not a value in Settings (or empty) come last:
"Addition · …", "timing to check in the recipe". A final extract or warm dry
hop extract of 0 counts as empty.

**Timing values** (decision #5): the Timing of a cellar addition is a dropdown
in the recipe editor with the `addition_timing` rows of `cellar_plan_parts`
(code stored in `recipe_ingredients.timing`). Settings can add values (label,
shows on cellar plan / Processing, on the addition day), make them inactive,
and delete unused ones. The free texts of the recipes with a plan were
replaced by these values in phase 4 (review sheet; extra text moved to the
note).

**Regeneration**: a generated step (`is_generated`) is updated to the new
recipe data and keeps its place; a step changed in the editor keeps its text
and trigger (only its linked lines are refreshed); steps added by hand stay;
generated steps the recipe no longer asks for are removed. Each generated
step has a `generated_key` (`dry_warm`, `cooling_dry_hop:16`, `dry_hop:16`,
`dry_hop:unset`, `cooling_lagering`, `sample_lab`, `addition:<line id>`).
A new recipe version gets the plan of the previous version, then the
generator links it to the new lines. **Apply order to the recipes**
(Settings, `apply_cellar_plan_order()`) regenerates every recipe with a plan
with `reset_order`: all steps in the Settings order, a step added by hand
right after the generated step it followed. Planned batches without
fermentation log entries then get the new plan; batches with entries keep
their snapshot.

`recipe_process_steps` checkboxes are **not** used to decide (unreliable:
e.g. Mooie Nel has dry_hop_warm and bevasil false while the recipe uses them).
Steps are editable and reorderable in the recipe editor; edited steps get
`is_generated = false`.

## Cellar plan progress (batch)
- A tag that names a step (`fermentation_log_entry_tags.batch_cellar_step_id`)
  ticks off that step. The other tags are counted per tag, ordered by
  `measured_at`: the n-th of them ticks off the n-th step with that tag that
  no tag names (a tag twice on one entry counts twice).
- Adding the tag **Addition** while two or more Addition steps are open asks
  "Which step is this addition?"; the chip then shows the step
  ("Addition · Super F"). Other tags (cooling, dry hop, …) follow the plan
  order without asking. The n-th occurrence of tag T ticks off the n-th
  `batch_cellar_steps` row (by `sort_order`) with tag T.
- Done step: green, ✓, date/time/initials of that log entry.
- First open step: orange, "next".
- Tasks x/y on the Active batches tile = done / total.

## Calculators (show only when relevant)
- Nagardo: recipe has an ingredient named Nagardo. Weight g = volume l ×
  ppm / 1000; water l = weight / 10 (1 % solution).
- PGA/alginate: recipe cellar addition PGA/alginate. Volume before centrifuge
  l = rate l/hl × volume l / 100; alginate g = that × 0.02 × 1000; hot water l
  = same volume.
- Nano Flavor: recipe is dealcoholised (concept, mockup only).
- "Save to log" adds a log entry with tag Addition and the calculated text.

## Processing / HBT
- Duration = end_time − start_time (an end before the start runs past
  midnight).
- **Minimum maturation** (check before processing, ticked automatically):
  days since lagering started (`batch_stages.lagering_started_at`) ≥
  `recipe_fermentation.lagering_time`. Not ticked while lagering has not
  started or the recipe has no lagering time.
- Cellar additions with a timing that shows on Processing (Settings › Cellar
  plan) are in the card **Additions processing · per HBT** (22-10; before:
  bullets under "From recipe", which keeps
  `recipe_process_steps.processing_comment`): rate, timing, batch amount and
  a tick box per HBT (`batch_dosing_checks`); under each box the amount for
  that HBT (rate × its end level) when the rate is per hl / l. "n/m added".
- The calculators (Nagardo, PGA / alginate) are also on Processing; "Save as
  comment" adds a processing comment.
- HBT end value = last `hbt_readings` row (by `sort_order`) of that HBT that
  has a level (a new row still being filled in does not count yet).
  Total end volume = Σ end levels.
- **Same HBT twice** (Jaap, 21-10): a tank can be filled, emptied and filled
  again for one batch; each fill is its own HBT row. The pages then name it
  with the day it was filled: "HBT16 · 01-10" (the first processing date of
  the sessions its readings belong to, else the day the row was made;
  "(2)" for a second fill that day, "(fill 2)" without a day). A tank used
  once keeps its plain code. "+ Add HBT" also offers a used tank ("fill
  again"). In the Split / transfer popup the tank is one "from" tank with
  the end value of its latest fill.
- CO2 status per reading: spec by `co2_target` from `recipe_packaging`
  (`co2_bottle_can_spec` ± `co2_bottle_can_tolerance`, keg: `co2_keg_spec` ±
  `co2_keg_tolerance`) → OK / High / Low.
- Red markers: O2 ≥ HBT spec (50 ppb), start turbidity and avg turbidity >
  `recipe_fermentation.turbidity_after_separation`, avg PU outside
  `pasteurization` ± tol.
- **Cellar loss** = volume into GLT (GLT total of the brews) − splits from
  GLT/LT (transfers whose from-tank is not one of the batch's HBTs) − total
  HBT end volume. Negative → red warning "More out than in — check splits and HBT
  volumes".

## Filling
- Quality / Cpk over all filling measurements of the batch; limits from
  `recipe_packaging` (TPO, HSO, DO, CO2 bottle/can, keg CO2/O2). Cpk ≥ 1.33
  green, ≥ 1 amber, < 1 red. (Formula in mockup `Filling.dc.html`.)
  Built in `filling.js`: a maximum (TPO, HSO, DO, keg O2) is "< limit"; when
  the recipe has no value the house limit is used (TPO 100, HSO 50, DO 50,
  keg O2 50 ppb, marked "house limit"); CO2 = spec ± tolerance, no Cpk
  without a recipe spec. Cpk = min(hi − mean, mean − lo) / 3σ (sample σ),
  estimated share in spec from the normal distribution; at least 2 values.
- Out-of-spec measurement cells are red with the same limits.
- **Day number** = day of the year, three digits: 1 January = 001 …
  31 December = 365 / 366 (Jaap, 20-10); shown for today and per filling
  session date.
- A new filling session takes today, the first HBT that is not finished, and
  its package when the HBT has one format. "Filled by" = who added the
  session (`created_by`). "HBT finished?" needs an HBT.
- HBT finished: an HBT is finished when any of its filling sessions has
  `is_hbt_finished`.

## Filling report — volume balance
Brewed into GLT → − splits from GLT/LT → − cellar loss → = in HBT after
processing → − splits from HBT → − packaged (bottle, can, keg) → = filling
remainder/loss (% of available for filling; ≤ 3 % green). Pie chart of
the shares of the GLT volume: bottle, can, keg, splits, cellar loss, filling
remainder.
- Brewed into GLT = the GLT total of Brewing (brews with a volume and an
  extract); in HBT = Σ HBT end values (Processing); a split from one of the
  batch's HBTs is "from HBT", any other split "from GLT / LT".
- Packaged per type = Σ count × litres per article, by the article's
  package (bottle, can, keg, tank: tank beer for the Jopenkerk, own pie part). Negative parts (more out than in) count 0 in the pie; the cellar
  loss row turns red with "More out than in".
- Per session: book in = count per article (litres = count × litres per
  article); book out = materials used. Expected per material = Σ count ×
  BOM quantity of the booked articles; loss = used − expected (> 0 amber:
  material lost; < 0 red: check the count; 0 green; "—" while used is
  empty). Filled litres against the session volume (Filling tab): ±3 %
  green. Module `filling-report.js`, test `tests/filling-report.test.js`.
- Summary: produced per SKU (= per packaging article, open-questions #13),
  the splits, totals, and the materials over all sessions.

## Transfers (splits)
- A transfer reduces the source volume and adds an incoming line on the
  receiving batch from `transferred_at`.
- New batch from split: next sequential batch number, brew count 0, recipe
  must exist; its ingredients are dosed on the **total** volume (Σ incoming).
- Built (phase 8), `split_batch()` (one transaction, rights of the user):
  - destination **new**: the next number of the year = highest
    `YY` + 3 digits + 1 (e.g. 26351 → 26352), name = recipe name, 0 brews,
    status planned; the insert trigger snapshots its ingredients and cellar
    plan; **batch**: an existing batch by number (not itself); **discard**:
    reason required.
  - always a log entry on the source batch at the transfer moment, tag
    Transfer, text "Transfer · 20.0 hl from GLT7 to new batch 26352 (Nel
    Framboos) · comment".
- **Dosing volume** (Jaap, 20-10) = brews × brew volume + Σ incoming
  transfers (`batch_stages.incoming_volume_hl`); per-brew amounts (malt,
  boil hops) follow the brews only. Batches with a fractional brew count
  (3.33, the old workaround) keep dosing on it; do not record a split into
  such a batch as well (it would count twice).
- **Base beer** in a recipe: `addition_type = 'base_beer'`,
  `source_recipe_group_id` = the source beer over all its versions,
  quantity = share in % (> 0, ≤ 100), no ingredient. The popup compares the
  incoming beer per recipe group with the shares (expected hl = share ×
  total incoming) and warns when the source beer is not a base beer of the
  receiving recipe (a warning, not a block).
- Cellar loss and the volume balance count the incoming beer with the GLT
  volume ("+ In from splits"); the pie shares are of brewed + received.
- Popup: "<tank> after transfer" = the volume in the tank (GLT total +
  incoming, or the HBT end value) − transfers out of it − this one.
- Deleting a transfer keeps a batch made by the split and the log entry.
- Deleting a batch (Batch creation): a batch that received beer from a split
  cannot be deleted while that transfer exists; the message names the source
  batch, volume and date (and stock movements, the other block). Deleting a
  source batch deletes its transfers out; the confirm question names the
  receiving batches.
- Module `splits.js` (next number preview, log text, tank after transfer,
  base beer check), test `tests/splits.test.js`; dosing in
  `batch-ingredients.js` (`dosingVolumeHl`, `amountContext`).

## Needs attention (!) on Active batches
To be defined by Jaap (open-questions). Mockup examples: overdue cellar step,
lab result missing, lagering longer than spec, release pending > n days, brew
tomorrow and not picked. Tile shows its two normal status lines plus a red
third line with the reason.
