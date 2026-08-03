-- ============================================================
-- NFC Digital Identity Platform — Step 2, part 1
-- Enums, identity, access, profiles, slugs
-- Target: PostgreSQL 16
-- ============================================================

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- enums ----------
-- Enums over check constraints: they are self-documenting in \d output, which
-- matters when an auditor is reading the schema rather than the application.

CREATE TYPE data_region       AS ENUM ('eu', 'us', 'in');
CREATE TYPE account_status    AS ENUM ('pending', 'active', 'suspended', 'tombstoned');
CREATE TYPE platform_role     AS ENUM ('none', 'support', 'admin', 'super_admin');
CREATE TYPE org_status        AS ENUM ('active', 'suspended', 'closed');
CREATE TYPE org_role          AS ENUM ('employee', 'manager', 'hr', 'org_admin');
CREATE TYPE membership_status AS ENUM ('invited', 'active', 'removed');
CREATE TYPE profile_status    AS ENUM ('draft', 'active', 'suspended', 'deleted');
CREATE TYPE card_status       AS ENUM ('manufactured', 'provisioned', 'claimed', 'active', 'suspended', 'revoked');
CREATE TYPE serving_state     AS ENUM ('unclaimed', 'active', 'lapsed', 'suspended', 'revoked');
CREATE TYPE chip_profile      AS ENUM ('ntag213', 'ntag215', 'ntag216', 'ntag424_dna');
CREATE TYPE sub_status        AS ENUM ('trialing', 'active', 'past_due', 'canceled', 'unpaid');
CREATE TYPE transfer_reason   AS ENUM ('activation', 'sale', 'gift', 'lost_replacement', 'org_reassignment', 'admin_correction');
CREATE TYPE tap_channel       AS ENUM ('nfc', 'qr', 'direct');
CREATE TYPE actor_scope       AS ENUM ('system', 'account', 'organization', 'platform');

-- ---------- organizations ----------

CREATE TABLE organizations (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name           text        NOT NULL,
    billing_email  citext      NOT NULL,
    status         org_status   NOT NULL DEFAULT 'active',
    data_region    data_region  NOT NULL,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT organizations_name_not_blank CHECK (length(btrim(name)) > 0)
);

-- ---------- accounts ----------
-- email is nullable ONLY so erasure can null it while keeping the row as a
-- tombstone; audit rows reference accounts by id and must never dangle (§10).

CREATE TABLE accounts (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email             citext,
    email_verified_at timestamptz,
    password_hash     text,
    full_name         text,
    platform_role     platform_role  NOT NULL DEFAULT 'none',
    status            account_status NOT NULL DEFAULT 'pending',
    data_region       data_region    NOT NULL,
    created_at        timestamptz    NOT NULL DEFAULT now(),
    updated_at        timestamptz    NOT NULL DEFAULT now(),
    tombstoned_at     timestamptz,

    -- A live account must be identifiable; a tombstone must not be.
    CONSTRAINT accounts_live_has_email CHECK (
        (tombstoned_at IS NULL  AND email IS NOT NULL)
     OR (tombstoned_at IS NOT NULL AND email IS NULL
         AND password_hash IS NULL AND full_name IS NULL
         AND status = 'tombstoned')
    )
);

-- Email uniqueness applies to live accounts only, so tombstoning frees the address.
CREATE UNIQUE INDEX accounts_email_live_key
    ON accounts (email) WHERE tombstoned_at IS NULL;

CREATE INDEX accounts_platform_role_idx
    ON accounts (platform_role) WHERE platform_role <> 'none';

-- ---------- org memberships ----------
-- UNIQUE (account_id, org_id) is load-bearing: cards references it to prove a
-- holder belongs to the owning organisation (§6).

CREATE TABLE org_memberships (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id      uuid NOT NULL REFERENCES organizations (id) ON DELETE RESTRICT,
    account_id  uuid NOT NULL REFERENCES accounts (id)      ON DELETE RESTRICT,
    role        org_role          NOT NULL DEFAULT 'employee',
    status      membership_status NOT NULL DEFAULT 'invited',
    invited_by  uuid REFERENCES accounts (id) ON DELETE SET NULL,
    joined_at   timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT org_memberships_account_org_key UNIQUE (account_id, org_id)
);

CREATE INDEX org_memberships_org_idx ON org_memberships (org_id, status);

-- ---------- sessions ----------
-- Server-side sessions, not JWTs, so revocation is immediate (§9).

CREATE TABLE sessions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id         uuid NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    family_id          uuid NOT NULL,
    refresh_token_hash bytea NOT NULL,
    device_label       text,
    device_class       text,
    ip_country         char(2),
    created_at         timestamptz NOT NULL DEFAULT now(),
    last_seen_at       timestamptz NOT NULL DEFAULT now(),
    expires_at         timestamptz NOT NULL,
    revoked_at         timestamptz,
    revoked_reason     text,
    CONSTRAINT sessions_refresh_hash_key UNIQUE (refresh_token_hash)
);

