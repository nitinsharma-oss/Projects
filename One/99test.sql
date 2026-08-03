-- ============================================================
-- Step 2 — constraint verification
--
-- Every invariant claimed in the architecture is asserted here against a real
-- Postgres. A design document that says "the database enforces this" is a
-- promise; this file is the evidence.
-- ============================================================

\set ON_ERROR_STOP on
SET client_min_messages TO WARNING;

CREATE TEMP TABLE results (label text, expectation text, outcome text);
-- The append-only tests run AS app_rw, so that role must be able to record its
-- own results. The helpers are deliberately NOT security definer: the statement
-- under test has to execute with the restricted role's real privileges.
GRANT ALL ON results TO app_rw;

-- Asserts a statement is REJECTED. Records a failure if it succeeds.
CREATE OR REPLACE FUNCTION expect_reject(label text, stmt text) RETURNS void AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
        INSERT INTO results VALUES (label, 'reject', 'FAIL — was accepted');
    EXCEPTION WHEN others THEN
        INSERT INTO results VALUES (label, 'reject', 'ok');
    END;
END $$ LANGUAGE plpgsql;

-- Asserts a statement is ACCEPTED.
CREATE OR REPLACE FUNCTION expect_accept(label text, stmt text) RETURNS void AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
        INSERT INTO results VALUES (label, 'accept', 'ok');
    EXCEPTION WHEN others THEN
        INSERT INTO results VALUES (label, 'accept', 'FAIL — ' || SQLERRM);
    END;
END $$ LANGUAGE plpgsql;

-- ============================================================
-- Fixtures: two people, two organisations
-- ============================================================

INSERT INTO organizations (id, name, billing_email, data_region) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'Acme Ltd',  'billing@acme.test', 'eu'),
  ('00000000-0000-0000-0000-0000000000a2', 'Rival Inc', 'billing@rival.test','us');

INSERT INTO accounts (id, email, full_name, data_region, status) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'vaibhav@example.test', 'Vaibhav', 'eu', 'active'),
  ('00000000-0000-0000-0000-0000000000b2', 'mallory@example.test', 'Mallory', 'eu', 'active'),
  ('00000000-0000-0000-0000-0000000000b3', 'encoder@acme.test',    'Encoder', 'eu', 'active');

-- Vaibhav is an Acme employee. Mallory is not.
INSERT INTO org_memberships (org_id, account_id, role, status, joined_at) VALUES
  ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1','employee','active', now());

