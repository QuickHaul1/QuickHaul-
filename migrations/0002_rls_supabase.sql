-- 0002_rls_supabase.sql
-- Add Row-Level Security (RLS) policies and helper functions for Supabase JWT claims
-- Target: PostgreSQL (Supabase environment)

-- NOTE:
-- This migration creates helper functions that read JWT claims injected by Supabase
-- into the Postgres session via current_setting('jwt.claims'). It then enables RLS
-- on key tables and establishes conservative policies scoped to the organization
-- (org_id) claim. Adjust claim names and policy logic to match your auth token
-- structure and application needs.

-- Helper: safely read a claim from the JWT claims session setting
CREATE OR REPLACE FUNCTION public.jwt_get_claim(key TEXT)
RETURNS TEXT AS $$
  SELECT (
    CASE
      WHEN current_setting('jwt.claims', true) IS NULL THEN '{}' 
      ELSE current_setting('jwt.claims', true)
    END
  )::json->>key;
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Helper: organization id from JWT (stored as uuid in tokens)
CREATE OR REPLACE FUNCTION public.jwt_org_id()
RETURNS UUID AS $$
  SELECT NULLIF(jwt_get_claim('org_id'), '')::uuid;
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Helper: role from JWT
CREATE OR REPLACE FUNCTION public.jwt_role()
RETURNS TEXT AS $$
  SELECT jwt_get_claim('role');
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Helper: user id from JWT (sub)
CREATE OR REPLACE FUNCTION public.jwt_user_id()
RETURNS UUID AS $$
  SELECT NULLIF(jwt_get_claim('sub'), '')::uuid;
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Helper: is admin
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
  SELECT jwt_role() = 'admin';
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Enable RLS & policies

-- organizations: org owners and admins
ALTER TABLE IF EXISTS organizations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS organizations_org_policy ON organizations;
CREATE POLICY organizations_org_policy ON organizations
  FOR ALL
  USING ( id = jwt_org_id() OR is_admin() )
  WITH CHECK ( id = jwt_org_id() OR is_admin() );

-- users: allow same-organization users to manage users in their org; admins can do anything
ALTER TABLE IF EXISTS users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS users_org_policy ON users;
CREATE POLICY users_org_policy ON users
  FOR ALL
  USING ( org_id = jwt_org_id() OR is_admin() )
  WITH CHECK ( org_id = jwt_org_id() OR is_admin() );

-- carriers: organization-scoped
ALTER TABLE IF EXISTS carriers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS carriers_org_policy ON carriers;
CREATE POLICY carriers_org_policy ON carriers
  FOR ALL
  USING ( org_id = jwt_org_id() OR is_admin() )
  WITH CHECK ( org_id = jwt_org_id() OR is_admin() );

-- carrier_specs & spec_versions: allow org members to view/manage specs for their carrier
ALTER TABLE IF EXISTS carrier_specs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS carrier_specs_org_policy ON carrier_specs;
CREATE POLICY carrier_specs_org_policy ON carrier_specs
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = carrier_specs.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = carrier_specs.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  );

ALTER TABLE IF EXISTS spec_versions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS spec_versions_org_policy ON spec_versions;
CREATE POLICY spec_versions_org_policy ON spec_versions
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM carrier_specs cs
      JOIN carriers c ON cs.carrier_id = c.id
      WHERE cs.id = spec_versions.carrier_spec_id AND c.org_id = jwt_org_id()
    )
    OR is_admin()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM carrier_specs cs
      JOIN carriers c ON cs.carrier_id = c.id
      WHERE cs.id = spec_versions.carrier_spec_id AND c.org_id = jwt_org_id()
    )
    OR is_admin()
  );

-- trucks
ALTER TABLE IF EXISTS trucks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trucks_org_policy ON trucks;
CREATE POLICY trucks_org_policy ON trucks
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = trucks.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = trucks.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  );

