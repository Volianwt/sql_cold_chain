/*
Cold-Chain Freight Operations Database
File: 02_seed_data.sql

Purpose:
Generate a repeatable, realistic portfolio dataset for SQL analysis.

Expected scale:
- 100 customers
- 50 locations
- 100 drivers
- 80 vehicles
- 20,000 shipments
- Multiple lifecycle events per shipment
- Approximately 200,000+ temperature readings
- One invoice for each delivered shipment

Run from the project root:
docker exec -i freight-postgres psql -U freight_user -d freight_ops < sql/02_seed_data.sql
*/

BEGIN;

-- Make the script safely repeatable during development.
TRUNCATE TABLE
    invoices,
    temperature_readings,
    shipment_status_history,
    shipments,
    vehicles,
    drivers,
    locations,
    customers
RESTART IDENTITY CASCADE;

-- 1. Customers
INSERT INTO customers (
    customer_name,
    customer_type,
    email,
    phone,
    active
)
SELECT
    'Customer ' || LPAD(g::TEXT, 3, '0'),
    CASE MOD(g, 5)
        WHEN 0 THEN 'RETAILER'
        WHEN 1 THEN 'GROWER'
        WHEN 2 THEN 'DISTRIBUTOR'
        WHEN 3 THEN 'MANUFACTURER'
        ELSE 'OTHER'
    END,
    'operations' || g || '@customer' || g || '.example',
    '+1-416-555-' || LPAD(g::TEXT, 4, '0'),
    MOD(g, 20) <> 0
FROM generate_series(1, 100) AS gs(g);

-- 2. Canadian and cross-border logistics locations
WITH city_data AS (
    SELECT *
    FROM (
        VALUES
            (1, 'Toronto', 'Ontario', 'Canada'),
            (2, 'Vittoria', 'Ontario', 'Canada'),
            (3, 'Oshawa', 'Ontario', 'Canada'),
            (4, 'Hamilton', 'Ontario', 'Canada'),
            (5, 'London', 'Ontario', 'Canada'),
            (6, 'Windsor', 'Ontario', 'Canada'),
            (7, 'Ottawa', 'Ontario', 'Canada'),
            (8, 'Montreal', 'Quebec', 'Canada'),
            (9, 'Quebec City', 'Quebec', 'Canada'),
            (10, 'Halifax', 'Nova Scotia', 'Canada'),
            (11, 'Moncton', 'New Brunswick', 'Canada'),
            (12, 'Winnipeg', 'Manitoba', 'Canada'),
            (13, 'Regina', 'Saskatchewan', 'Canada'),
            (14, 'Saskatoon', 'Saskatchewan', 'Canada'),
            (15, 'Calgary', 'Alberta', 'Canada'),
            (16, 'Edmonton', 'Alberta', 'Canada'),
            (17, 'Vancouver', 'British Columbia', 'Canada'),
            (18, 'Surrey', 'British Columbia', 'Canada'),
            (19, 'Detroit', 'Michigan', 'United States'),
            (20, 'Chicago', 'Illinois', 'United States'),
            (21, 'Buffalo', 'New York', 'United States'),
            (22, 'Cleveland', 'Ohio', 'United States'),
            (23, 'Columbus', 'Ohio', 'United States'),
            (24, 'Indianapolis', 'Indiana', 'United States'),
            (25, 'Grand Rapids', 'Michigan', 'United States')
    ) AS t(city_no, city, province_state, country)
)
INSERT INTO locations (
    facility_name,
    address_line,
    city,
    province_state,
    country,
    postal_code
)
SELECT
    'Distribution Facility ' || LPAD(g::TEXT, 2, '0'),
    (100 + g) || ' Logistics Way',
    c.city,
    c.province_state,
    c.country,
    CASE
        WHEN c.country = 'Canada'
            THEN 'A' || MOD(g, 9) || 'A ' || MOD(g + 3, 9) || 'A' || MOD(g + 6, 9)
        ELSE LPAD((48000 + g)::TEXT, 5, '0')
    END
FROM generate_series(1, 50) AS gs(g)
JOIN city_data AS c
    ON c.city_no = ((g - 1) % 25) + 1;

-- 3. Drivers
INSERT INTO drivers (
    first_name,
    last_name,
    license_number,
    hire_date,
    active
)
SELECT
    'Driver' || LPAD(g::TEXT, 3, '0'),
    'Operator' || LPAD(g::TEXT, 3, '0'),
    'ON-DL-' || LPAD(g::TEXT, 6, '0'),
    DATE '2018-01-01' + ((g * 23) % 2400),
    MOD(g, 18) <> 0
FROM generate_series(1, 100) AS gs(g);

