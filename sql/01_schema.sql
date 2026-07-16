/*
Cold-Chain Freight Operations Database
File: 01_schema.sql

Purpose:
Create the normalized relational schema and enforce core data-integrity rules.

Run from the project root:
docker exec -i freight-postgres psql -U freight_user -d freight_ops < sql/01_schema.sql
*/

BEGIN;

-- Reporting views are recreated after every development reset.
DROP VIEW IF EXISTS vw_invoice_aging;
DROP VIEW IF EXISTS vw_customer_delivery_performance;
DROP VIEW IF EXISTS vw_shipment_current_status;

-- Development reset: child tables are removed before their parent tables.
DROP TABLE IF EXISTS invoices;
DROP TABLE IF EXISTS temperature_readings;
DROP TABLE IF EXISTS shipment_status_history;
DROP TABLE IF EXISTS shipments;
DROP TABLE IF EXISTS vehicles;
DROP TABLE IF EXISTS drivers;
DROP TABLE IF EXISTS locations;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_name VARCHAR(120) NOT NULL,
    customer_type VARCHAR(30) NOT NULL
        CHECK (customer_type IN ('RETAILER', 'GROWER', 'DISTRIBUTOR', 'MANUFACTURER', 'OTHER')),
    email VARCHAR(255) UNIQUE,
    phone VARCHAR(30),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE locations (
    location_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_name VARCHAR(120),
    address_line VARCHAR(180),
    city VARCHAR(80) NOT NULL,
    province_state VARCHAR(80) NOT NULL,
    country VARCHAR(80) NOT NULL DEFAULT 'Canada',
    postal_code VARCHAR(20),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_location_address
        UNIQUE (address_line, city, province_state, country, postal_code)
);

CREATE TABLE drivers (
    driver_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(60) NOT NULL,
    last_name VARCHAR(60) NOT NULL,
    license_number VARCHAR(50) NOT NULL UNIQUE,
    hire_date DATE NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE vehicles (
    vehicle_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unit_number VARCHAR(30) NOT NULL UNIQUE,
    vehicle_type VARCHAR(40) NOT NULL
        CHECK (vehicle_type IN ('TRACTOR', 'REFRIGERATED_TRAILER', 'DRY_VAN', 'STRAIGHT_TRUCK')),
    model_year SMALLINT NOT NULL
        CHECK (model_year BETWEEN 1990 AND 2100),
    refrigerated BOOLEAN NOT NULL DEFAULT FALSE,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE shipments (
    shipment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference_number VARCHAR(40) NOT NULL UNIQUE,
    customer_id BIGINT NOT NULL,
    driver_id BIGINT,
    vehicle_id BIGINT,
    origin_location_id BIGINT NOT NULL,
    destination_location_id BIGINT NOT NULL,
    scheduled_pickup_at TIMESTAMPTZ NOT NULL,
    actual_pickup_at TIMESTAMPTZ,
    scheduled_delivery_at TIMESTAMPTZ NOT NULL,
    actual_delivery_at TIMESTAMPTZ,
    cargo_type VARCHAR(80) NOT NULL,
    weight_kg NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    agreed_revenue NUMERIC(12, 2) NOT NULL CHECK (agreed_revenue >= 0),
    estimated_cost NUMERIC(12, 2) NOT NULL CHECK (estimated_cost >= 0),
    required_temperature_c NUMERIC(5, 2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_shipments_customer
        FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_shipments_driver
        FOREIGN KEY (driver_id)
        REFERENCES drivers (driver_id)
        ON DELETE SET NULL,

    CONSTRAINT fk_shipments_vehicle
        FOREIGN KEY (vehicle_id)
        REFERENCES vehicles (vehicle_id)
        ON DELETE SET NULL,

    CONSTRAINT fk_shipments_origin
        FOREIGN KEY (origin_location_id)
        REFERENCES locations (location_id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_shipments_destination
        FOREIGN KEY (destination_location_id)
        REFERENCES locations (location_id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_different_locations
        CHECK (origin_location_id <> destination_location_id),

    CONSTRAINT chk_scheduled_timeline
        CHECK (scheduled_delivery_at > scheduled_pickup_at),

    CONSTRAINT chk_actual_timeline
        CHECK (
            actual_pickup_at IS NULL
            OR actual_delivery_at IS NULL
            OR actual_delivery_at >= actual_pickup_at
        ),

    CONSTRAINT chk_required_temperature
        CHECK (
            required_temperature_c IS NULL
            OR required_temperature_c BETWEEN -40 AND 25
        )
);

CREATE TABLE shipment_status_history (
    status_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id BIGINT NOT NULL,
    status VARCHAR(30) NOT NULL
        CHECK (
            status IN (
                'CREATED',
                'ASSIGNED',
                'PICKED_UP',
                'IN_TRANSIT',
                'DELAYED',
                'DELIVERED',
                'CANCELLED'
            )
        ),
    status_time TIMESTAMPTZ NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_status_shipment
        FOREIGN KEY (shipment_id)
        REFERENCES shipments (shipment_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_shipment_status_event
        UNIQUE (shipment_id, status, status_time)
);

CREATE TABLE temperature_readings (
    reading_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id BIGINT NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL,
    temperature_c NUMERIC(5, 2) NOT NULL
        CHECK (temperature_c BETWEEN -80 AND 60),
    sensor_id VARCHAR(50) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_temperature_shipment
        FOREIGN KEY (shipment_id)
        REFERENCES shipments (shipment_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_sensor_reading
        UNIQUE (shipment_id, sensor_id, recorded_at)
);

CREATE TABLE invoices (
    invoice_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_number VARCHAR(40) NOT NULL UNIQUE,
    shipment_id BIGINT NOT NULL UNIQUE,
    invoice_date DATE NOT NULL,
    due_date DATE NOT NULL,
    amount NUMERIC(12, 2) NOT NULL CHECK (amount >= 0),
    payment_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (payment_status IN ('PENDING', 'PAID', 'OVERDUE', 'VOID')),
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_invoice_shipment
        FOREIGN KEY (shipment_id)
        REFERENCES shipments (shipment_id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_invoice_dates
        CHECK (due_date >= invoice_date),

    CONSTRAINT chk_paid_timestamp
        CHECK (
            (payment_status = 'PAID' AND paid_at IS NOT NULL)
            OR (payment_status <> 'PAID' AND paid_at IS NULL)
        )
);

COMMENT ON TABLE shipments IS
    'Central freight order table connecting customers, drivers, vehicles, and locations.';

COMMENT ON TABLE shipment_status_history IS
    'Append-only shipment lifecycle events used to reconstruct current and historical status.';

COMMENT ON TABLE temperature_readings IS
    'Time-series cold-chain sensor readings associated with individual shipments.';

COMMENT ON COLUMN shipments.origin_location_id IS
    'Location where the freight is scheduled to be picked up.';

COMMENT ON COLUMN shipments.destination_location_id IS
    'Location where the freight is scheduled to be delivered.';

COMMIT;
