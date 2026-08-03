# NFC Digital Identity Platform
## Step 4 — Prisma Data Layer

**Version 1.0** · Prisma 6.19 · PostgreSQL 16 · verified

| Check | Result |
| --- | --- |
| 4 SQL migrations apply to a fresh database | clean |
| `schema.prisma` drift vs live catalog | **zero** |
| Structural datamodel validation (18 models, 15 enums, 18 named relations) | pass |
| `seed.ts` model accessors and data keys | pass |
| Constraint suite against the migrated database | 49 / 49 |
| RLS + refresh-token suite against the migrated database | 20 / 20 |
| Negative controls — do the checkers actually fail? | 4 / 4 fired |

```
npm ci
npm run db:migrate        # prisma migrate deploy — applies the SQL verbatim
npm run prisma:generate   # typed client
npm run db:seed
npm run check             # drift + seed verification
```

---

## 1. Prisma's role, and the boundary

Prisma is a **typed query builder here, never a schema manager.** The SQL migrations are the
source of truth. The datamodel is *generated from the database*, so it cannot drift.

Five constructs the security model depends on cannot be expressed in a Prisma datamodel:

| Construct | Where | Why it matters |
| --- | --- | --- |
| Partial unique indexes | `accounts.email` live-only; `slugs` one-current-per-profile | Tombstoning frees an email; permanent identity |
| Generated column in a composite FK | `cards.personal_holder_id` | Makes the ownership invariants declarative (Step 2 §2) |
| Table partitioning | `tap_events` by region→month, `audit_log` by month | Retention by partition drop; residency |
| RLS policies | 16 policies over 6 tables | Tenant isolation, fail-closed |
| Column-level grants | `app_resolver` reads 3 columns of `cards` | Bounds a resolver compromise |

`prisma migrate dev` and `prisma db push` both reconcile the database *to* the datamodel — so
either would **silently drop all five**. A comment asking people not to do that is not a control,
so `tools/prisma-guard.mjs` refuses those commands and every npm script routes through it:

```
$ npm run prisma -- migrate dev --name whatever
Refusing to run: prisma migrate dev --name whatever
Reason: it authors its own migration SQL from the datamodel.
```

`migrate deploy`, `migrate status` and `generate` pass through untouched.

---

## 2. The datamodel is generated, not hand-written

`tools/generate-prisma-schema.mjs` reads the live catalog — enums, tables, columns, primary keys,
unique constraints, foreign keys, delete rules — and emits `prisma/schema.prisma`. Hand-writing 18
models and *hoping* they match the DDL is precisely the drift this project cannot afford.

`tools/check-schema.mjs` then regenerates into memory and compares byte-for-byte with the committed
file. Any difference means a hand edit or an unapplied migration, and CI fails with the first
differing line printed.

It also validates the invariants Prisma itself enforces, since `prisma validate` is unavailable
here (§5): every relation has exactly two sides, named relations pair up, referenced fields exist
and are uniquely constrained, no duplicate field names, every type resolves.

### What the generator deliberately excludes

- **`tap_events` and `audit_log`** plus their 10 partition children. Introspection would emit 12
  models for 2 logical tables. These are reached through raw SQL in the analytics layer.
- **`cards.personal_holder_id`** — a stored generated column, unwritable by definition.
- **`cards_personal_profile_belongs_to_holder`** — the composite FK that uses that column. The
  generator detects this automatically and reports it as an SQL-only foreign key rather than
  silently dropping it.
- **Indexes.** Partial indexes cannot be represented, and emitting only the representable ones
  would misleadingly imply the set is complete.

---

## 3. Four bugs the tooling caught

Worth recording, because each would have surfaced as a confusing runtime error much later.

**`card_batches` became model `CardBatche`.** Naïve `-s` stripping. Fixed with proper handling of
`-ches`/`-shes`/`-ses`/`-xes`.

**`approvedBy` collided with itself.** `ownership_transfers.approved_by` yields scalar field
`approvedBy`; the relation derived from the same column wanted that name too. Prisma rejects
duplicate field names. Relation fields now claim a name only if it is free, else they append the
target model.

**`profiles ↔ slugs` would have been ambiguous.** They reference each other — `profiles.current_slug
→ slugs.slug` and `slugs.profile_id → profiles.id`. Prisma requires an explicit relation name when
two models are related more than once **in either direction**, and my pair counting was ordered, so
both sides came out unnamed. The key is now unordered, and self-relations are always named.

