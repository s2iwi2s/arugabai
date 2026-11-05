-- =====================================================================================================
-- afterMigrate__grants.sql: Flyway callback, run after every migrate, even when nothing was pending.
-- Re-applies the runtime roles' privileges so a later migration can never silently widen or drop them.
-- Must be idempotent. The REVOKEs come last so nothing above can widen them.
--
-- When a migration adds an ops table that needs UPDATE (for example ops.reminders in V2), grant it
-- both in that migration and here.
-- =====================================================================================================

GRANT USAGE ON SCHEMA pii, clinical, ops TO app_rw, app_ro;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA pii, clinical TO app_rw;
GRANT SELECT, INSERT         ON ALL TABLES IN SCHEMA ops           TO app_rw;
GRANT UPDATE ON ops.jobs TO app_rw;
GRANT UPDATE ON ops.reminders, ops.providers, ops.provider_candidates, ops.corpus_sources TO app_rw;   -- V2

GRANT SELECT ON ALL TABLES IN SCHEMA pii, clinical, ops TO app_ro;

GRANT EXECUTE ON FUNCTION ops.current_profiles(), ops.current_user_id() TO app_rw, app_ro;

-- No hard deletes anywhere (soft delete; erasure is crypto-shredding), and the ledgers are append-only.
REVOKE DELETE, TRUNCATE ON ALL TABLES IN SCHEMA pii, clinical, ops FROM PUBLIC, app_rw, app_ro;
REVOKE UPDATE ON ops.consent_events, ops.audit_log FROM PUBLIC, app_rw, app_ro;
