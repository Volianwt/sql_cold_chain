# Business query samples

These values were produced from the deterministic seed by `sql/04_business_queries.sql` and focused verification queries.

## Executive shipment summary

| Total | Delivered | Late | On-time | Delivered revenue | Estimated margin |
|---:|---:|---:|---:|---:|---:|
| 20,000 | 19,097 | 4,202 | 78.00% | $87,799,745.80 | $21,958,715.80 |

## Current shipment status

| Latest status | Shipments |
|---|---:|
| CANCELLED | 689 |
| CREATED | 39 |
| DELAYED | 28 |
| DELIVERED | 19,097 |
| IN_TRANSIT | 147 |

No 2025 shipment remains open in the 2026-07-16 reporting snapshot.

## Accounts-receivable aging

| Aging bucket | Invoices | Amount |
|---|---:|---:|
| PAID | 13,388 | $61,564,275.05 |
| CURRENT | 98 | $430,579.35 |
| 1–30 days | 323 | $1,485,286.60 |
| 31–60 days | 326 | $1,514,451.20 |
| 61–90 days | 334 | $1,532,606.45 |
| 90+ days | 4,628 | $21,272,547.15 |

## Reliability distribution check

Customer on-time delivery rates range from **76.72% to 79.58%**. The test suite also confirms that neither customer nor driver groups contain synthetic 0%/100% extremes.
