#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ensure_env
cd "$PROJECT_ROOT"

docker compose up -d
wait_for_db

run_sql_file /sql/01_schema.sql
run_sql_file /sql/02_seed_data.sql

for migration in "$PROJECT_ROOT"/sql/migrations/*.sql; do
    [[ -e "$migration" ]] || continue
    run_sql_file "/sql/migrations/$(basename "$migration")"
done

run_sql_file /sql/05_indexes_and_performance.sql
run_sql_file /sql/06_reporting_views.sql

echo "Setup complete: PostgreSQL is populated, migrated, indexed, and ready."
