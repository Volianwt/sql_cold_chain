# Verified performance snapshot

Captured by `sql/05_indexes_and_performance.sql` on PostgreSQL 16.14.

| Scenario | Before | After | Result |
|---|---:|---:|---|
| Latest status for every shipment | 30.966 ms | 22.823 ms | ordered index-only scan replaces incremental sort |
| Oldest open exceptions | 1.020 ms | 0.066 ms | partial index-only scan |
| Oldest outstanding invoices | 1.374 ms | 0.045 ms | partial index-only scan |
| Customer delivery slice | 0.945 ms | 0.108 ms | bitmap index/heap scan |

Timings are local measurements and vary with cache state and hardware. Full rationale and buffer evidence are in `docs/performance.md`.
