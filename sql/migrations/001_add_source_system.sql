/*
Example forward migration.
Adds lineage metadata without rewriting application queries. The default
backfills existing rows and supports future integrations from multiple TMS feeds.
*/

BEGIN;

ALTER TABLE shipments
    ADD COLUMN IF NOT EXISTS source_system VARCHAR(30)
    NOT NULL DEFAULT 'SYNTHETIC_GENERATOR';

ALTER TABLE shipments
    DROP CONSTRAINT IF EXISTS chk_shipments_source_system;

ALTER TABLE shipments
    ADD CONSTRAINT chk_shipments_source_system
    CHECK (source_system IN ('SYNTHETIC_GENERATOR', 'TMS', 'EDI', 'MANUAL'));

COMMENT ON COLUMN shipments.source_system IS
    'Originating integration channel; added by migration 001.';

COMMIT;
