/*
Cold-Chain Freight Operations Database
File: 03_data_quality_checks.sql

Purpose:
Demonstrate database validation, integrity monitoring, and operational
exception detection. Structural checks should return PASS. Operational
exceptions are intentionally present in the synthetic dataset and should
return REVIEW.

Run from the project root:
docker exec -i freight-postgres psql -U freight_user -d freight_ops < sql/03_data_quality_checks.sql
*/

\pset pager off
\timing on
\set as_of_date '2026-07-16'

\echo ''
\echo '============================================================'
\echo 'A. STRUCTURAL DATA QUALITY SUMMARY'
\echo 'Expected result: every check should show PASS and issue_count 0'
\echo '============================================================'

CREATE TEMP TABLE dq_structural_results AS
WITH structural_checks AS (
    SELECT
        'Missing required shipment values' AS check_name,
        COUNT(*) AS issue_count
    FROM shipments
    WHERE
        reference_number IS NULL
        OR customer_id IS NULL
        OR origin_location_id IS NULL
        OR destination_location_id IS NULL
        OR scheduled_pickup_at IS NULL
        OR scheduled_delivery_at IS NULL
        OR cargo_type IS NULL

    UNION ALL

    SELECT
        'Duplicate shipment reference numbers',
        COUNT(*)
    FROM (
        SELECT reference_number
        FROM shipments
        GROUP BY reference_number
        HAVING COUNT(*) > 1
    ) AS duplicate_references

    UNION ALL

    SELECT
        'Broken shipment foreign-key relationships',
        COUNT(*)
    FROM shipments AS s
    LEFT JOIN customers AS c
        ON c.customer_id = s.customer_id
    LEFT JOIN drivers AS d
        ON d.driver_id = s.driver_id
    LEFT JOIN vehicles AS v
        ON v.vehicle_id = s.vehicle_id
    LEFT JOIN locations AS origin
        ON origin.location_id = s.origin_location_id
    LEFT JOIN locations AS destination
        ON destination.location_id = s.destination_location_id
    WHERE
        c.customer_id IS NULL
        OR origin.location_id IS NULL
        OR destination.location_id IS NULL
        OR (s.driver_id IS NOT NULL AND d.driver_id IS NULL)
        OR (s.vehicle_id IS NOT NULL AND v.vehicle_id IS NULL)

    UNION ALL

    SELECT
        'Origin and destination are identical',
        COUNT(*)
    FROM shipments
    WHERE origin_location_id = destination_location_id

    UNION ALL

    SELECT
        'Invalid scheduled or actual timelines',
        COUNT(*)
    FROM shipments
    WHERE
        scheduled_delivery_at <= scheduled_pickup_at
        OR (
            actual_pickup_at IS NOT NULL
            AND actual_delivery_at IS NOT NULL
            AND actual_delivery_at < actual_pickup_at
        )

    UNION ALL

    SELECT
        'Shipments missing all status history',
        COUNT(*)
    FROM shipments AS s
    WHERE NOT EXISTS (
        SELECT 1
        FROM shipment_status_history AS h
        WHERE h.shipment_id = s.shipment_id
    )

    UNION ALL

    SELECT
        'Delivered timestamp and DELIVERED event disagree',
        COUNT(*)
    FROM shipments AS s
    WHERE
        (s.actual_delivery_at IS NOT NULL)
        <>
        EXISTS (
            SELECT 1
            FROM shipment_status_history AS h
            WHERE
                h.shipment_id = s.shipment_id
                AND h.status = 'DELIVERED'
        )

    UNION ALL

    SELECT
        'Cancelled shipments contain pickup/delivery activity',
        COUNT(*)
    FROM shipments AS s
    WHERE
        EXISTS (
            SELECT 1
            FROM shipment_status_history AS h
            WHERE
                h.shipment_id = s.shipment_id
                AND h.status = 'CANCELLED'
        )
        AND (
            s.actual_pickup_at IS NOT NULL
            OR s.actual_delivery_at IS NOT NULL
            OR s.driver_id IS NOT NULL
            OR s.vehicle_id IS NOT NULL
        )

    UNION ALL

    SELECT
        'Temperature-controlled trips missing readings',
        COUNT(*)
    FROM shipments AS s
    WHERE
        s.required_temperature_c IS NOT NULL
        AND s.actual_pickup_at IS NOT NULL
        AND NOT EXISTS (
            SELECT 1
            FROM temperature_readings AS t
            WHERE t.shipment_id = s.shipment_id
        )

    UNION ALL

    SELECT
        'Dry-goods shipments contain temperature readings',
        COUNT(*)
    FROM shipments AS s
    WHERE
        s.required_temperature_c IS NULL
        AND EXISTS (
            SELECT 1
            FROM temperature_readings AS t
            WHERE t.shipment_id = s.shipment_id
        )

    UNION ALL

    SELECT
        'Duplicate sensor readings',
        COUNT(*)
    FROM (
        SELECT shipment_id, sensor_id, recorded_at
        FROM temperature_readings
        GROUP BY shipment_id, sensor_id, recorded_at
        HAVING COUNT(*) > 1
    ) AS duplicate_readings

    UNION ALL

    SELECT
        'Delivered shipments missing invoices',
        COUNT(*)
    FROM shipments AS s
    WHERE
        s.actual_delivery_at IS NOT NULL
        AND NOT EXISTS (
            SELECT 1
            FROM invoices AS i
            WHERE i.shipment_id = s.shipment_id
        )

    UNION ALL

    SELECT
        'Invoices attached to undelivered shipments',
        COUNT(*)
    FROM invoices AS i
    JOIN shipments AS s
        ON s.shipment_id = i.shipment_id
    WHERE s.actual_delivery_at IS NULL

    UNION ALL

    SELECT
        'Invoice amount differs from shipment revenue',
        COUNT(*)
    FROM invoices AS i
    JOIN shipments AS s
        ON s.shipment_id = i.shipment_id
    WHERE ABS(i.amount - s.agreed_revenue) > 0.01

    UNION ALL

    SELECT
        'Payment status and paid timestamp disagree',
        COUNT(*)
    FROM invoices
    WHERE
        (payment_status = 'PAID' AND paid_at IS NULL)
        OR (payment_status <> 'PAID' AND paid_at IS NOT NULL)
)
SELECT
    check_name,
    issue_count,
    CASE
        WHEN issue_count = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS result
