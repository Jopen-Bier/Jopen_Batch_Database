#!/usr/bin/env bash
# Publishes a file as one check-run annotation (readable via the checks API).
python3 - "$1" "$2" <<'PY'
import sys
t, f = sys.argv[1], sys.argv[2]
txt = open(f).read()[:60000].replace('%', '%25').replace('\r', '').replace('\n', '%0A')
print(f"::notice title={t}::{txt}")
PY
