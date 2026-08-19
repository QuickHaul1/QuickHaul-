-- 0001_create_core_tables.sql
-- Initial database schema for QuickHaul freight dispatch marketplace
-- Target: PostgreSQL

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ENUM types
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
        CREATE TYPE user_role AS ENUM ('admin', 'carrier', 'shipper', 'broker');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'agreement_status') THEN
        CREATE TYPE agreement_status AS ENUM ('DRAFT','PENDING_SIGNATURE','ACTIVE','EXPIRING','EXPIRED','TERMINATED','SUSPENDED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'onboarding_status') THEN
        CREATE TYPE onboarding_status AS ENUM ('started','profile_complete','documents_pending','verification_pending','verified','active','failed','needs_attention','suspended');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'load_status') THEN
        CREATE TYPE load_status AS ENUM ('posted','matched','offered','accepted','booked','dispatched','en_route','picked_up','delivered','pod_received','completed','settled','cancelled','expired','disputed');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'offer_status') THEN
        CREATE TYPE offer_status AS ENUM ('sent','viewed','accepted','rejected','expired','cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'booking_status') THEN
        CREATE TYPE booking_status AS ENUM ('pending','booked','pending_dispatch','dispatched','completed','cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'document_status') THEN
        CREATE TYPE document_status AS ENUM ('uploaded','scanning','scanned','extracted','verified','rejected','expired','needs_attention');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ledger_settlement_status') THEN
        CREATE TYPE ledger_settlement_status AS ENUM ('pending','processing','paid','failed','refunded');
    END IF;
END $$;

-- Core tables

-- organizations / businesses
CREATE TABLE IF NOT EXISTS organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name TEXT NOT NULL,
    dba TEXT,
    tax_id TEXT,
    primary_contact_name TEXT,
    primary_contact_email TEXT,
    address JSONB,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- users
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id) ON DELETE SET NULL,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    role user_role NOT NULL,
    full_name TEXT,
    phone TEXT,
    status TEXT DEFAULT 'active',
    mfa_enabled BOOLEAN DEFAULT FALSE,
    last_login_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_users_org_id ON users(org_id);

-- carriers (business-level carrier profile)
CREATE TABLE IF NOT EXISTS carriers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    legal_name TEXT NOT NULL,
    dba TEXT,
    ein TEXT,
    usdot TEXT,
    mc TEXT,
    operating_authority JSONB,
    membership_status TEXT DEFAULT 'inactive', -- membership handled separately
    onboarding_state onboarding_status DEFAULT 'started',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_carriers_org_id ON carriers(org_id);
CREATE INDEX IF NOT EXISTS idx_carriers_usdot ON carriers(usdot);

-- carrier_specs and spec_versions
CREATE TABLE IF NOT EXISTS carrier_specs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    name TEXT,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS spec_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carrier_spec_id UUID REFERENCES carrier_specs(id) ON DELETE CASCADE,
    version_hash TEXT NOT NULL,
    canonical_spec JSONB NOT NULL,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    UNIQUE (carrier_spec_id, version_hash)
);
CREATE INDEX IF NOT EXISTS idx_spec_versions_hash ON spec_versions(version_hash);

-- trucks
CREATE TABLE IF NOT EXISTS trucks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    vin TEXT,
    plate TEXT,
    equipment_type TEXT,
    dims JSONB, -- length/width/height in inches or meters with unit
    weight_capacity_kg NUMERIC,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_trucks_carrier_id ON trucks(carrier_id);

-- drivers
CREATE TABLE IF NOT EXISTS drivers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    full_name TEXT,
    license JSONB,
    contact JSONB,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_drivers_carrier_id ON drivers(carrier_id);