-- Personal profile (Vaibhav's), Mallory's, an Acme work profile, a Rival work profile.
-- NOTE: profiles.current_slug -> slugs.slug is DEFERRABLE INITIALLY DEFERRED, so a
-- profile and its first slug MUST be created inside one transaction. This is a real
-- constraint on the write path, not a test artifact — the repository layer has to
-- honour it.

BEGIN;
INSERT INTO profiles (id, owner_account_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000b1','vaibhav','Vaibhav','active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('vaibhav','current','00000000-0000-0000-0000-0000000000c1');

INSERT INTO profiles (id, owner_account_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0000-0000000000c2','00000000-0000-0000-0000-0000000000b2','mallory','Mallory','active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('mallory','current','00000000-0000-0000-0000-0000000000c2');

INSERT INTO profiles (id, owner_org_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0000-0000000000c3','00000000-0000-0000-0000-0000000000a1','acme-vaibhav','Vaibhav at Acme','active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('acme-vaibhav','current','00000000-0000-0000-0000-0000000000c3');

INSERT INTO profiles (id, owner_org_id, current_slug, display_name, status) VALUES
  ('00000000-0000-0000-0000-0000000000c4','00000000-0000-0000-0000-0000000000a2','rival-desk','Rival Desk','active');
INSERT INTO slugs (slug, kind, profile_id) VALUES ('rival-desk','current','00000000-0000-0000-0000-0000000000c4');
COMMIT;

-- ============================================================
-- 1. Ownership invariants (MATCH SIMPLE composite foreign keys)
-- ============================================================

SELECT expect_accept('personal card -> own profile', $$
  INSERT INTO cards (id, token_hash, token_prefix, chip, owner_account_id,
                     holder_account_id, profile_id, serving_slug, serving_state,
                     status, locked_at)
  VALUES ('00000000-0000-0000-0000-0000000000d1', '\x01'::bytea, 'aaaaaa', 'ntag213',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c1', 'vaibhav', 'active', 'active', now())
$$);

SELECT expect_reject('personal card -> someone else''s profile', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_account_id,
                     holder_account_id, profile_id, serving_slug, status, locked_at)
  VALUES ('\x02'::bytea, 'bbbbbb', 'ntag213',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c2', 'mallory', 'active', now())
$$);

SELECT expect_accept('org card -> org profile, holder is member', $$
  INSERT INTO cards (id, token_hash, token_prefix, chip, dna_key_ref, owner_org_id,
                     holder_account_id, profile_id, serving_slug, serving_state,
                     status, locked_at)
  VALUES ('00000000-0000-0000-0000-0000000000d2', '\x03'::bytea, 'cccccc', 'ntag424_dna',
          'kms://nfc-dna/master/v1#card-d2',
          '00000000-0000-0000-0000-0000000000a1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c3', 'acme-vaibhav', 'active', 'active', now())
$$);

-- THE decision from §2.6, enforced in the database rather than in a code review.
SELECT expect_reject('org card -> personal profile', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_org_id,
                     holder_account_id, profile_id, serving_slug, status, locked_at)
  VALUES ('\x04'::bytea, 'dddddd', 'ntag213',
          '00000000-0000-0000-0000-0000000000a1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c1', 'vaibhav', 'active', now())
$$);

SELECT expect_reject('org card -> another org''s profile', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_org_id,
                     holder_account_id, profile_id, serving_slug, status, locked_at)
  VALUES ('\x05'::bytea, 'eeeeee', 'ntag213',
          '00000000-0000-0000-0000-0000000000a1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c4', 'rival-desk', 'active', now())
$$);

SELECT expect_reject('org card -> holder is not a member', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_org_id,
                     holder_account_id, profile_id, serving_slug, status, locked_at)
  VALUES ('\x06'::bytea, 'ffffff', 'ntag213',
          '00000000-0000-0000-0000-0000000000a1',
          '00000000-0000-0000-0000-0000000000b2',
          '00000000-0000-0000-0000-0000000000c3', 'acme-vaibhav', 'active', now())
$$);

SELECT expect_reject('card with two owners', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_org_id, owner_account_id,
                     holder_account_id, profile_id, status)
  VALUES ('\x07'::bytea, 'gggggg', 'ntag213',
          '00000000-0000-0000-0000-0000000000a1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c3', 'provisioned')
$$);

-- ============================================================
-- 2. Card state integrity
-- ============================================================

SELECT expect_reject('active card that was never locked', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_account_id,
                     holder_account_id, profile_id, serving_slug, status)
  VALUES ('\x08'::bytea, 'hhhhhh', 'ntag213',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c1', 'vaibhav', 'active')
$$);

SELECT expect_reject('active card with no profile bound', $$
  INSERT INTO cards (token_hash, token_prefix, chip, owner_account_id,
                     holder_account_id, status, locked_at)
  VALUES ('\x09'::bytea, 'iiiiii', 'ntag213',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b1', 'active', now())
$$);

SELECT expect_reject('revoked card with no reason', $$
  INSERT INTO cards (token_hash, token_prefix, chip, status, serving_state, revoked_at)
  VALUES ('\x0a'::bytea, 'jjjjjj', 'ntag213', 'revoked', 'revoked', now())
$$);

SELECT expect_reject('DNA chip with no key reference', $$
  INSERT INTO cards (token_hash, token_prefix, chip, status)
  VALUES ('\x0b'::bytea, 'kkkkkk', 'ntag424_dna', 'manufactured')
$$);

SELECT expect_reject('basic chip claiming a DNA key', $$
  INSERT INTO cards (token_hash, token_prefix, chip, status, dna_key_ref)
  VALUES ('\x0c'::bytea, 'llllll', 'ntag213', 'manufactured', 'kms://key/1')
$$);

SELECT expect_reject('duplicate token hash', $$
  INSERT INTO cards (token_hash, token_prefix, chip, status)
  VALUES ('\x01'::bytea, 'mmmmmm', 'ntag213', 'manufactured')
$$);

-- ============================================================
-- 3. Permanent identity — the slug namespace
-- ============================================================

SELECT expect_reject('reusing a slug for a different profile', $$
  INSERT INTO slugs (slug, kind, profile_id)
  VALUES ('vaibhav', 'current', '00000000-0000-0000-0000-0000000000c2')
$$);

SELECT expect_reject('claiming a reserved slug', $$
  INSERT INTO slugs (slug, kind, profile_id)
  VALUES ('admin', 'current', '00000000-0000-0000-0000-0000000000c2')
$$);

SELECT expect_reject('two current slugs for one profile', $$
  INSERT INTO slugs (slug, kind, profile_id)
  VALUES ('vaibhav-two', 'current', '00000000-0000-0000-0000-0000000000c1')
$$);

SELECT expect_reject('slug with invalid characters', $$
  INSERT INTO slugs (slug, kind, profile_id)
  VALUES ('Bad_Slug!', 'current', '00000000-0000-0000-0000-0000000000c2')
$$);

SELECT expect_reject('retired slug with no retirement timestamp', $$
  INSERT INTO slugs (slug, kind, profile_id)
  VALUES ('old-handle', 'retired', '00000000-0000-0000-0000-0000000000c1')
$$);

-- A rename keeps the old slug alive forever, pointing at the same profile.
SELECT expect_accept('rename retires the old slug and keeps it', $$
  UPDATE slugs SET kind = 'retired', retired_at = now() WHERE slug = 'vaibhav';
  INSERT INTO slugs (slug, kind, profile_id)
    VALUES ('vaibhav-k', 'current', '00000000-0000-0000-0000-0000000000c1');
  UPDATE profiles SET current_slug = 'vaibhav-k'
    WHERE id = '00000000-0000-0000-0000-0000000000c1';
  UPDATE cards SET serving_slug = 'vaibhav-k'
    WHERE profile_id = '00000000-0000-0000-0000-0000000000c1'
$$);

SELECT expect_reject('a third party grabbing the retired slug', $$
  INSERT INTO slugs (slug, kind, profile_id)
  VALUES ('vaibhav', 'current', '00000000-0000-0000-0000-0000000000c2')
$$);

-- ============================================================
-- 4. Encoding and locking
-- ============================================================

SELECT expect_reject('locked chip whose verify read failed', $$
  INSERT INTO card_encodings (card_id, encoder_account_id, station_id, chip, locked, verify_read_ok)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b3', 'station-01', 'ntag213', true, false)
$$);

SELECT expect_accept('locked chip with a successful verify read', $$
  INSERT INTO card_encodings (card_id, encoder_account_id, station_id, chip, locked, verify_read_ok)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b3', 'station-01', 'ntag213', true, true)
$$);

-- ============================================================
-- 5. Transfers
-- ============================================================

SELECT expect_accept('activation transfer has no origin', $$
  INSERT INTO ownership_transfers (card_id, to_account_id, reason)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b1', 'activation')
$$);

SELECT expect_reject('activation transfer with an origin', $$
  INSERT INTO ownership_transfers (card_id, from_account_id, to_account_id, reason)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b2',
          '00000000-0000-0000-0000-0000000000b1', 'activation')
$$);

SELECT expect_reject('sale transfer with no origin', $$
  INSERT INTO ownership_transfers (card_id, to_account_id, reason, approved_by)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b2', 'sale',
          '00000000-0000-0000-0000-0000000000b3')
$$);

