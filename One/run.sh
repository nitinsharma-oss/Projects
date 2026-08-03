#!/usr/bin/env bash
# Applies the schema to a scratch database, runs both verification suites, and
# prints the audit evidence pack.
#
#   ./run.sh                        # uses $PGDATABASE or 'nfc'
#   PGHOST=... PGPORT=... ./run.sh
set -euo pipefail
DB="${PGDATABASE:-nfc}"
DIR="$(cd "$(dirname "$0")" && pwd)"

psql -q -d postgres -c "DROP DATABASE IF EXISTS ${DB};" -c "CREATE DATABASE ${DB};"

for f in 01_core.sql 02_cards.sql 03_billing_audit_analytics.sql 04_auth_hardening.sql; do
  echo "applying ${f}"
  psql -q -d "${DB}" -v ON_ERROR_STOP=1 -f "${DIR}/${f}"
done

# The two suites are order-independent by design; each scopes its assertions to
# its own fixtures.
echo; echo "verifying constraints (Step 2)"
psql -q -d "${DB}" -f "${DIR}/99_constraint_tests.sql"

echo; echo "verifying RLS and refresh tokens (Step 3)"
psql -q -d "${DB}" -f "${DIR}/98_auth_rls_tests.sql"

echo; echo "audit evidence pack"
psql -q -d "${DB}" -f "${DIR}/97_audit_evidence.sql"