-- availability
CREATE TABLE IF NOT EXISTS availability (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    truck_id UUID REFERENCES trucks(id) ON DELETE SET NULL,
    driver_id UUID REFERENCES drivers(id) ON DELETE SET NULL,
    availability_window JSONB NOT NULL, -- e.g. array of windows or cron-like rules
    timezone TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_availability_carrier_id ON availability(carrier_id);

-- home_time (blackout windows)
CREATE TABLE IF NOT EXISTS home_time (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    blackout_windows JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- documents
CREATE TABLE IF NOT EXISTS documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_type TEXT NOT NULL, -- e.g., 'carrier','driver','truck','load','booking'
    owner_id UUID NOT NULL,
    type TEXT NOT NULL,
    s3_key TEXT NOT NULL,
    metadata JSONB,
    status document_status DEFAULT 'uploaded',
    expiry_date DATE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_documents_owner ON documents(owner_type, owner_id);
CREATE INDEX IF NOT EXISTS idx_documents_expiry ON documents(expiry_date);

-- loads and stops
CREATE TABLE IF NOT EXISTS loads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shipper_org_id UUID REFERENCES organizations(id) ON DELETE SET NULL,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    external_ref TEXT,
    stops JSONB NOT NULL, -- canonical array of stops with pickup/delivery, windows, contacts
    commodity JSONB,
    weight_kg NUMERIC,
    dims JSONB,
    pieces INTEGER,
    equipment_requirements JSONB,
    accessorials JSONB,
    rate_budget JSONB,
    documents JSONB,
    notes TEXT,
    status load_status DEFAULT 'posted',
    posted_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_loads_status ON loads(status);
CREATE INDEX IF NOT EXISTS idx_loads_shipper ON loads(shipper_org_id);

-- matches and match_decisions
CREATE TABLE IF NOT EXISTS matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    load_id UUID REFERENCES loads(id) ON DELETE CASCADE,
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    spec_version_hash TEXT,
    passed_gates BOOLEAN DEFAULT FALSE,
    failed_gates JSONB,
    score NUMERIC,
    scoring_breakdown JSONB,
    decision_metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_matches_load_id ON matches(load_id);
CREATE INDEX IF NOT EXISTS idx_matches_carrier_id ON matches(carrier_id);

-- offers
CREATE TABLE IF NOT EXISTS offers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID REFERENCES matches(id) ON DELETE CASCADE,
    sent_at TIMESTAMP WITH TIME ZONE,
    viewed_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE,
    status offer_status DEFAULT 'sent',
    auto_offer BOOLEAN DEFAULT FALSE,
    auto_accept_rule_hash TEXT,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_offers_match_id ON offers(match_id);
CREATE INDEX IF NOT EXISTS idx_offers_status_expires ON offers(status, expires_at);

-- bookings
CREATE TABLE IF NOT EXISTS bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    load_id UUID REFERENCES loads(id) ON DELETE CASCADE,
    offer_id UUID REFERENCES offers(id) ON DELETE SET NULL,
    carrier_id UUID REFERENCES carriers(id) ON DELETE CASCADE,
    truck_id UUID REFERENCES trucks(id) ON DELETE SET NULL,
    driver_id UUID REFERENCES drivers(id) ON DELETE SET NULL,
    status booking_status DEFAULT 'pending',
    idempotency_key TEXT,
    locked_at TIMESTAMP WITH TIME ZONE,
    booked_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    UNIQUE (idempotency_key) WHERE idempotency_key IS NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bookings_load_id ON bookings(load_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings(status);

-- dispatches
CREATE TABLE IF NOT EXISTS dispatches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
    instructions JSONB,
    documents JSONB,
    status TEXT DEFAULT 'pending',
    dispatched_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- payments, invoices, settlements
CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    provider TEXT,
    provider_payment_id TEXT,
    gross_amount_cents BIGINT NOT NULL,
    currency TEXT DEFAULT 'USD',
    status TEXT,
    raw_event JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE IF NOT EXISTS invoices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id) ON DELETE SET NULL,
    external_ref TEXT,
    line_items JSONB,
    total_cents BIGINT,
    currency TEXT DEFAULT 'USD',
    issued_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    paid_at TIMESTAMP WITH TIME ZONE
);

-- ledger entries (immutable audit trail for dispatch fee calculations and settlements)
CREATE TABLE IF NOT EXISTS ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID REFERENCES bookings(id) ON DELETE SET NULL,
    gross_amount_cents BIGINT NOT NULL,
    fee_percent NUMERIC NOT NULL,
    fee_amount_cents BIGINT NOT NULL,
    carrier_net_cents BIGINT NOT NULL,
    membership_status_at_tx TEXT,
    settlement_status ledger_settlement_status DEFAULT 'pending',
    payment_reference TEXT,
    provider_event_id TEXT,
    metadata JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ledger_booking_id ON ledger_entries(booking_id);

-- audit events
CREATE TABLE IF NOT EXISTS audit_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id UUID,
    actor_role user_role,
    action TEXT NOT NULL,
    target_type TEXT,
    target_id UUID,
    payload JSONB,
    ip_address TEXT,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_actor ON audit_events(actor_id);

-- helpers: trigger to update updated_at
CREATE OR REPLACE FUNCTION trigger_set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- attach trigger to common tables
DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOR tbl IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename IN (
        'organizations','users','carriers','carrier_specs','spec_versions','trucks','drivers','availability','home_time','documents','loads','matches','offers','bookings','dispatches','payments','invoices','ledger_entries','audit_events'
    ) LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS set_timestamp ON %I', tbl);
        EXECUTE format('CREATE TRIGGER set_timestamp BEFORE UPDATE ON %I FOR EACH ROW EXECUTE PROCEDURE trigger_set_timestamp()', tbl);
    END LOOP;
END$$;

-- sample indexes for common queries
CREATE INDEX IF NOT EXISTS idx_loads_posted_at ON loads (posted_at);
CREATE INDEX IF NOT EXISTS idx_matches_created_at ON matches (created_at);

-- partial index to find active offers
CREATE INDEX IF NOT EXISTS idx_active_offers ON offers (match_id) WHERE status = 'sent' OR status = 'viewed';

-- Unique constraints for external references
CREATE UNIQUE INDEX IF NOT EXISTS uq_loads_external_ref ON loads (external_ref) WHERE external_ref IS NOT NULL;

-- End of migration

