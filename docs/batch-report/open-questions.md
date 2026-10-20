# Open questions

Do not decide these yourself. Ask Jaap (or the chat), or build the phase
without the open part and note it in the PR.

| # | Question | Needed in phase |
|---|---|---|
| 1 | **Needs attention (!)**: which situations make a tile show "!"? (Mockup examples: overdue cellar step, lab result missing, lagering over spec, release pending > n days, brew tomorrow and not picked.) | 1 (can ship without "!") |
| 2 | ~~All batches default filter: **All** or **Active**?~~ **Answered 19-10:** always all batches, no Active/Closed toggle; active ones are on Active batches. | 1 |
| 3 | ~~Fermentation → Lagering: when the cellar plan step "Cooling to [lagering temp]" is done (or LT set)?~~ **Answered 19-10:** only when that cooling step is done; setting an LT does not count. | 4 |
| 4 | ~~Sample to lab: after the last cooling step only, or also after cooling to 16 °C?~~ **Answered 19-10:** after the last cooling. | 4 |
| 5 | ~~Cellar additions: which timings become cellar plan steps, which go to Processing?~~ **Answered 19/20-10:** standard timing values (dropdown, managed in Settings › Cellar plan); the 45 texts were mapped in the review sheet and replaced in phase 4. | 4 |
| 17 | ~~Dry hop `cold_2` (cold dry hop at or below the lagering temperature): order of the steps?~~ **Answered 19-10:** cooling to the lagering temperature, sample to lab, then the dry hop. Dry hop timings fixed from the review; Quiet XPA keeps 2 lines without timing for now. | 4 |
| 6 | Add `stock_movements.batch_ingredient_id` to link consumption exactly to added batch rows? Phase 2 matches lots by ingredient group, which also covers added rows; only needed if the same ingredient appears twice with different lots. | 2 (built without) |
| 7 | Unused empty columns on `batches` (`operator`, `extract`, `alcohol`, `bitterness`, `color`, `ph`, `total_final_volume`, `brew_date`): drop later, or keep? `brew_date` duplicates brew 1 start. | any (separate cleanup) |
| 8 | Who signs the filling report; four-eyes (not the person who completed it)? Fields for comments filling / Mdrank entry. (Parked: Jaap talks with the admin.) | 7 |
| 9 | ~~Base beer in a recipe: reference the source beer by recipe group (share in %), or as a normal ingredient per beer?~~ **Answered 20-10:** by recipe group (the beer over all its versions), with a share in %; a blend of two beers = two lines. The split form records the volume. | 8 |
| 10 | "OGW" meaning (Excel). | — |
| 11 | Keep the checkbox "Do hops smell fresh?"? | 3 |
| 12 | ~~Four-eyes check for Nagardo?~~ **Answered 19-10:** not now. | 4 |
| 13 | Definition of a SKU in the Summary (article, or beer + package) and layout per Mdrank. **Built 20-10 as one line per packaging article**; the Mdrank layout ("Copy for Mdrank") waits. | 7 |
| 14 | Translations awaiting Jaap: ~~Discharges / Interval · Standpipe / Bottom valve~~ (OK as is, 20-10) · JK labels · Filling labels · Split / transfer, Transfer moment, To batch, Incoming beer, One line per source beer, Base beer (built with these labels in phase 8). | per phase |
| 15 | ~~Beer status / beer risk dropdown list: what exactly is needed?~~ **Answered 19-10:** the values in the existing recipes; these are already the lists in `recipe-values.js`, the check constraints and the recipe editor dropdowns. Nothing to build. | 0 |
| 16 | ~~Tanks: all HBTs at WP? CKT used for both fermentation and lagering?~~ **Answered 19-10:** yes, all HBTs are at WP; a CKT is a combi tank. | 0 |
