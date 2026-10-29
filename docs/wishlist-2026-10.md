# Wishlist October 2026 — backlog

Colleagues' wishlist (items 2–31), checked against the code and the live
database on 29-10-2026. Built on branch `wishlist-2026-10`, one commit per
item, one pull request at the end.

Size: **S** = hours, **M** = about a day, **L** = several days.
**DB** = needs a migration (Jaap runs it in the SQL Editor and registers it
before the push). **Data** = changes existing rows (confirmed per item).

Status: `open question` → waiting for Jaap · `ready` → can be built ·
`done` · `postponed`.

| # | Item | Area | Size | DB | Status |
|---|------|------|------|----|--------|
| 31 | Batch opens in a new tab | Batch lists | S | – | done |
| 15 | Rename "Final batch volume" → "Final brew volume" | Recipe | S | – | done |
| 13 | Unit in its own column (forecast + Excel) | Consumption forecast | S | – | done |
| 23 | Zinc sulphate grams on the Overview | Batch report | S | – | done |
| 14 | Flow and turbidity in HBT readings | Processing | S | DB | done |
| 17 | Boil time field in the recipe (+ fill it for all recipes) | Recipe | S | DB + Data | done |
| 11 | Wort cooling temperature (recipe + brew log) | Recipe / Brewing | S | DB | done |
| 28 | Filling checks signed with initials | Filling | S | DB | done |
| 24 | Filtration time from start/end time (popup) | Brewing | S | – | done |
| 10 | Zinc sulphate line in every recipe, no amount | Recipe | S | Data | done |
| 18 | Brewery field + editable list in Settings | Recipe / Settings | M | DB | done |
| 22 | Yeast calculator + renamed yeast questions | Brewing / Overview / forecast | M | DB | done |
| 29 | "+ Add" extra addition on Brewing | Brewing / Overview | M | maybe | done |
| 30 | Email processing summary | Processing | M | DB | done |
| 2 | Printable pallet labels | Filling | L | – | done |

All items built (29-10-2026). Decisions from Jaap's answers, and what was
changed in the live data:
- Migrations `20261029123501_wishlist_2026_10_columns` (via the connector)
  and `20261029150000_wishlist_2026_10_breweries_report_recipients` (SQL
  Editor, registered).
- #17: boil time filled for 509 recipes (highest numeric boil hop timing,
  10–180 min), no revisions; 97 stay empty (no boil hops, or 0/1/2000).
- #10: active + draft recipes all have one Zinksulfaat (561) line, timing
  Whirlpool: 70 added, 9 updated (timing, or 562 "(g/brew)" → 561).
- #18: 20 breweries from the names in brackets; every recipe assigned (the
  bracket name, otherwise Jopen) without touching `updated_at`. Left out as
  not a brewery: Glutenvrij, BIO, Red Wine, Whisky, Jack Daniels, Fresh Hop,
  needs updating, niet af; unclear, not added: NPI, BOIL.
- #22: same columns, labels "Yeast Beast used?" / "Temperature GLT checked?";
  the consumption forecast keeps the maximum dosage.
- #2: batch code L<batch>/<HBT tank number> on both labels.

---

## 31 · Batch opens in a new tab — S, ready
Active batches and All batches link to the batch screens with a plain link.
Add `target="_blank"` (plus `rel="noopener"`) in `active-batches.html` and
`all-batches.html`. Ctrl-click keeps working too.

## 15 · "Final batch volume" → "Final brew volume" — S, ready
Label only (`recept-invoer.html` Cooling block, `receptoverzicht.html`). The
column is already `recipe_brewing_specs.brew_final_volume`, so no DB change.

## 13 · Unit in its own column — S, ready
`verbruiksprognose.html`: the amount column gets the number only and a new
"Unit" column; same split in the Excel export. Rounding stays as it is.
The page is still Dutch code; this touches only the table/export part, so no
full translation unless you want that.

## 23 · Zinc sulphate grams on the Overview — S, open question
The calculator on Brewing writes ml onto the batch line (4 ml/hl). The
Overview will show next to it: grams = ml × 0.176 / 4 (0.044 g per ml).
- **Q23:** is 0.176 g per 4 ml a fixed fact (then a constant next to
  `ZINC_ML_PER_HL` in `batch-ingredients.js`), or should it be editable
  somewhere? I suggest the constant.

## 14 · Flow and turbidity in HBT readings — S + DB, ready
`hbt_readings` has level, O2, CO2, CO2 target. New columns `flow_hl_h` and
`turbidity_ebc` (numeric, same units as the processing start values), two
extra inputs per reading on the Processing page, and shown in the HBT
history. RLS: the existing policies on the table cover the new columns.

## 17 · Boil time in the recipe — S + DB + Data, open question
New column `recipe_brewing_specs.boil_time_min`, field in the recipe editor
(Boil block) and shown as target next to "Total boil time" in the brew log.
Fill it for all recipes with the highest boil hop timing (minutes).
- **Q17a:** you wrote "first dry hop"; I read that as the first **boil** hop
  (highest number, e.g. 60 min). Correct?
- **Q17b:** fill all 599 recipes (also archived), or only active/draft?
  Recipes without a numeric boil hop timing stay empty.
- **Q17c:** a new recipe revision for the filled recipes, or a silent fill?
  I suggest silent (no change in brewing content).

## 11 · Wort cooling temperature — S + DB, open question
In the app only (not the Excel). The recipe already has "Start fermentation
temp" (`pitching_temp`), shown on Brewing as target "Wort to GLT temp."
- **Q11a:** is the wort cooling temperature a different value from that
  target, or should the brew log just get an actual "Wort cooling temp" row
  (per brew, next to Aeration) checked against the existing pitching temp?
  If it is the same value, no new recipe field is needed.