**The seed set `orgMembershipsViaAccountId` on `Organization`.** That field exists — on `Account`,
which has two FKs to `org_memberships` and therefore needs the disambiguating suffix. On
`Organization` there is one FK, so the field is plain `orgMemberships`. A field name valid on one
model and invalid on another is the single most likely seed bug, and `tools/check-seed.mjs` walks
the TypeScript AST checking each `data:` key against *the model that call targets*.

---

## 4. Negative controls

A checker that never fails is decoration. Each was proven to fire:

| Injected fault | Detected |
| --- | --- |
| Misspelled key inside a Prisma `data:` object | `"tokenPrefx" is not a field on model Card` |
| Field valid on another model, wrong here | `"billingEmail" is not a field on model CardEncoding` |
| Non-existent model accessor | `"cardBatches" is not a model` |
| Hand-edited `schema.prisma` | drift, with the differing line |
| Column added to the DB without a migration | drift, showing `experimentalFlag` |

**A known limitation, stated rather than hidden:** keys passed through helper functions are not
checked, because the checker resolves models from `prisma.<model>.<method>` call sites. A misspelling
in a helper's own parameter object is invisible to it. `tsc --noEmit` against a generated client
covers that; run it wherever `prisma generate` works.

---

## 5. Environment constraint

Prisma distributes its engines **only** from `binaries.prisma.sh`, which was unreachable in the
build environment used here (HTTP 403 from the egress proxy). So `prisma validate`, `prisma db pull`
and `prisma migrate diff` could not be run, and the typed client could not be generated.

Compensating verification, all of which *was* run:

- Migrations applied to a fresh PostgreSQL 16 database — clean.
- Datamodel generated from that database and compared byte-for-byte — zero drift.
- Datamodel structurally validated against Prisma's own relation rules.
- `seed.ts` checked key-by-key against the datamodel, with model context.
- Both SQL suites re-run against the migrated database — 69/69.
- `prisma.config.ts` validated by the real CLI: it now parses and proceeds as far as the engine
  fetch, which is how we know the config shape is right.

**In your environment, also run:**

```bash
npx prisma validate
npx prisma generate
npm run check:types

# independent parity proof using Prisma's own differ — expect no difference
npx prisma migrate diff \
  --from-migrations prisma/migrations \
  --to-schema-datamodel prisma/schema.prisma \
  --shadow-database-url "$SHADOW_DATABASE_URL" \
  --exit-code
```

That last command checks more than my drift tool does. If it reports a difference, it will be in
the SQL-only constructs listed in §1 — which is expected and documented — and not in table or
column shape.

---

## 6. Notes on the seed

- Prints plaintext tap URLs and claim codes **once**. They are unrecoverable afterwards; only
  hashes are stored.
- Token generation uses **rejection sampling**, not `% 62`. A modulus of a uniform byte biases the
  first eight characters of the alphabet. At 128 bits the practical risk is nil, but a biased token
  generator is a finding an assessor will raise, and correctness is free.
- Claim codes use a 31-character alphabet with `I`, `L`, `O`, `0`, `1` removed, so a code can be
  read off a card without transcription errors.
- Passwords and claim codes are Argon2id; tokens are SHA-256 (Step 3 §5).
- Profiles and their first slug are created **inside one transaction**, because
  `profiles.current_slug → slugs.slug` is `DEFERRABLE INITIALLY DEFERRED` (Step 2 §4.3).
- Alice is seeded with **two** profiles — a permanent personal one and an Acme-owned work one — so
  the §2.6 decision is visible in dev data rather than only in a document.
- Requires owner credentials (`DIRECT_DATABASE_URL`), not `app_rw`: RLS would filter everything,
  and `app_rw` cannot delete from append-only tables during reset. It refuses to run with
  `NODE_ENV=production`.

---

## 7. Open items

1. **Verify `prisma migrate diff` in an unrestricted environment** (§5). Until then, parity rests on
   my generator rather than Prisma's differ.
2. **Data residency** — the `data_region` enum is `eu / us / in`. Still unconfirmed since Step 2.
3. **`tap_events` retention window** — still open. Legal and product.
4. **Origin separation** (Step 3 §4) — unconfirmed, and it gates the first card batch.

---

## Step 5 — REST API will contain

Route surface for resolver, owner, and admin APIs; the request-scoped transaction helper that sets
`app.account_id` for RLS on every authenticated query; input validation schemas including the
`https`-only link allowlist; idempotency middleware; and the rate-limit implementations from
Step 3 §6.
