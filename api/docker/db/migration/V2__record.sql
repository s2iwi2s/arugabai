-- =====================================================================================================
-- V2__record.sql: the clinical record tables and the ops tables that serve them (API-005, #12)
-- Spec: Arugabai/techspec source/database/DATABASE_DDL_BRIEF.md §4 "V2", §5, §6.2, §8, plus the #12
-- implementation plan and addendum. Every departure from the brief is listed in docs/db/README.md.
--
-- Every clinical table here, and ops.reminders, is profile-scoped: ENABLE + FORCE row-level security
-- keyed on the profile column, no DELETE for any runtime role. The provider and corpus tables are
-- public reference data with no profile and no RLS; corpus_chunks must never hold PHI.
--
-- Child rows reference their parent by (care_profile_id, parent_id), not by parent_id alone: a
-- foreign-key check bypasses RLS, so a plain FK would let a profile-A row point at profile B's data.
--
-- Timeline, packet and log:answer reads must filter status = 'reviewed'. The endpoints enforce that;
-- nothing here makes an unreviewed record authoritative.
--
-- Prerequisite: V1. Flyway runs with search_path = flyway, so every name is schema-qualified,
-- including pgvector's type and operator class, which live in public.
-- =====================================================================================================

-- ---------------------------------------------------------------------------------------------------
-- ops reference tables first: clinical.appointments references ops.providers.
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE ops.providers (
  id               uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  name             text             NOT NULL,
  type             text,
  address          text,
  barangay         text,
  city             text,
  lat              double precision,
  lng              double precision,
  hours            jsonb,
  services         text[],
  cost_range       text,
  accepts_packets  boolean          NOT NULL DEFAULT false,
  emergency        boolean          NOT NULL DEFAULT false,
  phone            text,
  source_id        text,
  verified_at      timestamptz,
  verified_by      text[],
  status           text             NOT NULL DEFAULT 'candidate'
                                    CONSTRAINT ck_providers_status CHECK (status IN ('candidate', 'verified', 'stale')),
  created_at       timestamptz      NOT NULL DEFAULT now(),
  updated_at       timestamptz      NOT NULL DEFAULT now(),
  -- Non-negotiable 8: every provider fact carries source_id and verified_at; nothing unverified is served.
  CONSTRAINT ck_providers_verified_has_source
    CHECK (status <> 'verified' OR (source_id IS NOT NULL AND verified_at IS NOT NULL))
);
CREATE INDEX ix_providers_city_type ON ops.providers (city, type);
CREATE INDEX ix_providers_barangay  ON ops.providers (barangay);
COMMENT ON TABLE ops.providers
  IS 'Public QC directory, no RLS. Only status = ''verified'' rows are served (the app filters); a verified row must carry source_id and verified_at.';

-- Staging mirror of providers, never served. LIKE copies the columns, defaults and CHECKs (under the
-- parent's names, renamed below); it does not copy indexes.
CREATE TABLE ops.provider_candidates (
  LIKE ops.providers INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
  source_url text,
  PRIMARY KEY (id)
);
ALTER TABLE ops.provider_candidates RENAME CONSTRAINT ck_providers_status TO ck_provider_candidates_status;
ALTER TABLE ops.provider_candidates
  RENAME CONSTRAINT ck_providers_verified_has_source TO ck_provider_candidates_verified_has_source;
COMMENT ON TABLE ops.provider_candidates IS 'Staging mirror of ops.providers with source_url. Never served.';

CREATE TABLE ops.corpus_sources (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         text        NOT NULL
                           CONSTRAINT ck_corpus_sources_kind CHECK (kind IN ('provider', 'coverage', 'city_requirement', 'reference')),
  title        text,
  url          text,
  version      text,
  verified_on  date,
  verified_by  text[],
  plan_id      text,
  status       text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN ops.corpus_sources.plan_id IS 'When set, restricts this source''s coverage chunks to one plan.';

CREATE TABLE ops.corpus_chunks (
  id          uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id   uuid               NOT NULL
                                 CONSTRAINT fk_corpus_chunks_source_id REFERENCES ops.corpus_sources (id) ON DELETE RESTRICT,
  text        text               NOT NULL,
  embedding   public.vector(1024),
  meta        jsonb,
  plan_id     text,
  created_at  timestamptz        NOT NULL DEFAULT now()
);
-- Brief §8. Cosine distance and 1024 dimensions are the brief's defaults (ASK #1).
CREATE INDEX ix_corpus_chunks_hnsw   ON ops.corpus_chunks USING hnsw (embedding public.vector_cosine_ops);
CREATE INDEX ix_corpus_chunks_source ON ops.corpus_chunks (source_id);
COMMENT ON TABLE ops.corpus_chunks
  IS 'Retrieval corpus. NO PHI EVER. Insert-only: re-embedding writes new rows, so there is no updated_at and no UPDATE grant.';
COMMENT ON COLUMN ops.corpus_chunks.embedding IS 'vector(1024), cosine: brief ASK #1 defaults; must match the embedding model.';

-- ---------------------------------------------------------------------------------------------------
-- clinical.documents
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE clinical.documents (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  care_profile_id  uuid        NOT NULL
                               CONSTRAINT fk_documents_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  object_key       text        NOT NULL,
  type             text        CONSTRAINT ck_documents_type CHECK (type IN
                                 ('prescription', 'discharge', 'lab', 'imaging', 'hmo', 'receipt', 'id', 'other')),
  phash            bytea,
  status           text        NOT NULL DEFAULT 'stored'
                               CONSTRAINT ck_documents_status CHECK (status IN ('stored', 'classified', 'failed')),
  uploaded_by      uuid,
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_documents_care_profile_id_id UNIQUE (care_profile_id, id)   -- parent key for composite FKs
);
CREATE INDEX ix_documents_profile ON clinical.documents (care_profile_id);
CREATE INDEX ix_documents_phash   ON clinical.documents (care_profile_id, phash);
COMMENT ON COLUMN clinical.documents.object_key IS 'Opaque object-storage key built from ids only; never a filename (a filename can itself be PHI).';
COMMENT ON COLUMN clinical.documents.phash      IS 'Perceptual hash for de-duplication. A hash, so it may be indexed.';

-- ---------------------------------------------------------------------------------------------------
-- clinical.ai_status, clinical.records and the review-state guard (brief §6.2)
-- ---------------------------------------------------------------------------------------------------
CREATE TYPE clinical.ai_status AS ENUM ('pending', 'review_pending', 'reviewed');

CREATE TABLE clinical.records (
  id               uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
  care_profile_id  uuid               NOT NULL
                                      CONSTRAINT fk_records_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  type             text,
  value_enc        bytea,
  confidence       real,
  status           clinical.ai_status NOT NULL DEFAULT 'review_pending',
  source_doc_id    uuid,
  reviewed_by      uuid,
  reviewed_at      timestamptz,
  deleted_at       timestamptz,
  created_at       timestamptz        NOT NULL DEFAULT now(),
  updated_at       timestamptz        NOT NULL DEFAULT now(),
  CONSTRAINT fk_records_source_doc_id FOREIGN KEY (care_profile_id, source_doc_id)
    REFERENCES clinical.documents (care_profile_id, id) ON DELETE RESTRICT
);
CREATE INDEX ix_records_care_profile_id_status ON clinical.records (care_profile_id, status);
COMMENT ON TABLE clinical.records
  IS 'AI-read values land as review_pending; only reviewed rows are authoritative. Timeline, packet and log:answer reads filter status = ''reviewed''.';
COMMENT ON COLUMN clinical.records.value_enc IS 'AES-256-GCM under profile DEK; AAD=clinical.records.value_enc:<id>';

-- Verbatim from the brief. It blocks moving a reviewed record backwards; it does not stop an update
-- of a reviewed row's value_enc (plan decision 4: full immutability is #27, supersede-not-update).
CREATE OR REPLACE FUNCTION clinical.guard_ai_status() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'reviewed' AND NEW.status <> 'reviewed' THEN
    RAISE EXCEPTION 'cannot move a reviewed record back to %', NEW.status;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_ai_status BEFORE UPDATE ON clinical.records
  FOR EACH ROW EXECUTE FUNCTION clinical.guard_ai_status();

-- ---------------------------------------------------------------------------------------------------
-- clinical.medications and clinical.med_events
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE clinical.medications (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  care_profile_id  uuid        NOT NULL
                               CONSTRAINT fk_medications_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  drug_enc         bytea,
  drug_norm        text,
  strength         text,
  schedule_enc     bytea,
  for_enc          bytea,
  active           boolean     NOT NULL DEFAULT true,
  source_doc_id    uuid,
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_medications_care_profile_id_id UNIQUE (care_profile_id, id),   -- parent key for med_events, reminders
  CONSTRAINT fk_medications_source_doc_id FOREIGN KEY (care_profile_id, source_doc_id)
    REFERENCES clinical.documents (care_profile_id, id) ON DELETE RESTRICT
);
-- Indexed per the brief's default; pending DPO sign-off (brief ASK #2, plan decision 6).
CREATE INDEX ix_medications_care_profile_id_drug_norm ON clinical.medications (care_profile_id, drug_norm);
COMMENT ON COLUMN clinical.medications.drug_enc     IS 'AES-256-GCM under profile DEK; AAD=clinical.medications.drug_enc:<id>';
COMMENT ON COLUMN clinical.medications.schedule_enc IS 'AES-256-GCM under profile DEK; AAD=clinical.medications.schedule_enc:<id>. The prescriber''s words as written, never an instruction.';
COMMENT ON COLUMN clinical.medications.for_enc      IS 'AES-256-GCM under profile DEK; AAD=clinical.medications.for_enc:<id>';
COMMENT ON COLUMN clinical.medications.drug_norm
  IS 'Derived generic/brand key for matching; not raw PHI. Indexing is pending DPO sign-off (brief ASK #2).';
COMMENT ON COLUMN clinical.medications.strength
  IS 'Plaintext per the brief (e.g. a tablet strength), never a dose instruction. Pending DPO view: becomes strength_enc if it counts as PHI.';

CREATE TABLE clinical.med_events (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  care_profile_id  uuid        NOT NULL
                               CONSTRAINT fk_med_events_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  medication_id    uuid        NOT NULL,
  given_at         timestamptz,
  by_user          uuid,
  care_event_id    uuid,
  voided           boolean     NOT NULL DEFAULT false,
  voided_by        uuid,
  voided_at        timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_med_events_medication_id FOREIGN KEY (care_profile_id, medication_id)
    REFERENCES clinical.medications (care_profile_id, id) ON DELETE RESTRICT
);
CREATE INDEX ix_med_events_care_profile_id_given_at ON clinical.med_events (care_profile_id, given_at);
COMMENT ON COLUMN clinical.med_events.care_event_id IS 'FK to clinical.care_events is added in V4 (Home Care Mode).';
COMMENT ON COLUMN clinical.med_events.voided        IS 'Voiding replaces deletion: a voided event stays, with who and when.';

-- ---------------------------------------------------------------------------------------------------
-- clinical.appointments, clinical.conversations, clinical.conversation_turns
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE clinical.appointments (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  care_profile_id  uuid        NOT NULL
                               CONSTRAINT fk_appointments_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  -- A plain FK is right here: providers are public rows, not profile data.
  provider_id      uuid        CONSTRAINT fk_appointments_provider_id REFERENCES ops.providers (id) ON DELETE RESTRICT,
  at               timestamptz,
  type             text,
  notes_enc        bytea,
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_appointments_care_profile_id_at ON clinical.appointments (care_profile_id, at);
COMMENT ON COLUMN clinical.appointments.notes_enc IS 'AES-256-GCM under profile DEK; AAD=clinical.appointments.notes_enc:<id>';

CREATE TABLE clinical.conversations (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  care_profile_id  uuid        NOT NULL
                               CONSTRAINT fk_conversations_care_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  channel          text,
  started_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_conversations_care_profile_id_id UNIQUE (care_profile_id, id)   -- parent key for turns
);

CREATE TABLE clinical.conversation_turns (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid        NOT NULL,
  care_profile_id  uuid        NOT NULL,
  role             text        NOT NULL
                               CONSTRAINT ck_conversation_turns_role CHECK (role IN ('user', 'assistant')),
  content_enc      bytea,
  cards_enc        bytea,
  lang             text,
  tokens_in        integer,
  tokens_out       integer,
  model_id         text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  -- Brief ASK #5 default: turns are meaningless without their conversation, which is soft-deleted upstream.
  CONSTRAINT fk_conversation_turns_conversation_id FOREIGN KEY (care_profile_id, conversation_id)
    REFERENCES clinical.conversations (care_profile_id, id) ON DELETE CASCADE
);
CREATE INDEX ix_conversation_turns_conversation_id_created_at ON clinical.conversation_turns (conversation_id, created_at);
COMMENT ON TABLE clinical.conversation_turns
  IS 'Insert-only. 90-day retention: the purge.conversations job deletes old turns; it is a job, not a constraint. Partitioning by month is deferred (brief ASK #4).';
COMMENT ON COLUMN clinical.conversation_turns.content_enc IS 'AES-256-GCM under profile DEK; AAD=clinical.conversation_turns.content_enc:<id>';
COMMENT ON COLUMN clinical.conversation_turns.cards_enc   IS 'AES-256-GCM under profile DEK; AAD=clinical.conversation_turns.cards_enc:<id>';
COMMENT ON COLUMN clinical.conversation_turns.model_id    IS 'Pinned model id that produced the turn (non-negotiable 11).';

-- ---------------------------------------------------------------------------------------------------
-- ops.reminders: profile-scoped, so RLS like the clinical tables (keyed on profile_id, the spec's name)
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE ops.reminders (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id          uuid        NOT NULL
                                  CONSTRAINT fk_reminders_profile_id REFERENCES clinical.care_profiles (id) ON DELETE RESTRICT,
  kind                text        NOT NULL
                                  CONSTRAINT ck_reminders_kind CHECK (kind IN ('dose', 'refill', 'follow_up', 'lab', 'fasting', 'document')),
  due_at              timestamptz NOT NULL,
  medication_id       uuid,
  status              text        NOT NULL DEFAULT 'pending'
                                  CONSTRAINT ck_reminders_status CHECK (status IN ('pending', 'done', 'expired', 'cancelled')),
  closed_by_event_id  uuid,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_reminders_medication_id FOREIGN KEY (profile_id, medication_id)
    REFERENCES clinical.medications (care_profile_id, id) ON DELETE RESTRICT
);
CREATE INDEX ix_reminders_profile_id_due_at ON ops.reminders (profile_id, due_at);
CREATE INDEX ix_reminders_status_due_at     ON ops.reminders (status, due_at);
COMMENT ON TABLE ops.reminders
  IS 'Profile-scoped. Under RLS a status sweep sees only profiles in scope, so reminders are scheduled through ops.jobs, not swept across profiles.';

-- ---------------------------------------------------------------------------------------------------
-- Row-level security: one explicit block per profile-scoped table (brief §5)
-- ---------------------------------------------------------------------------------------------------
ALTER TABLE clinical.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.documents FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_documents ON clinical.documents
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE clinical.records ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.records FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_records ON clinical.records
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE clinical.medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.medications FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_medications ON clinical.medications
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE clinical.med_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.med_events FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_med_events ON clinical.med_events
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE clinical.appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.appointments FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_appointments ON clinical.appointments
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE clinical.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.conversations FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_conversations ON clinical.conversations
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE clinical.conversation_turns ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinical.conversation_turns FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_conversation_turns ON clinical.conversation_turns
  USING      (care_profile_id = ANY (ops.current_profiles()))
  WITH CHECK (care_profile_id = ANY (ops.current_profiles()));

ALTER TABLE ops.reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE ops.reminders FORCE ROW LEVEL SECURITY;
CREATE POLICY rls_reminders ON ops.reminders
  USING      (profile_id = ANY (ops.current_profiles()))
  WITH CHECK (profile_id = ANY (ops.current_profiles()));

-- ---------------------------------------------------------------------------------------------------
-- updated_at triggers. On records, BEFORE triggers fire in name order, so guard_ai_status runs first.
-- ---------------------------------------------------------------------------------------------------
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.documents        FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.records          FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.medications      FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.med_events       FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.appointments     FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON clinical.conversations    FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON ops.reminders             FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON ops.providers             FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON ops.provider_candidates   FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON ops.corpus_sources        FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

-- ---------------------------------------------------------------------------------------------------
-- Grants. V1's default privileges already give the clinical tables SELECT/INSERT/UPDATE to app_rw and
-- the ops tables SELECT/INSERT; SELECT to app_ro; no DELETE anywhere. These ops tables change status,
-- so app_rw also gets UPDATE (mirrored in afterMigrate__grants.sql). corpus_chunks stays insert-only.
-- ---------------------------------------------------------------------------------------------------
GRANT UPDATE ON ops.reminders, ops.providers, ops.provider_candidates, ops.corpus_sources TO app_rw;
