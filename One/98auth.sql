-- ============================================================
-- Step 3 — RLS and refresh-token verification
--
-- Run AFTER 04_auth_hardening.sql, in its own psql session (the temp tables
-- must not collide with 99_constraint_tests.sql).
--
-- Every scenario runs as a real restricted role. Testing RLS as superuser is
-- meaningless -- superusers and table owners bypass policies entirely, which is
-- the classic way a team convinces itself RLS is working when it is not.
-- ============================================================

\set ON_ERROR_STOP on
SET client_min_messages TO WARNING;

CREATE TEMP TABLE rls_results (label text, expected text, got text);

-- Scoping predicates are applied DIRECTLY to base tables, never through a view.
-- A view owned by postgres reads its base tables with the VIEW OWNER's
-- privileges unless security_invoker=true, which silently bypasses RLS and
-- turns these assertions into false passes. Base tables only, deliberately.
GRANT ALL ON rls_results TO app_rw, app_renderer, app_resolver, app_auth;

CREATE OR REPLACE FUNCTION expect_reject_rls(label text, stmt text) RETURNS void AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
        INSERT INTO rls_results VALUES (label, 'reject', 'FAIL — was accepted');
    EXCEPTION WHEN others THEN
        INSERT INTO rls_results VALUES (label, 'reject', 'reject');
    END;
END $$ LANGUAGE plpgsql;

-- ============================================================
-- Fixtures
-- ============================================================

INSERT INTO organizations (id, name, billing_email, data_region) VALUES
  ('00000000-0000-0000-0001-0000000000a1', 'Acme Two',  'b@acme2.test',  'eu'),
  ('00000000-0000-0000-0001-0000000000a2', 'Rival Two', 'b@rival2.test', 'us');

INSERT INTO accounts (id, email, full_name, data_region, status) VALUES
  ('00000000-0000-0000-0001-0000000000b1', 'alice@t.test', 'Alice', 'eu', 'active'),
  ('00000000-0000-0000-0001-0000000000b2', 'bob@t.test',   'Bob',   'eu', 'active');

-- Alice is an Acme Two employee. Bob is not in any organisation.
INSERT INTO org_memberships (org_id, account_id, role, status, joined_at) VALUES
  ('00000000-0000-0000-0001-0000000000a1','00000000-0000-0000-0001-0000000000b1','employee','active', now());

