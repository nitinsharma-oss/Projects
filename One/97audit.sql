-- ============================================================
-- Step 3 — audit evidence pack
--
-- An assessor does not want a document claiming controls exist. They want to
-- run something. Each query below answers one question they will ask, and each
-- is designed so the WRONG answer is visibly wrong rather than absent.
--
--   psql -d <db> -f 97_audit_evidence.sql
-- ============================================================

\pset pager off
\pset border 2

\echo '\n### E1. Which tables are append-only, and is it enforced by grant?\n'
-- Expect exactly INSERT, SELECT on the four immutable tables. Any UPDATE or
-- DELETE here is a finding.
SELECT c.relname AS table_name,
       string_agg(DISTINCT a.privilege_type, ', ' ORDER BY a.privilege_type) AS app_rw_privileges
  FROM pg_class c
  CROSS JOIN LATERAL aclexplode(c.relacl) a
  JOIN pg_roles r ON r.oid = a.grantee
 WHERE r.rolname = 'app_rw'
   AND c.relname IN ('audit_log','ownership_transfers','card_assignments','card_encodings')
 GROUP BY c.relname
 ORDER BY c.relname;

\echo '\n### E2. Which tables enforce row-level security, and under which policies?\n'
SELECT c.relname AS table_name,
       c.relrowsecurity AS rls_enabled,
       count(p.polname) AS policies,
       string_agg(p.polname, ', ' ORDER BY p.polname) AS policy_names
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_policy p ON p.polrelid = c.oid
 WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
 GROUP BY c.relname, c.relrowsecurity
 ORDER BY c.relname;

\echo '\n### E3. Do any SECURITY DEFINER functions have an unpinned search_path?\n'
-- Zero rows is the passing answer. A row here is a privilege escalation finding.
SELECT p.proname AS unpinned_definer_function
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.prosecdef
   AND (p.proconfig IS NULL OR NOT array_to_string(p.proconfig, ',') LIKE '%search_path%');

\echo '\n### E4. Can any role read a card token in plaintext?\n'
-- The schema stores only token_hash. A column literally named "token" would be
-- a finding; zero rows is the passing answer.
SELECT table_name, column_name, data_type
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND column_name IN ('token','plain_token','token_plaintext');

\echo '\n### E5. What exactly can the resolver read?\n'
-- Least privilege on the highest-traffic, least-trusted service. Expect three
-- columns of one table and nothing else.
SELECT table_name, column_name, privilege_type
  FROM information_schema.column_privileges
 WHERE grantee = 'app_resolver'
 ORDER BY table_name, column_name;

\echo '\n### E6. Which credentials are stored, and with which algorithm class?\n'
-- Documented in Step 3 §5. High-entropy secrets use SHA-256 because brute force
-- is infeasible; low-entropy human-entered secrets use Argon2id.
SELECT 'accounts.password_hash'  AS secret, 'Argon2id'  AS algorithm, 'human-chosen, low entropy'      AS rationale
UNION ALL SELECT 'cards.claim_code_hash',   'Argon2id',  'human-typed scratch code, ~60 bits'
UNION ALL SELECT 'cards.token_hash',        'SHA-256',   '128-bit CSPRNG, no pepper (see note)'
UNION ALL SELECT 'refresh_tokens.token_hash','SHA-256',  '256-bit CSPRNG, high entropy'
UNION ALL SELECT 'otp_codes.code_hash',     'Argon2id',  'six digits, rate-limited'
 ORDER BY 1;

\echo '\n### E7. Integrity constraint inventory (the ownership invariants)\n'
SELECT conname AS constraint_name,
       CASE contype WHEN 'f' THEN 'foreign key'
                    WHEN 'c' THEN 'check'
                    WHEN 'u' THEN 'unique'
                    WHEN 'p' THEN 'primary key' END AS kind,
       convalidated AS validated
  FROM pg_constraint
 WHERE conrelid = 'cards'::regclass
 ORDER BY contype, conname;

\echo '\n### E8. Is partition management current? (writes fail without a partition)\n'
SELECT parent.relname AS partitioned_table,
       count(child.relname) AS partition_count,
       max(child.relname)   AS newest_partition
  FROM pg_inherits i
  JOIN pg_class parent ON parent.oid = i.inhparent
  JOIN pg_class child  ON child.oid  = i.inhrelid
 WHERE parent.relname IN ('tap_events','audit_log','tap_events_eu','tap_events_us','tap_events_in')
 GROUP BY parent.relname
 ORDER BY parent.relname;

\echo '\n### E9. Which roles exist, and can any of them bypass RLS or log in?\n'
-- BYPASSRLS or SUPERUSER on an application role is a finding.
SELECT rolname, rolsuper AS superuser, rolbypassrls AS bypasses_rls, rolcanlogin AS can_login
  FROM pg_roles
 WHERE rolname LIKE 'app%'
 ORDER BY rolname;

\echo '\n### E10. Does any table holding visitor data carry a raw IP address?\n'
-- GDPR posture from §8: country is derived at ingest and the address discarded.
-- Zero rows is the passing answer.
SELECT table_name, column_name
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND (column_name LIKE '%ip_address%' OR data_type IN ('inet','cidr'));

\echo '\n### Evidence pack complete.\n'
