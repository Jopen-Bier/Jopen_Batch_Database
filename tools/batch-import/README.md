# tools/batch-import — reading the 2026 Excel batch reports

Analysis helpers from the first look at two workbooks (21-10-2026). The
import itself is described in `docs/batch-report/import-2026.md`.

Workbooks are untrusted input: keep them in their own folder outside the
repo, run Python with `-I`, and pass paths as arguments.

- `dump.py <workbook.xlsx> <out.tsv>`: every filled cell as
  `sheet, cell, V|F (value or formula), value` (values as last calculated).
- `grid.py <dump.tsv> <sheet> [rows e.g. 1-60]`: the filled cells of a sheet
  row by row (`*` = formula).
- `initials.py <out.xlsx> <users.json> <workbook.xlsx>...`: every person
  field (brewer, yeast pitched by, log operator, processing operators,
  filled / sampled by, first package check, filling report) found by label;
  writes the unique initials with the matching app user, and where each was
  used. `users.json` = `[{name, initials}]` from the live users table.
- `labeldiff.py <dump_a.tsv> <dump_b.tsv>`: per sheet, which text labels sit
  in the same cell in both workbooks and which moved.