SELECT expect_reject('transfer to two destinations at once', $$
  INSERT INTO ownership_transfers (card_id, from_account_id, to_account_id, to_org_id, reason, approved_by)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b2',
          '00000000-0000-0000-0000-0000000000a1', 'sale',
          '00000000-0000-0000-0000-0000000000b3')
$$);

SELECT expect_reject('non-activation transfer with no approver', $$
  INSERT INTO ownership_transfers (card_id, from_account_id, to_account_id, reason)
  VALUES ('00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000b2', 'sale')
$$);

-- ============================================================
-- 6. Subscriptions
-- ============================================================

SELECT expect_accept('personal subscription, one seat', $$
  INSERT INTO subscriptions (owner_account_id, plan, status, seats)
  VALUES ('00000000-0000-0000-0000-0000000000b1', 'pro', 'active', 1)
$$);

SELECT expect_reject('personal subscription with multiple seats', $$
  INSERT INTO subscriptions (owner_account_id, plan, status, seats)
  VALUES ('00000000-0000-0000-0000-0000000000b2', 'pro', 'active', 5)
$$);

SELECT expect_reject('second live subscription for one account', $$
  INSERT INTO subscriptions (owner_account_id, plan, status, seats)
  VALUES ('00000000-0000-0000-0000-0000000000b1', 'pro', 'active', 1)
$$);

SELECT expect_reject('subscription owned by both an account and an org', $$
  INSERT INTO subscriptions (owner_account_id, owner_org_id, plan, status)
  VALUES ('00000000-0000-0000-0000-0000000000b2',
          '00000000-0000-0000-0000-0000000000a1', 'team', 'active')
$$);

SELECT expect_accept('org subscription with many seats', $$
  INSERT INTO subscriptions (owner_org_id, plan, status, seats)
  VALUES ('00000000-0000-0000-0000-0000000000a1', 'team', 'active', 50)
$$);