- Brew log: new column `batch_brews.wort_cooling_temp_c`, row under
  Aeration.

## 28 · Filling checks with initials — S + DB, open question
The four checks per filling session (first package, fill tube first/end,
burst bottles) are tick boxes now. Proposal: ticking stores who did it
(`…_checked_by` uuid → users) and shows the initials instead of only a tick;
unticking clears it.
- **Q28:** is "the logged-in user" enough, or must the operator pick initials
  from a list (e.g. the first package check needs two operators)?

## 24 · Filtration time from start/end — S, open question
Clicking "Filtration time" on Brewing opens a small popup with start and end
time (hh:mm, past midnight handled) and fills in the minutes. Only the
minutes are stored (no extra rows).
- **Q24:** do you also want to keep the start and end time (two extra
  columns, not shown as rows), or only the minutes?

## 10 · Zinc sulphate line in every recipe — S + Data, open question
254 recipes have no zinc sulphate line (68 active, 2 draft, 184 archived).
The existing lines are mixed: two ingredients ("Zinksulfaat" id 561,
"Zinksulfaat (g/brew)" id 562), timings "bij de gist", "Whirlpool", "GLT",
"15 min", and amounts in g/hl.
- **Q10a:** which ingredient: 561 "Zinksulfaat"?
- **Q10b:** add only to active + draft recipes, or also archived?
- **Q10c:** existing zinc lines: leave as they are, or make them uniform
  (timing "With yeast", no amount)? The calculator overrides the amount on
  the batch anyway.
- **Q10d:** the timing as text: "bij de gist" (as now) or English "With yeast"?
- **Q10e:** should new recipes get the line automatically (default line in
  the recipe editor), or is a one-off fill enough?

## 18 · Brewery field — M + DB, open question
New table `breweries` (name, sort order, active), RLS via the permission
helpers; `recipes.brewery_id` → `breweries`. Recipe editor General tab: a
dropdown. Settings: a new tab "Breweries" to add/rename/deactivate.
- **Q18a:** the starting list: Jopen, GDV, Bird, … — which ones exactly?
- **Q18b:** should existing recipes get a default (e.g. Jopen) or stay empty?
- **Q18c:** show it anywhere else (recipe overview filter, batch lists)?

## 22 · Yeast calculator — M + DB, open question
On Brewing, block "Dry yeast pitching":
- New field "Brews on the first day" between Yeast strain and Weight.
  Weight = brews × brew size (hl) × yeast ratio (g/hl), written onto the
  batch yeast line like the zinc calculator (all in the first brew, the
  calculation as reason). The Overview then shows the grams; until then only
  the ratio.
- Questions renamed: "Rehydrated?" → "Yeast Beast used?", "Yeast program
  on?" → "Temperature GLT checked?".

Implications found:
- **Q22a:** the renamed questions mean something else, so the columns
  should follow (`yeast_rehydrated` → `yeast_beast_used`,
  `yeast_program_on` → `glt_temperature_checked`). Existing answers (from
  the 2026 import) then carry the new meaning. Rename, or new columns and
  keep the old answers?
- **Q22b:** the zinc calculator also asks "brews on the first day". Store
  that number once on the batch (`batches.first_day_brew_count`) and use it
  for both calculators?
- **Q22c:** consumption forecast: today yeast = ratio × hl × all brews. What
  should it use instead: ratio × brew size × an assumed number of first-day
  brews (how many?), or keep it as is until stock booking comes?
- Also affected: the Excel batch report gets the yeast weight from the
  recipe as today (no change unless you want it), filling report/other
  screens do not use these fields.

## 29 · "+ Add" extra addition on Brewing — M, open question
Extra ingredients per batch already exist on the Overview ("Added" lines,
`batch_ingredients.is_added`). Brewing gets a "+ Add" button in "Additions
brewers": ingredient, amount, moment; the tick boxes per brew (already
there) say which brews got it. The line appears on the Overview as "Added".
- **Q29a:** is the amount entered **per brew** (total = amount × ticked
  brews) or the total for the batch?
- **Q29b:** only brewhouse additions here, or any ingredient type?
- Stock booking stays out of scope (as agreed for the batch report); the
  Overview line is what will be booked later.

## 30 · Email processing summary — M + DB, open question
A browser cannot send mail from someone's Outlook account by itself. What
works without IT: an "Email" button that opens a new message in the
default mail program (Outlook) with recipients, subject and a text summary
filled in (`mailto:`), the user presses Send. Limits: plain text, no table
layout, and long summaries may be cut (≈2000 characters).
A real send (with layout, from the account) needs Microsoft Graph / an app
registration in your Microsoft 365 — a separate project.
- **Q30a:** is the `mailto:` approach good enough to start?
- **Q30b:** recipients: a fixed list editable in Settings (new small table),
  or per location?
- **Q30c:** what goes into the summary — an example of the current mail
  would help.

## 2 · Printable pallet labels — L, needs files
Filling page: button "Print pallet label" → popup: choose HBT (batch number
on the label = `L<batch number>/<HBT number>`), labels per pallet (default
2), number of pallets. 2 per pallet × 10 pallets = 20 labels, numbered
1–10, two of each. Keg label one per page; can/bottle label two prints on
one A4 (folded round the pallet corner).
- **Needed:** the current keg and can/bottle pallet labels (file or photo).
- **Q2a:** which fields are on the label besides the batch number and pallet
  number (beer name, format, best before, quantity per pallet, date)?
- **Q2b:** printer: a normal A4 printer (print from the browser)?
- **Q2c:** "HBT number": the tank number or the 1st/2nd/3rd HBT of the batch?
