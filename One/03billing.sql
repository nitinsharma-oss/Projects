-- ============================================================
-- Step 2, part 3 — billing, audit, analytics
-- ============================================================

-- ---------- subscriptions ----------
-- Same dual-owner idiom as cards, deliberately (§2.5): one pattern an auditor
-- learns once and can then verify everywhere.

CREATE TABLE subscriptions (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_account_id       uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    owner_org_id           uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    plan                   text NOT NULL,
    status                 sub_status NOT NULL,
    seats                  int NOT NULL DEFAULT 1,
    stripe_customer_id     text,
    stripe_subscription_id text,
    current_period_end     timestamptz,
    cancel_at              timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT subscriptions_single_owner CHECK (
        num_nonnulls(owner_account_id, owner_org_id) = 1
    ),
    CONSTRAINT subscriptions_seats_positive CHECK (seats > 0),
    -- A personal plan cannot have seats; an org plan is the only multi-seat shape.
    CONSTRAINT subscriptions_personal_single_seat CHECK (
        owner_account_id IS NULL OR seats = 1
    ),
    CONSTRAINT subscriptions_stripe_sub_key UNIQUE (stripe_subscription_id)
);

CREATE UNIQUE INDEX subscriptions_one_live_per_account
    ON subscriptions (owner_account_id)
    WHERE owner_account_id IS NOT NULL AND status IN ('trialing','active','past_due');

CREATE UNIQUE INDEX subscriptions_one_live_per_org
    ON subscriptions (owner_org_id)
    WHERE owner_org_id IS NOT NULL AND status IN ('trialing','active','past_due');

-- ---------- stripe webhook idempotency ----------
-- Stripe redelivers. Without this, a redelivered invoice event double-applies.

CREATE TABLE stripe_events (
    stripe_event_id text PRIMARY KEY,
    type            text NOT NULL,
    payload         jsonb NOT NULL,
    received_at     timestamptz NOT NULL DEFAULT now(),
    processed_at    timestamptz,
    error           text
);

CREATE INDEX stripe_events_unprocessed_idx
    ON stripe_events (received_at) WHERE processed_at IS NULL;

-- ---------- generic API idempotency ----------

CREATE TABLE idempotency_keys (
    key           text PRIMARY KEY,
    account_id    uuid REFERENCES accounts (id) ON DELETE CASCADE,
    endpoint      text NOT NULL,
    request_hash  bytea NOT NULL,
    response_code int,
    response_body jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    completed_at  timestamptz
);

CREATE INDEX idempotency_keys_created_idx ON idempotency_keys (created_at);

-- ============================================================
-- Audit log — partitioned monthly, append-only.
--
-- Actors are referenced by opaque id ONLY. No email, no name. That is what
-- lets erasure tombstone an account (§10) while the audit history survives
-- intact: the id remains, and it no longer resolves to a person.
-- ============================================================

CREATE TABLE audit_log (
    id             uuid NOT NULL DEFAULT gen_random_uuid(),
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    actor_scope    actor_scope NOT NULL,
    actor_account_id uuid,
    actor_org_id     uuid,
    action         text NOT NULL,
    subject_type   text NOT NULL,
    subject_id     uuid,
    before         jsonb,
    after          jsonb,
    correlation_id uuid,
    ip_country     char(2),
    PRIMARY KEY (id, occurred_at),

    -- A system action has no actor; every other scope must name one.
    CONSTRAINT audit_actor_shape CHECK (
        (actor_scope = 'system' AND actor_account_id IS NULL)
     OR (actor_scope <> 'system' AND actor_account_id IS NOT NULL)
    )
) PARTITION BY RANGE (occurred_at);

CREATE INDEX audit_log_subject_idx ON audit_log (subject_type, subject_id, occurred_at DESC);
CREATE INDEX audit_log_actor_idx   ON audit_log (actor_account_id, occurred_at DESC);

-- NOTE: audit_log deliberately carries NO foreign key to accounts. An FK would
-- force ON DELETE behaviour on a table that must never lose rows, and would let
-- account deletion cascade into the audit trail. Referential integrity here is
-- one-directional by design: accounts are tombstoned, never deleted (§10).

CREATE TABLE audit_log_2026_08 PARTITION OF audit_log
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE audit_log_2026_09 PARTITION OF audit_log
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE audit_log_default PARTITION OF audit_log DEFAULT;

