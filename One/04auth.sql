-- ============================================================
-- Step 3, migration 04 — auth hardening
--
--   a) refresh token rotation with reuse detection
--   b) row-level security on tenant-scoped tables
--
-- (a) is a correction: Step 2's sessions table stored only the CURRENT refresh
-- token hash, which makes a replayed old token indistinguishable from a random
-- invalid one. Reuse detection requires retaining used tokens.
-- ============================================================

-- ------------------------------------------------------------
-- (a) refresh token rotation
-- ------------------------------------------------------------

-- The session is now the device login. Its id IS the token family, so the
-- separate family_id column is redundant.
ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_refresh_hash_key;
ALTER TABLE sessions DROP COLUMN IF EXISTS refresh_token_hash;
ALTER TABLE sessions DROP COLUMN IF EXISTS family_id;

-- One row per refresh token ever issued for a session. Rotation marks the old
-- token used and points it at its successor; presenting a used token is proof
-- of theft, because a well-behaved client discards a token the moment it
-- exchanges it.
CREATE TABLE refresh_tokens (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id   uuid  NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    token_hash   bytea NOT NULL,
    issued_at    timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    used_at      timestamptz,
    replaced_by  uuid REFERENCES refresh_tokens (id) ON DELETE SET NULL,

    CONSTRAINT refresh_tokens_hash_key UNIQUE (token_hash),

    -- A used token must name its successor. This is what makes reuse detection
    -- possible rather than merely intended.
    CONSTRAINT refresh_tokens_used_has_successor CHECK (
        (used_at IS NULL AND replaced_by IS NULL)
     OR (used_at IS NOT NULL AND replaced_by IS NOT NULL)
    ),
    CONSTRAINT refresh_tokens_expiry_after_issue CHECK (expires_at > issued_at)
);

CREATE INDEX refresh_tokens_session_idx  ON refresh_tokens (session_id, issued_at DESC);
CREATE INDEX refresh_tokens_live_idx     ON refresh_tokens (expires_at) WHERE used_at IS NULL;

COMMENT ON TABLE refresh_tokens IS
  'One row per issued refresh token. A hit with used_at NOT NULL is a replay: revoke the entire session and raise a security event.';

-- Security events are audit rows, not a separate table -- one immutable log.
COMMENT ON COLUMN sessions.revoked_reason IS
  'e.g. user_signout, refresh_reuse_detected, admin_revoked, password_changed.';

-- ------------------------------------------------------------
-- (b) row-level security
--
-- Deferred in Step 2 §8, adopted here. The argument is not that it stops a
-- compromised application server -- it does not, since the app supplies the
-- identity. The argument is that tenant scoping becomes ONE predicate the
-- database enforces on every query, instead of a WHERE clause every developer
-- must remember on every query forever. It converts a whole class of IDOR bug
-- from "possible" to "impossible without also removing a policy".
--
-- Fails closed: with no app.account_id set, the predicates compare against
-- NULL, which is never true, so queries return zero rows rather than
-- everything.
-- ------------------------------------------------------------

-- Pinned search_path: a SECURITY DEFINER function without one is a privilege
-- escalation vector, and is the first thing an assessor greps for.
CREATE OR REPLACE FUNCTION app_current_account() RETURNS uuid
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, public
AS $$
    SELECT nullif(current_setting('app.account_id', true), '')::uuid
$$;

-- SECURITY DEFINER so it can read org_memberships without RLS recursion:
-- a policy that queried the table directly would re-enter that table's own
-- policy. STABLE so it evaluates once per query, not once per row.
CREATE OR REPLACE FUNCTION app_current_org_ids() RETURNS uuid[]
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, public
AS $$
    SELECT coalesce(array_agg(org_id), '{}'::uuid[])
      FROM org_memberships
     WHERE account_id = app_current_account()
       AND status = 'active'
$$;

REVOKE ALL ON FUNCTION app_current_org_ids() FROM PUBLIC;