-- 4. Vehicles
INSERT INTO vehicles (
    unit_number,
    vehicle_type,
    model_year,
    refrigerated,
    active
)
SELECT
    'UNIT-' || LPAD(g::TEXT, 4, '0'),
    CASE MOD(g, 4)
        WHEN 0 THEN 'TRACTOR'
        WHEN 1 THEN 'REFRIGERATED_TRAILER'
        WHEN 2 THEN 'DRY_VAN'
        ELSE 'STRAIGHT_TRUCK'
    END,
    2017 + MOD(g, 10),
    MOD(g, 4) IN (1, 3),
    MOD(g, 17) <> 0
FROM generate_series(1, 80) AS gs(g);

-- 5. Twenty thousand shipments
WITH shipment_base AS (
    SELECT
        g,
        ((g - 1) % 100) + 1 AS customer_id,
        ((g - 1) % 50) + 1 AS origin_id,
        (((((g - 1) % 50) + 1) - 1 + 1 + MOD(g, 49)) % 50) + 1 AS destination_id,
        TIMESTAMPTZ '2025-01-01 08:00:00+00'
            + MOD(g, 540) * INTERVAL '1 day'
            + MOD(g * 7, 24) * INTERVAL '1 hour' AS pickup_time,
        12 + MOD(g * 11, 109) AS transit_hours,
        MOD(g * 5, 7) - 2 AS pickup_delay_hours,
        CASE
            -- A block term prevents lateness from repeating by customer/driver ID.
            -- Roughly 22% of completed shipments arrive 1-12 hours late.
            WHEN MOD(g * 31 + (g / 100) * 17, 100) < 22
                THEN 1 + MOD(g * 11, 12)
            -- The remaining shipments arrive on time or up to 6 hours early.
            ELSE -6 + MOD(g * 11, 7)
        END AS delivery_delay_hours,
        MOD(g, 29) = 0 AS cancelled,
        CASE MOD(g, 5)
            WHEN 0 THEN 'FRESH_PRODUCE'
            WHEN 1 THEN 'FROZEN_FOOD'
            WHEN 2 THEN 'DAIRY'
            WHEN 3 THEN 'MEAT'
            ELSE 'DRY_GOODS'
        END AS cargo_type
    FROM generate_series(1, 20000) AS gs(g)
),
shipment_enriched AS (
    SELECT
        *,
        pickup_time + transit_hours * INTERVAL '1 hour' AS delivery_time,
        (
            MOD(g, 540) >= 525
            AND MOD(g * 19 + (g / 100) * 7, 13) = 0
        ) AS unassigned,
        CASE
            -- Historical shipments are complete; only recent shipments may remain open.
            WHEN pickup_time + transit_hours * INTERVAL '1 hour'
                < TIMESTAMPTZ '2026-06-15 00:00:00+00'
                THEN TRUE
            ELSE MOD(g * 17 + (g / 100) * 11, 10) < 6
        END AS completed,
        CASE cargo_type
            WHEN 'FRESH_PRODUCE' THEN 4.00
            WHEN 'FROZEN_FOOD' THEN -18.00
            WHEN 'DAIRY' THEN 2.00
            WHEN 'MEAT' THEN -2.00
            ELSE NULL
        END AS required_temp
    FROM shipment_base
)
INSERT INTO shipments (
    reference_number,
    customer_id,
    driver_id,
    vehicle_id,
    origin_location_id,
    destination_location_id,
    scheduled_pickup_at,
    actual_pickup_at,
    scheduled_delivery_at,
    actual_delivery_at,
    cargo_type,
    weight_kg,
    agreed_revenue,
    estimated_cost,
    required_temperature_c
)
SELECT
    'SHP-' || LPAD(g::TEXT, 7, '0'),
    customer_id,
    CASE
        WHEN cancelled OR unassigned THEN NULL
        ELSE ((g - 1) % 100) + 1
    END,
    CASE
        WHEN cancelled OR unassigned THEN NULL
        ELSE ((g - 1) % 80) + 1
    END,
    origin_id,
    destination_id,
    pickup_time,
    CASE
        WHEN cancelled OR unassigned THEN NULL
        ELSE pickup_time + pickup_delay_hours * INTERVAL '1 hour'
    END,
    delivery_time,
    CASE
        WHEN cancelled OR unassigned OR NOT completed THEN NULL
        ELSE delivery_time + delivery_delay_hours * INTERVAL '1 hour'
    END,
    cargo_type,
    (5000 + MOD(g * 137, 35000))::NUMERIC(10, 2),
    ROUND((1200 + MOD(g * 83, 8000) * 0.85)::NUMERIC, 2),
    ROUND(
        ((1200 + MOD(g * 83, 8000) * 0.85)
        * (0.68 + MOD(g, 15) / 100.0))::NUMERIC,
        2
    ),
    required_temp
FROM shipment_enriched;

-- 6. Shipment lifecycle events
INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'CREATED',
    scheduled_pickup_at - INTERVAL '3 days',
    'Shipment order created.'
FROM shipments;

INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'ASSIGNED',
    scheduled_pickup_at - INTERVAL '2 days',
    'Driver and vehicle assigned.'
