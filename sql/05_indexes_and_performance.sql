/*
Cold-Chain Freight Operations Database
File: 05_indexes_and_performance.sql

Purpose:
Create workload-driven indexes and print reproducible before/after plans.
The DROP statements make the comparison repeatable in a development dataset.
*/

\pset pager off
\timing on
\set as_of_date '2026-07-16'

DROP INDEX IF EXISTS idx_status_latest;
DROP INDEX IF EXISTS idx_shipments_open_schedule;
DROP INDEX IF EXISTS idx_invoices_outstanding_due;
DROP INDEX IF EXISTS idx_shipments_customer_delivery;
ANALYZE;

\echo ''
\echo 'P1 BEFORE - latest lifecycle event for every shipment'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM (
    SELECT DISTINCT ON (shipment_id)
        shipment_id, status, status_time
    FROM shipment_status_history
    ORDER BY shipment_id, status_time DESC, status_id DESC
) AS latest_status;

\echo ''
\echo 'P2 BEFORE - oldest open operational exceptions'
EXPLAIN (ANALYZE, BUFFERS)
SELECT shipment_id, reference_number, customer_id, scheduled_delivery_at
FROM shipments
WHERE actual_delivery_at IS NULL
  AND scheduled_delivery_at < :'as_of_date'::DATE::TIMESTAMPTZ
ORDER BY scheduled_delivery_at, shipment_id
LIMIT 50;

\echo ''
\echo 'P3 BEFORE - oldest outstanding invoices'
EXPLAIN (ANALYZE, BUFFERS)
SELECT shipment_id, due_date, amount, payment_status
FROM invoices
WHERE payment_status IN ('PENDING', 'OVERDUE')
  AND due_date < DATE '2025-04-01'
ORDER BY due_date, shipment_id
LIMIT 50;

\echo ''
\echo 'P4 BEFORE - customer delivery reporting slice'
EXPLAIN (ANALYZE, BUFFERS)
SELECT actual_delivery_at, agreed_revenue, estimated_cost
FROM shipments
WHERE customer_id = 42
  AND actual_delivery_at >= TIMESTAMPTZ '2026-01-01 00:00:00+00'
ORDER BY actual_delivery_at;

CREATE INDEX idx_status_latest
    ON shipment_status_history (shipment_id, status_time DESC, status_id DESC)
    INCLUDE (status, notes);

CREATE INDEX idx_shipments_open_schedule
    ON shipments (scheduled_delivery_at, shipment_id)
    INCLUDE (reference_number, customer_id)
    WHERE actual_delivery_at IS NULL;

CREATE INDEX idx_invoices_outstanding_due
    ON invoices (due_date, shipment_id)
    INCLUDE (amount, payment_status)
    WHERE payment_status IN ('PENDING', 'OVERDUE');

CREATE INDEX idx_shipments_customer_delivery
    ON shipments (customer_id, actual_delivery_at)
    INCLUDE (agreed_revenue, estimated_cost)
    WHERE actual_delivery_at IS NOT NULL;

ANALYZE;

\echo ''
\echo 'P1 AFTER - latest lifecycle event for every shipment'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM (
    SELECT DISTINCT ON (shipment_id)
        shipment_id, status, status_time
    FROM shipment_status_history
    ORDER BY shipment_id, status_time DESC, status_id DESC
) AS latest_status;

\echo ''
\echo 'P2 AFTER - oldest open operational exceptions'
EXPLAIN (ANALYZE, BUFFERS)
SELECT shipment_id, reference_number, customer_id, scheduled_delivery_at
FROM shipments
WHERE actual_delivery_at IS NULL
  AND scheduled_delivery_at < :'as_of_date'::DATE::TIMESTAMPTZ
ORDER BY scheduled_delivery_at, shipment_id
LIMIT 50;

\echo ''
\echo 'P3 AFTER - oldest outstanding invoices'
EXPLAIN (ANALYZE, BUFFERS)
SELECT shipment_id, due_date, amount, payment_status
FROM invoices
WHERE payment_status IN ('PENDING', 'OVERDUE')
  AND due_date < DATE '2025-04-01'
ORDER BY due_date, shipment_id
LIMIT 50;

\echo ''
\echo 'P4 AFTER - customer delivery reporting slice'
EXPLAIN (ANALYZE, BUFFERS)
SELECT actual_delivery_at, agreed_revenue, estimated_cost
FROM shipments
WHERE customer_id = 42
  AND actual_delivery_at >= TIMESTAMPTZ '2026-01-01 00:00:00+00'
ORDER BY actual_delivery_at;

\timing off