-- ============================================================
-- 7. Erasure vs immutable audit (§10)
-- ============================================================

SELECT expect_accept('audit row referencing an actor by opaque id', $$
  INSERT INTO audit_log (actor_scope, actor_account_id, action, subject_type, subject_id)
  VALUES ('account', '00000000-0000-0000-0000-0000000000b2', 'profile.update',
          'profile', '00000000-0000-0000-0000-0000000000c2')
$$);

SELECT expect_reject('a non-system action with no actor', $$
  INSERT INTO audit_log (actor_scope, action, subject_type)
  VALUES ('account', 'profile.update', 'profile')
$$);

SELECT expect_accept('system action with no actor', $$
  INSERT INTO audit_log (actor_scope, action, subject_type)
  VALUES ('system', 'serving_state.reconcile', 'card')
$$);

SELECT expect_reject('tombstoning while personal data remains', $$
  UPDATE accounts SET tombstoned_at = now(), status = 'tombstoned'
  WHERE id = '00000000-0000-0000-0000-0000000000b2'
$$);

SELECT expect_accept('tombstoning that actually erases the person', $$
  UPDATE accounts
     SET tombstoned_at = now(), status = 'tombstoned',
         email = NULL, password_hash = NULL, full_name = NULL
   WHERE id = '00000000-0000-0000-0000-0000000000b2'
$$);

-- The audit trail survives the erasure it describes.
SELECT expect_accept('audit row survives actor erasure', $$
  DO $inner$
  BEGIN
    IF NOT EXISTS (
      SELECT 1 FROM audit_log
       WHERE actor_account_id = '00000000-0000-0000-0000-0000000000b2'
    ) THEN RAISE EXCEPTION 'audit row vanished with the account';
    END IF;
  END $inner$
$$);

SELECT expect_accept('tombstoning frees the email address for reuse', $$
  INSERT INTO accounts (email, full_name, data_region, status)
  VALUES ('mallory@example.test', 'Someone Else', 'eu', 'active')
$$);

-- ============================================================
-- 8. Analytics partition routing
-- ============================================================

SELECT expect_accept('tap event routes to its region and month', $$
  INSERT INTO tap_events (occurred_at, region, card_id, profile_id, channel, country, device_class)
  VALUES ('2026-08-15 10:00+00', 'eu', '00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000000c1', 'nfc', 'DE', 'android-phone')
$$);

SELECT expect_accept('a QR scan is the same event with a different channel', $$
  INSERT INTO tap_events (occurred_at, region, profile_id, channel, country)
  VALUES ('2026-09-02 11:00+00', 'in', '00000000-0000-0000-0000-0000000000c1', 'qr', 'IN')
$$);

SELECT expect_reject('event in a region with no partition', $$
  INSERT INTO tap_events (occurred_at, region, profile_id, channel)
  VALUES ('2026-08-15 10:00+00', 'us', '00000000-0000-0000-0000-0000000000c1', 'nfc');
  INSERT INTO tap_events (occurred_at, region, profile_id, channel)
  VALUES ('2030-01-01 10:00+00', 'us', '00000000-0000-0000-0000-0000000000c1', 'nfc')
$$);

-- ============================================================
-- 9. Append-only enforced by GRANT, not by convention (§10)
-- ============================================================

SET ROLE app_rw;

SELECT expect_reject('app role rewriting ownership history', $$
  UPDATE ownership_transfers SET reason = 'gift'
$$);

SELECT expect_reject('app role deleting ownership history', $$
  DELETE FROM ownership_transfers
$$);

SELECT expect_reject('app role editing the audit log', $$
  UPDATE audit_log SET action = 'nothing.happened'
$$);

SELECT expect_reject('app role deleting audit rows', $$
  DELETE FROM audit_log
$$);

SELECT expect_reject('app role rewriting an encoding record', $$
  UPDATE card_encodings SET locked = false
$$);

SELECT expect_reject('app role hard-deleting an account', $$
  DELETE FROM accounts
$$);

SELECT expect_reject('app role deleting a slug to free it', $$
  DELETE FROM slugs WHERE slug = 'vaibhav'
$$);

RESET ROLE;

-- ============================================================
-- Report
-- ============================================================

\echo ''
\echo '=== constraint verification ==='
SELECT label, expectation, outcome FROM results WHERE outcome <> 'ok';
SELECT count(*) FILTER (WHERE outcome = 'ok')  AS passed,
       count(*) FILTER (WHERE outcome <> 'ok') AS failed
  FROM results;
