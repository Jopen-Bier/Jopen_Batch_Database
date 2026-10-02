#!/usr/bin/env bash
# Zet een backup terug in een LEGE Postgres-database (de wegwerpcontainer in
# GitHub Actions). Gebruikt door de nachtelijke backup én de wekelijkse
# restore-test, zodat beide exact dezelfde procedure volgen.
#
#   herstel.sh <public-dump> <auth-dump> <doel-connectionstring>
#
# Volgorde is belangrijk:
#   1. supabase_stub.sql  - rollen, schema's en auth.uid()/jwt() die een echt
#                           Supabase-project al heeft
#   2. auth-dump          - auth.users + auth.identities (structuur + data)
#   3. public-dump        - onze eigen tabellen; de 9 foreign keys naar
#                           auth.users slagen alleen als stap 2 al gedaan is
#
# --exit-on-error: elke fout breekt de restore af. Vroeger werden fouten
# "genegeerd" en leek een half mislukte restore geslaagd.
#
# De regel "SCHEMA - public" wordt uit de inhoudsopgave gefilterd: het
# public-schema bestaat al in elke database, opnieuw aanmaken geeft alleen
# een (onschuldige) fout die --exit-on-error anders zou laten afbreken.

set -euo pipefail

PUBLIC_DUMP="$1"
AUTH_DUMP="$2"
DOEL="$3"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/17/bin}"
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIJST="$(mktemp)"

echo "== Stub-schema laden"
"$PG_BIN/psql" "$DOEL" -v ON_ERROR_STOP=1 -q -f "$HIER/supabase_stub.sql"

echo "== auth.users / auth.identities terugzetten"
"$PG_BIN/pg_restore" --no-owner --no-privileges --exit-on-error \
  -d "$DOEL" "$AUTH_DUMP"

echo "== public terugzetten"
"$PG_BIN/pg_restore" -l "$PUBLIC_DUMP" | grep -v ' SCHEMA - public ' > "$LIJST"
"$PG_BIN/pg_restore" --no-owner --no-privileges --exit-on-error \
  -L "$LIJST" -d "$DOEL" "$PUBLIC_DUMP"

rm -f "$LIJST"
echo "== Restore zonder fouten voltooid"