CREATE INDEX sessions_account_live_idx
    ON sessions (account_id, last_seen_at DESC) WHERE revoked_at IS NULL;
CREATE INDEX sessions_family_idx ON sessions (family_id);

-- ---------- otp codes ----------

CREATE TABLE otp_codes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  uuid NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    purpose     text  NOT NULL,
    code_hash   bytea NOT NULL,
    attempts    int   NOT NULL DEFAULT 0,
    expires_at  timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT otp_attempts_bounded CHECK (attempts >= 0 AND attempts <= 10)
);

CREATE INDEX otp_codes_account_idx
    ON otp_codes (account_id, purpose) WHERE consumed_at IS NULL;

-- ---------- profiles ----------
-- Owned by exactly one of account or organization (§2.6). The two partial
-- unique indexes below are what let cards prove "profile belongs to holder"
-- and "profile belongs to owning org" as plain foreign keys.

CREATE TABLE profiles (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_account_id  uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    owner_org_id      uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    current_slug      citext NOT NULL,
    display_name      text   NOT NULL,
    headline          text,
    bio               text,
    links             jsonb  NOT NULL DEFAULT '{}'::jsonb,
    theme             text   NOT NULL DEFAULT 'default',
    template          text   NOT NULL DEFAULT 'standard',
    avatar_key        text,
    resume_key        text,
    status            profile_status NOT NULL DEFAULT 'draft',
    published_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT profiles_single_owner CHECK (
        num_nonnulls(owner_account_id, owner_org_id) = 1
    ),
    CONSTRAINT profiles_links_is_object CHECK (jsonb_typeof(links) = 'object')
);

-- Referenced by the composite foreign keys on cards. These MUST NOT be partial:
-- Postgres will not let a foreign key reference a partial unique index. They are
-- redundant given id is already the primary key, which is precisely why they are
-- free to add -- their only job is to make the ownership invariants expressible
-- as declarative foreign keys instead of triggers.
ALTER TABLE profiles ADD CONSTRAINT profiles_id_owner_account_key
    UNIQUE (id, owner_account_id);
ALTER TABLE profiles ADD CONSTRAINT profiles_id_owner_org_key
    UNIQUE (id, owner_org_id);

CREATE INDEX profiles_owner_account_idx ON profiles (owner_account_id) WHERE owner_account_id IS NOT NULL;
CREATE INDEX profiles_owner_org_idx     ON profiles (owner_org_id)     WHERE owner_org_id IS NOT NULL;

-- ---------- slugs ----------
-- ONE table owns the entire slug namespace: current slugs, retired slugs, and
-- platform reservations all collide on the same primary key. A retired slug can
-- never be reissued to a different profile, so every link ever shared keeps
-- resolving to the same identity forever. Reservations are rows with no profile,
-- which blocks impersonation without needing a trigger or a subquery.

CREATE TYPE slug_kind AS ENUM ('current', 'retired', 'reserved');

CREATE TABLE slugs (
    slug        citext PRIMARY KEY,
    kind        slug_kind NOT NULL,
    profile_id  uuid REFERENCES profiles (id) ON DELETE RESTRICT,
    reason      text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    retired_at  timestamptz,

    CONSTRAINT slugs_profile_presence CHECK (
        (kind = 'reserved' AND profile_id IS NULL)
     OR (kind <> 'reserved' AND profile_id IS NOT NULL)
    ),
    CONSTRAINT slugs_retired_timestamp CHECK (
        (kind = 'retired' AND retired_at IS NOT NULL)
     OR (kind <> 'retired' AND retired_at IS NULL)
    ),
    -- Reservations may be short — claiming 't' and 'u' is the whole point.
    -- User-facing slugs need at least 3 characters.
    CONSTRAINT slugs_shape CHECK (slug ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),
    CONSTRAINT slugs_user_min_length CHECK (
        kind = 'reserved' OR length(slug) >= 3
    )
);

-- Exactly one current slug per profile.
CREATE UNIQUE INDEX slugs_one_current_per_profile
    ON slugs (profile_id) WHERE kind = 'current';

CREATE INDEX slugs_profile_idx ON slugs (profile_id) WHERE profile_id IS NOT NULL;

-- profiles.current_slug must name a real slug. Deferred so a profile and its
-- first slug can be inserted in either order inside one transaction.
ALTER TABLE profiles
    ADD CONSTRAINT profiles_current_slug_fk
    FOREIGN KEY (current_slug) REFERENCES slugs (slug)
    DEFERRABLE INITIALLY DEFERRED;

INSERT INTO slugs (slug, kind, reason) VALUES
    ('admin','reserved','platform'),      ('api','reserved','platform'),
    ('t','reserved','resolver'),          ('u','reserved','profile-namespace'),
    ('login','reserved','platform'),      ('signup','reserved','platform'),
    ('support','reserved','impersonation'),('billing','reserved','impersonation'),
    ('security','reserved','impersonation'),('help','reserved','platform'),
    ('www','reserved','platform'),        ('settings','reserved','platform');
