-- =====================================================================================================
-- Superuser bootstrap: run once per database, as a superuser, BEFORE Flyway's first migrate.
-- Staging/prod: Ansible does the equivalent (runbook in Arugabai/infra). Tests: the Testcontainers
-- init script and scripts/db-verify.sh.
--
-- Passwords are set out of band, never in this repo: the test harness sets a random migrator
-- password at runtime.
-- =====================================================================================================

-- Flyway runs as migrator: it owns every object, may create the app roles, and is never used by the
-- running service. Not a superuser, and it cannot bypass row-level security.
CREATE ROLE migrator LOGIN CREATEROLE NOSUPERUSER NOBYPASSRLS;

-- To create the pii, clinical, ops and flyway schemas.
GRANT CREATE ON DATABASE arugabai TO migrator;

-- pgvector is not a trusted extension, so only a superuser can create it (V1 then finds it present).
CREATE EXTENSION IF NOT EXISTS vector;
-- digest() for the audit hash chain. Never used for field encryption.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
