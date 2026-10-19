# Open questions

Do not decide these yourself. Ask Jaap (or the chat), or build the phase
without the open part and note it in the PR.

| # | Question | Needed in phase |
|---|---|---|
| 1 | **Needs attention (!)**: which situations make a tile show "!"? (Mockup examples: overdue cellar step, lab result missing, lagering over spec, release pending > n days, brew tomorrow and not picked.) | 1 (can ship without "!") |
| 2 | All batches default filter: **All** or **Active**? | 1 |
| 3 | Fermentation → Lagering: when the cellar plan step "Cooling to [lagering temp]" is done (or LT set)? | 4 (view in 1 can treat cellar as one stage) |
| 4 | Sample to lab: after the **last** cooling step only (assumed), or also after cooling to 16 °C? | 4 |
| 5 | Cellar additions: `recipe_ingredients.timing` is free text (lagering, verwerking, HBT, centrifuge, …). Which lines become cellar plan steps, which are shown on Processing? Proposal: timing mentioning processing/verwerking/centrifuge/fuge/HBT → Processing; the rest → cellar plan on `cellar_addition_day`. | 4 |
| 6 | Add `stock_movements.batch_ingredient_id` to link consumption exactly to added batch rows? | 2 |
| 7 | Unused empty columns on `batches` (`operator`, `extract`, `alcohol`, `bitterness`, `color`, `ph`, `total_final_volume`, `brew_date`): drop later, or keep? `brew_date` duplicates brew 1 start. | any (separate cleanup) |
| 8 | Who signs the filling report; four-eyes (not the person who completed it)? Fields for comments filling / Mdrank entry. (Parked: Jaap talks with the admin.) | 7 |
| 9 | Base beer in a recipe: reference the source beer by recipe group (share in %), or as a normal ingredient per beer? | 8 |
| 10 | "OGW" meaning (Excel). | — |
| 11 | Keep the checkbox "Do hops smell fresh?"? | 3 |
| 12 | Four-eyes check for Nagardo? | 4 |
| 13 | Definition of a SKU in the Summary (article, or beer + package) and layout per Mdrank. | 7 |
| 14 | Translations awaiting Jaap: Discharges / Interval · Standpipe / Bottom valve · JK labels · Filling labels · Split / transfer, Transfer moment, To batch, Incoming beer, One line per source beer. | per phase |
| 15 | Beer status / beer risk dropdown list (left open in the architecture work, step 3): what exactly is needed? | 0 |
| 16 | Tanks: all HBTs at WP? CKT used for both fermentation and lagering? | 0 |
