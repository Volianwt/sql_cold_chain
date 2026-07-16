# Performance analysis

## Method

The repeatable experiment in `sql/05_indexes_and_performance.sql` starts with only primary-key and unique-constraint indexes, runs `ANALYZE`, captures four `EXPLAIN (ANALYZE, BUFFERS)` plans, creates workload indexes, runs `ANALYZE` again, and repeats identical queries.

The measurements below were captured on PostgreSQL 16.14 in the Docker environment on 2026-07-16. They are evidence of plan selection for this dataset, not a claim about production throughput.

| Workload | Before plan / buffers | After plan / buffers | Execution time |
|---|---|---|---:|
| Latest event for all 20,000 shipments | unique + incremental sort over `uq_shipment_status_event`; 102,608 hits | ordered `idx_status_latest` index-only scan; 101,794 hits + 1,109 reads during index warm-up | 30.966 → 22.823 ms |
| First 50 overdue open shipments | seq scan of 20,000 rows + top-N sort; 417 hits | `idx_shipments_open_schedule` partial index-only scan; 50 hits + 2 reads | 1.020 → 0.066 ms |
| First 50 old outstanding invoices | seq scan of 19,097 rows + top-N sort; 236 hits | `idx_invoices_outstanding_due` partial index-only scan; 49 hits + 2 reads | 1.374 → 0.045 ms |
| Customer 42 deliveries since 2026-01-01 | seq scan of 20,000 rows; 417 hits | bitmap scan on `idx_shipments_customer_delivery`; 66 hits + 3 reads | 0.945 → 0.108 ms |

## Index rationale

### `idx_status_latest (shipment_id, status_time DESC, status_id DESC)`

`shipment_id` groups each shipment's events; descending timestamp matches latest-first access; `status_id` deterministically breaks timestamp ties. Included status and notes columns support the current-status view without widening the search key.

### `idx_shipments_open_schedule (scheduled_delivery_at, shipment_id) WHERE actual_delivery_at IS NULL`

The partial predicate stores only open/cancelled rows (903 of 20,000 in the verified seed). The leading schedule column supports overdue range filters and oldest-first ordering; `shipment_id` stabilizes ordering. Included reference/customer fields cover the exception list.

### `idx_invoices_outstanding_due (due_date, shipment_id) WHERE payment_status IN (...)`

Paid invoices are excluded, keeping the index focused on the 5,709-row collection workload. `due_date` supports aging ranges and priority ordering; `shipment_id` is the stable tie-breaker.

### `idx_shipments_customer_delivery (customer_id, actual_delivery_at) WHERE actual_delivery_at IS NOT NULL`

Equality on customer comes first, followed by the delivery-time range. Revenue and cost are included for reporting aggregates. Undelivered rows are irrelevant to delivered-performance reports and omitted.

## Why there is no extra temperature index

The unique constraint on `(shipment_id, sensor_id, recorded_at)` already provides an index beginning with `shipment_id`. Each seeded cold-chain shipment has only 15 readings, so PostgreSQL efficiently retrieves that small set and sorts it in memory. A trial `(shipment_id, recorded_at)` index did not improve the measured plan enough to justify extra write and storage cost. At production telemetry scale, the decision should be revisited using real time-range workloads, partitioning, and retention requirements.

## Planner caveats

- A sequential scan can be correct for broad predicates or small tables.
- Index-only scans may still fetch heap pages until vacuum updates the visibility map.
- Cache state explains some run-to-run variation; compare scan shape, rows, and buffers alongside time.
- PostgreSQL statistics and real selectivity should drive index changes; disabling sequential scans would make the demonstration less credible.
