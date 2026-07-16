#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ensure_env
wait_for_db

backup_file="${1:-}"
target_db="${2:-freight_ops_restore_test}"

if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
    echo "Usage: $0 BACKUP_FILE [TARGET_DB]" >&2
    exit 2
fi

if [[ "$target_db" == "$POSTGRES_DB" ]]; then
    echo "Refusing to overwrite the primary database '$POSTGRES_DB'." >&2
    exit 2
fi

docker exec "$DB_CONTAINER" dropdb \
    -U "$POSTGRES_USER" --if-exists --force "$target_db"
docker exec "$DB_CONTAINER" createdb \
    -U "$POSTGRES_USER" "$target_db"
docker exec -i "$DB_CONTAINER" pg_restore \
    -U "$POSTGRES_USER" -d "$target_db" \
    --no-owner --no-privileges <"$backup_file"

docker exec "$DB_CONTAINER" psql -X -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" -d "$target_db" \
    -c "SELECT CASE WHEN COUNT(*) = 20000 THEN 'PASS' ELSE 'FAIL' END AS restore_check, COUNT(*) AS shipments FROM shipments;"

echo "Restore verified in database: $target_db"
