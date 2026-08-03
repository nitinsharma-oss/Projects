# NFC Digital Identity Platform
## Step 3 — Security Model

**Version 1.0** · verified against PostgreSQL 16 · **69 of 69 assertions passing**

| Suite | Assertions | Result |
| --- | --- | --- |
| `99_constraint_tests.sql` — integrity invariants (Step 2) | 49 | pass |
| `98_auth_rls_tests.sql` — RLS, refresh rotation, role isolation | 20 | pass |
| `97_audit_evidence.sql` — 10 assessor queries | 10 | all return the passing answer |

Both suites are order-independent; each scopes assertions to its own fixtures. `sql/run.sh`
applies everything and prints the evidence pack.

---

## 1. Two corrections to earlier steps

### 1.1 Refresh token reuse detection was not implementable

Step 1 promised that a replayed refresh token invalidates the whole token family. Step 2's
`sessions` table stored only the **current** `refresh_token_hash` — which makes a replayed old
token indistinguishable from a random invalid one. The control was specified and not
constructible.

Migration `04_auth_hardening.sql` splits them: `sessions` is the device login, and
`refresh_tokens` holds one row per token ever issued, with `used_at` and `replaced_by`. A lookup
that hits a row with `used_at IS NOT NULL` is proof of theft, because a correct client discards a
refresh token the instant it exchanges it. A check constraint enforces that a used token must
name its successor, so the detection signal cannot be half-written.

### 1.2 Row-level security: deferred in Step 2, adopted here

**The argument is not that RLS stops a compromised application server.** It does not — the
application supplies the identity via `app.account_id`, so an attacker with code execution simply
sets it. Anyone claiming otherwise is overselling.

The argument is that tenant scoping becomes *one predicate the database enforces on every query*
instead of a `WHERE` clause every developer must remember on every query forever. It converts a
whole class of IDOR bug from "possible" to "impossible without also dropping a policy," and
policy changes are visible in `\d` and in review. That is worth having.

It **fails closed**: with no `app.account_id` set, predicates compare against NULL, which is
never true, so queries return zero rows rather than everything. Two assertions cover exactly this.

*Trade-off:* every authenticated query must run inside a transaction that has done `SET LOCAL
app.account_id`. Forgetting it yields an empty result, not a leak — the correct failure direction,
but it will cost a developer an afternoon the first time. This is also why `SET LOCAL` rather than
`SET`: it is compatible with PgBouncer transaction-mode pooling, which `SET` is not.

### 1.3 A footgun found while testing, worth writing down

The first version of the RLS suite scoped its counts through temp views. **A view reads its base
tables with the view owner's privileges unless `security_invoker = true`** — so views owned by
`postgres` bypassed RLS entirely and the assertions passed for the wrong reason. The suite now
queries base tables directly.

This is the standard way a team convinces itself RLS works when it does not. Two rules follow:
never test RLS as a superuser or table owner, and audit every view over an RLS-protected table for
`security_invoker`.

---

## 2. Attack surfaces

| Surface | Exposure | Authenticated | Highest-value asset reachable |
| --- | --- | --- | --- |
| NFC chip | Physical | No | Nothing — an opaque pointer |
| Resolver `/t/{token}` | Internet, unauthenticated | No | Card serving state |
| Profile renderer `/u/{slug}` | Internet, unauthenticated | No | Published profile content |
| Claim endpoint | Internet | Yes | Card ownership |
| Auth endpoints | Internet | Partially | Account credentials |
| Owner API | Internet | Yes | One tenant's data |
| Admin API | Restricted network | Yes + step-up | **Every tenant; ownership transfer** |
| Stripe webhook | Internet, signed | Signature | Subscription state |
| Encoding station | Physical, internal | Yes | **HSM; ability to mint valid cards** |
| Workers | Internal only | N/A | Analytics, reconciliation |

The two crown jewels are the Admin API and the encoding station. Everything else is either public
by design or scoped to one tenant.

---

## 3. Threat model

### 3.1 The chip

| Threat | Control | Residual |
| --- | --- | --- |
| Rewrite → phishing redirect | Permanent lock at encoding, verified by read-back, recorded as an immutable `card_encodings` row | None for locked cards |
| Cloning | NTAG424 DNA rotating CMAC (enterprise tier) | **Basic NTAG cards are clonable and clones are undetectable** — accepted, see §11 |
| Theft | The token is a pointer, not a credential. A thief gets a public page | Owner reports it; revocation is immediate |
| Fleet key extraction | Per-card diversified keys from an HSM master | One chip compromised yields one chip |

### 3.2 The resolver

The only unauthenticated write-adjacent path at internet scale.

