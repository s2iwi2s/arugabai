-- =====================================================================================================
-- V1__foundations.sql: schemas, roles, helpers and the eight foundation tables (API-004, #11)
-- Spec: Arugabai/techspec source/database/DATABASE_DDL_BRIEF.md §1–§4 "V1", §6.1, plus the #11
-- implementation plan and its addendum. Every departure from the brief is listed in docs/db/README.md.
--
-- THE CONTRACT: what this schema enforces vs. what the application enforces (brief §3)
--
--   The database enforces: schema isolation; row-level security by care profile; role privileges;
--   append-only ledgers (grants); the audit hash chain; FK integrity; soft delete (no DELETE grant).
--
--   The application enforces (NOT this schema): resolving user -> profile -> role -> entitlement
--   (the chokepoint); unwrapping the per-profile DEK; AES-256-GCM encrypt/decrypt of every _enc
--   column; and, once per transaction, after the chokepoint has decided:
--
--       SELECT set_config('app.profile_ids', '{<uuid>,...}', true);  -- uuid[] as text
--       SELECT set_config('app.user_id',     '<uuid>',       true);  -- only where a policy needs it
--
--   (set_config(..., true) is SET LOCAL with a bind parameter; SET LOCAL itself cannot take one.)
--   With neither set, every RLS policy below returns no rows: fail closed.
--
--   No encryption happens in SQL. Every _enc column is bytea holding ciphertext the API produced.
--   pgcrypto is used for digest() in the audit chain only, never for field encryption.
--
-- Prerequisites (not in this file): a superuser has created the migrator role and the vector and
-- pgcrypto extensions (src/test/resources/db/bootstrap/00_superuser.sql; Ansible in staging/prod).
-- Flyway runs as migrator with defaultSchema=flyway and schemas=flyway, so every name here is
-- schema-qualified.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- Extensions and schemas
-- ---------------------------------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector, for ops.corpus_chunks (V2); created by the bootstrap
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- digest() for the audit chain only; created by the bootstrap

CREATE SCHEMA IF NOT EXISTS pii;
CREATE SCHEMA IF NOT EXISTS clinical;
CREATE SCHEMA IF NOT EXISTS ops;

-- ---------------------------------------------------------------------------------------------------
-- Roles. Shared across the server, so existing roles are skipped here and their attributes are
-- asserted by db/verification/v1_structure.sql. Passwords are set out of band, never in a migration.
-- ---------------------------------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'migrator') THEN
    CREATE ROLE migrator NOLOGIN;  -- normally pre-created by the superuser bootstrap
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ro') THEN
    CREATE ROLE app_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------
-- Schema access and default privileges. Default privileges apply only to objects created by the
-- role that set them, so Flyway must always run as migrator.
-- ops defaults to SELECT, INSERT only (stricter than the brief): a new ops table stays append-only
-- until someone grants UPDATE on purpose, as ops.jobs does below.
-- ---------------------------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA pii, clinical, ops TO app_rw, app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA pii, clinical  GRANT SELECT, INSERT, UPDATE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA ops            GRANT SELECT, INSERT         ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA pii, clinical, ops GRANT SELECT             ON TABLES TO app_ro;

-- ---------------------------------------------------------------------------------------------------
-- Enum and helper functions
-- ---------------------------------------------------------------------------------------------------
CREATE TYPE ops.role_enum AS ENUM ('owner', 'edit', 'view');

-- Brief §3, verbatim: the caller's authorized profiles for this transaction; '{}' when unset.
CREATE OR REPLACE FUNCTION ops.current_profiles() RETURNS uuid[]
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('app.profile_ids', true), ''), '{}')::uuid[]
$$;

-- Plan decision 5 / addendum 2: the caller's user id for this transaction; NULL when unset.
-- Lets "which profiles is this user on?" be answered without already knowing the profiles.
CREATE FUNCTION ops.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$$;