-- The admin surface is a separate database role, so "admins see everything" is
-- a visible policy an assessor can read rather than an application if-statement.
-- Four application roles, each with the narrowest grant that lets it work.
-- Least privilege is expressed as roles + policies, so a compromise of any one
-- service is bounded by something an assessor can read.
DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['app_admin','app_renderer','app_auth'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

-- The public renderer reads published profile content and nothing else.
GRANT SELECT ON profiles, slugs TO app_renderer;

-- The authenticator owns credential verification and token rotation only.
GRANT SELECT, INSERT, UPDATE ON sessions TO app_auth;
GRANT SELECT ON accounts TO app_auth;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_admin;
REVOKE UPDATE, DELETE ON ownership_transfers, card_assignments,
                         card_encodings, audit_log FROM app_admin;

GRANT SELECT, INSERT, UPDATE, DELETE ON refresh_tokens TO app_rw, app_admin;
GRANT EXECUTE ON FUNCTION app_current_account(), app_current_org_ids()
    TO app_rw, app_admin;

-- ---------- profiles ----------

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_tenant ON profiles
    FOR ALL TO app_rw
    USING (
        owner_account_id = app_current_account()
     OR owner_org_id     = ANY (app_current_org_ids())
    )
    WITH CHECK (
        owner_account_id = app_current_account()
     OR owner_org_id     = ANY (app_current_org_ids())
    );

CREATE POLICY profiles_admin ON profiles FOR ALL TO app_admin USING (true) WITH CHECK (true);

-- The public profile renderer needs to read any published profile by slug, and
-- must never see drafts or suspended profiles. That is a policy, not a filter
-- the renderer is trusted to remember.
CREATE POLICY profiles_public_read ON profiles
    FOR SELECT TO app_renderer
    USING (status = 'active');

-- ---------- cards ----------

ALTER TABLE cards ENABLE ROW LEVEL SECURITY;

CREATE POLICY cards_tenant ON cards
    FOR ALL TO app_rw
    USING (
        holder_account_id = app_current_account()
     OR owner_account_id  = app_current_account()
     OR owner_org_id      = ANY (app_current_org_ids())
    )
    WITH CHECK (
        holder_account_id = app_current_account()
     OR owner_account_id  = app_current_account()
     OR owner_org_id      = ANY (app_current_org_ids())
    );

CREATE POLICY cards_admin ON cards FOR ALL TO app_admin USING (true) WITH CHECK (true);

-- The resolver must resolve ANY token -- it has no user context. Its blast
-- radius is bounded by column-level grants instead (three columns, §4.7).
CREATE POLICY cards_resolver ON cards FOR SELECT TO app_resolver USING (true);

-- ---------- subscriptions ----------

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY subscriptions_tenant ON subscriptions
    FOR ALL TO app_rw
    USING (
        owner_account_id = app_current_account()
     OR owner_org_id     = ANY (app_current_org_ids())
    )
    WITH CHECK (
        owner_account_id = app_current_account()
     OR owner_org_id     = ANY (app_current_org_ids())
    );

CREATE POLICY subscriptions_admin ON subscriptions FOR ALL TO app_admin USING (true) WITH CHECK (true);

-- ---------- org memberships ----------
-- Who works where is personal data. Visible to the member themselves and to
-- fellow members of the same organisation.

ALTER TABLE org_memberships ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_memberships_tenant ON org_memberships
    FOR ALL TO app_rw
    USING (
        account_id = app_current_account()
     OR org_id     = ANY (app_current_org_ids())
    )
    WITH CHECK (
        org_id = ANY (app_current_org_ids())
    );

CREATE POLICY org_memberships_admin ON org_memberships FOR ALL TO app_admin USING (true) WITH CHECK (true);

-- ---------- sessions and refresh tokens ----------
-- A session listing must never leak another account's devices.

ALTER TABLE sessions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY sessions_own ON sessions
    FOR ALL TO app_rw
    USING (account_id = app_current_account())
    WITH CHECK (account_id = app_current_account());

CREATE POLICY sessions_admin ON sessions FOR ALL TO app_admin USING (true) WITH CHECK (true);

-- Refresh token lookup happens BEFORE an identity exists -- the token is what
-- establishes it. So the authenticator uses its own role, and app_rw sees only
-- its own rows for the "sign out everywhere" listing.
CREATE POLICY refresh_tokens_own ON refresh_tokens
    FOR ALL TO app_rw
    USING (session_id IN (SELECT id FROM sessions WHERE account_id = app_current_account()))
    WITH CHECK (session_id IN (SELECT id FROM sessions WHERE account_id = app_current_account()));

CREATE POLICY refresh_tokens_authenticator ON refresh_tokens
    FOR ALL TO app_auth USING (true) WITH CHECK (true);

CREATE POLICY sessions_authenticator ON sessions
    FOR ALL TO app_auth USING (true) WITH CHECK (true);

CREATE POLICY refresh_tokens_admin ON refresh_tokens FOR ALL TO app_admin USING (true) WITH CHECK (true);