| Threat | Control |
| --- | --- |
| Token enumeration | 128-bit CSPRNG; shape validation before any I/O |
| **Database amplification DoS** | Negative caching so absent tokens die in Redis; edge limiting on *miss ratio*, not request rate |
| Cache stampede on a viral card | Single-flight: one fetch per key |
| Revocation bypass via caching | 302 never 301, `Cache-Control: no-store`, short cache TTL with explicit invalidation |
| **Open redirect** | The redirect target is built from `serving_slug` alone. No `next`, `redirect`, or `url` parameter is read, ever. This gets a test |
| Data exfiltration via resolver compromise | `app_resolver` holds column-level `SELECT` on three columns of one table (evidence E5) |

### 3.3 The profile renderer — the highest-likelihood web vulnerability

**Stored XSS in profile content is the most probable serious finding in this product.** Bio,
display name and links are attacker-authorable and rendered to strangers on your domain.

| Threat | Control |
| --- | --- |
| Stored XSS | No user HTML anywhere. Bio is stored and rendered as plain text, escaped at output. Never a rich-text field without a vetted sanitiser |
| Malicious link schemes | `links` values must parse as absolute `https://` URLs. `javascript:`, `data:`, and `file:` rejected at write time |
| XSS pivoting into the dashboard | **Origin separation — see §4** |
| Draft or suspended profile disclosure | An RLS policy restricts `app_renderer` to `status = 'active'`; the renderer is not trusted to remember a filter (assertion: "renderer sees active profiles only") |
| Clickjacking | `frame-ancestors 'none'` |
| SVG avatar as a script vector | **SVG uploads rejected outright.** SVG is script-capable |

Content-Security-Policy for profile pages:

```
default-src 'none'; img-src https://media.<storage-domain>; style-src 'self' 'nonce-…';
script-src 'self' 'nonce-…'; font-src 'self'; connect-src 'none';
frame-ancestors 'none'; base-uri 'none'; form-action 'none'
```

`connect-src 'none'` is deliberate: a public profile page has no reason to make network calls, so
an injected script cannot exfiltrate even if everything else fails.

### 3.4 The claim endpoint

| Threat | Control |
| --- | --- |
| Claiming an unsold card | Scratch code required, stored as Argon2id |
| Brute-forcing a scratch code | Rate limit per token, per account, per IP; lockout after 10 failures per token (`claim_locked_until`) |
| **Card-existence oracle** | Identical body, status code and timing for "unknown token" and "wrong code" |
| Stolen batch, claimed in bulk | Anomaly alert on many distinct tokens claimed from one IP or account |
| Replaying a used code | Single use, invalidated inside the activation transaction |

### 3.5 Auth and the Admin API

| Threat | Control |
| --- | --- |
| Credential stuffing | Argon2id, per-account and per-IP limits, exponential backoff |
| Account enumeration at signup or reset | Uniform response regardless of whether the address exists; the email carries the signal |
| Session theft | Server-side sessions, immediate revocation, `HttpOnly` `Secure` `SameSite=Lax` |
| Refresh token theft | Rotation with reuse detection (§1.1) |
| Privilege escalation | Platform and organisation role scopes never conflated; no ambient "is admin" boolean |
| Malicious ownership transfer | Admin approval + step-up auth + append-only record + audit row, one transaction |
| Admin impersonation abuse | "View as user" is time-boxed, requires step-up, and writes an audit row on entry and exit |
| SQL injection | Parameterised queries only; RLS as a second layer |

---

## 4. Origin separation (architectural requirement)

**Profile pages must not share a registrable domain with the dashboard.**

If profiles live at `app.example.com/u/alice` and the dashboard at `app.example.com/dashboard`,
one stored XSS in any profile reaches session cookies for every logged-in user who views it.
Subdomains are insufficient: cookies can be scoped to a parent domain, and subdomain takeover or
cookie-tossing crosses that boundary.

Recommended topology:

| Host | Serves | Cookies |
| --- | --- | --- |
| `tapd.link/t/{token}` | Resolver | None |
| `tapd.link/u/{slug}` | Public profiles (untrusted content) | None, ever |
| `app.example.com` | Dashboard, owner API | Session cookies |
| `admin.example.com` | Admin API | Session cookies, network-restricted |
| `media.tapd.link` | Uploaded media | None |

*Trade-off:* a split brand, more certificates, CORS configuration, and a shortener-style domain on
the physical card. Against: it makes the single most likely serious vulnerability in the product
survivable rather than catastrophic. The short domain is also genuinely better on a card.

A pleasant side effect: because profile pages set no cookies at all, they are trivially cacheable
at the CDN.

---

## 5. Cryptographic decisions

