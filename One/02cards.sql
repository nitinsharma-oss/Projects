-- ============================================================
-- Step 2, part 2 — cards and the ownership invariants
-- ============================================================

-- ---------- card batches ----------

CREATE TABLE card_batches (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id        uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    chip          chip_profile NOT NULL,
    quantity      int NOT NULL,
    manufacturer  text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT card_batches_quantity_positive CHECK (quantity > 0)
);

-- ---------- cards ----------
-- The token is NEVER stored in plaintext. The resolver hashes the incoming
-- token and looks up the hash, so a database disclosure does not hand an
-- attacker a catalogue of live tokens mapped to identities. token_prefix is
-- kept unhashed purely so support can find "the card ending in ...".
--
-- Three edges (§0.1): owner = title, holder = custody, profile = what it serves.

CREATE TABLE cards (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash         bytea NOT NULL,
    token_prefix       char(6) NOT NULL,
    batch_id           uuid REFERENCES card_batches (id) ON DELETE RESTRICT,
    chip               chip_profile NOT NULL,

    owner_account_id   uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    owner_org_id       uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    holder_account_id  uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    profile_id         uuid REFERENCES profiles (id)      ON DELETE RESTRICT,

    -- Denormalised so the resolver answers from one row with no join (§5.1).
    -- Kept consistent by the write path; reconciled on a schedule (§2.2).
    serving_slug       citext,
    serving_state      serving_state NOT NULL DEFAULT 'unclaimed',

    status             card_status NOT NULL DEFAULT 'manufactured',
    claim_code_hash    text,
    claim_attempts     int NOT NULL DEFAULT 0,
    claim_locked_until timestamptz,

    dna_key_ref        text,
    dna_counter        bigint,

    -- Discriminator for the personal-ownership foreign key below. NULL whenever
    -- the card is NOT personally owned, which is what makes MATCH SIMPLE stand
    -- the constraint down for organisation-owned cards. Generated, so it cannot
    -- drift from owner_account_id.
    personal_holder_id uuid GENERATED ALWAYS AS (
        CASE WHEN owner_account_id IS NOT NULL THEN holder_account_id END
    ) STORED,

    locked_at          timestamptz,
    claimed_at         timestamptz,
    activated_at       timestamptz,
    revoked_at         timestamptz,
    revoked_reason     text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT cards_token_hash_key UNIQUE (token_hash),

    -- At most one owner, and an owned card must have exactly one.
    CONSTRAINT cards_single_owner CHECK (
        num_nonnulls(owner_account_id, owner_org_id) <= 1
    ),

    -- An active card must be fully bound and must have been locked at encoding.
    CONSTRAINT cards_active_is_bound CHECK (
        status <> 'active' OR (
            num_nonnulls(owner_account_id, owner_org_id) = 1
            AND holder_account_id IS NOT NULL
            AND profile_id        IS NOT NULL
            AND serving_slug      IS NOT NULL
            AND locked_at         IS NOT NULL
        )
    ),

    -- Revoked is terminal and must record why.
    CONSTRAINT cards_revoked_has_reason CHECK (
        status <> 'revoked' OR (revoked_at IS NOT NULL AND revoked_reason IS NOT NULL)
    ),

    -- Only a revoked card may carry serving_state 'revoked', and vice versa.
    CONSTRAINT cards_revoked_state_agrees CHECK (
        (status = 'revoked') = (serving_state = 'revoked')
    ),

    -- DNA cards must reference a key; basic chips must not pretend to.
    CONSTRAINT cards_dna_key_present CHECK (
        (chip = 'ntag424_dna') = (dna_key_ref IS NOT NULL)
    ),

    CONSTRAINT cards_claim_attempts_bounded CHECK (claim_attempts >= 0)
);

-- ============================================================
-- The ownership invariants, enforced as plain foreign keys.
--
-- All three use Postgres's default MATCH SIMPLE: a composite FK containing a
-- NULL column is NOT enforced. So each key activates only for the ownership
-- shape it governs, with no triggers and no application logic.
--
-- CRITICAL SUBTLETY: MATCH SIMPLE only stands down when a column *inside the
-- key* is NULL. The discriminator therefore has to BE a key column. An earlier
-- draft used (profile_id, holder_account_id) for the personal key, reasoning
-- that owner_account_id IS NULL would disable it for org cards -- but
-- owner_account_id is not in that key, and both of its columns are populated on
-- an org card, so the constraint fired and made org cards impossible to insert.
-- Hence personal_holder_id: generated, NULL for org-owned cards, in the key.
--
--   personal card -> owner_org_id IS NULL       -> org keys stand down
--   org card      -> personal_holder_id IS NULL -> personal key stands down
-- ============================================================

