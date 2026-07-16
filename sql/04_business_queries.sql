/*
Cold-Chain Freight Operations Database
File: 04_business_queries.sql

Purpose:
Answer operational and management questions with practical SQL. This file
demonstrates joins, CTEs, conditional aggregation, correlated subqueries,
window functions, rankings, time-series analysis, and exception reporting.

Run from the project root:
docker exec -i freight-postgres psql -U freight_user -d freight_ops < sql/04_business_queries.sql
*/

\pset pager off
\timing on
\set as_of_date '2026-07-16'

\echo ''
\echo '============================================================'
\echo 'Q1. EXECUTIVE SHIPMENT SUMMARY'
\echo 'Concepts: FILTER, conditional aggregation, NULLIF, ROUND'
\echo '============================================================'

SELECT
    COUNT(*) AS total_shipments,
    COUNT(*) FILTER (WHERE actual_delivery_at IS NOT NULL) AS delivered_shipments,
    COUNT(*) FILTER (WHERE actual_delivery_at IS NULL) AS open_or_cancelled_shipments,
    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE actual_delivery_at <= scheduled_delivery_at
        )
        / NULLIF(
            COUNT(*) FILTER (WHERE actual_delivery_at IS NOT NULL),
            0
        ),
        2
    ) AS on_time_delivery_pct,
    ROUND(
        SUM(agreed_revenue) FILTER (WHERE actual_delivery_at IS NOT NULL),
        2
    ) AS delivered_revenue,
    ROUND(
        SUM(agreed_revenue - estimated_cost)
            FILTER (WHERE actual_delivery_at IS NOT NULL),
        2
    ) AS estimated_margin
FROM shipments;

\echo ''
\echo '============================================================'
\echo 'Q2. CUSTOMER DELIVERY AND REVENUE PERFORMANCE'
\echo 'Concepts: JOIN, GROUP BY, FILTER, conditional aggregation'
\echo '============================================================'

SELECT
    c.customer_id,
    c.customer_name,
    COUNT(*) AS shipment_count,
    COUNT(*) FILTER (WHERE s.actual_delivery_at IS NOT NULL) AS delivered_count,
    COUNT(*) FILTER (
        WHERE s.actual_delivery_at > s.scheduled_delivery_at
    ) AS late_delivery_count,
    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE s.actual_delivery_at <= s.scheduled_delivery_at
        )
        / NULLIF(
            COUNT(*) FILTER (WHERE s.actual_delivery_at IS NOT NULL),
            0
        ),
        2
    ) AS on_time_pct,
    ROUND(
        SUM(s.agreed_revenue)
            FILTER (WHERE s.actual_delivery_at IS NOT NULL),
        2
    ) AS delivered_revenue,
    ROUND(
        SUM(s.agreed_revenue - s.estimated_cost)
            FILTER (WHERE s.actual_delivery_at IS NOT NULL),
        2
    ) AS estimated_margin
FROM customers AS c
JOIN shipments AS s
    ON s.customer_id = c.customer_id
GROUP BY c.customer_id, c.customer_name
ORDER BY delivered_revenue DESC NULLS LAST
LIMIT 15;

\echo ''
\echo '============================================================'
\echo 'Q3. HIGHEST-VOLUME FREIGHT LANES'
\echo 'Concepts: joining the locations table twice, GROUP BY, KPIs'
\echo '============================================================'

SELECT
    origin.city || ', ' || origin.province_state AS origin,
    destination.city || ', ' || destination.province_state AS destination,
    COUNT(*) AS shipment_count,
    ROUND(AVG(s.weight_kg), 2) AS average_weight_kg,
    ROUND(SUM(s.agreed_revenue), 2) AS total_revenue,
    ROUND(SUM(s.agreed_revenue - s.estimated_cost), 2) AS estimated_margin,
    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE s.actual_delivery_at <= s.scheduled_delivery_at
        )
        / NULLIF(
            COUNT(*) FILTER (WHERE s.actual_delivery_at IS NOT NULL),
            0
        ),
        2
    ) AS on_time_pct
FROM shipments AS s
JOIN locations AS origin
    ON origin.location_id = s.origin_location_id
JOIN locations AS destination
    ON destination.location_id = s.destination_location_id
GROUP BY
    origin.location_id,
    origin.city,
    origin.province_state,
    destination.location_id,
    destination.city,
    destination.province_state
ORDER BY shipment_count DESC, total_revenue DESC
LIMIT 15;

\echo ''
\echo '============================================================'
\echo 'Q4. LATEST STATUS FOR ACTIVE EXCEPTION SHIPMENTS'
\echo 'Concepts: CTE, ROW_NUMBER, PARTITION BY, latest-row pattern'
\echo '============================================================'

