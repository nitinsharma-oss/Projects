# Start here

A short guide. Three things: how to set up, which folder does what, and where every file goes.

---

## 1. Set up (5 steps)

You need **Node 20 or newer** and **PostgreSQL 16**.

```bash
# 1. install the packages
npm install

# 2. make your settings file
cp .env.example .env

# 3. make an empty database
createdb nfc

# 4. tell the tools where it is
export DATABASE_URL="postgresql://YOUR_USER:YOUR_PASSWORD@localhost:5432/nfc"

# 5. build the tables
npm run db:migrate
```

Now check it worked:

```bash
node tools/db-tools.cjs check
```

You should see:

```
  ok    18 models, 15 enums, 18 named relations
  ok    no drift: schema.prisma matches the live database exactly
  ok    seed.ts model accessors and data keys resolve
all checks passed
```

Then run the tests and start the service:

```bash
npm run test:unit        # quick tests, no database needed
npm test                 # all tests
npm run start:resolver   # start the tap service
```

**If step 5 fails**, the usual cause is a wrong `DATABASE_URL`. Check the user, password and
database name.

---

## 2. What each folder is for

| Folder | In one line |
| --- | --- |
| `docs/` | The plan. Read it, don't run it. |
| `prisma/migrations/` | The real database tables, written as SQL. |
| `prisma/` | Other database files: the model file and the sample data. |
| `src/` | The code that actually runs and serves users. |
| `test/` | Tests for the code in `src/`. |
| `sql/` | Tests for the database itself. |
| `tools/` | Small scripts that check for mistakes. |

Simple version: **`src/` runs. `test/` and `sql/` check. `prisma/` builds the database.
`docs/` explains. `tools/` protects.**

---

## 3. Every file, and where it goes

The last column shows which "ALL-FILES part" the file came from, in case you still have those.

### Root folder (put these at the top level)

| File | What it does | Was in |
| --- | --- | --- |
| `package.json` | List of packages and commands | Part 3 |
| `tsconfig.json` | TypeScript settings | Part 3 |
| `prisma.config.ts` | Tells Prisma where things are | Part 3 |
| `.env.example` | Example settings. Copy it to `.env`. | Part 3 |
| `.gitignore` | Files Git should ignore | new |
| `README.md` | Main readme | new |
| `START-HERE.md` | This file | new |
| `CONTRIBUTING.md` | How to make changes safely | new |

### `docs/` — the plan

| File | What it does | Was in |
| --- | --- | --- |
| `docs/01-system-architecture.md` | How the whole system fits together | separate |
| `docs/02-database-design.md` | Every table and rule, explained | separate |
| `docs/03-security-model.md` | The security plan | separate |
| `docs/04-prisma-data-layer.md` | Why Prisma is only used to read, never to build | separate |
| `docs/05-resolver-service.md` | What the tap service does | separate |
| `docs/STRUCTURE.md` | Longer version of this file | new |
| `docs/adr/0001-resolver-uses-pg-not-prisma.md` | Why the tap service skips Prisma | Part 3 |
| `docs/adr/0002-rls-requires-transaction-scoped-access.md` | Why all queries use one helper | Part 3 |

### `prisma/` — builds the database

| File | What it does | Was in |
| --- | --- | --- |
| `prisma/migrations/20260801000000_core/migration.sql` | Users, companies, profiles, names | Part 4 |
| `prisma/migrations/20260801000001_cards/migration.sql` | Cards and who owns them | Part 4 |
| `prisma/migrations/20260801000002_billing_audit_analytics/migration.sql` | Payments, logs, tap counts | Part 4 |
| `prisma/migrations/20260801000003_auth_hardening/migration.sql` | Login tokens and access rules | Part 4 |
| `prisma/migrations/migration_lock.toml` | Says the database is PostgreSQL | Part 4 |
| `prisma/schema.prisma` | **Made by a tool.** Never edit by hand. | Part 4 |
| `prisma/seed.ts` | Puts sample data in, for testing | Part 4 |

### `src/` — the code that runs

| File | What it does | Was in |
| --- | --- | --- |
| `src/config.ts` | Reads settings. Stops the app if they are wrong. | Part 1 |
| `src/validation.ts` | Checks what users type, so bad input is refused | Part 1 |
| `src/db/pools.ts` | Opens database connections | Part 1 |
| `src/db/with-account.ts` | **The only safe way to read user data.** Always use this. | Part 1 |
| `src/resolver/main.ts` | Starts the tap service | Part 1 |
| `src/resolver/http.ts` | Handles the web request when a card is tapped | Part 1 |
| `src/resolver/service.ts` | Decides where to send the visitor | Part 1 |
| `src/resolver/token.ts` | Checks the card code and scrambles it for storage | Part 1 |
| `src/resolver/cache.ts` | Remembers answers, so the database is not hammered | Part 1 |
| `src/resolver/events.ts` | Counts taps, without slowing anything down | Part 1 |

### `test/` — tests for the code

| File | What it does | Was in |
| --- | --- | --- |
| `test/helpers.ts` | Shared setup. Not a test itself. | Part 2 |
| `test/resolver.test.ts` | Tests the tap service (22 checks) | Part 2 |
| `test/rls.test.ts` | Tests that users cannot see each other's data (10) | Part 2 |
| `test/cache.test.ts` | Tests the cache (7) | Part 2 |
| `test/validation.test.ts` | Tests input checking (15) | Part 2 |
| `test/config.test.ts` | Tests the settings checks (4) | Part 2 |

### `sql/` — tests for the database

| File | What it does | Was in |
| --- | --- | --- |
| `sql/99_constraint_tests.sql` | Tries to break the rules and checks it fails (49) | Part 5 |
| `sql/98_auth_rls_tests.sql` | Tests access rules and login tokens (20) | Part 5 |
| `sql/97_audit_evidence.sql` | 10 questions a security auditor will ask | Part 5 |
| `sql/run.sh` | Runs all three at once | Part 5 |

### `tools/` — mistake checkers

| File | What it does | Was in |
| --- | --- | --- |
| `tools/db-tools.cjs` | Makes `schema.prisma`, and warns if it is out of date | Part 3 |
| `tools/prisma-guard.cjs` | Blocks commands that would break the database | Part 3 |

---

## 4. Three rules

**1. Never run these:**

```
prisma migrate dev
prisma migrate reset
prisma db push
```

They rebuild the database from `schema.prisma` and would delete important security settings.
`tools/prisma-guard.cjs` blocks them for you.

**2. Never edit `prisma/schema.prisma` by hand.** A tool makes it. To change the database, add a
new SQL file in `prisma/migrations/`, then run:

```bash
npm run db:migrate
node tools/db-tools.cjs generate
```

**3. To read user data, always use `withAccount()`** from `src/db/with-account.ts`. If you query
directly, you get **zero rows** and no error, which is very confusing. See `docs/adr/0002`.
