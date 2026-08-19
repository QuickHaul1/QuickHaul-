# PR: Add initial Postgres migrations + Supabase RLS

This PR adds:

- migrations/0001_create_core_tables.sql
  - Initial schema for QuickHaul: organizations, users, carriers, carrier_specs, spec_versions, trucks, drivers, availability, home_time, documents, loads, matches, offers, bookings, dispatches, payments, invoices, ledger_entries, audit_events.
  - Enums for statuses, helper trigger to set updated_at, indexes and constraints.

- migrations/0002_rls_supabase.sql
  - Supabase-specific RLS helpers (jwt_get_claim, jwt_org_id, jwt_role, jwt_user_id, is_admin) and conservative default RLS policies that scope rows to org_id and admin role.

- migrations/README.md and migrations/README_SUPABASE_RLS.md
  - How to run migrations and notes about RLS and Supabase JWT claims.

Why

- These migrations implement the core database model and initial Row-Level Security that enforces tenant isolation in a Supabase environment.
- They align with the platform architecture: shared DB with RLS, immutable ledger entries, spec versioning, idempotent booking keys.

Checklist

- [x] Add initial SQL schema migration
- [x] Add Supabase RLS migration and helpers
- [ ] Add seed fixtures (optional next step)
- [ ] Add CI job to run migrations and smoke tests (optional next step)
- [ ] Add migration conversion to Supabase format if desired (optional next step)

Notes

- The RLS policies are conservative defaults. Please review and adjust policies to allow minimal read-only access for matching endpoints or other cross-organization needs.
- Confirm JWT claim names in Supabase tokens; adjust helper functions if claim keys differ.