WITH ranked_statuses AS (
    SELECT
        h.shipment_id,
        h.status,
        h.status_time,
        h.notes,
        ROW_NUMBER() OVER (
            PARTITION BY h.shipment_id
            ORDER BY h.status_time DESC, h.status_id DESC
        ) AS row_num
    FROM shipment_status_history AS h
),
latest_status AS (
    SELECT
        shipment_id,
        status,
        status_time,
        notes
    FROM ranked_statuses
    WHERE row_num = 1
)
SELECT
    s.reference_number,
    c.customer_name,
    ls.status AS latest_status,
    ls.status_time,
    s.scheduled_delivery_at,
    ROUND(
        EXTRACT(
            EPOCH FROM (
                :'as_of_date'::DATE::TIMESTAMPTZ
                - s.scheduled_delivery_at
            )
        ) / 3600.0,
        1
    ) AS hours_past_scheduled_delivery,
    ls.notes
FROM shipments AS s
JOIN customers AS c
    ON c.customer_id = s.customer_id
JOIN latest_status AS ls
    ON ls.shipment_id = s.shipment_id
WHERE
    s.actual_delivery_at IS NULL
    AND ls.status IN ('DELAYED', 'IN_TRANSIT', 'PICKED_UP')
ORDER BY hours_past_scheduled_delivery DESC
LIMIT 20;

\echo ''
\echo '============================================================'
\echo 'Q5. MONTHLY REVENUE GROWTH'
\echo 'Concepts: CTE, DATE_TRUNC, LAG, month-over-month comparison'
\echo '============================================================'

WITH monthly_performance AS (
    SELECT
        DATE_TRUNC('month', actual_delivery_at)::DATE AS delivery_month,
        COUNT(*) AS delivered_shipments,
        SUM(agreed_revenue) AS monthly_revenue,
        SUM(agreed_revenue - estimated_cost) AS monthly_margin
    FROM shipments
    WHERE actual_delivery_at IS NOT NULL
    GROUP BY DATE_TRUNC('month', actual_delivery_at)::DATE
),
with_previous_month AS (
    SELECT
        *,
        LAG(monthly_revenue) OVER (
            ORDER BY delivery_month
        ) AS previous_month_revenue
    FROM monthly_performance
)
SELECT
    delivery_month,
    delivered_shipments,
    ROUND(monthly_revenue, 2) AS monthly_revenue,
    ROUND(monthly_margin, 2) AS monthly_margin,
    ROUND(previous_month_revenue, 2) AS previous_month_revenue,
    ROUND(
        100.0
        * (monthly_revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0),
        2
    ) AS revenue_growth_pct
FROM with_previous_month
ORDER BY delivery_month;

\echo ''
\echo '============================================================'
\echo 'Q6. THREE-MONTH ROLLING OPERATING TREND'
\echo 'Concepts: window frames, rolling AVG, time-series analysis'
\echo '============================================================'