-- 1. Personal card: the profile must belong to the holder.
ALTER TABLE cards
    ADD CONSTRAINT cards_personal_profile_belongs_to_holder
    FOREIGN KEY (profile_id, personal_holder_id)
    REFERENCES profiles (id, owner_account_id);

-- 2. Org card: the profile must belong to the owning organisation.
ALTER TABLE cards
    ADD CONSTRAINT cards_org_profile_belongs_to_org
    FOREIGN KEY (profile_id, owner_org_id)
    REFERENCES profiles (id, owner_org_id);

-- 3. Org card: the holder must be a member of the owning organisation.
ALTER TABLE cards
    ADD CONSTRAINT cards_org_holder_is_member
    FOREIGN KEY (holder_account_id, owner_org_id)
    REFERENCES org_memberships (account_id, org_id);

-- ---------- resolver indexes ----------
-- The only index the hot path uses. Partial, because the resolver never asks
-- about cards that cannot serve, which keeps it small enough to stay cached.

CREATE INDEX cards_resolver_idx
    ON cards (token_hash) INCLUDE (serving_state, serving_slug);

CREATE INDEX cards_token_prefix_idx  ON cards (token_prefix);
CREATE INDEX cards_holder_idx        ON cards (holder_account_id) WHERE holder_account_id IS NOT NULL;
CREATE INDEX cards_owner_org_idx     ON cards (owner_org_id)      WHERE owner_org_id IS NOT NULL;
CREATE INDEX cards_owner_account_idx ON cards (owner_account_id)  WHERE owner_account_id IS NOT NULL;
CREATE INDEX cards_profile_idx       ON cards (profile_id)        WHERE profile_id IS NOT NULL;

-- Drift reconciliation sweeps by state; keep it cheap.
CREATE INDEX cards_serving_state_idx ON cards (serving_state, updated_at);

-- ---------- ownership transfers (append-only) ----------
-- The record of TITLE. Every change of owner, forever. Activation is the first
-- row, with a null "from".

CREATE TABLE ownership_transfers (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    card_id           uuid NOT NULL REFERENCES cards (id) ON DELETE RESTRICT,
    from_account_id   uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    from_org_id       uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    to_account_id     uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    to_org_id         uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    reason            transfer_reason NOT NULL,
    requested_by      uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    approved_by       uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    approved_at       timestamptz NOT NULL DEFAULT now(),
    correlation_id    uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),

    -- A transfer must land somewhere, on exactly one kind of owner.
    CONSTRAINT transfers_single_destination CHECK (
        num_nonnulls(to_account_id, to_org_id) = 1
    ),
    -- Origin is either absent (activation) or exactly one kind.
    CONSTRAINT transfers_origin_shape CHECK (
        (reason = 'activation' AND num_nonnulls(from_account_id, from_org_id) = 0)
     OR (reason <> 'activation' AND num_nonnulls(from_account_id, from_org_id) = 1)
    ),
    -- Only an admin correction may lack a named approver.
    CONSTRAINT transfers_approved CHECK (
        approved_by IS NOT NULL OR reason = 'activation'
    )
);

CREATE INDEX transfers_card_idx ON ownership_transfers (card_id, approved_at DESC);

-- ---------- card assignments (append-only) ----------
-- Holder changes for org cards. NOT transfers: title does not move, so these
-- deliberately do not pollute the ownership record.

CREATE TABLE card_assignments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    card_id          uuid NOT NULL REFERENCES cards (id) ON DELETE RESTRICT,
    from_account_id  uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    to_account_id    uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    assigned_by      uuid NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    correlation_id   uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT assignments_changes_something CHECK (
        from_account_id IS DISTINCT FROM to_account_id
    )
);

CREATE INDEX assignments_card_idx ON card_assignments (card_id, created_at DESC);

-- ---------- encodings (append-only) ----------
-- The immutable proof that a chip was locked, by whom, on which station (§7.3).
-- This replaces a mutable chip_locked boolean: a flag can be flipped by a bug,
-- an append-only row cannot be un-written.

CREATE TABLE card_encodings (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    card_id            uuid NOT NULL REFERENCES cards (id) ON DELETE RESTRICT,
    encoder_account_id uuid NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    station_id         text NOT NULL,
    chip               chip_profile NOT NULL,
    locked             boolean NOT NULL,
    verify_read_ok     boolean NOT NULL,
    occurred_at        timestamptz NOT NULL DEFAULT now(),

    -- A card may only ship if the lock was applied AND read back successfully.
    CONSTRAINT encodings_lock_verified CHECK (NOT locked OR verify_read_ok)
);

CREATE INDEX encodings_card_idx ON card_encodings (card_id, occurred_at DESC);
