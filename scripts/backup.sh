#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ensure_env
wait_for_db

backup_dir="$PROJECT_ROOT/backups"
mkdir -p "$backup_dir"
output="${1:-$backup_dir/${POSTGRES_DB}_$(date -u +%Y%m%dT%H%M%SZ).dump}"

docker exec "$DB_CONTAINER" pg_dump \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --format=custom --no-owner --no-privileges >"$output"

test -s "$output"
echo "$output"