-- drivers
ALTER TABLE IF EXISTS drivers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS drivers_org_policy ON drivers;
CREATE POLICY drivers_org_policy ON drivers
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = drivers.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = drivers.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  );

-- availability
ALTER TABLE IF EXISTS availability ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS availability_org_policy ON availability;
CREATE POLICY availability_org_policy ON availability
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = availability.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = availability.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  );

-- home_time
ALTER TABLE IF EXISTS home_time ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS home_time_org_policy ON home_time;
CREATE POLICY home_time_org_policy ON home_time
  FOR ALL
  USING (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = home_time.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM carriers c WHERE c.id = home_time.carrier_id AND c.org_id = jwt_org_id())
    OR is_admin()
  );

-- documents: support multiple owner types; conservative policy allowing org or owning carrier
ALTER TABLE IF EXISTS documents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS documents_org_policy ON documents;
CREATE POLICY documents_org_policy ON documents
  FOR ALL
  USING (
    (
      owner_type = 'organization' AND owner_id = jwt_org_id()
    ) OR (
      owner_type = 'carrier' AND EXISTS (SELECT 1 FROM carriers c WHERE c.id = documents.owner_id AND c.org_id = jwt_org_id())
    ) OR (
      owner_type = 'driver' AND EXISTS (SELECT 1 FROM drivers d JOIN carriers c ON d.carrier_id = c.id WHERE d.id = documents.owner_id AND c.org_id = jwt_org_id())
    ) OR is_admin()
  )
  WITH CHECK (
    (
      owner_type = 'organization' AND owner_id = jwt_org_id()
    ) OR (
      owner_type = 'carrier' AND EXISTS (SELECT 1 FROM carriers c WHERE c.id = documents.owner_id AND c.org_id = jwt_org_id())
    ) OR (
      owner_type = 'driver' AND EXISTS (SELECT 1 FROM drivers d JOIN carriers c ON d.carrier_id = c.id WHERE d.id = documents.owner_id AND c.org_id = jwt_org_id())
    ) OR is_admin()
  );

-- loads: shipper_org_id owns loads
ALTER TABLE IF EXISTS loads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS loads_org_policy ON loads;
CREATE POLICY loads_org_policy ON loads
  FOR ALL
  USING ( shipper_org_id = jwt_org_id() OR is_admin() )
  WITH CHECK ( shipper_org_id = jwt_org_id() OR is_admin() );

-- matches: allow carriers to view their own matches and admins
ALTER TABLE IF EXISTS matches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS matches_org_policy ON matches;
CREATE POLICY matches_org_policy ON matches
  FOR ALL
  USING (
    is_admin() OR EXISTS (SELECT 1 FROM carriers c WHERE c.id = matches.carrier_id AND c.org_id = jwt_org_id())
  )
  WITH CHECK (
    is_admin() OR EXISTS (SELECT 1 FROM carriers c WHERE c.id = matches.carrier_id AND c.org_id = jwt_org_id())
  );

-- offers: similar to matches
ALTER TABLE IF EXISTS offers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS offers_org_policy ON offers;
CREATE POLICY offers_org_policy ON offers
  FOR ALL
  USING (
    is_admin() OR EXISTS (
      SELECT 1 FROM matches m JOIN carriers c ON m.carrier_id = c.id WHERE m.id = offers.match_id AND c.org_id = jwt_org_id()
    )
  )
  WITH CHECK (
    is_admin() OR EXISTS (
      SELECT 1 FROM matches m JOIN carriers c ON m.carrier_id = c.id WHERE m.id = offers.match_id AND c.org_id = jwt_org_id()
    )
  );