-- Brief §6.4
CREATE FUNCTION ops.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------------------------------
-- pii: identity. No RLS (app-guarded); every value about a person is _enc bytea or a hash.
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE pii.users (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  firebase_uid  text        CONSTRAINT uq_users_firebase_uid UNIQUE,
  email_enc     bytea,
  phone_enc     bytea,
  status        text        NOT NULL DEFAULT 'active'
                            CONSTRAINT ck_users_status CHECK (status IN ('active', 'disabled', 'deleted')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN pii.users.email_enc IS 'AES-256-GCM; key TBD (API-012); AAD=pii.users.email_enc:<id>';
COMMENT ON COLUMN pii.users.phone_enc IS 'AES-256-GCM; key TBD (API-012); AAD=pii.users.phone_enc:<id>';

CREATE TABLE pii.channel_identities (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        NOT NULL
                                    CONSTRAINT fk_channel_identities_user_id REFERENCES pii.users (id) ON DELETE RESTRICT,
  channel               text        NOT NULL
                                    CONSTRAINT ck_channel_identities_channel CHECK (channel IN ('viber', 'messenger')),
  channel_user_id_enc   bytea,
  channel_user_id_hash  bytea       NOT NULL,
  linked_at             timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_channel_identities_channel_hash UNIQUE (channel, channel_user_id_hash)
);
CREATE INDEX ix_channel_identities_user_id ON pii.channel_identities (user_id);
COMMENT ON COLUMN pii.channel_identities.channel_user_id_enc
  IS 'AES-256-GCM; key TBD (API-012); AAD=pii.channel_identities.channel_user_id_enc:<id>';
COMMENT ON COLUMN pii.channel_identities.channel_user_id_hash
  IS 'App-computed HMAC of the channel user id: the lookup and uniqueness key (never index the _enc column)';

CREATE TABLE pii.device_keys (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid        NOT NULL
                             CONSTRAINT fk_device_keys_user_id REFERENCES pii.users (id) ON DELETE RESTRICT,
  public_key     text        NOT NULL,
  device_model   text,
  registered_at  timestamptz NOT NULL DEFAULT now(),
  revoked_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_device_keys_user_id ON pii.device_keys (user_id);
-- Addendum 4: no duplicate active key per user, even on two simultaneous first sign-ins (#9).
CREATE UNIQUE INDEX uq_device_keys_user_id_public_key_active
  ON pii.device_keys (user_id, public_key) WHERE revoked_at IS NULL;
COMMENT ON TABLE pii.device_keys IS 'Device public keys; they sign care-event objects (Home Care Mode).';

-- ---------------------------------------------------------------------------------------------------
-- clinical: the care profile and its data key. ENABLE + FORCE row-level security.
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE clinical.care_profiles (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id     uuid        NOT NULL
                                CONSTRAINT fk_care_profiles_owner_user_id REFERENCES pii.users (id) ON DELETE RESTRICT,
  guardian_flag     boolean     NOT NULL DEFAULT false,
  household_id      uuid,
  display_name_enc  bytea,
  dob_enc           bytea,
  deleted_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_care_profiles_owner_user_id ON clinical.care_profiles (owner_user_id);
COMMENT ON COLUMN clinical.care_profiles.owner_user_id
  IS 'Who created the profile. Not an authority: roles, ownership included, come only from ops.consent_events.';
COMMENT ON COLUMN clinical.care_profiles.display_name_enc
  IS 'AES-256-GCM under profile DEK; AAD=clinical.care_profiles.display_name_enc:<id>';
COMMENT ON COLUMN clinical.care_profiles.dob_enc
  IS 'AES-256-GCM under profile DEK; AAD=clinical.care_profiles.dob_enc:<id>';

CREATE TABLE clinical.profile_keys (
  care_profile_id  uuid        PRIMARY KEY
                               CONSTRAINT fk_profile_keys_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  wrapped_dek      bytea       NOT NULL,
  kek_id           text        NOT NULL,
  key_version      integer     NOT NULL DEFAULT 1,
  rotated_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE clinical.profile_keys
  IS 'One wrapped DEK per profile. The crypto-shred target: destroying this row makes the profile unreadable.';
COMMENT ON COLUMN clinical.profile_keys.wrapped_dek IS 'The profile DEK wrapped by the KMS key named in kek_id; never plaintext.';

ALTER TABLE clinical.care_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.care_profiles FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_care_profiles ON clinical.care_profiles
  USING      (id = ANY (ops.current_profiles()))
  WITH CHECK (id = ANY (ops.current_profiles()));

ALTER TABLE clinical.profile_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.profile_keys FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_profile_keys ON clinical.profile_keys
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

-- ---------------------------------------------------------------------------------------------------
-- ops.consent_events: the append-only consent ledger. SELECT, INSERT only (grants below).
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE ops.consent_events (
  id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id   uuid          NOT NULL
                             CONSTRAINT fk_consent_events_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  -- Addendum 1: an append-only ledger cannot close a grant by updating valid_to, so a revoke is
  -- its own event. Confirm this list with #20 (API-014) before merge.
  kind         text          NOT NULL
                             CONSTRAINT ck_consent_events_kind CHECK (kind IN
                               ('invite', 'accept', 'grant', 'revoke', 'enrol', 'share',
                                'packet_revoke', 'packet_open', 'shred')),
  grantee_id   uuid          CONSTRAINT fk_consent_events_grantee_id REFERENCES pii.users (id) ON DELETE RESTRICT,
  role         ops.role_enum,
  event_types  text[]        NOT NULL DEFAULT '{*}',
  scope        text          NOT NULL
                             CONSTRAINT ck_consent_events_scope CHECK (scope IN ('household', 'packet', 'share_link')),
  valid_from   timestamptz   NOT NULL,
  valid_to     timestamptz,
  granted_by   uuid,
  reason       text,
  prev_hash    bytea,
  created_at   timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT ck_consent_events_grant_has_role CHECK (kind <> 'grant' OR role IS NOT NULL),
  CONSTRAINT ck_consent_events_grant_revoke_has_grantee CHECK (kind NOT IN ('grant', 'revoke') OR grantee_id IS NOT NULL)
);
CREATE INDEX ix_consent_events_profile_id_grantee_id_valid_from
  ON ops.consent_events (profile_id, grantee_id, valid_from);
CREATE INDEX ix_consent_events_grantee_id ON ops.consent_events (grantee_id);
COMMENT ON TABLE ops.consent_events
  IS 'Append-only consent ledger. Roles are resolved from the latest grant/revoke as of a time; never updated in place.';
COMMENT ON COLUMN ops.consent_events.prev_hash IS 'Per-profile hash chain; the trigger that fills it is #20 (API-014).';

ALTER TABLE ops.consent_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.consent_events FORCE ROW LEVEL SECURITY;
-- Reads: events of the profiles in scope, or the caller's own grants (decision 5). Inserts: in-scope profiles only.
CREATE POLICY rls_consent_events ON ops.consent_events
  USING      (profile_id = ANY (ops.current_profiles()) OR grantee_id = ops.current_user_id())
  WITH CHECK (profile_id = ANY (ops.current_profiles()));

-- ---------------------------------------------------------------------------------------------------
-- ops.audit_log: hash-chained, append-only (brief §6.1, with plan decision 4 and addendum 5).
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE ops.audit_log (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at      timestamptz NOT NULL DEFAULT now(),
  actor_user_id    uuid,
  care_profile_id  uuid,
  action           text,
  resource_type    text,
  resource_id      uuid,
  metadata         jsonb,
  prev_hash        bytea,
  row_hash         bytea,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_log_occurred_at_id ON ops.audit_log (occurred_at, id);   -- the chain lookup
CREATE INDEX ix_audit_log_care_profile_id ON ops.audit_log (care_profile_id);
COMMENT ON TABLE ops.audit_log
  IS 'One hash chain across all profiles. Write the audit row late in each transaction: the chain lock is held until commit. Partitioning by month is deferred (brief ASK #4).';
COMMENT ON COLUMN ops.audit_log.metadata IS 'Ids and enums only. Never PHI, names or free text.';

-- The brief's trigger runs as the inserting role, so RLS filtered its "previous row" lookup and every
-- profile got its own chain (verified). This version runs as the table owner, serializes writers
-- with a transaction-scoped advisory lock, takes the timestamp itself so insert order is chain order,
-- and pins the settings that occurred_at::text depends on. The digest() input is the brief's, verbatim.
CREATE FUNCTION ops.audit_chain() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
SET TimeZone = 'UTC'
SET DateStyle = 'ISO, MDY'
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('ops.audit_log'));
  NEW.occurred_at := clock_timestamp();
  SELECT row_hash INTO NEW.prev_hash FROM ops.audit_log ORDER BY occurred_at DESC, id DESC LIMIT 1;
  NEW.row_hash := public.digest(
      coalesce(NEW.prev_hash, ''::bytea)
      || convert_to(NEW.occurred_at::text, 'UTF8')
      || convert_to(coalesce(NEW.actor_user_id::text,''), 'UTF8')
      || convert_to(coalesce(NEW.care_profile_id::text,''), 'UTF8')
      || convert_to(coalesce(NEW.action,''), 'UTF8')
      || convert_to(coalesce(NEW.resource_type,''), 'UTF8')
      || convert_to(coalesce(NEW.resource_id::text,''), 'UTF8')
      || convert_to(coalesce(NEW.metadata::text,''), 'UTF8'),
      'sha256');
  RETURN NEW;
END $$;
CREATE TRIGGER audit_chain BEFORE INSERT ON ops.audit_log
  FOR EACH ROW EXECUTE FUNCTION ops.audit_chain();

-- ENABLE but not FORCE: the owner-run trigger must see the whole chain. app_rw and app_ro are not
-- the owner, so the policies still apply to them. Separate policies, so a system event (no profile,
-- e.g. a sign-in) can be written but never read back through RLS. Consequence: audit inserts must not
-- use RETURNING, because returned rows are checked against the SELECT policy (addendum 3).
ALTER TABLE ops.audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY rls_audit_log_select ON ops.audit_log FOR SELECT
  USING (care_profile_id = ANY (ops.current_profiles()));
CREATE POLICY rls_audit_log_insert ON ops.audit_log FOR INSERT
  WITH CHECK (care_profile_id IS NULL OR care_profile_id = ANY (ops.current_profiles()));

-- ---------------------------------------------------------------------------------------------------
-- ops.jobs: the PostgreSQL-backed queue. Operational, so no RLS; the payload holds references only.
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE ops.jobs (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  type        text        NOT NULL,
  payload     jsonb,
  run_at      timestamptz NOT NULL DEFAULT now(),
  locked_by   text,
  locked_at   timestamptz,
  attempts    integer     NOT NULL DEFAULT 0,
  status      text        NOT NULL DEFAULT 'queued'
                          CONSTRAINT ck_jobs_status CHECK (status IN ('queued', 'running', 'done', 'dead')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_jobs_status_run_at ON ops.jobs (status, run_at);
COMMENT ON TABLE ops.jobs IS
$c$The job queue (ADR-007: PostgreSQL is the queue). payload holds ids and references only, never PHI.
Claim query (brief §7):
  WITH next AS (
    SELECT id FROM ops.jobs
     WHERE status = 'queued' AND run_at <= now()
     ORDER BY run_at
     FOR UPDATE SKIP LOCKED
     LIMIT 1)
  UPDATE ops.jobs j
     SET status='running', locked_at=now(), locked_by=$1, attempts=attempts+1
    FROM next WHERE j.id = next.id
    RETURNING j.*;$c$;

-- ---------------------------------------------------------------------------------------------------
-- updated_at triggers on the mutable tables (not on the two ledgers)
-- ---------------------------------------------------------------------------------------------------
CREATE TRIGGER set_updated_at BEFORE UPDATE ON pii.users              FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON pii.channel_identities FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON pii.device_keys        FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.care_profiles FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.profile_keys  FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON ops.jobs               FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

-- ---------------------------------------------------------------------------------------------------
-- Grants for the objects above (afterMigrate__grants.sql re-applies them after every migrate)
-- ---------------------------------------------------------------------------------------------------
GRANT UPDATE ON ops.jobs TO app_rw;
GRANT EXECUTE ON FUNCTION ops.current_profiles(), ops.current_user_id() TO app_rw, app_ro;
REVOKE UPDATE, DELETE, TRUNCATE ON ops.consent_events, ops.audit_log FROM PUBLIC, app_rw, app_ro;