-- ============================================================
-- tap_events — ~100M rows/month, ~1.2B/year (§1).
--
-- Partitioned by REGION first, then by month. Region-first is the decision that
-- keeps data residency open: an EU-only deployment becomes a partition move
-- rather than a 1.2-billion-row rewrite. Carrying the dimension unused costs
-- almost nothing; adding it later is one of the most expensive migrations in
-- this class of system.
--
-- Contains data about VISITORS, who never agreed to anything. Therefore: no raw
-- IP, device class not fingerprint, retention by partition drop (§8).
-- ============================================================

CREATE TABLE tap_events (
    id            bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    region        data_region NOT NULL,
    card_id       uuid,
    profile_id    uuid NOT NULL,
    channel       tap_channel NOT NULL DEFAULT 'nfc',
    country       char(2),
    device_class  text,
    referrer_host text,
    is_bot        boolean NOT NULL DEFAULT false,
    PRIMARY KEY (id, region, occurred_at)
) PARTITION BY LIST (region);

-- No foreign keys. At 800 writes/sec on the ingest path an FK check per row is
-- pure overhead, and a dangling card_id after a hard delete is acceptable in an
-- analytics table where cards are RESTRICT-protected anyway.

CREATE TABLE tap_events_eu PARTITION OF tap_events
    FOR VALUES IN ('eu') PARTITION BY RANGE (occurred_at);
CREATE TABLE tap_events_us PARTITION OF tap_events
    FOR VALUES IN ('us') PARTITION BY RANGE (occurred_at);
CREATE TABLE tap_events_in PARTITION OF tap_events
    FOR VALUES IN ('in') PARTITION BY RANGE (occurred_at);

CREATE TABLE tap_events_eu_2026_08 PARTITION OF tap_events_eu
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE tap_events_eu_2026_09 PARTITION OF tap_events_eu
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE tap_events_us_2026_08 PARTITION OF tap_events_us
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE tap_events_us_2026_09 PARTITION OF tap_events_us
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE tap_events_in_2026_08 PARTITION OF tap_events_in
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE tap_events_in_2026_09 PARTITION OF tap_events_in
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

CREATE INDEX tap_events_profile_idx ON tap_events (profile_id, occurred_at DESC);
CREATE INDEX tap_events_card_idx    ON tap_events (card_id, occurred_at DESC);

-- ---------- rollups ----------
-- The dashboard reads ONLY these. It must never touch tap_events, and these
-- outlive the raw partitions so analytics survive retention drops (§8).

CREATE TABLE tap_daily (
    profile_id   uuid NOT NULL,
    day          date NOT NULL,
    region       data_region NOT NULL,
    taps         bigint NOT NULL DEFAULT 0,
    nfc_taps     bigint NOT NULL DEFAULT 0,
    qr_taps      bigint NOT NULL DEFAULT 0,
    bot_taps     bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (profile_id, day, region)
);

CREATE TABLE tap_daily_country (
    profile_id uuid NOT NULL,
    day        date NOT NULL,
    country    char(2) NOT NULL,
    taps       bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (profile_id, day, country)
);

CREATE INDEX tap_daily_day_idx ON tap_daily (day);

-- ============================================================
-- Append-only enforcement (§10).
--
-- A database grant, not a convention. The application role physically cannot
-- rewrite history, so "immutable audit trail" is a property an auditor can
-- verify with \dp rather than a claim about code review discipline.
-- ============================================================

-- Roles are cluster-scoped, so creation must be idempotent for repeatable runs.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_resolver') THEN
        CREATE ROLE app_resolver NOLOGIN;
    END IF;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;

REVOKE UPDATE, DELETE ON ownership_transfers FROM app_rw;
REVOKE UPDATE, DELETE ON card_assignments    FROM app_rw;
REVOKE UPDATE, DELETE ON card_encodings      FROM app_rw;
REVOKE UPDATE, DELETE ON audit_log           FROM app_rw;
REVOKE DELETE           ON slugs             FROM app_rw;
REVOKE DELETE           ON accounts          FROM app_rw;

-- The resolver reads one table and nothing else. Least privilege at the
-- database level means a resolver compromise cannot read profiles or accounts.
GRANT SELECT (token_hash, serving_state, serving_slug) ON cards TO app_resolver;
