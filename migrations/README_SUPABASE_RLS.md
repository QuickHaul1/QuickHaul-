# Postgres Migrations - Supabase & RLS

This update adds a second migration to enable Row-Level Security (RLS) and helper
functions tailored for Supabase JWT claims. It creates helper functions to read
JWT claims from the Postgres session and sets conservative RLS policies across
core tables to enforce tenant isolation.

Files added in this change:
- migrations/0002_rls_supabase.sql

Important notes
- Claims: This migration expects JWTs to include 'org_id' (UUID), 'role' (text),
  and 'sub' (user id) claims. If you use different claim names, update the
  helper functions (jwt_get_claim, jwt_org_id, jwt_role, jwt_user_id).
- Supabase behavior: Supabase injects JWT claims into the Postgres session; the
  exact key used in current_setting may vary. Confirm your Supabase configuration
  and adjust the current_setting key if required.
- Policy scope: The policies created are conservative defaults. Tailor them to
  your real access model (e.g., public view of posted loads, carrier access to
  loads they are eligible for, read-only public endpoints, etc.).

How to apply

  psql postgresql://user:pass@host:5432/dbname -f migrations/0002_rls_supabase.sql

After applying
- Verify that RLS is enabled on the listed tables and that policies exist.
- Test using a Supabase auth session or by setting the session JWT claims before
  the connection (e.g., SET LOCAL "jwt.claims" = '{"org_id":"<uuid>","role":"carrier","sub":"<uuid>"}'; )