| Secret | Algorithm | Why |
| --- | --- | --- |
| `accounts.password_hash` | Argon2id | Human-chosen, low entropy — needs to be slow |
| `cards.claim_code_hash` | Argon2id | Human-typed scratch code, ~60 bits — needs to be slow |
| `otp_codes.code_hash` | Argon2id | Six digits; trivially crackable from a dump otherwise |
| `cards.token_hash` | **SHA-256, no pepper** | 128-bit CSPRNG — see below |
| `refresh_tokens.token_hash` | SHA-256 | 256-bit CSPRNG, high entropy |

### Why no pepper on the card token, deliberately

A pepper defends against offline brute force of low-entropy inputs. A card token is 128 bits of
uniform randomness: there is no dictionary, no rainbow table, and no feasible search. A pepper
would buy nothing.

It would also be **unrotatable**. The platform never retains plaintext tokens — that is the point
of hashing them — so it could never rehash them under a new pepper. Adding one would create a
permanent, unrotatable secret in exchange for no security benefit. Plain SHA-256 is the correct
choice and this reasoning belongs in the audit response, because "why no pepper" will be asked.

A slow KDF is likewise wrong here: the resolver hashes on every tap, and slowing that down to
defend against an attack that entropy already prevents would be a self-inflicted DoS.

---

## 6. Rate limits and abuse budgets

Limits are per-window, enforced at the edge where possible and in the application where identity
is required.

| Endpoint | Limit | Keyed on | On breach |
| --- | --- | --- | --- |
| `GET /t/{token}` | 600/min | IP | Throttle |
| `GET /t/{token}` | miss ratio > 20% over 100 reqs | IP / ASN | Throttle — this catches enumeration, which raw request rate does not |
| `GET /u/{slug}` | 300/min | IP | Throttle; CDN absorbs the rest |
| `POST /cards/claim` | 5/hr, 10/hr, 20/hr | token, account, IP | Lockout at 10 failures per token |
| `POST /auth/login` | 10/hr, 30/hr | account, IP | Exponential backoff |
| `POST /auth/otp/verify` | 5 attempts | code | Invalidate the code |
| `POST /auth/signup` | 5/hr | IP | Challenge |
| `POST /auth/password-reset` | 3/hr | email, IP | Uniform response regardless |
| `PUT /me/profile` | 60/hr | account | Throttle |
| `POST /me/profile/media` | 20/day | account | Throttle |
| `POST /admin/**` | 100/day | admin account | Alert, not just throttle |
| Stripe webhook | none | — | Signature verification + `stripe_events` idempotency |

Limiting the resolver on **miss ratio rather than request rate** is the important line in this
table. A legitimate client's taps are nearly all cache hits; an enumerator's are all misses. Rate
alone cannot tell them apart, and the enumerator is the one that reaches the database.

---

## 7. Uploads and media

Two upload paths: avatar image and resume PDF.

- **Size caps** enforced before the body is buffered.
- **Magic-byte sniffing**, not `Content-Type`, and not the file extension.
- **Images are re-encoded server-side**, which normalises the format and strips EXIF. Profile
  photos routinely carry GPS coordinates; publishing them is a privacy incident.
- **SVG rejected.** It is script-capable and cannot be safely served from a media domain.
- **PDFs served with `Content-Disposition: attachment`**, `Content-Type: application/pdf`, and
  `X-Content-Type-Options: nosniff`. A PDF rendered inline is a script execution context.
- **Served from `media.tapd.link`**, never the app domain, via short-lived signed URLs.
- **No server-side fetching of user-supplied URLs** anywhere — that is the SSRF door, and this
  product has no reason to open it.

---

## 8. Key and secret management

| Secret | Storage | Rotation |
| --- | --- | --- |
| NTAG424 master key | HSM/KMS, non-extractable | **Versioned, not rotated** — see below |
| Per-card DNA key | Derived; never stored | N/A |
| Session signing / cookie secret | KMS | Rotatable with an overlap window |
| Stripe webhook secret | KMS | Dual-secret window during rotation |
| Database credentials | KMS, short-lived where the platform allows | Automated |
| Argon2 parameters | Config, versioned per hash | Rehash on next successful login |

### The uncomfortable truth about the DNA master key

**Keys on permanently locked cards cannot be changed.** Locking is what defeats phishing-by-rewrite
(§3.1), and it is irreversible — so there is no mechanism to re-key a card in the field.

Consequences, stated plainly because an assessor will ask and the answer must not be improvised:

- Master key compromise means **every DNA card ever issued is compromised**, permanently.
- The only remediation is physically reissuing cards.
- Therefore: key generation happens in an HSM ceremony under split knowledge and dual control; the
  key is non-extractable; and `dna_key_ref` carries a **version**, so new production moves to a
  new key version while existing cards keep theirs.
- Per-card diversification bounds the *other* direction: extracting a key from one chip in a lab
  yields that one chip and nothing else.

This is a genuine single point of catastrophic failure with no software mitigation. It is
acceptable only because the HSM makes extraction hard and the ceremony makes insider extraction
require collusion.