WITH monthly_performance AS (
    SELECT
        DATE_TRUNC('month', actual_delivery_at)::DATE AS delivery_month,
        COUNT(*) AS delivered_shipments,
        SUM(agreed_revenue) AS monthly_revenue
    FROM shipments
    WHERE actual_delivery_at IS NOT NULL
    GROUP BY DATE_TRUNC('month', actual_delivery_at)::DATE
)
SELECT
    delivery_month,
    delivered_shipments,
    ROUND(monthly_revenue, 2) AS monthly_revenue,
    ROUND(
        AVG(delivered_shipments) OVER (
            ORDER BY delivery_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS rolling_3_month_shipments,
    ROUND(
        AVG(monthly_revenue) OVER (
            ORDER BY delivery_month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS rolling_3_month_revenue
FROM monthly_performance
ORDER BY delivery_month;

\echo ''
\echo '============================================================'
\echo 'Q7. TOP THREE CUSTOMERS BY REVENUE IN EACH MONTH'
\echo 'Concepts: multiple CTEs, DENSE_RANK, PARTITION BY'
\echo '============================================================'

WITH customer_monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', s.actual_delivery_at)::DATE AS delivery_month,
        c.customer_id,
        c.customer_name,
        COUNT(*) AS delivered_shipments,
        SUM(s.agreed_revenue) AS monthly_revenue
    FROM shipments AS s
    JOIN customers AS c
        ON c.customer_id = s.customer_id
    WHERE s.actual_delivery_at IS NOT NULL
    GROUP BY
        DATE_TRUNC('month', s.actual_delivery_at)::DATE,
        c.customer_id,
        c.customer_name
),
ranked_customers AS (
    SELECT
        *,
        DENSE_RANK() OVER (
            PARTITION BY delivery_month
            ORDER BY monthly_revenue DESC
        ) AS revenue_rank
    FROM customer_monthly_revenue
)
SELECT
    delivery_month,
    revenue_rank,
    customer_id,
    customer_name,
    delivered_shipments,
    ROUND(monthly_revenue, 2) AS monthly_revenue
FROM ranked_customers
WHERE revenue_rank <= 3
ORDER BY delivery_month DESC, revenue_rank, customer_id
LIMIT 36;

\echo ''
\echo '============================================================'
\echo 'Q8. DRIVER DELIVERY PERFORMANCE'
\echo 'Concepts: JOIN, FILTER, duration calculation, ranking'
\echo '============================================================'

WITH driver_performance AS (
    SELECT
        d.driver_id,
        d.first_name || ' ' || d.last_name AS driver_name,
        COUNT(*) AS delivered_shipments,
        COUNT(*) FILTER (
            WHERE s.actual_delivery_at <= s.scheduled_delivery_at
        ) AS on_time_deliveries,
        ROUND(
            100.0
            * COUNT(*) FILTER (
                WHERE s.actual_delivery_at <= s.scheduled_delivery_at
            )
            / NULLIF(COUNT(*), 0),
            2
        ) AS on_time_pct,
        ROUND(
            AVG(
                EXTRACT(
                    EPOCH FROM (s.actual_delivery_at - s.actual_pickup_at)
                ) / 3600.0
            ),
            2
        ) AS average_transit_hours,
        SUM(s.agreed_revenue) AS delivered_revenue
    FROM drivers AS d
    JOIN shipments AS s
        ON s.driver_id = d.driver_id
    WHERE s.actual_delivery_at IS NOT NULL
    GROUP BY d.driver_id, d.first_name, d.last_name
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY on_time_pct DESC, delivered_shipments DESC
    ) AS performance_rank,
    driver_id,
    driver_name,
    delivered_shipments,
    on_time_deliveries,
    on_time_pct,
    average_transit_hours,
    ROUND(delivered_revenue, 2) AS delivered_revenue
FROM driver_performance
ORDER BY performance_rank
LIMIT 15;

\echo ''
\echo '============================================================'
\echo 'Q9. SHIPMENTS WITH THE MOST SERIOUS TEMPERATURE EXCURSIONS'
\echo 'Concepts: multi-table JOIN, HAVING, conditional aggregation'
\echo '============================================================'

SELECT
    s.reference_number,
    c.customer_name,
    s.cargo_type,
    s.required_temperature_c AS target_temperature_c,
    COUNT(*) AS total_readings,
    COUNT(*) FILTER (
        WHERE ABS(t.temperature_c - s.required_temperature_c) > 3
    ) AS excursion_readings,
    ROUND(
        MAX(ABS(t.temperature_c - s.required_temperature_c)),
        2
    ) AS maximum_deviation_c,
    ROUND(MIN(t.temperature_c), 2) AS minimum_temperature_c,
    ROUND(MAX(t.temperature_c), 2) AS maximum_temperature_c
FROM shipments AS s
JOIN customers AS c
    ON c.customer_id = s.customer_id
JOIN temperature_readings AS t
    ON t.shipment_id = s.shipment_id
GROUP BY
    s.shipment_id,
    s.reference_number,
    c.customer_name,
    s.cargo_type,
    s.required_temperature_c
HAVING COUNT(*) FILTER (
    WHERE ABS(t.temperature_c - s.required_temperature_c) > 3
) > 0
ORDER BY maximum_deviation_c DESC, excursion_readings DESC
LIMIT 20;

\echo ''
\echo '============================================================'
\echo 'Q10. ACCOUNTS-RECEIVABLE AGING'
\echo 'Concepts: CASE buckets, CTE, date arithmetic, aggregation'
\echo '============================================================'

WITH aging_detail AS (
    SELECT
        i.invoice_id,
        i.amount,
        CASE
            WHEN i.payment_status = 'PAID' THEN 'PAID'
            WHEN i.due_date >= :'as_of_date'::DATE THEN 'CURRENT'
            WHEN :'as_of_date'::DATE - i.due_date BETWEEN 1 AND 30 THEN '1-30 DAYS'
            WHEN :'as_of_date'::DATE - i.due_date BETWEEN 31 AND 60 THEN '31-60 DAYS'
            WHEN :'as_of_date'::DATE - i.due_date BETWEEN 61 AND 90 THEN '61-90 DAYS'
            ELSE '90+ DAYS'
        END AS aging_bucket,
        CASE
            WHEN i.payment_status = 'PAID' THEN 1
            WHEN i.due_date >= :'as_of_date'::DATE THEN 2
            WHEN :'as_of_date'::DATE - i.due_date BETWEEN 1 AND 30 THEN 3
            WHEN :'as_of_date'::DATE - i.due_date BETWEEN 31 AND 60 THEN 4
            WHEN :'as_of_date'::DATE - i.due_date BETWEEN 61 AND 90 THEN 5
            ELSE 6
        END AS bucket_order
    FROM invoices AS i
)
SELECT
    aging_bucket,
    COUNT(*) AS invoice_count,
    ROUND(SUM(amount), 2) AS total_amount,
    ROUND(AVG(amount), 2) AS average_invoice_amount
FROM aging_detail
GROUP BY aging_bucket, bucket_order
ORDER BY bucket_order;

\echo ''
\echo '============================================================'
\echo 'Q11. CUSTOMERS WITH ABOVE-AVERAGE LIFETIME REVENUE'
\echo 'Concepts: CTE, subquery comparison, HAVING-style analysis'
\echo '============================================================'

WITH customer_totals AS (
    SELECT
        c.customer_id,
        c.customer_name,
        COUNT(*) FILTER (
            WHERE s.actual_delivery_at IS NOT NULL
        ) AS delivered_shipments,
        SUM(s.agreed_revenue) FILTER (
            WHERE s.actual_delivery_at IS NOT NULL
        ) AS lifetime_revenue
    FROM customers AS c
    JOIN shipments AS s
        ON s.customer_id = c.customer_id
    GROUP BY c.customer_id, c.customer_name
)
SELECT
    customer_id,
    customer_name,
    delivered_shipments,
    ROUND(lifetime_revenue, 2) AS lifetime_revenue,
    ROUND(
        lifetime_revenue
        - (SELECT AVG(lifetime_revenue) FROM customer_totals),
        2
    ) AS revenue_above_average
FROM customer_totals
WHERE lifetime_revenue > (
    SELECT AVG(lifetime_revenue)
    FROM customer_totals
)
ORDER BY lifetime_revenue DESC
LIMIT 20;

\echo ''
\echo '============================================================'
\echo 'Q12. COMBINED OPERATIONAL EXCEPTION REPORT'
\echo 'Concepts: layered CTEs, ROW_NUMBER, LEFT JOIN, severity scoring'
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
),
latest_status AS (
    SELECT shipment_id, status, status_time
    FROM ranked_statuses
    WHERE row_num = 1
),
temperature_summary AS (
    SELECT
        t.shipment_id,
        COUNT(*) FILTER (
            WHERE ABS(t.temperature_c - s.required_temperature_c) > 3
        ) AS excursion_count,
        MAX(ABS(t.temperature_c - s.required_temperature_c)) AS max_deviation_c
    FROM temperature_readings AS t
    JOIN shipments AS s
        ON s.shipment_id = t.shipment_id
    GROUP BY t.shipment_id
),
exception_report AS (
    SELECT
        s.shipment_id,
        s.reference_number,
        c.customer_name,
        ls.status AS latest_status,
        s.scheduled_delivery_at,
        s.actual_delivery_at,
        COALESCE(ts.excursion_count, 0) AS temperature_excursions,
        COALESCE(ts.max_deviation_c, 0) AS maximum_temperature_deviation_c,
        i.payment_status,
        (
            CASE
                WHEN s.actual_delivery_at > s.scheduled_delivery_at THEN 3
                ELSE 0
            END
            + CASE
                WHEN COALESCE(ts.excursion_count, 0) > 0 THEN 4
                ELSE 0
              END
            + CASE
                WHEN i.payment_status = 'OVERDUE' THEN 2
                ELSE 0
              END
            + CASE
                WHEN ls.status = 'DELAYED'
                    AND s.actual_delivery_at IS NULL THEN 2
                ELSE 0
              END
        ) AS severity_score
    FROM shipments AS s
    JOIN customers AS c
        ON c.customer_id = s.customer_id
    JOIN latest_status AS ls
        ON ls.shipment_id = s.shipment_id
    LEFT JOIN temperature_summary AS ts
        ON ts.shipment_id = s.shipment_id
    LEFT JOIN invoices AS i
        ON i.shipment_id = s.shipment_id
)
SELECT
    reference_number,
    customer_name,
    latest_status,
    temperature_excursions,
    ROUND(maximum_temperature_deviation_c, 2) AS max_temp_deviation_c,
    payment_status,
    severity_score
FROM exception_report
WHERE severity_score > 0
ORDER BY severity_score DESC, reference_number
LIMIT 25;

\timing off
