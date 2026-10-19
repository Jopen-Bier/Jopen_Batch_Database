# Test scenarios

Worked examples (from the mockup data) to test calculations against.

## Cellar loss and volume balance (Processing / Filling report)
- Brewed into GLT 7: 80.0 hl.
- Split from GLT 7 (before processing): 3.0 hl → batch 26420.
- HBT end values: HBT 12 = 40.5 hl, HBT 14 = 35.0 hl → total 75.5 hl.
- Cellar loss = 80.0 − 3.0 − 75.5 = **1.5 hl** (1.9 % of GLT volume).
- If HBT 14 ends at 38.0 hl: 80.0 − 3.0 − 78.5 = −1.5 → **red warning**.

## Brewing — volume and extract to GLT
- Brew 1: brew volume 40.1 hl, water addition 0.3 hl, whirlpool extract
  15.2 °P → volume to GLT 40.4 hl; extract to GLT 15.2 × 40.1 / 40.4 =
  **15.09 °P**.
- Brew 2: 40.0 hl + 0.2 hl, 15.1 °P → 40.2 hl; 15.1 × 40.0 / 40.2 =
  **15.02 °P**.
- GLT total: 80.6 hl, extract (40.4 × 15.09 + 40.2 × 15.02) / 80.6 ≈
  **15.06 °P**.
- Evaporation brew 1: boil start extract 14.6, end 15.1 → (15.1 − 14.6) /
  14.6 × 100 = **3.4 %**.

## Cellar plan ticking
Plan: 1 Dry warm (dry_warm), 2 Cooling to 16 °C (cooling), 3 Dryhopping
@16 °C (dryhopping), 4 Cooling to 0 °C (cooling, starts lagering),
5 Sample to lab (sample_lab), 6 Addition · Bevasil (addition).
Log tags in time order: purge, tasting, dry_warm, spunding,
cooling + dryhopping (same row).
- Done: 1 (dry_warm #1), 2 (cooling #1), 3 (dryhopping #1). Next: **4**
  (needs cooling #2). Tasks 3/6. Stage: Fermentation.
- Add a row with tag cooling → 4 done (cooling #2) → stage **Lagering**
  (if open-question 3 is confirmed). Next: 5.

## Deviations (Overview)
Batch of 2 brews × 40 hl.
- Dry hop Cascade T90 recipe 10,000 g, batch 8,000 g → Δ **−2.0 kg**,
  order picking complete → "Return to same lot · CAS90-2025-088".
- Dry hop Cascade T45 2,500 → 3,500 g → Δ **+1.0 kg** → "Extra issue · …".
- Malt Pale Ale 405 kg/brew → 415 → Δ (415 − 405) × 2 = **+20 kg**.
- Bevasil 40 ml/hl → 45 ml/hl → Δ 5 × 80 = **+400 ml**.
- Removed Protafloc 2.75 g/hl → Δ −2.75 × 80 = **−220 g**, change "Removed".

## Stage derivation
| Data | Stage |
|---|---|
| batch only | raw |
| brew 1 has mash_in_started_at | brewing |
| brew_count = 2, both brews have brewing_ended_at | fermentation |
| step "Cooling to [lagering temp]" done | lagering |
| processing session with processing_date | hbt |
| a filling session | filling |
| both HBTs have a session with is_hbt_finished | filled |
| status = completed | closed |