---

## 9. Encoding station

The station holds HSM access and can mint valid cards. It is the second crown jewel and the one
most often left out of a threat model because it looks like manufacturing rather than software.

- Dedicated hardware, no general internet egress, allowlisted to the provisioning API only.
- Per-encoder credentials — `card_encodings.encoder_account_id` is `NOT NULL`, so every physical
  card traces to a named person and a named station.
- Dual control for batch creation.
- Lock verified by read-back before a card is marked shippable; `encodings_lock_verified` rejects
  a claimed lock whose verification failed.
- Every encoding is an append-only row that `app_rw` cannot modify (evidence E1).

---

## 10. OWASP Top 10 (2021) mapping

| Risk | Primary controls |
| --- | --- |
| A01 Broken access control | RLS on tenant tables, scoped roles, composite FK ownership invariants, admin step-up |
| A02 Cryptographic failures | §5; tokens hashed at rest; TLS everywhere; no raw IP stored |
| A03 Injection | Parameterised queries; no user HTML; strict `links` validation; CSP |
| A04 Insecure design | Threat model per surface; origin separation; append-only history |
| A05 Security misconfiguration | Least-privilege DB roles; evidence pack E1–E10 as a config regression test |
| A06 Vulnerable components | Dependency scanning in CI, SBOM, pinned lockfiles |
| A07 Auth failures | Argon2id, OTP, server-side sessions, rotation with reuse detection, rate limits |
| A08 Integrity failures | Signed Stripe webhooks; idempotency keys; append-only grants |
| A09 Logging failures | `audit_log` in-transaction with the change; security events; drift alarms |
| A10 SSRF | No server-side fetching of user-supplied URLs, anywhere |

---

## 11. Residual risks accepted

Stated explicitly, because an assessor trusts a document that names what it does not solve.

1. **RLS does not defend against a compromised application server.** The app supplies the
   identity. RLS is defence against *bugs*, not against code execution.
2. **Basic NTAG cards are clonable and clones are undetectable.** A copied token resolves
   identically. Only NTAG424 DNA closes this, at roughly 5× the card cost. Consumer tier accepts
   it; the impact is that someone can make a card pointing at *your public page*, which is close
   to harmless.
3. **Analytics events are dropped when the buffer is full** — during incidents and deploys,
   exactly when volume is interesting. Deliberate: resolution is a guarantee, analytics are not.
4. **A stolen card resolves normally until reported.** It is a pointer to a public page, not a
   credential, so this is low-impact by design.
5. **DNA master key compromise is unrecoverable in software** (§8).
6. **`serving_state` is a denormalised cache and can drift.** Bounded by the reconciliation job
   and its drift alarm, not eliminated.

---

## 12. Incident playbooks

**Refresh token reuse detected** — automated: revoke the session, cascade the family, write a
security audit row, notify the account holder, require re-authentication. No human in the loop.

**DNA master key suspected compromise** — freeze DNA provisioning; issue a new key version for new
cards; assess exposure from `card_encodings`; existing cards cannot be re-keyed, so the decision
is a commercial one about recall. Rehearse this before launch; do not improvise it.

**Admin account compromise** — revoke all sessions for the account; query `audit_log` filtered on
`actor_account_id` for the exposure window; every ownership transfer in that window is suspect and
reversible only by a new append-only transfer, never by editing history.

**Database disclosure** — no plaintext tokens, passwords or claim codes are exposed (E4, E6).
Rotate database credentials and session secrets. Card tokens are in the clear on physical cards
regardless, so the marginal loss is the mapping of token to identity, which is a privacy incident
rather than an access-control one.

**Stored XSS found in profile content** — origin separation (§4) means dashboard sessions are not
reachable. Purge the CDN, patch validation, audit `profiles.links` and `bio` for the same pattern
across the fleet.

---

## 13. Open items

1. **Confirm origin separation** (§4). It affects the domain printed on every physical card, so it
   must be decided before the first production batch is encoded. This is the most
   schedule-sensitive item in the document.
2. **HSM vendor and key ceremony procedure** (§8). Needs a named owner and a rehearsal.
3. **`tap_events` retention window** — still open from Step 2. Legal and product decision.
4. **Penetration test scope** — recommend the resolver, claim flow, and profile renderer as
   priority one; admin API as priority two with credentials supplied.

---

## Step 4 — Prisma Schema will contain

The Prisma datamodel for the verified DDL, with `prisma migrate diff` run against the live
database to **prove zero drift**. Prisma cannot express partial unique indexes, generated columns
in composite foreign keys, table partitioning, RLS policies, or column-level grants — all of which
carry security weight here — so those stay in raw SQL migrations and the document will state
exactly which constructs live outside Prisma's model and why.
