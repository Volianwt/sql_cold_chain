#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_CONTAINER="${DB_CONTAINER:-freight-postgres}"

ensure_env() {
    if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
        cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
        echo "Created .env from .env.example"
    fi

    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
}

wait_for_db() {
    local attempt
    for attempt in {1..30}; do
        if docker exec "$DB_CONTAINER" pg_isready \
            -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    echo "PostgreSQL did not become ready within 60 seconds." >&2
    return 1
}

run_sql_file() {
    local container_path="$1"
    docker exec "$DB_CONTAINER" psql -X -v ON_ERROR_STOP=1 \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$container_path"
}
