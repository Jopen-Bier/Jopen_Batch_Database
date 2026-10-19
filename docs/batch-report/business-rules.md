# Business rules and calculations

Put shared calculations in a module with a Node test (pattern
`brew-calculations.js`), e.g. `batch-report-calculations.js`. Reuse
`brew-calculations.js` for EBU and malt colour, `recipe-values.js` for value
lists and labels.

## Stage of a batch (view `batch_stages`)
Evaluated top-down, first match wins:

| Stage | Rule |
|---|---|
| `closed` | `batches.status = 'completed'` (later: filling report signed sets this) |
| `filled` | the batch has ≥1 `batch_hbts` and every one has a filling session with `is_hbt_finished` |
| `filling` | the batch has ≥1 `filling_sessions` row |
| `hbt` | a `processing_sessions` row has `processing_date` |
| `lagering` | `lt_tank_id` is set, **or** the `batch_cellar_steps` step with `starts_lagering` is done (open-questions: confirm) |
| `fermentation` | number of brews with `brewing_ended_at` = `batches.brew_count` |
| `brewing` | a brew has `mash_in_started_at` |
| `raw` | otherwise (batch report exists, not brewed yet) |

UI labels: Raw material preparation · Brewing · Fermentation · Lagering ·
HBT · Filling · Filled · Closed. Active batches shows Fermentation and
Lagering as two rows of one "Cellar" block.

- **Start date** = earliest `mash_in_started_at` of the batch.
- **End date** = filling report signed (parked). Until then empty; for
  historical `completed` batches leave empty.

## Initials
`upper(left(first word of name,1) || left(last word of name,1))`; stored in
`users.initials` by trigger when null; editable.

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

## Brewing (per brew, grey/calculated)
- Evaporation % = (boil_end_extract − boil_start_extract) /
  boil_start_extract × 100 (extract-based, as in the mockup; compare with
  `recipe_brewing_specs` desired evaporation).
- Volume to GLT = brew_volume_hl + water_addition_hl.
- Extract to GLT = whirlpool_extract × brew_volume_hl / (brew_volume_hl +
  water_addition_hl).
- GLT total (running): volume = Σ volume to GLT; extract = volume-weighted
  mean of extract to GLT; pH = mean whirlpool_ph.
- Total brewing time = brewing_ended_at − mash_in_started_at (minus pause, JK).
- **GLT total becomes the first fermentation log measurement** (extract, pH)
  at Time 0 — offer it, do not duplicate it silently.
- Result per brew vs recipe: °P at GLT vs `recipe_specs.original_extract` ±
  tol; hl at GLT vs `recipes.brew_volume_hl` ± 0.5.

## Time 0 and days
- Time 0 default = `brewing_ended_at` of the last brew; editable.
- Day of an entry = (measured_at − time_zero) in days, 1 decimal.
- Recipe days (`recipe_process_steps.dry_hop_1_day`, `cellar_addition_day`)
  count from Time 0.

## Cellar plan generation (recipe → `recipe_cellar_steps`)
Fixed order, generated from recipe data:
1. **Dry warm** — if the recipe has `dry_hop` lines with timing `warm`.
   Trigger: extract = `recipe_fermentation.dry_hop_warm_extract_1` ±
   `dry_hop_warm_extract_1_tol`; indicative day = `dry_hop_1_day`. Tag
   `dry_warm`. Links the warm dry hop lines.
2. **Cooling to 16 °C** — only if the recipe has `dry_hop` with timing
   `cold_16`. Trigger: after previous / end of fermentation (final extract).
   Tag `cooling`.
3. **Dryhopping @16 °C** — same condition. Trigger: after previous. Tag
   `dryhopping`. Links the `cold_16` lines.
4. **Cooling to [lagering temp]** — always; temperature =
   `recipe_fermentation.lagering_temp`. Tag `cooling`. `starts_lagering = true`.
5. **Sample to lab** — always, after step 4 (assumed after the *last* cooling
   step — open-questions). Tag `sample_lab`.
6. **Additions** — cellar additions on their day
   (`cellar_addition_day`), tag `addition`, linking the `cellar_addition`
   lines whose timing belongs to the cellar (open-questions: timing is free
   text; lines for processing/centrifuge/HBT are shown on Processing
   instead).

`recipe_process_steps` checkboxes are **not** used to decide (unreliable:
e.g. Mooie Nel has dry_hop_warm and bevasil false while the recipe uses them).
Steps are editable and reorderable in the recipe editor; edited steps get
`is_generated = false`.

## Cellar plan progress (batch)
- Count tag occurrences in `fermentation_log_entry_tags`, ordered by
  `measured_at`. The n-th occurrence of tag T ticks off the n-th
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
- Duration = end_time − start_time.
- HBT end value = last `hbt_readings` row (by `sort_order`) of that HBT.
  Total end volume = Σ end levels.
- CO2 status per reading: spec by `co2_target` from `recipe_packaging`
  (`co2_bottle_can_spec` ± `co2_bottle_can_tolerance`, keg: `co2_keg_spec` ±
  `co2_keg_tolerance`) → OK / High / Low.
- Red markers: O2 ≥ HBT spec (50 ppb), start turbidity and avg turbidity >
  `recipe_fermentation.turbidity_after_separation`, avg PU outside
  `pasteurization` ± tol.
- **Cellar loss** = volume into GLT − splits from GLT/LT − total HBT end
  volume. Negative → red warning "More out than in — check splits and HBT
  volumes".

## Filling
- Quality / Cpk over all filling measurements of the batch; limits from
  `recipe_packaging` (TPO, HSO, DO, CO2 bottle/can, keg CO2/O2). Cpk ≥ 1.33
  green, ≥ 1 amber, < 1 red. (Formula in mockup `Filling.dc.html`.)
- HBT finished: an HBT is finished when any of its filling sessions has
  `is_hbt_finished`.

## Filling report — volume balance
Brewed into GLT → − splits from GLT/LT → − cellar loss → = in HBT after
processing → − splits from HBT → − packaged (bottle, can, keg) → = filling
remainder/loss (% of available for filling; ≤ 3 % green). Pie chart of
the shares of the GLT volume: bottle, can, keg, splits, cellar loss, filling
remainder.

## Transfers (splits)
- A transfer reduces the source volume and adds an incoming line on the
  receiving batch from `transferred_at`.
- New batch from split: next sequential batch number, brew count 0, recipe
  must exist; its ingredients are dosed on the **total** volume (Σ incoming).

## Needs attention (!) on Active batches
To be defined by Jaap (open-questions). Mockup examples: overdue cellar step,
lab result missing, lagering longer than spec, release pending > n days, brew
tomorrow and not picked. Tile shows its two normal status lines plus a red
third line with the reason.