-- bookings: allow admins or parties directly involved (carrier org or shipper org via load)
ALTER TABLE IF EXISTS bookings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bookings_org_policy ON bookings;
CREATE POLICY bookings_org_policy ON bookings
  FOR ALL
  USING (
    is_admin()
    OR EXISTS (SELECT 1 FROM carriers c WHERE c.id = bookings.carrier_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM loads l WHERE l.id = bookings.load_id AND l.shipper_org_id = jwt_org_id())
  )
  WITH CHECK (
    is_admin()
    OR EXISTS (SELECT 1 FROM carriers c WHERE c.id = bookings.carrier_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM loads l WHERE l.id = bookings.load_id AND l.shipper_org_id = jwt_org_id())
  );

-- dispatches: allow access if booking is visible
ALTER TABLE IF EXISTS dispatches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dispatches_org_policy ON dispatches;
CREATE POLICY dispatches_org_policy ON dispatches
  FOR ALL
  USING (
    is_admin()
    OR EXISTS (SELECT 1 FROM bookings b JOIN carriers c ON b.carrier_id = c.id WHERE b.id = dispatches.booking_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM bookings b JOIN loads l ON b.load_id = l.id WHERE b.id = dispatches.booking_id AND l.shipper_org_id = jwt_org_id())
  )
  WITH CHECK (
    is_admin()
    OR EXISTS (SELECT 1 FROM bookings b JOIN carriers c ON b.carrier_id = c.id WHERE b.id = dispatches.booking_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM bookings b JOIN loads l ON b.load_id = l.id WHERE b.id = dispatches.booking_id AND l.shipper_org_id = jwt_org_id())
  );

-- payments: restrict to admins and orgs involved via booking->load/carrier
ALTER TABLE IF EXISTS payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payments_org_policy ON payments;
CREATE POLICY payments_org_policy ON payments
  FOR ALL
  USING (
    is_admin()
    OR EXISTS (SELECT 1 FROM bookings b JOIN carriers c ON b.carrier_id = c.id WHERE b.id = payments.booking_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM bookings b JOIN loads l ON b.load_id = l.id WHERE b.id = payments.booking_id AND l.shipper_org_id = jwt_org_id())
  )
  WITH CHECK (
    is_admin()
    OR EXISTS (SELECT 1 FROM bookings b JOIN carriers c ON b.carrier_id = c.id WHERE b.id = payments.booking_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM bookings b JOIN loads l ON b.load_id = l.id WHERE b.id = payments.booking_id AND l.shipper_org_id = jwt_org_id())
  );

-- ledger_entries: conservative policy - admins or orgs linked to booking
ALTER TABLE IF EXISTS ledger_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ledger_entries_org_policy ON ledger_entries;
CREATE POLICY ledger_entries_org_policy ON ledger_entries
  FOR ALL
  USING (
    is_admin()
    OR EXISTS (SELECT 1 FROM bookings b JOIN carriers c ON b.carrier_id = c.id WHERE b.id = ledger_entries.booking_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM bookings b JOIN loads l ON b.load_id = l.id WHERE b.id = ledger_entries.booking_id AND l.shipper_org_id = jwt_org_id())
  )
  WITH CHECK (
    is_admin()
    OR EXISTS (SELECT 1 FROM bookings b JOIN carriers c ON b.carrier_id = c.id WHERE b.id = ledger_entries.booking_id AND c.org_id = jwt_org_id())
    OR EXISTS (SELECT 1 FROM bookings b JOIN loads l ON b.load_id = l.id WHERE b.id = ledger_entries.booking_id AND l.shipper_org_id = jwt_org_id())
  );

-- audit_events: only admins may view most audit events; allow actors to see their own
ALTER TABLE IF EXISTS audit_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_events_org_policy ON audit_events;
CREATE POLICY audit_events_org_policy ON audit_events
  FOR SELECT
  USING (
    is_admin() OR actor_id = jwt_user_id()
  );

-- Done. NOTE: These policies are conservative defaults. You should review and refine them
-- to fit business logic (e.g., read-only views for public load postings, allowing carriers to
-- see posted loads for matching when eligibility exists, etc.). Also confirm the JWT claim
-- names (org_id, role, sub) match your Supabase/JWT configuration.