FROM shipments
WHERE driver_id IS NOT NULL;

INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'PICKED_UP',
    actual_pickup_at,
    'Freight collected from origin.'
FROM shipments
WHERE actual_pickup_at IS NOT NULL;

INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'IN_TRANSIT',
    actual_pickup_at + INTERVAL '1 hour',
    'Shipment departed origin facility.'
FROM shipments
WHERE actual_pickup_at IS NOT NULL;

INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'DELAYED',
    scheduled_delivery_at + INTERVAL '1 hour',
    CASE
        WHEN actual_delivery_at IS NOT NULL
            THEN 'Delivered after the scheduled time.'
        ELSE 'Delivery exception requires follow-up.'
    END
FROM shipments
WHERE
    actual_delivery_at > scheduled_delivery_at
    OR (
        actual_delivery_at IS NULL
        AND actual_pickup_at IS NOT NULL
        AND scheduled_delivery_at < TIMESTAMPTZ '2026-07-01 00:00:00+00'
        AND MOD(shipment_id, 7) = 0
    );

INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'DELIVERED',
    actual_delivery_at,
    'Shipment delivered to destination.'
FROM shipments
WHERE actual_delivery_at IS NOT NULL;

INSERT INTO shipment_status_history (
    shipment_id,
    status,
    status_time,
    notes
)
SELECT
    shipment_id,
    'CANCELLED',
    scheduled_pickup_at - INTERVAL '1 day',
    'Shipment cancelled before pickup.'
FROM shipments
WHERE MOD(shipment_id, 29) = 0;

-- 7. Cold-chain sensor readings
-- Fifteen readings are distributed across each temperature-controlled shipment.
INSERT INTO temperature_readings (
    shipment_id,
    recorded_at,
    temperature_c,
    sensor_id
)
SELECT
    s.shipment_id,
    s.actual_pickup_at
        + (s.scheduled_delivery_at - s.actual_pickup_at)
        * (reading_no::NUMERIC / 16),
    ROUND(
        (
            s.required_temperature_c
            + (MOD(s.shipment_id * reading_no, 31) - 15)::NUMERIC / 10
            + CASE
                WHEN MOD(s.shipment_id + reading_no, 97) = 0 THEN 8
                ELSE 0
              END
        )::NUMERIC,
        2
    ),
    'SNS-' || LPAD(s.vehicle_id::TEXT, 4, '0')
FROM shipments AS s
CROSS JOIN generate_series(1, 15) AS readings(reading_no)
WHERE
    s.required_temperature_c IS NOT NULL
    AND s.actual_pickup_at IS NOT NULL;

-- 8. Invoices for delivered shipments
WITH reporting_parameters AS (
    -- Fixed anchor keeps the synthetic portfolio dataset reproducible.
    SELECT DATE '2026-07-16' AS as_of_date
),
delivered_shipments AS (
    SELECT
        shipment_id,
        actual_delivery_at::DATE + 1 AS invoice_date,
        actual_delivery_at::DATE + 31 AS due_date,
        agreed_revenue,
        ROW_NUMBER() OVER (ORDER BY shipment_id) AS invoice_sequence
    FROM shipments
    WHERE actual_delivery_at IS NOT NULL
),
invoice_data AS (
    SELECT
        d.*,
        CASE
            WHEN MOD(d.shipment_id, 10) < 7 THEN 'PAID'
            WHEN d.due_date < p.as_of_date THEN 'OVERDUE'
            ELSE 'PENDING'
        END AS calculated_status
    FROM delivered_shipments AS d
    CROSS JOIN reporting_parameters AS p
)
INSERT INTO invoices (
    invoice_number,
    shipment_id,
    invoice_date,
    due_date,
    amount,
    payment_status,
    paid_at
)
SELECT
    'INV-' || LPAD(invoice_sequence::TEXT, 7, '0'),
    shipment_id,
    invoice_date,
    due_date,
    agreed_revenue,
    calculated_status,
    CASE
        WHEN calculated_status = 'PAID'
            THEN invoice_date::TIMESTAMPTZ
                + (5 + MOD(shipment_id, 20)) * INTERVAL '1 day'
        ELSE NULL
    END
FROM invoice_data;

COMMIT;

-- Refresh planner statistics so later EXPLAIN ANALYZE results are meaningful.
ANALYZE;

-- Final row-count report
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL
SELECT 'locations', COUNT(*) FROM locations
UNION ALL
SELECT 'drivers', COUNT(*) FROM drivers
UNION ALL
SELECT 'vehicles', COUNT(*) FROM vehicles
UNION ALL
SELECT 'shipments', COUNT(*) FROM shipments
UNION ALL
SELECT 'shipment_status_history', COUNT(*) FROM shipment_status_history
UNION ALL
SELECT 'temperature_readings', COUNT(*) FROM temperature_readings
UNION ALL
SELECT 'invoices', COUNT(*) FROM invoices
ORDER BY table_name;
