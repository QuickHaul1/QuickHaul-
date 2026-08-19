# Postgres Migrations - QuickHaul

This directory contains initial SQL migrations for the QuickHaul freight dispatch marketplace.

Files
- migrations/0001_create_core_tables.sql: Initial schema (organizations, users, carriers, specs, trucks, drivers, availability, loads, matches, offers, bookings, dispatches, payments, ledger_entries, audit_events, documents, etc.)

How to run

Prerequisites:
- PostgreSQL 12+
- An account with CREATE EXTENSION privileges for `pgcrypto` (used for gen_random_uuid())

Run with psql (example):

  psql postgresql://user:pass@host:5432/dbname -f migrations/0001_create_core_tables.sql

If you use a migrations tool (Flyway, Liquibase, Sqitch, Prisma Migrate, etc.), import this SQL file as the first migration.

Notes & recommendations
- This migration uses UUID primary keys via the `pgcrypto` extension's gen_random_uuid(). If your environment prefers `uuid-ossp`, change the extension and defaults accordingly.
- Use Row-Level Security (RLS) policies to enforce tenant isolation in production (this migration does NOT add RLS policies).
- Keep `ledger_entries` immutable at the application level; avoid UPDATE/DELETE by regular users.
- Add additional indexes and partitioning strategies as load increases (e.g., partition ledger_entries by date or tenant).
- Consider adding an idempotent migrations table if your chosen migration tool doesn't provide one.

Security
- Ensure S3 or object storage is used for documents and only the s3_key is stored here.
- Do not store raw card data in the database.

