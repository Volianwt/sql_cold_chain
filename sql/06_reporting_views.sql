/* Stable reporting interfaces for BI tools and ad-hoc analysis. */

BEGIN;

CREATE OR REPLACE VIEW vw_shipment_current_status AS
SELECT DISTINCT ON (h.shipment_id)
    h.shipment_id,
    s.reference_number,
    h.status AS current_status,
    h.status_time,
    h.notes
FROM shipment_status_history AS h
JOIN shipments AS s USING (shipment_id)
ORDER BY h.shipment_id, h.status_time DESC, h.status_id DESC;

CREATE OR REPLACE VIEW vw_customer_delivery_performance AS
SELECT
    c.customer_id,
    c.customer_name,
    COUNT(s.shipment_id) AS shipment_count,
    COUNT(*) FILTER (WHERE s.actual_delivery_at IS NOT NULL) AS delivered_count,
    COUNT(*) FILTER (WHERE s.actual_delivery_at > s.scheduled_delivery_at) AS late_count,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE s.actual_delivery_at <= s.scheduled_delivery_at
        ) / NULLIF(COUNT(*) FILTER (WHERE s.actual_delivery_at IS NOT NULL), 0),
        2
    ) AS on_time_pct,
    ROUND(
        COALESCE(SUM(s.agreed_revenue) FILTER (
            WHERE s.actual_delivery_at IS NOT NULL
        ), 0),
        2
    ) AS delivered_revenue
FROM customers AS c
LEFT JOIN shipments AS s USING (customer_id)
GROUP BY c.customer_id, c.customer_name;

CREATE OR REPLACE VIEW vw_invoice_aging AS
WITH parameters AS (
    SELECT DATE '2026-07-16' AS as_of_date
)
SELECT
    i.invoice_id,
    i.invoice_number,
    i.shipment_id,
    i.amount,
    i.payment_status,
    i.due_date,
    p.as_of_date,
    CASE
        WHEN i.payment_status = 'PAID' THEN 'PAID'
        WHEN i.due_date >= p.as_of_date THEN 'CURRENT'
        WHEN p.as_of_date - i.due_date BETWEEN 1 AND 30 THEN '1-30 DAYS'
        WHEN p.as_of_date - i.due_date BETWEEN 31 AND 60 THEN '31-60 DAYS'
        WHEN p.as_of_date - i.due_date BETWEEN 61 AND 90 THEN '61-90 DAYS'
        ELSE '90+ DAYS'
    END AS aging_bucket
FROM invoices AS i
CROSS JOIN parameters AS p;

COMMENT ON VIEW vw_shipment_current_status IS
    'Latest append-only lifecycle event for each shipment.';
COMMENT ON VIEW vw_customer_delivery_performance IS
    'Customer-level delivery reliability and delivered revenue metrics.';
COMMENT ON VIEW vw_invoice_aging IS
    'Reproducible invoice aging as of 2026-07-16 for the synthetic dataset.';

COMMIT;
