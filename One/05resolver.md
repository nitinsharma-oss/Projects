# NFC Digital Identity Platform
## Step 5 — Resolver Service and Shared Foundations

**Version 1.0** · architecture frozen · implemented to Steps 1–4

| Suite | Assertions | Result |
| --- | --- | --- |
| `test/resolver.test.ts` — HTTP behaviour, decisions, events, role privilege | 22 | pass |
| `test/rls.test.ts` — ADR-0002, tenant isolation, fail-closed | 10 | pass |
| `test/cache.test.ts` — negative caching, single-flight, expiry | 7 | pass |
| `test/validation.test.ts` — link/XSS surface, DB agreement | 15 | pass |
| `test/config.test.ts` — origin separation at boot | 4 | pass |
| **TypeScript** `tsc --noEmit` | — | clean |
| Carried forward: SQL constraint + RLS suites | 69 | pass |

**Total: 58 application assertions + 69 database assertions, all passing.**

```bash
npm test                  # everything (needs DATABASE_URL)
npm run test:unit         # no database required
npm run start:resolver
```

---

## 1. Architecture decisions recorded

Two contradictions were found between the frozen documents and implementation
reality. Both are recorded in `docs/adr/` before any code deviated.

### ADR-0001 — the resolver uses `pg`, not Prisma Client

Step 4 makes Prisma the typed query builder. Step 3 grants `app_resolver`
**column-level `SELECT` on three columns of one table**. A Prisma Client generated
from the 18-model datamodel would advertise an API surface that role cannot
execute — nearly every call failing at runtime with a permission error, which
invites a future developer to widen the grant instead of narrowing the query.

The resolver now issues exactly one prepared statement whose column list matches
its grant. It **cannot express** a query the role would be refused. Three tests
confirm `app_resolver` is denied `profiles.bio`, `accounts.email`, and
`cards.claim_code_hash`.

### ADR-0002 — one transaction helper, or RLS silently returns nothing

Step 3 §1.2 requires `SET LOCAL app.account_id` but not a mechanism. `SET LOCAL`
is transaction-scoped, so a query outside a transaction gets no setting and RLS
returns **zero rows rather than an error**. Session-scoped `SET` would survive but
is prohibited outright: under the PgBouncer transaction pooling that Step 1 §11
mandates, the next transaction on that connection could inherit another user's
identity — a cross-tenant leak.

`withAccount(pool, accountId, fn)` is now the only exported way to get a
tenant-scoped handle. The unscoped path is named `unsafeWithoutAccount` so it is
conspicuous in review and greppable in CI. A test proves a query outside the
helper sees nothing, and another proves the identity does not survive into the
next transaction on the same connection.

---

## 2. What the resolver does, and what it refuses to do

The decision table from Step 1 §5.1 is implemented exactly:

| `serving_state` | Response |
| --- | --- |
| `active` | `302` → `/u/{slug}`, `Cache-Control: no-store` |
| `lapsed` / `suspended` | `302` → paused page |
| `revoked` | `410 Gone` — terminal |
| `unclaimed` | `302` → claim flow |
| absent or malformed | `404`, **byte-identical responses** |

Forbidden on this path per Step 1 §5.6 and enforced by construction: no
subscription check, no Stripe call, no join, no page rendering, no synchronous
write. The subscription question is already answered by the precomputed
`serving_state` column.

### The two rules with tests attached

**302, never 301.** A 301 is cached by browsers indefinitely and cannot be
recalled, which would make revocation permanently impossible on every device that
had seen the card — with no remedy short of physically retrieving it. Tested
explicitly, including a `notEqual(301)`.

**No open redirect.** `Location` is built only from `serving_slug` and the
configured base URL. No query parameter is read for any purpose. Tested against
`?next=`, `?redirect=`, `?url=`, `?Location=`, and a path-traversal token. The
slug is re-validated at render time so a corrupted row cannot emit a
scheme-relative `//evil.test`, which browsers treat as absolute.

### Amplification DoS, the resolver's real threat

Organic peak is ~800 req/s (Step 1 §1). An attacker generating random tokens
produces a **100% cache-miss rate**, converting modest bandwidth into database
saturation on the one service whose failure stops every card in the field.

Three layered controls, each tested:

1. Shape validation before any I/O — a wrong length costs one regex, not a Redis
   round trip and a database read.
2. Negative caching — *50 requests for an unknown token cause 1 database read*,
   and a flood of 1000 distinct unknown tokens stays bounded by `maxEntries`.
3. Single-flight — *1000 concurrent requests for one uncached token cause exactly
   1 database read*, with all 1000 callers receiving the answer.

Negative entries expire sooner than positive ones, so a missed purge at
provisioning time makes a real card 404 briefly rather than for a full TTL. A
failed load releases the in-flight slot, or a transient database error would
render a token permanently unresolvable.

### Events cannot break resolution

Step 1 §5.5: emission touches only memory. A bounded buffer, batched flush, and
**a full buffer drops events**. A failing sink does *not* requeue — that would
grow the buffer until the process died, converting an analytics outage into a
resolver outage.

Malformed tokens emit nothing; unknown tokens **do** emit, because the miss-ratio
signal in Step 3 §6 is what detects enumeration. Device *class* only, never a
fingerprint, and referrers reduced to a host so a query string carrying an email
address is discarded at the edge.

---

## 3. Validation: the XSS surface

Step 3 §3.3 identifies stored XSS in profile content as the most probable serious
finding. Links are restricted to **absolute `https`** by allowlist, not denylist —
the set of dangerous schemes is open-ended (`javascript:`, `data:`, `blob:`,
`view-source:`, vendor handlers) while the set needed is exactly one. Nine attack
strings are tested, plus embedded credentials (`https://paypal.com:pass@evil.test`
is a phishing primitive) and hostnames without a dot, which would be internal
hosts.

Free text is **stored verbatim and escaped at render**, not sanitised. Silently
stripping tags would hide hostile input from review while giving false confidence;
a test asserts `<script>` survives storage unchanged.

Slug rules are duplicated between the application and the database CHECK, so a
drift test runs twelve candidates through both and asserts they agree. Without it,
a divergence turns a 400 into a 500.

---

## 4. Origin separation fails the boot, not a log line

Step 3 §4 is the most schedule-sensitive decision in the project — it determines
the domain printed on every physical card. `assertOriginSeparation` refuses to
start the resolver if `TAP_BASE_URL` and `APP_BASE_URL` share a registrable
domain, with an explicit `ALLOW_SHARED_ORIGIN=1` escape for multi-part TLD false
positives. Comparing the last two labels is a deliberate approximation: it catches
the mistake that matters without bundling a public-suffix list, and the error
message says so.

---

## 5. Deliberately not in this step

- **Owner and admin REST routes.** They depend on Prisma Client, which cannot be
  generated in the build environment (Step 4 §5). Writing them unverified would
  contradict this project's standard, so they wait until `prisma generate` runs.
- **Idempotency middleware.** The `idempotency_keys` table exists; the middleware
  belongs with the routes that need it.
- **Rate limiting.** The budgets are specified in Step 3 §6. The implementation
  belongs at the edge and in the app layer together, and testing it meaningfully
  needs the route surface.
- **Redis.** The cache interface is Redis-shaped and in-process for now; swapping
  it does not touch the service.

---

## 6. Open items unchanged from earlier steps

1. **Origin separation** — now enforced in code, still unconfirmed as a product
   decision. Gates the first card batch.
2. **Data residency** — `data_region` remains `eu / us / in`.
3. **`tap_events` retention window** — legal and product.
4. **`prisma migrate diff` in an unrestricted environment** (Step 4 §5).
