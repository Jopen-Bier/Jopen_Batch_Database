# Screens

The mockup source in `mockup/*.dc.html` is the reference for layout, labels,
example data and interaction. This file lists what the mockup cannot show:
data sources, rules and behaviour. Labels in quotes are the agreed English UI
text. Visual language: same as Recipes/Ingredients/Inventory (cream/green/
amber, `jopen-shared.css`).

## Shared behaviour (all batch screens)
- **Header**: batch number, beer name + recipe version, stage pill, "All
  changes saved" indicator, "Export batch report (.xlsx)" (keeps the existing
  Excel generator; later fed with report data).
- **Tab bar**: Overview · Brewing · Fermentation log · Processing · Filling ·
  Filling report. Suggested pages: `batch-overview.html?id=…`,
  `batch-brewing.html`, `batch-fermentation.html`, `batch-processing.html`,
  `batch-filling.html`, `batch-filling-report.html`, with a shared module for
  header/tabs/loading the batch (e.g. `batch-report-shell.js`).
- **Autosave** on change (blur/change), no save button. Calculated fields
  update on change.
- **Every row and input can be deleted**: confirm dialog ("Delete … ? You can
  undo this right after deleting. The deletion is recorded in the audit
  trail.") → toast "… deleted" with **Undo** (10 s).
- Input cells: yellow background; calculated cells: grey; out of spec: red
  cell (light red background, dark red bold text); deviation from recipe:
  amber.
- Operator columns ("Op.") show `users.initials` of `created_by`.
- Read-only for users without `can_edit('batches')`.
- Brewhouse WP/JK comes from `recipes.location`; JK-only fields hidden for WP
  and vice versa.

## Home — group "Batch reports" (`mockup/Home.dc.html`)
Replace the current "Batches" group on `index.html`: tiles **Batch
creation**, **Active batches** (count active, count "!"), **All batches**
(total). Keep the existing tile style (`jopen-tegel`).

## Active batches (`mockup/ActiveBatches.dc.html`)
- Source: `batch_stages` + the fields per stage.
- Full-width blocks: Raw material preparation · Brewing · Cellar
  (sub-rows Fermentation, Lagering) · HBT · Filling · Filled. Header per
  block: name, count, "! n" when issues, stage rule text.
- Top: summary chips per stage, search (beer, batch, tank), "Needs attention
  · n" toggle, WP/JK filter.
- Compact tiles, **sorted by tank number** (no tank: by batch number). Tile:
  tank chip, batch number, JK label, beer name, **two status lines**, small
  progress bar where relevant; an issue adds a red "!" badge and a red third
  line with the reason. Tile links to the matching tab.
  - Raw: "Order picking dd-mm" / "✓ Picked" (tile green) or "Not picked yet".
    "No order picking date" when the date is empty. No tank chip while a
    batch has no tank.
  - Brewing: "Brew 2 / 3" / "Next: brew 3".
  - Cellar: "Day 4.2 · tasks 1/5" / "Next: <step>" (green "✓ …" when all done).
  - HBT: formats / "✓ Released" (tile green) or "1/2 released".
  - Filling: formats / "1/2 HBT finished".
  - Filled: "76.8 hl packaged" / report status.

## All batches (`mockup/AllBatches.dc.html`)
Table: Batch · Name (+JK) · Version · Status (stage pill, colour per stage) ·
Start date · End date. Sort by clicking headers. Always shows **all** batches (no Active/Closed toggle; active batches have
their own screen). Filters: search, status, year (default all years), WP/JK.
15 rows per page. Batch number links to the Overview. "Export (.xlsx)".

## Overview (`mockup/Overview.dc.html`)
- Progress strip (stage per tab), Batch card (recipe, beer style, brewery,
  brews, beer risk/status pills, Date order picking + **"Order picking
  complete"** checkbox), Recipe revisions (latest), Specifications (recipe,
  read-only).
- Ingredient cards from `batch_ingredients`: Malt & Grains, Hops and Herbs
  (grouped by timing, EBU per line + total vs spec), Hops total weights
  (bar per hop: boil vs dry hop), Additions brewing, Yeasts, Additions cellar.
  - Editable: amount, alpha, EBC; added rows also name (ingredient search),
    unit, timing. Buttons "+ Malt", "+ Boil hop", "+ Dry hop", "+ Addition",
    "+ Yeast", "+ Cellar addition". Delete = soft (`is_removed`).
  - Amber input when ≠ recipe; tooltip "Recipe: <value unit>". Label "Added"
    on new rows.
  - Lot column: lots from `stock_movements` on this batch (read-only; the
    mockup's pencil to change a lot is not built — stock booking is parked).
  - Added row: "+ …" opens an ingredient search (filtered on the card's
    category); the row is saved as soon as an ingredient is picked.
- **"Changes vs recipe · this batch"**: list built from the cards: Change
  (Changed / Added / Removed), ingredient + category, Recipe, Batch, Δ batch,
  Inventory effect, Reason (required, amber when empty). Pill: "Order picking
  complete · awaiting accounting sign-off" / "Not picked yet" + explanation.
- Target water profile (recipe, read-only).

## Brewing (`mockup/Brewing.dc.html`)
- Brew day card: brewhouse (from recipe), recipe name software (WP/JK
  column of `recipe_brewing_specs`), special bin, "Recipe number Braukon"
  (`batches.brewhouse_recipe_number`), brews, GLT, date first brew; recipe
  comments.
- Brew specifications (recipe, read-only): brewhouse settings, recipe targets,
  mash schedule, hop dosing per brew, additions per brew (amount per brew
  calculated), dry yeast pitching (`batches.yeast_*`).
- Brewer's comments (`batch_brew_comments`): time, brew (or All), comment, Op.
- **Brew log** matrix: one column per brew ("Add brew"), rows per field of
  `batch_brews` grouped General · Mashing · Filtration (mash filter WP /
  lauter tun JK) · Boiling · Whirlpool / end of boil · End · Hygiene & CIP
  (JK). Unit and recipe value right after the parameter. Grey calculated rows.
- Result per brew at GLT (°P, hl, pH vs spec) and GLT total.

## Fermentation log (`mockup/Main.dc.html`)
- Batch card: GLT, LT (tank dropdowns), today, beer risk/status, **Time 0**.
- Specifications: ADF and theoretical ABV (calculated from log), fermentation
  and lagering specs from the recipe.
- **Cellar plan · from recipe**: steps from `batch_cellar_steps`; columns
  Step · What · When · Tag · Done. Done = green ✓ with date, time, initials;
  first open = orange "next". Calculators (Nagardo, PGA/alginate, Nano Flavor)
  only when relevant; "Manage action tags" link to Settings.
- **Measurements & actions**: Days · Plato · Temp. high · Temp. low · pH ·
  Plato decr. · Hours · Date · Time · Action (tag chips + "+ tag") ·
  Comments · Op. Missing days shown as dashed rows "+ measurement this day".
  Removing a tag chip asks for confirmation.
- **Splits / transfers out** (`batch_transfers`), same record as on
  Processing and Filling report; "+ Split / transfer" opens the popup.
- Fermentation curve: Plato and temperatures vs days since Time 0, spec lines
  (final extract, warm dry hop extract).

## Settings · action tags (`mockup/Settings.dc.html`)
CRUD of `cellar_action_tags` (label, milestone yes/no, order, active).
Lives on `settings.html` (or its own section) under module `settings`.

## Processing (`mockup/Processing.dc.html`)
- Check before processing (beer risk, minimum maturation auto-check,
  "Cellar adds completed"), Specifications (turbidity after centrifuge,
  pasteurisation, O2 in HBT, CO2 per format).
- **Processing session** tabs ("+ session"): operators, date, start, end,
  duration; processed from (G)LT, outlet Standpipe / Bottom valve,
  Discharges, Interval (min); **Start measurements** table (Centrifuge in:
  time, O2, CO2; Centrifuge out: time, O2, CO2, Start flow, Start turbidity).
- Comments processing (rows) with the recipe processing note; Tasting
  (comment, Go / Not go).
- **Bright beer tanks (HBT)**, blocks stacked full width ("Add HBT"): HBT,
  filled in session(s), Intended for (Bottle/Can/Keg), **Release** button
  ("Mark as released" → "Released · <initials> <date time>"), end value;
  readings table: #, Session, HL, O2, CO2, CO2 target, Spec status, Comments.
- **Total measured volumes**: per HBT: intended for, end HL/O2/CO2 +
  operator inputs Avg. in-line O2, Avg. PU, Avg. turbidity, Avg. flow; total
  end volume, **Cellar loss**, GLT empty?
- Splits / transfers out (same record).

## Filling (`mockup/Filling.dc.html`)
- Batch card: HBTs with status Not started / Filling / ✓ Finished and the
  summary; Specifications (bottle/can, keg) from `recipe_packaging`.
- Filling sessions ("Add filling session"): date, HBT, package, volume,
  start, end, filled by, sampled by; checks (first package two operators,
  fill tube detection first/end, burst bottles for bottle) and **"HBT <n>
  finished?"**; measurements table per package type (bottle/can: TPO, HSO,
  DO, HS vol., pressure, temp, CO2; keg: CO2, O2).
- Quality · process capability (n, average, std, Cpk, est. in spec).

## Filling report (`mockup/FillingReport.dc.html`)
- **Volume balance** table + **pie chart** with legend (hl and % per part).
- Sessions per HBT and package: articles produced, materials used (BOM in/
  out, loss per material).
- Splits / transfers out (same record); comments filling; "Summary" popup
  (litres per SKU, material use, blends).
- Close filling report (Completed / Signed) and Mdrank fields: **parked**.

## Popups
- Calculators (`mockup/Calculators.dc.html`): Nagardo, PGA/alginate; "Save
  to log".
- Nano Flavor (`mockup/NanoFlavor.dc.html`): concept only — do not build
  without Jaap.
- Split / transfer (`mockup/SplitBatch.dc.html`): transfer moment, volume,
  from tank, destination New batch / Existing batch / Discard; new batch:
  recipe (existing only), next batch number, 0 brews; preview of the
  receiving batch (incoming beer lines, recipe ingredients dosed on total
  volume, lots/status). Phase 8.
- Batch creation lot selection (`mockup/BatchCreation.dc.html`): sketch for
  the later inventory coupling — not in these phases.
