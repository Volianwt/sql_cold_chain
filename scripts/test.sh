#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ensure_env
wait_for_db

run_sql_file /sql/03_data_quality_checks.sql

business_output="$(mktemp)"
trap 'rm -f "$business_output"' EXIT
run_sql_file /sql/04_business_queries.sql >"$business_output"

docker exec -i "$DB_CONTAINER" psql -X -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
DO $$
DECLARE
    total_shipments BIGINT;
    delivered_shipments BIGINT;
    late_deliveries BIGINT;
    cancelled_shipments BIGINT;
    open_non_cancelled BIGINT;
    historical_open BIGINT;
    base_table_count BIGINT;
    primary_key_count BIGINT;
    foreign_key_count BIGINT;
    check_constraint_count BIGINT;
    unique_constraint_count BIGINT;
    view_count BIGINT;
    portfolio_index_count BIGINT;
    extreme_customer_rates BIGINT;
    extreme_driver_rates BIGINT;
BEGIN
    SELECT COUNT(*) INTO base_table_count
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

    IF base_table_count <> 8 THEN
        RAISE EXCEPTION 'Expected 8 base tables, found %', base_table_count;
    END IF;

    IF (SELECT COUNT(*) FROM customers) <> 100
        OR (SELECT COUNT(*) FROM locations) <> 50
        OR (SELECT COUNT(*) FROM drivers) <> 100
        OR (SELECT COUNT(*) FROM vehicles) <> 80
        OR (SELECT COUNT(*) FROM shipment_status_history) <> 101832
        OR (SELECT COUNT(*) FROM temperature_readings) <> 231225
        OR (SELECT COUNT(*) FROM invoices) <> 19097 THEN
        RAISE EXCEPTION 'One or more deterministic table counts differ from the expected seed';
    END IF;

    SELECT
        COUNT(*) FILTER (WHERE c.contype = 'p'),
        COUNT(*) FILTER (WHERE c.contype = 'f'),
        COUNT(*) FILTER (WHERE c.contype = 'c'),
        COUNT(*) FILTER (WHERE c.contype = 'u')
    INTO primary_key_count, foreign_key_count,
         check_constraint_count, unique_constraint_count
    FROM pg_constraint AS c
    JOIN pg_namespace AS n ON n.oid = c.connamespace
    WHERE n.nspname = 'public';

    IF (primary_key_count, foreign_key_count,
        check_constraint_count, unique_constraint_count) <> (8, 8, 17, 9) THEN
        RAISE EXCEPTION 'Unexpected constraint counts: PK %, FK %, CHECK %, UQ %',
            primary_key_count, foreign_key_count,
            check_constraint_count, unique_constraint_count;
    END IF;

    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE actual_delivery_at IS NOT NULL),
        COUNT(*) FILTER (WHERE actual_delivery_at > scheduled_delivery_at)
    INTO total_shipments, delivered_shipments, late_deliveries
    FROM shipments;

    IF (total_shipments, delivered_shipments, late_deliveries)
        <> (20000, 19097, 4202) THEN
        RAISE EXCEPTION 'Unexpected shipment metrics: total %, delivered %, late %',
            total_shipments, delivered_shipments, late_deliveries;
    END IF;

    WITH current_status AS (
        SELECT DISTINCT ON (shipment_id)
            shipment_id, status
        FROM shipment_status_history
        ORDER BY shipment_id, status_time DESC, status_id DESC
    )
    SELECT
        COUNT(*) FILTER (WHERE cs.status = 'CANCELLED'),
        COUNT(*) FILTER (
            WHERE cs.status <> 'CANCELLED' AND s.actual_delivery_at IS NULL
        ),
        COUNT(*) FILTER (
            WHERE cs.status <> 'CANCELLED'
              AND s.actual_delivery_at IS NULL
              AND s.scheduled_pickup_at < TIMESTAMPTZ '2026-01-01 00:00:00+00'
        )
    INTO cancelled_shipments, open_non_cancelled, historical_open
    FROM shipments AS s
    JOIN current_status AS cs USING (shipment_id);

    IF (cancelled_shipments, open_non_cancelled, historical_open)
        <> (689, 214, 0) THEN
        RAISE EXCEPTION 'Unexpected status metrics: cancelled %, open %, historical open %',
            cancelled_shipments, open_non_cancelled, historical_open;
    END IF;

    SELECT COUNT(*) INTO view_count
    FROM information_schema.views
    WHERE table_schema = 'public'
      AND table_name IN (
          'vw_shipment_current_status',
          'vw_customer_delivery_performance',
          'vw_invoice_aging'
      );

    IF view_count <> 3 THEN
        RAISE EXCEPTION 'Expected 3 reporting views, found %', view_count;
    END IF;

    SELECT COUNT(*) INTO portfolio_index_count
    FROM pg_indexes
    WHERE schemaname = 'public' AND indexname LIKE 'idx_%';

    IF portfolio_index_count <> 4 THEN
        RAISE EXCEPTION 'Expected 4 workload indexes, found %', portfolio_index_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'shipments'
          AND column_name = 'source_system'
    ) THEN
        RAISE EXCEPTION 'Migration 001 was not applied';
    END IF;

    SELECT COUNT(*) INTO extreme_customer_rates
    FROM (
        SELECT customer_id,
            ROUND(
                100.0 * COUNT(*) FILTER (
                    WHERE actual_delivery_at <= scheduled_delivery_at
                ) / NULLIF(COUNT(*) FILTER (
                    WHERE actual_delivery_at IS NOT NULL
                ), 0),
                2
            ) AS on_time_pct
        FROM shipments
        GROUP BY customer_id
    ) AS customer_rates
    WHERE on_time_pct IN (0, 100);

    SELECT COUNT(*) INTO extreme_driver_rates
    FROM (
        SELECT driver_id,
            ROUND(
                100.0 * COUNT(*) FILTER (
                    WHERE actual_delivery_at <= scheduled_delivery_at
                ) / NULLIF(COUNT(*), 0),
                2
            ) AS on_time_pct
        FROM shipments
        WHERE actual_delivery_at IS NOT NULL
        GROUP BY driver_id
    ) AS driver_rates
    WHERE on_time_pct IN (0, 100);

    IF extreme_customer_rates <> 0 OR extreme_driver_rates <> 0 THEN
        RAISE EXCEPTION 'Found extreme synthetic rates: customers %, drivers %',
            extreme_customer_rates, extreme_driver_rates;
    END IF;
END;
$$;

SELECT
    COUNT(*) AS total_shipments,
    COUNT(*) FILTER (WHERE actual_delivery_at IS NOT NULL) AS delivered_shipments,
    COUNT(*) FILTER (WHERE actual_delivery_at > scheduled_delivery_at) AS late_deliveries,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE actual_delivery_at <= scheduled_delivery_at
        ) / NULLIF(COUNT(*) FILTER (
            WHERE actual_delivery_at IS NOT NULL
        ), 0),
        2
    ) AS on_time_delivery_pct
FROM shipments;
SQL

echo "PASS: 8 tables, 15 structural checks, seed metrics, migration, indexes, views, and all 12 business queries."