FROM structural_checks
;

SELECT check_name, issue_count, result
FROM dq_structural_results
ORDER BY result DESC, check_name;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM dq_structural_results) <> 15 THEN
        RAISE EXCEPTION 'Expected 15 structural checks, found %',
            (SELECT COUNT(*) FROM dq_structural_results);
    END IF;

    IF EXISTS (
        SELECT 1
        FROM dq_structural_results
        WHERE issue_count <> 0 OR result <> 'PASS'
    ) THEN
        RAISE EXCEPTION 'One or more structural data-quality checks failed';
    END IF;
END;
$$;

\echo ''
\echo '============================================================'
\echo 'B. OPERATIONAL EXCEPTIONS SUMMARY'
\echo 'Expected result: non-zero REVIEW counts are intentional'
\echo '============================================================'

WITH operational_exceptions AS (
    SELECT
        'Late completed deliveries' AS exception_name,
        COUNT(*) AS issue_count
    FROM shipments
    WHERE actual_delivery_at > scheduled_delivery_at

    UNION ALL

    SELECT
        'Currently unassigned, non-cancelled shipments',
        COUNT(*)
    FROM shipments AS s
    WHERE
        s.driver_id IS NULL
        AND NOT EXISTS (
            SELECT 1
            FROM shipment_status_history AS h
            WHERE
                h.shipment_id = s.shipment_id
                AND h.status = 'CANCELLED'
        )

    UNION ALL

    SELECT
        'Temperature excursion readings (> 3 C from target)',
        COUNT(*)
    FROM temperature_readings AS t
    JOIN shipments AS s
        ON s.shipment_id = t.shipment_id
    WHERE ABS(t.temperature_c - s.required_temperature_c) > 3

    UNION ALL

    SELECT
        'Shipments with at least one temperature excursion',
        COUNT(DISTINCT t.shipment_id)
    FROM temperature_readings AS t
    JOIN shipments AS s
        ON s.shipment_id = t.shipment_id
    WHERE ABS(t.temperature_c - s.required_temperature_c) > 3

    UNION ALL

    SELECT
        'Overdue invoices',
        COUNT(*)
    FROM invoices
    WHERE payment_status = 'OVERDUE'

    UNION ALL

    SELECT
        'Outstanding invoice count',
        COUNT(*)
    FROM invoices
    WHERE payment_status IN ('PENDING', 'OVERDUE')
)
SELECT
    exception_name,
    issue_count,
    'REVIEW' AS result
FROM operational_exceptions
ORDER BY issue_count DESC, exception_name;

\echo ''
\echo '============================================================'
\echo 'C. SAMPLE TEMPERATURE EXCURSIONS'
\echo '============================================================'

SELECT
    s.reference_number,
    s.cargo_type,
    s.required_temperature_c AS target_temperature_c,
    t.temperature_c AS recorded_temperature_c,
    ROUND(
        ABS(t.temperature_c - s.required_temperature_c),
        2
    ) AS deviation_c,
    t.recorded_at,
    t.sensor_id
FROM temperature_readings AS t
JOIN shipments AS s
    ON s.shipment_id = t.shipment_id
WHERE ABS(t.temperature_c - s.required_temperature_c) > 3
ORDER BY deviation_c DESC, t.recorded_at
LIMIT 15;

\echo ''
\echo '============================================================'
\echo 'D. SAMPLE OVERDUE INVOICES'
\echo '============================================================'

SELECT
    i.invoice_number,
    s.reference_number,
    c.customer_name,
    i.amount,
    i.due_date,
    :'as_of_date'::DATE - i.due_date AS days_overdue
FROM invoices AS i
JOIN shipments AS s
    ON s.shipment_id = i.shipment_id
JOIN customers AS c
    ON c.customer_id = s.customer_id
WHERE i.payment_status = 'OVERDUE'
ORDER BY days_overdue DESC, i.amount DESC
LIMIT 15;

\echo ''
\echo '============================================================'
\echo 'E. LATEST STATUS VALIDATION USING ROW_NUMBER'
\echo '============================================================'

WITH ranked_statuses AS (
    SELECT
        h.shipment_id,
        h.status,
        h.status_time,
        ROW_NUMBER() OVER (
            PARTITION BY h.shipment_id
            ORDER BY h.status_time DESC, h.status_id DESC
        ) AS row_num
    FROM shipment_status_history AS h
)
SELECT
    s.reference_number,
    r.status AS latest_status,
    r.status_time,
    s.actual_delivery_at
FROM ranked_statuses AS r
JOIN shipments AS s
    ON s.shipment_id = r.shipment_id
WHERE r.row_num = 1
ORDER BY r.status_time DESC
LIMIT 20;

\timing off
