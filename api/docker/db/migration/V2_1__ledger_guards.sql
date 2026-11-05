-- =====================================================================================================
-- V2_1__ledger_guards.sql: the second enforcement layer for the append-only ledgers (DDL brief §6.3,
-- API-006 / #13). The first layer is the grants in V1 (SELECT, INSERT only). These triggers catch a
-- grant that is widened by mistake, and the owner, which the grants never restrict.
--
-- Row triggers refuse UPDATE and DELETE. Statement triggers refuse TRUNCATE, because row triggers never
-- fire on TRUNCATE. Both are ENABLE ALWAYS, so they also fire under session_replication_role = replica.
-- Version 2.1 sorts after V2 and before any V3, so it must merge before V3 is written (Flyway
-- refuses a lower version than one already applied, with outOfOrder=false).
--
-- The audit hash chain's timezone and DateStyle pins are already in V1's ops.audit_chain(). Nothing
-- here changes the chain.
-- =====================================================================================================

CREATE FUNCTION ops.forbid_ledger_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Raised with the default P0001 (raise_exception). The verification scripts match on the message.
  RAISE EXCEPTION 'append-only ledger: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END $$;
COMMENT ON FUNCTION ops.forbid_ledger_change()
  IS 'Refuses UPDATE, DELETE and TRUNCATE on the append-only ledgers (brief §6.3). Second layer behind the grants.';

CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON ops.audit_log
  FOR EACH ROW EXECUTE FUNCTION ops.forbid_ledger_change();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON ops.audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION ops.forbid_ledger_change();

CREATE TRIGGER consent_events_append_only BEFORE UPDATE OR DELETE ON ops.consent_events
  FOR EACH ROW EXECUTE FUNCTION ops.forbid_ledger_change();
CREATE TRIGGER consent_events_no_truncate BEFORE TRUNCATE ON ops.consent_events
  FOR EACH STATEMENT EXECUTE FUNCTION ops.forbid_ledger_change();

-- Fire even when session_replication_role = replica (a superuser's quiet bypass otherwise).
-- A superuser can still DISABLE TRIGGER; the hash chain and the off-box chain head (#21) cover that.
ALTER TABLE ops.audit_log      ENABLE ALWAYS TRIGGER audit_log_append_only;
ALTER TABLE ops.audit_log      ENABLE ALWAYS TRIGGER audit_log_no_truncate;
ALTER TABLE ops.consent_events ENABLE ALWAYS TRIGGER consent_events_append_only;
ALTER TABLE ops.consent_events ENABLE ALWAYS TRIGGER consent_events_no_truncate;