BEGIN;
INSERT INTO profiles (id, owner_account_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0001-0000000000c1', '00000000-0000-0000-0001-0000000000b1', 'alice', 'Alice', 'active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('alice','current','00000000-0000-0000-0001-0000000000c1');

INSERT INTO profiles (id, owner_account_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0001-0000000000c2', '00000000-0000-0000-0001-0000000000b2', 'bob', 'Bob', 'active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('bob','current','00000000-0000-0000-0001-0000000000c2');

INSERT INTO profiles (id, owner_org_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0001-0000000000c3', '00000000-0000-0000-0001-0000000000a1', 'acme2-desk', 'Acme Two Desk', 'active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('acme2-desk','current','00000000-0000-0000-0001-0000000000c3');

INSERT INTO profiles (id, owner_org_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0001-0000000000c4', '00000000-0000-0000-0001-0000000000a1', 'acme2-draft', 'Acme Two Draft', 'draft');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('acme2-draft','current','00000000-0000-0000-0001-0000000000c4');
COMMIT;

INSERT INTO cards (id, token_hash, token_prefix, chip, owner_account_id,
                   holder_account_id, profile_id, serving_slug, serving_state, status, locked_at)
VALUES ('00000000-0000-0000-0001-0000000000d1', '\xa1'::bytea, 'zzzzzz', 'ntag213',
        '00000000-0000-0000-0001-0000000000b1',
        '00000000-0000-0000-0001-0000000000b1',
        '00000000-0000-0000-0001-0000000000c1', 'alice', 'active', 'active', now());

INSERT INTO sessions (id, account_id, device_label, expires_at) VALUES
  ('00000000-0000-0000-0001-0000000000e1','00000000-0000-0000-0001-0000000000b1','Alice iPhone', now() + interval '12 hours'),
  ('00000000-0000-0000-0001-0000000000e2','00000000-0000-0000-0001-0000000000b2','Bob Pixel',    now() + interval '12 hours');

-- ============================================================
-- 1. RLS fails CLOSED when no identity is set
-- ============================================================

BEGIN;
SET ROLE app_rw;
INSERT INTO rls_results
  VALUES ('no identity set -> zero profiles', '0', (SELECT count(*)::text FROM profiles WHERE current_slug IN ('alice','bob','acme2-desk','acme2-draft')));
INSERT INTO rls_results
  VALUES ('no identity set -> zero cards', '0', (SELECT count(*)::text FROM cards WHERE token_prefix = 'zzzzzz'));
RESET ROLE;
COMMIT;

-- ============================================================
-- 2. Tenant isolation
-- ============================================================

BEGIN;
SET ROLE app_rw;
SET LOCAL app.account_id = '00000000-0000-0000-0001-0000000000b1';
-- Alice: her own profile + both Acme Two profiles (she is an active member).
INSERT INTO rls_results
  VALUES ('alice sees own + org profiles', '3', (SELECT count(*)::text FROM profiles WHERE current_slug IN ('alice','bob','acme2-desk','acme2-draft')));
INSERT INTO rls_results
  VALUES ('alice cannot see bob''s profile', '0',
          (SELECT count(*)::text FROM profiles WHERE current_slug = 'bob'));
INSERT INTO rls_results
  VALUES ('alice sees her own card', '1', (SELECT count(*)::text FROM cards WHERE token_prefix = 'zzzzzz'));
INSERT INTO rls_results
  VALUES ('alice sees only her own session', '1', (SELECT count(*)::text FROM sessions WHERE device_label IN ('Alice iPhone','Bob Pixel')));
RESET ROLE;
COMMIT;

BEGIN;
SET ROLE app_rw;
SET LOCAL app.account_id = '00000000-0000-0000-0001-0000000000b2';
-- Bob is in no organisation, so he sees exactly one profile.
INSERT INTO rls_results
  VALUES ('bob sees only his own profile', '1', (SELECT count(*)::text FROM profiles WHERE current_slug IN ('alice','bob','acme2-desk','acme2-draft')));
INSERT INTO rls_results
  VALUES ('bob sees no cards', '0', (SELECT count(*)::text FROM cards WHERE token_prefix = 'zzzzzz'));
INSERT INTO rls_results
  VALUES ('bob cannot see alice''s session', '0',
          (SELECT count(*)::text FROM sessions WHERE device_label = 'Alice iPhone'));
RESET ROLE;
COMMIT;

-- ============================================================
-- 3. WITH CHECK blocks writing into another tenant
-- ============================================================

BEGIN;
SET ROLE app_rw;
SET LOCAL app.account_id = '00000000-0000-0000-0001-0000000000b1';
SELECT expect_reject_rls('alice cannot create a profile owned by bob', $$
  INSERT INTO profiles (owner_account_id, current_slug, display_name)
  VALUES ('00000000-0000-0000-0001-0000000000b2', 'alice-forged', 'Forged')
$$);
SELECT expect_reject_rls('alice cannot reassign her profile to bob', $$
  UPDATE profiles SET owner_account_id = '00000000-0000-0000-0001-0000000000b2'
   WHERE current_slug = 'alice'
$$);
SELECT expect_reject_rls('alice cannot create a profile for an org she is not in', $$
  INSERT INTO profiles (owner_org_id, current_slug, display_name)
  VALUES ('00000000-0000-0000-0001-0000000000a2', 'rival-forged', 'Forged')
$$);
RESET ROLE;
ROLLBACK;

-- ============================================================
-- 4. Service roles see exactly what they need
-- ============================================================

BEGIN;
SET ROLE app_renderer;
-- The renderer must never serve a draft, and that is a policy, not a filter it
-- is trusted to remember. 4 profiles exist; 3 are active.
INSERT INTO rls_results
  VALUES ('renderer sees active profiles only', '3', (SELECT count(*)::text FROM profiles WHERE current_slug IN ('alice','bob','acme2-desk','acme2-draft')));
RESET ROLE;
COMMIT;

BEGIN;
SET ROLE app_resolver;
-- Resolves any token: it has no user context. Counting a granted column,
-- because column-level privileges do not permit count(*).
INSERT INTO rls_results
  VALUES ('resolver can resolve any card', '1', (SELECT count(token_hash)::text FROM cards WHERE token_hash = '\xa1'::bytea));
RESET ROLE;
COMMIT;

BEGIN;
SET ROLE app_resolver;
SELECT expect_reject_rls('resolver cannot read profile content', $$
  SELECT bio FROM profiles LIMIT 1
$$);
SELECT expect_reject_rls('resolver cannot read accounts', $$
  SELECT email FROM accounts LIMIT 1
$$);
SELECT expect_reject_rls('resolver cannot read a card''s claim code hash', $$
  SELECT claim_code_hash FROM cards LIMIT 1
$$);
RESET ROLE;
ROLLBACK;

-- ============================================================
-- 5. Refresh token rotation and reuse detection
-- ============================================================

-- Issue the first token for Alice's session.
INSERT INTO refresh_tokens (id, session_id, token_hash, expires_at) VALUES
  ('00000000-0000-0000-0001-0000000000f1','00000000-0000-0000-0001-0000000000e1',
   '\xb1'::bytea, now() + interval '30 days');

SELECT expect_reject_rls('a used token with no successor', $$
  UPDATE refresh_tokens SET used_at = now()
   WHERE id = '00000000-0000-0000-0001-0000000000f1'
$$);

SELECT expect_reject_rls('a token that expires before it was issued', $$
  INSERT INTO refresh_tokens (session_id, token_hash, issued_at, expires_at)
  VALUES ('00000000-0000-0000-0001-0000000000e1', '\xbf'::bytea,
          now(), now() - interval '1 hour')
$$);

SELECT expect_reject_rls('two tokens sharing a hash', $$
  INSERT INTO refresh_tokens (session_id, token_hash, expires_at)
  VALUES ('00000000-0000-0000-0001-0000000000e1', '\xb1'::bytea, now() + interval '30 days')
$$);

-- Rotation: issue the successor, then mark the predecessor used, atomically.
BEGIN;
INSERT INTO refresh_tokens (id, session_id, token_hash, expires_at) VALUES
  ('00000000-0000-0000-0001-0000000000f2','00000000-0000-0000-0001-0000000000e1',
   '\xb2'::bytea, now() + interval '30 days');
UPDATE refresh_tokens
   SET used_at = now(), replaced_by = '00000000-0000-0000-0001-0000000000f2'
 WHERE id = '00000000-0000-0000-0001-0000000000f1';
COMMIT;

INSERT INTO rls_results
  VALUES ('rotation marks the predecessor used', 'used',
          (SELECT CASE WHEN used_at IS NOT NULL AND replaced_by IS NOT NULL
                       THEN 'used' ELSE 'not-used' END
             FROM refresh_tokens WHERE id = '00000000-0000-0000-0001-0000000000f1'));

-- The replay: a client presenting \xb1 again. A used row is found, which is
-- proof of theft, because a correct client discards a token on exchange.
INSERT INTO rls_results
  VALUES ('replayed token is detectable as used', 'replay-detected',
          (SELECT CASE WHEN used_at IS NOT NULL THEN 'replay-detected' ELSE 'undetected' END
             FROM refresh_tokens WHERE token_hash = '\xb1'::bytea));

-- Response to detection: revoke the whole session, which cascades the family.
UPDATE sessions SET revoked_at = now(), revoked_reason = 'refresh_reuse_detected'
 WHERE id = '00000000-0000-0000-0001-0000000000e1';

INSERT INTO rls_results
  VALUES ('reuse revokes the entire session', 'refresh_reuse_detected',
          (SELECT revoked_reason FROM sessions WHERE id = '00000000-0000-0000-0001-0000000000e1'));

INSERT INTO rls_results
  VALUES ('both family tokens still auditable after revocation', '2',
          (SELECT count(*)::text FROM refresh_tokens
            WHERE session_id = '00000000-0000-0000-0001-0000000000e1'));

-- ============================================================
-- 6. SECURITY DEFINER hygiene
-- ============================================================

INSERT INTO rls_results
  VALUES ('definer function has a pinned search_path', 'pinned',
          (SELECT CASE WHEN array_to_string(proconfig, ',') LIKE '%search_path%'
                       THEN 'pinned' ELSE 'UNPINNED — escalation risk' END
             FROM pg_proc WHERE proname = 'app_current_org_ids'));

INSERT INTO rls_results
  VALUES ('definer function is not executable by PUBLIC', 'restricted',
          (SELECT CASE WHEN has_function_privilege('public', 'app_current_org_ids()', 'EXECUTE')
                       THEN 'PUBLIC CAN EXECUTE' ELSE 'restricted' END));

-- ============================================================
-- Report
-- ============================================================

\echo ''
\echo '=== RLS and refresh-token verification ==='
SELECT label, expected, got FROM rls_results WHERE got IS DISTINCT FROM expected;
SELECT count(*) FILTER (WHERE got = expected)                AS passed,
       count(*) FILTER (WHERE got IS DISTINCT FROM expected) AS failed
  FROM rls_results;
