# All source files — application (part 1 of 2)

Every file is in a code block so it can be copied directly. Create each file at the path in its heading. SQL migrations and verification suites are in **ALL-FILES-sql.md**.

## Directory layout

```
nfc-identity-platform/
├── package.json
├── prisma.config.ts
├── tsconfig.json
├── .env                       (copy from .env.example)
├── prisma/
│   ├── schema.prisma          GENERATED — do not hand-edit
│   ├── seed.ts
│   └── migrations/
│       ├── migration_lock.toml
│       ├── 20260801000000_core/migration.sql
│       ├── 20260801000001_cards/migration.sql
│       ├── 20260801000002_billing_audit_analytics/migration.sql
│       └── 20260801000003_auth_hardening/migration.sql
├── tools/
│   ├── db-tools.cjs           schema generator + drift + seed checks
│   └── prisma-guard.cjs       blocks destructive prisma commands
└── sql/                       verification suites (not shipped with the app)
    ├── 97_audit_evidence.sql
    ├── 98_auth_rls_tests.sql
    ├── 99_constraint_tests.sql
    └── run.sh
```

## Quick start

```bash
npm install
cp .env.example .env           # then edit DATABASE_URL

export DATABASE_URL="postgresql://user:pass@localhost:5432/nfc?schema=public"
npm run db:migrate             # applies the 4 SQL migrations
node tools/db-tools.cjs check
```

Expected:

```
database layer check
  ok    18 models, 15 enums, 18 named relations
  ok    no drift: schema.prisma matches the live database exactly
  ok    seed.ts model accessors and data keys resolve

all checks passed
```

## Never run these

`prisma migrate dev` · `prisma migrate reset` · `prisma db push`

Each reconciles the database *to* the datamodel, which would drop the partial unique indexes,
the generated column inside the ownership foreign key, the table partitioning, the 16 RLS
policies, and the resolver's column-level grants. `tools/prisma-guard.cjs` refuses them.


## Files in this document

| Path | Lines |
| --- | --- |
| `package.json` | 29 |
| `prisma.config.ts` | 25 |
| `tsconfig.json` | 19 |
| `.env.example` | 19 |
| `prisma/schema.prisma` | 515 |
| `prisma/seed.ts` | 384 |
| `tools/db-tools.cjs` | 740 |
| `tools/prisma-guard.cjs` | 40 |

---

## `package.json`

`````json
{
  "name": "nfc-identity-platform",
  "version": "0.4.1",
  "private": true,
  "description": "Secure NFC digital identity platform — Prisma data layer",
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "prisma": "node tools/prisma-guard.cjs",
    "db:migrate": "node tools/prisma-guard.cjs migrate deploy",
    "db:status": "node tools/prisma-guard.cjs migrate status",
    "db:seed": "tsx prisma/seed.ts",
    "prisma:generate": "node tools/prisma-guard.cjs generate",
    "prisma:generate-schema": "node tools/db-tools.cjs generate",
    "check": "node tools/db-tools.cjs check",
    "check:types": "tsc --noEmit"
  },
  "dependencies": {
    "@node-rs/argon2": "^2.0.2",
    "@prisma/client": "^6.19.3",
    "pg": "^8.22.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "prisma": "^6.19.3",
    "tsx": "^4.19.0",
    "typescript": "~5.9.3"
  }
}
`````

## `prisma.config.ts`

`````typescript
import path from 'node:path';
import { defineConfig } from 'prisma/config';

/**
 * Prisma is used here ONLY as a typed query builder.
 *
 * Schema management is done with the raw SQL migrations in prisma/migrations,
 * because the security model depends on constructs a Prisma datamodel cannot
 * express: partial unique indexes, a generated column inside a composite foreign
 * key, table partitioning, RLS policies, and column-level grants.
 *
 *   USE     npm run db:migrate    -> prisma migrate deploy (applies SQL verbatim)
 *   USE     npm run prisma:generate
 *   BLOCKED prisma migrate dev / migrate reset / db push
 *
 * The block is enforced by tools/prisma-guard.mjs, not by convention — either of
 * those commands would silently drop the constructs above.
 */
export default defineConfig({
  schema: path.join('prisma', 'schema.prisma'),
  migrations: {
    path: path.join('prisma', 'migrations'),
    seed: 'tsx prisma/seed.ts',
  },
});
`````

## `tsconfig.json`

`````json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "lib": ["ES2022"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "exactOptionalPropertyTypes": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "noEmit": true,
    "types": ["node"]
  },
  "include": ["prisma/**/*.ts", "src/**/*.ts", "prisma.config.ts"]
}
`````

## `.env.example`

`````bash
# Application connection. Runs as app_rw, so RLS applies and append-only tables
# cannot be rewritten. Every authenticated query must run inside a transaction
# that has executed:  SET LOCAL app.account_id = '<uuid>'
DATABASE_URL="postgresql://app_rw:CHANGEME@localhost:5432/nfc?schema=public&pgbouncer=true"

# Migration and seed connection. Needs table-owner rights, so it is NOT app_rw.
# Keep this out of application runtime configuration.
DIRECT_DATABASE_URL="postgresql://migrator:CHANGEME@localhost:5432/nfc?schema=public"

# Resolver connection. Column-level SELECT on three columns of cards, nothing else.
RESOLVER_DATABASE_URL="postgresql://app_resolver:CHANGEME@localhost:5432/nfc?schema=public"

# 32+ random bytes, base64. Rotate with an overlap window.
SESSION_SECRET="CHANGEME"

# Where tags point. MUST be a different registrable domain from the dashboard
# (Step 3 §4) so stored XSS in profile content cannot reach dashboard cookies.
TAP_BASE_URL="https://tapd.link"
APP_BASE_URL="https://app.example.com"
`````

## `prisma/schema.prisma`

`````prisma
// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Produced by `npm run prisma:generate-schema` from the live database catalog.
// The raw SQL migrations in prisma/migrations are the source of truth; this
// datamodel is derived from them so it cannot drift.
//
// Prisma is used here ONLY as a typed query builder. It is never used for schema
// management, because the following security-bearing constructs cannot be
// expressed in a Prisma datamodel:
//
//   * partial unique indexes        (accounts.email live-only uniqueness,
//                                    slugs one-current-per-profile)
//   * generated columns in FKs      (cards.personal_holder_id, which is what
//                                    makes the ownership invariants declarative)
//   * table partitioning            (tap_events by region then month, audit_log
//                                    by month)
//   * row-level security policies   (16 policies across 6 tables)
//   * column-level grants           (app_resolver reads 3 columns of cards)
//
// Consequently NEVER run `prisma migrate dev` or `prisma db push` against this
// project — either would attempt to drop the constructs above. Schema changes go
// in a new numbered SQL migration, then this file is regenerated.
// ─────────────────────────────────────────────────────────────────────────────

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}


// ── Tables deliberately absent from this datamodel ───────────────────────────
// tap_events        partitioned LIST(region) -> RANGE(occurred_at); raw SQL only
// audit_log         partitioned RANGE(occurred_at);                 raw SQL only
// (+ 10 partition children)
//
// cards.personal_holder_id is a STORED GENERATED column and is omitted from the
// Card model. It is unwritable by definition, and it carries the personal
// ownership foreign key. Do not add it.

enum AccountStatus {
  pending
  active
  suspended
  tombstoned

  @@map("account_status")
}

enum ActorScope {
  system
  account
  organization
  platform

  @@map("actor_scope")
}

enum CardStatus {
  manufactured
  provisioned
  claimed
  active
  suspended
  revoked

  @@map("card_status")
}

enum ChipProfile {
  ntag213
  ntag215
  ntag216
  ntag424_dna

  @@map("chip_profile")
}

enum DataRegion {
  eu
  us
  in

  @@map("data_region")
}

enum MembershipStatus {
  invited
  active
  removed

  @@map("membership_status")
}

enum OrgRole {
  employee
  manager
  hr
  org_admin

  @@map("org_role")
}

enum OrgStatus {
  active
  suspended
  closed

  @@map("org_status")
}

enum PlatformRole {
  none
  support
  admin
  super_admin

  @@map("platform_role")
}

enum ProfileStatus {
  draft
  active
  suspended
  deleted

  @@map("profile_status")
}

enum ServingState {
  unclaimed
  active
  lapsed
  suspended
  revoked

  @@map("serving_state")
}

enum SlugKind {
  current
  retired
  reserved

  @@map("slug_kind")
}

enum SubStatus {
  trialing
  active
  past_due
  canceled
  unpaid

  @@map("sub_status")
}

enum TapChannel {
  nfc
  qr
  direct

  @@map("tap_channel")
}

enum TransferReason {
  activation
  sale
  gift
  lost_replacement
  org_reassignment
  admin_correction

  @@map("transfer_reason")
}

model Account {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  email                      String?              @db.Citext
  emailVerifiedAt            DateTime?            @map("email_verified_at") @db.Timestamptz(6)
  passwordHash               String?              @map("password_hash")
  fullName                   String?              @map("full_name")
  platformRole               PlatformRole         @default(none) @map("platform_role")
  status                     AccountStatus        @default(pending)
  dataRegion                 DataRegion           @map("data_region")
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt                  DateTime             @default(now()) @map("updated_at") @db.Timestamptz(6)
  tombstonedAt               DateTime?            @map("tombstoned_at") @db.Timestamptz(6)
  cardAssignmentsViaAssignedBy CardAssignment[]     @relation(name: "card_assignments_assigned_by_fkey")
  cardAssignmentsViaFromAccountId CardAssignment[]     @relation(name: "card_assignments_from_account_id_fkey")
  cardAssignmentsViaToAccountId CardAssignment[]     @relation(name: "card_assignments_to_account_id_fkey")
  cardEncodings              CardEncoding[]
  cardsViaHolderAccountId    Card[]               @relation(name: "cards_holder_account_id_fkey")
  cardsViaOwnerAccountId     Card[]               @relation(name: "cards_owner_account_id_fkey")
  idempotencyKeys            IdempotencyKey[]
  orgMembershipsViaAccountId OrgMembership[]      @relation(name: "org_memberships_account_id_fkey")
  orgMembershipsViaInvitedBy OrgMembership[]      @relation(name: "org_memberships_invited_by_fkey")
  otpCodes                   OtpCode[]
  ownershipTransfersViaApprovedBy OwnershipTransfer[]  @relation(name: "ownership_transfers_approved_by_fkey")
  ownershipTransfersViaFromAccountId OwnershipTransfer[]  @relation(name: "ownership_transfers_from_account_id_fkey")
  ownershipTransfersViaRequestedBy OwnershipTransfer[]  @relation(name: "ownership_transfers_requested_by_fkey")
  ownershipTransfersViaToAccountId OwnershipTransfer[]  @relation(name: "ownership_transfers_to_account_id_fkey")
  profiles                   Profile[]
  sessions                   Session[]
  subscriptions              Subscription[]

  @@map("accounts")
}

model CardAssignment {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  cardId                     String               @map("card_id") @db.Uuid
  fromAccountId              String?              @map("from_account_id") @db.Uuid
  toAccountId                String?              @map("to_account_id") @db.Uuid
  assignedBy                 String               @map("assigned_by") @db.Uuid
  correlationId              String?              @map("correlation_id") @db.Uuid
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  assignedByAccounts         Account              @relation(fields: [assignedBy], references: [id], name: "card_assignments_assigned_by_fkey", onDelete: Restrict)
  card                       Card                 @relation(fields: [cardId], references: [id], onDelete: Restrict)
  fromAccount                Account?             @relation(fields: [fromAccountId], references: [id], name: "card_assignments_from_account_id_fkey", onDelete: Restrict)
  toAccount                  Account?             @relation(fields: [toAccountId], references: [id], name: "card_assignments_to_account_id_fkey", onDelete: Restrict)

  @@map("card_assignments")
}

model CardBatch {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  orgId                      String?              @map("org_id") @db.Uuid
  chip                       ChipProfile
  quantity                   Int
  manufacturer               String?
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  org                        Organization?        @relation(fields: [orgId], references: [id], onDelete: Restrict)
  cards                      Card[]

  @@map("card_batches")
}

model CardEncoding {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  cardId                     String               @map("card_id") @db.Uuid
  encoderAccountId           String               @map("encoder_account_id") @db.Uuid
  stationId                  String               @map("station_id")
  chip                       ChipProfile
  locked                     Boolean
  verifyReadOk               Boolean              @map("verify_read_ok")
  occurredAt                 DateTime             @default(now()) @map("occurred_at") @db.Timestamptz(6)
  card                       Card                 @relation(fields: [cardId], references: [id], onDelete: Restrict)
  encoderAccount             Account              @relation(fields: [encoderAccountId], references: [id], onDelete: Restrict)

  @@map("card_encodings")
}

model Card {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  tokenHash                  Bytes                @map("token_hash")
  tokenPrefix                String               @map("token_prefix") @db.Char(6)
  batchId                    String?              @map("batch_id") @db.Uuid
  chip                       ChipProfile
  ownerAccountId             String?              @map("owner_account_id") @db.Uuid
  ownerOrgId                 String?              @map("owner_org_id") @db.Uuid
  holderAccountId            String?              @map("holder_account_id") @db.Uuid
  profileId                  String?              @map("profile_id") @db.Uuid
  servingSlug                String?              @map("serving_slug") @db.Citext
  servingState               ServingState         @default(unclaimed) @map("serving_state")
  status                     CardStatus           @default(manufactured)
  claimCodeHash              String?              @map("claim_code_hash")
  claimAttempts              Int                  @default(0) @map("claim_attempts")
  claimLockedUntil           DateTime?            @map("claim_locked_until") @db.Timestamptz(6)
  dnaKeyRef                  String?              @map("dna_key_ref")
  dnaCounter                 BigInt?              @map("dna_counter")
  lockedAt                   DateTime?            @map("locked_at") @db.Timestamptz(6)
  claimedAt                  DateTime?            @map("claimed_at") @db.Timestamptz(6)
  activatedAt                DateTime?            @map("activated_at") @db.Timestamptz(6)
  revokedAt                  DateTime?            @map("revoked_at") @db.Timestamptz(6)
  revokedReason              String?              @map("revoked_reason")
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt                  DateTime             @default(now()) @map("updated_at") @db.Timestamptz(6)
  batch                      CardBatch?           @relation(fields: [batchId], references: [id], onDelete: Restrict)
  holderAccount              Account?             @relation(fields: [holderAccountId], references: [id], name: "cards_holder_account_id_fkey", onDelete: Restrict)
  holderMembership           OrgMembership?       @relation(fields: [holderAccountId, ownerOrgId], references: [accountId, orgId], onDelete: NoAction)
  orgProfile                 Profile?             @relation(fields: [profileId, ownerOrgId], references: [id, ownerOrgId], name: "cards_org_profile_belongs_to_org", onDelete: NoAction)
  ownerAccount               Account?             @relation(fields: [ownerAccountId], references: [id], name: "cards_owner_account_id_fkey", onDelete: Restrict)
  ownerOrg                   Organization?        @relation(fields: [ownerOrgId], references: [id], onDelete: Restrict)
  profile                    Profile?             @relation(fields: [profileId], references: [id], name: "cards_profile_id_fkey", onDelete: Restrict)
  cardAssignments            CardAssignment[]
  cardEncodings              CardEncoding[]
  ownershipTransfers         OwnershipTransfer[]

  @@unique([tokenHash], map: "cards_token_hash_key")
  @@map("cards")
}

model IdempotencyKey {
  key                        String               @id
  accountId                  String?              @map("account_id") @db.Uuid
  endpoint                   String
  requestHash                Bytes                @map("request_hash")
  responseCode               Int?                 @map("response_code")
  responseBody               Json?                @map("response_body")
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  completedAt                DateTime?            @map("completed_at") @db.Timestamptz(6)
  account                    Account?             @relation(fields: [accountId], references: [id], onDelete: Cascade)

  @@map("idempotency_keys")
}

model OrgMembership {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  orgId                      String               @map("org_id") @db.Uuid
  accountId                  String               @map("account_id") @db.Uuid
  role                       OrgRole              @default(employee)
  status                     MembershipStatus     @default(invited)
  invitedBy                  String?              @map("invited_by") @db.Uuid
  joinedAt                   DateTime?            @map("joined_at") @db.Timestamptz(6)
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt                  DateTime             @default(now()) @map("updated_at") @db.Timestamptz(6)
  account                    Account              @relation(fields: [accountId], references: [id], name: "org_memberships_account_id_fkey", onDelete: Restrict)
  invitedByAccounts          Account?             @relation(fields: [invitedBy], references: [id], name: "org_memberships_invited_by_fkey", onDelete: SetNull)
  org                        Organization         @relation(fields: [orgId], references: [id], onDelete: Restrict)
  cards                      Card[]

  @@unique([accountId, orgId], map: "org_memberships_account_org_key")
  @@map("org_memberships")
}

model Organization {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  name                       String
  billingEmail               String               @map("billing_email") @db.Citext
  status                     OrgStatus            @default(active)
  dataRegion                 DataRegion           @map("data_region")
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt                  DateTime             @default(now()) @map("updated_at") @db.Timestamptz(6)
  cardBatches                CardBatch[]
  cards                      Card[]
  orgMemberships             OrgMembership[]
  ownershipTransfersViaFromOrgId OwnershipTransfer[]  @relation(name: "ownership_transfers_from_org_id_fkey")
  ownershipTransfersViaToOrgId OwnershipTransfer[]  @relation(name: "ownership_transfers_to_org_id_fkey")
  profiles                   Profile[]
  subscriptions              Subscription[]

  @@map("organizations")
}

model OtpCode {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  accountId                  String               @map("account_id") @db.Uuid
  purpose                    String
  codeHash                   Bytes                @map("code_hash")
  attempts                   Int                  @default(0)
  expiresAt                  DateTime             @map("expires_at") @db.Timestamptz(6)
  consumedAt                 DateTime?            @map("consumed_at") @db.Timestamptz(6)
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  account                    Account              @relation(fields: [accountId], references: [id], onDelete: Cascade)

  @@map("otp_codes")
}

model OwnershipTransfer {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  cardId                     String               @map("card_id") @db.Uuid
  fromAccountId              String?              @map("from_account_id") @db.Uuid
  fromOrgId                  String?              @map("from_org_id") @db.Uuid
  toAccountId                String?              @map("to_account_id") @db.Uuid
  toOrgId                    String?              @map("to_org_id") @db.Uuid
  reason                     TransferReason
  requestedBy                String?              @map("requested_by") @db.Uuid
  approvedBy                 String?              @map("approved_by") @db.Uuid
  approvedAt                 DateTime             @default(now()) @map("approved_at") @db.Timestamptz(6)
  correlationId              String?              @map("correlation_id") @db.Uuid
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  approvedByAccounts         Account?             @relation(fields: [approvedBy], references: [id], name: "ownership_transfers_approved_by_fkey", onDelete: Restrict)
  card                       Card                 @relation(fields: [cardId], references: [id], onDelete: Restrict)
  fromAccount                Account?             @relation(fields: [fromAccountId], references: [id], name: "ownership_transfers_from_account_id_fkey", onDelete: Restrict)
  fromOrg                    Organization?        @relation(fields: [fromOrgId], references: [id], name: "ownership_transfers_from_org_id_fkey", onDelete: Restrict)
  requestedByAccounts        Account?             @relation(fields: [requestedBy], references: [id], name: "ownership_transfers_requested_by_fkey", onDelete: Restrict)
  toAccount                  Account?             @relation(fields: [toAccountId], references: [id], name: "ownership_transfers_to_account_id_fkey", onDelete: Restrict)
  toOrg                      Organization?        @relation(fields: [toOrgId], references: [id], name: "ownership_transfers_to_org_id_fkey", onDelete: Restrict)

  @@map("ownership_transfers")
}

model Profile {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  ownerAccountId             String?              @map("owner_account_id") @db.Uuid
  ownerOrgId                 String?              @map("owner_org_id") @db.Uuid
  currentSlug                String               @map("current_slug") @db.Citext
  displayName                String               @map("display_name")
  headline                   String?
  bio                        String?
  links                      Json                 @default("{}")
  theme                      String               @default("default")
  template                   String               @default("standard")
  avatarKey                  String?              @map("avatar_key")
  resumeKey                  String?              @map("resume_key")
  status                     ProfileStatus        @default(draft)
  publishedAt                DateTime?            @map("published_at") @db.Timestamptz(6)
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt                  DateTime             @default(now()) @map("updated_at") @db.Timestamptz(6)
  currentSlugSlugs           Slug                 @relation(fields: [currentSlug], references: [slug], name: "profiles_current_slug_fk", onDelete: NoAction)
  ownerAccount               Account?             @relation(fields: [ownerAccountId], references: [id], onDelete: Restrict)
  ownerOrg                   Organization?        @relation(fields: [ownerOrgId], references: [id], onDelete: Restrict)
  cardsViaProfileId          Card[]               @relation(name: "cards_org_profile_belongs_to_org")
  cardsViaProfileIdCardsRef  Card[]               @relation(name: "cards_profile_id_fkey")
  slugsViaProfileId          Slug[]               @relation(name: "slugs_profile_id_fkey")

  @@unique([id, ownerAccountId], map: "profiles_id_owner_account_key")
  @@unique([id, ownerOrgId], map: "profiles_id_owner_org_key")
  @@map("profiles")
}

model RefreshToken {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  sessionId                  String               @map("session_id") @db.Uuid
  tokenHash                  Bytes                @map("token_hash")
  issuedAt                   DateTime             @default(now()) @map("issued_at") @db.Timestamptz(6)
  expiresAt                  DateTime             @map("expires_at") @db.Timestamptz(6)
  usedAt                     DateTime?            @map("used_at") @db.Timestamptz(6)
  replacedBy                 String?              @map("replaced_by") @db.Uuid
  replacedByRefreshTokens    RefreshToken?        @relation(fields: [replacedBy], references: [id], name: "refresh_tokens_replaced_by_fkey", onDelete: SetNull)
  session                    Session              @relation(fields: [sessionId], references: [id], onDelete: Cascade)
  replacedByOf               RefreshToken[]       @relation(name: "refresh_tokens_replaced_by_fkey")

  @@unique([tokenHash], map: "refresh_tokens_hash_key")
  @@map("refresh_tokens")
}

model Session {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  accountId                  String               @map("account_id") @db.Uuid
  deviceLabel                String?              @map("device_label")
  deviceClass                String?              @map("device_class")
  ipCountry                  String?              @map("ip_country") @db.Char(2)
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  lastSeenAt                 DateTime             @default(now()) @map("last_seen_at") @db.Timestamptz(6)
  expiresAt                  DateTime             @map("expires_at") @db.Timestamptz(6)
  revokedAt                  DateTime?            @map("revoked_at") @db.Timestamptz(6)
  revokedReason              String?              @map("revoked_reason")
  account                    Account              @relation(fields: [accountId], references: [id], onDelete: Cascade)
  refreshTokens              RefreshToken[]

  @@map("sessions")
}

model Slug {
  slug                       String               @id @db.Citext
  kind                       SlugKind
  profileId                  String?              @map("profile_id") @db.Uuid
  reason                     String?
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  retiredAt                  DateTime?            @map("retired_at") @db.Timestamptz(6)
  profile                    Profile?             @relation(fields: [profileId], references: [id], name: "slugs_profile_id_fkey", onDelete: Restrict)
  profilesViaCurrentSlug     Profile[]            @relation(name: "profiles_current_slug_fk")

  @@map("slugs")
}

model StripeEvent {
  stripeEventId              String               @id @map("stripe_event_id")
  type                       String
  payload                    Json
  receivedAt                 DateTime             @default(now()) @map("received_at") @db.Timestamptz(6)
  processedAt                DateTime?            @map("processed_at") @db.Timestamptz(6)
  error                      String?

  @@map("stripe_events")
}

model Subscription {
  id                         String               @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  ownerAccountId             String?              @map("owner_account_id") @db.Uuid
  ownerOrgId                 String?              @map("owner_org_id") @db.Uuid
  plan                       String
  status                     SubStatus
  seats                      Int                  @default(1)
  stripeCustomerId           String?              @map("stripe_customer_id")
  stripeSubscriptionId       String?              @map("stripe_subscription_id")
  currentPeriodEnd           DateTime?            @map("current_period_end") @db.Timestamptz(6)
  cancelAt                   DateTime?            @map("cancel_at") @db.Timestamptz(6)
  createdAt                  DateTime             @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt                  DateTime             @default(now()) @map("updated_at") @db.Timestamptz(6)
  ownerAccount               Account?             @relation(fields: [ownerAccountId], references: [id], onDelete: Restrict)
  ownerOrg                   Organization?        @relation(fields: [ownerOrgId], references: [id], onDelete: Restrict)

  @@unique([stripeSubscriptionId], map: "subscriptions_stripe_sub_key")
  @@map("subscriptions")
}

model TapDaily {
  profileId                  String               @map("profile_id") @db.Uuid
  day                        DateTime             @db.Date
  region                     DataRegion
  taps                       BigInt               @default(0)
  nfcTaps                    BigInt               @default(0) @map("nfc_taps")
  qrTaps                     BigInt               @default(0) @map("qr_taps")
  botTaps                    BigInt               @default(0) @map("bot_taps")

  @@id([profileId, day, region])
  @@map("tap_daily")
}

model TapDailyCountry {
  profileId                  String               @map("profile_id") @db.Uuid
  day                        DateTime             @db.Date
  country                    String               @db.Char(2)
  taps                       BigInt               @default(0)

  @@id([profileId, day, country])
  @@map("tap_daily_country")
}
`````

## `prisma/seed.ts`

`````typescript
/**
 * Development seed.
 *
 * Creates one consumer, one organisation with an employee, and the cards that
 * exercise both ownership shapes. Prints the plaintext tap URLs and claim codes,
 * because they are never recoverable afterwards — the database stores only
 * hashes.
 *
 * MUST run with owner/migrator credentials (DIRECT_DATABASE_URL), not app_rw:
 *   - RLS would otherwise filter everything (no app.account_id is set)
 *   - append-only tables reject writes other than INSERT from app_rw
 *
 * Never run against production. The guard below refuses a non-dev NODE_ENV.
 */

import { PrismaClient, Prisma } from '@prisma/client';
import { hash as argonHash } from '@node-rs/argon2';
import { randomBytes, createHash } from 'node:crypto';

const prisma = new PrismaClient({
  datasources: { db: { url: process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL } },
});

const TAP_BASE_URL = process.env.TAP_BASE_URL ?? 'https://tapd.link';

/* ── token and code generation ────────────────────────────────────────────── */

const BASE62 = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

/**
 * 128 bits of CSPRNG entropy, base62 encoded (~22 chars).
 *
 * Rejection sampling rather than `% 62`: taking a modulus of a uniform byte
 * biases the first 8 characters of the alphabet, which would shrink the
 * effective keyspace. At this entropy the practical risk is negligible, but a
 * biased token generator is a finding an assessor will raise, and correctness
 * here is free.
 */
function generateToken(): string {
  const out: string[] = [];
  while (out.length < 22) {
    for (const byte of randomBytes(32)) {
      if (byte < 248) out.push(BASE62[byte % 62]!); // 248 = 4 * 62
      if (out.length === 22) break;
    }
  }
  return out.join('');
}

/** Card tokens are hashed with plain SHA-256, deliberately: the input is 128-bit
 *  uniform randomness, so there is nothing to brute force, and a pepper could
 *  never be rotated because plaintext tokens are not retained (Step 3 §5). */
const hashToken = (token: string): Buffer =>
  createHash('sha256').update(token, 'utf8').digest();

/** Human-typed scratch code: 12 chars from an unambiguous alphabet (no I, L, O,
 *  0, 1) so it can be read off a card without transcription errors. ~55 bits. */
function generateClaimCode(): string {
  const alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  const bytes = randomBytes(24);
  let code = '';
  for (const b of bytes) {
    if (b < 248 && code.length < 12) code += alphabet[b % 31];
  }
  return code.length === 12 ? code : generateClaimCode();
}

/** Low-entropy human input, so a slow KDF is required (Step 3 §5). */
const slowHash = (secret: string) =>
  argonHash(secret, { memoryCost: 19456, timeCost: 2, parallelism: 1 });

/* ── seed ─────────────────────────────────────────────────────────────────── */

type CardSecret = { label: string; token: string; claimCode: string };
const secrets: CardSecret[] = [];

async function main() {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Refusing to seed with NODE_ENV=production.');
  }

  await reset();

  const password = await slowHash('password123');

  // ── accounts ───────────────────────────────────────────────────────────────
  const platformAdmin = await prisma.account.create({
    data: {
      email: 'admin@example.test',
      fullName: 'Platform Admin',
      passwordHash: password,
      platformRole: 'super_admin',
      status: 'active',
      dataRegion: 'eu',
      emailVerifiedAt: new Date(),
    },
  });

  const encoder = await prisma.account.create({
    data: {
      email: 'encoder@example.test',
      fullName: 'Encoding Station Operator',
      passwordHash: password,
      platformRole: 'support',
      status: 'active',
      dataRegion: 'eu',
      emailVerifiedAt: new Date(),
    },
  });

  // Consumer: owns their card outright.
  const bob = await prisma.account.create({
    data: {
      email: 'bob@example.test',
      fullName: 'Bob Consumer',
      passwordHash: password,
      status: 'active',
      dataRegion: 'eu',
      emailVerifiedAt: new Date(),
    },
  });

  // Employee: holds a card the organisation owns.
  const alice = await prisma.account.create({
    data: {
      email: 'alice@acme.test',
      fullName: 'Alice Employee',
      passwordHash: password,
      status: 'active',
      dataRegion: 'eu',
      emailVerifiedAt: new Date(),
    },
  });

  // ── organisation ───────────────────────────────────────────────────────────
  const acme = await prisma.organization.create({
    data: {
      name: 'Acme Ltd',
      billingEmail: 'billing@acme.test',
      status: 'active',
      dataRegion: 'eu',
    },
  });

  // Written as a separate flat create with scalar foreign keys rather than a
  // nested write. Mixing relation objects with relation scalars is where
  // Prisma's checked/unchecked create variants get subtle; flat scalars are
  // unambiguous and read closer to the SQL they become.
  await prisma.orgMembership.create({
    data: {
      orgId: acme.id,
      accountId: alice.id,
      role: 'employee',
      status: 'active',
      joinedAt: new Date(),
    },
  });

  // ── profiles ───────────────────────────────────────────────────────────────
  // profiles.current_slug -> slugs.slug is DEFERRABLE INITIALLY DEFERRED, so a
  // profile and its first slug must be written in ONE transaction (Step 2 §4.3).
  const bobProfile = await createProfileWithSlug({
    slug: 'bob',
    displayName: 'Bob Consumer',
    headline: 'Independent consultant',
    ownerAccountId: bob.id,
  });

  const alicePersonal = await createProfileWithSlug({
    slug: 'alice',
    displayName: 'Alice',
    headline: 'Personal profile — stays with Alice forever',
    ownerAccountId: alice.id,
  });

  // Organisation-owned work profile. An org card may ONLY point here, never at
  // alicePersonal — enforced by cards_org_profile_belongs_to_org (Step 2 §2.6).
  const aliceWork = await createProfileWithSlug({
    slug: 'acme-alice',
    displayName: 'Alice at Acme',
    headline: 'Head of Partnerships, Acme Ltd',
    ownerOrgId: acme.id,
  });

  // ── batch ──────────────────────────────────────────────────────────────────
  const batch = await prisma.cardBatch.create({
    data: { orgId: acme.id, chip: 'ntag213', quantity: 100, manufacturer: 'Dev Fixture Co' },
  });

  // ── cards ──────────────────────────────────────────────────────────────────
  await createActiveCard({
    label: "Bob's personal card",
    chip: 'ntag213',
    batchId: batch.id,
    ownerAccountId: bob.id,
    holderAccountId: bob.id,
    profileId: bobProfile.id,
    slug: 'bob',
    encoderId: encoder.id,
    activatedBy: bob.id,
  });

  await createActiveCard({
    label: "Acme card held by Alice",
    chip: 'ntag424_dna',
    dnaKeyRef: 'kms://nfc-dna/master/v1#diversified',
    batchId: batch.id,
    ownerOrgId: acme.id,
    holderAccountId: alice.id,
    profileId: aliceWork.id,
    slug: 'acme-alice',
    encoderId: encoder.id,
    activatedByOrg: acme.id,
  });

  // A provisioned-but-unclaimed card, to exercise the claim flow.
  const unclaimedToken = generateToken();
  const unclaimedCode = generateClaimCode();
  await prisma.card.create({
    data: {
      tokenHash: hashToken(unclaimedToken),
      tokenPrefix: unclaimedToken.slice(0, 6),
      chip: 'ntag213',
      batchId: batch.id,
      status: 'provisioned',
      servingState: 'unclaimed',
      claimCodeHash: await slowHash(unclaimedCode),
      lockedAt: new Date(),
    },
  });
  secrets.push({ label: 'Unclaimed card (try the claim flow)', token: unclaimedToken, claimCode: unclaimedCode });

  // ── subscriptions ──────────────────────────────────────────────────────────
  await prisma.subscription.create({
    data: { ownerAccountId: bob.id, plan: 'pro', status: 'active', seats: 1,
            currentPeriodEnd: new Date(Date.now() + 30 * 86_400_000) },
  });
  await prisma.subscription.create({
    data: { ownerOrgId: acme.id, plan: 'team', status: 'active', seats: 50,
            currentPeriodEnd: new Date(Date.now() + 30 * 86_400_000) },
  });

  report({ platformAdmin, alicePersonal });
}

/* ── helpers ──────────────────────────────────────────────────────────────── */

async function createProfileWithSlug(args: {
  slug: string;
  displayName: string;
  headline: string;
  ownerAccountId?: string;
  ownerOrgId?: string;
}) {
  return prisma.$transaction(async (tx) => {
    const profile = await tx.profile.create({
      data: {
        currentSlug: args.slug,
        displayName: args.displayName,
        headline: args.headline,
        status: 'active',
        publishedAt: new Date(),
        links: { linkedin: `https://linkedin.com/in/${args.slug}` } as Prisma.InputJsonValue,
        ...(args.ownerAccountId ? { ownerAccountId: args.ownerAccountId } : {}),
        ...(args.ownerOrgId ? { ownerOrgId: args.ownerOrgId } : {}),
      },
    });
    await tx.slug.create({ data: { slug: args.slug, kind: 'current', profileId: profile.id } });
    return profile;
  });
}

async function createActiveCard(args: {
  label: string;
  chip: 'ntag213' | 'ntag215' | 'ntag216' | 'ntag424_dna';
  dnaKeyRef?: string;
  batchId: string;
  ownerAccountId?: string;
  ownerOrgId?: string;
  holderAccountId: string;
  profileId: string;
  slug: string;
  encoderId: string;
  activatedBy?: string;
  activatedByOrg?: string;
}) {
  const token = generateToken();
  const claimCode = generateClaimCode();
  const now = new Date();

  await prisma.$transaction(async (tx) => {
    const card = await tx.card.create({
      data: {
        tokenHash: hashToken(token),
        tokenPrefix: token.slice(0, 6),
        chip: args.chip,
        batchId: args.batchId,
        holderAccountId: args.holderAccountId,
        profileId: args.profileId,
        servingSlug: args.slug,
        servingState: 'active',
        status: 'active',
        claimCodeHash: await slowHash(claimCode),
        lockedAt: now,
        claimedAt: now,
        activatedAt: now,
        ...(args.dnaKeyRef ? { dnaKeyRef: args.dnaKeyRef } : {}),
        ...(args.ownerAccountId ? { ownerAccountId: args.ownerAccountId } : {}),
        ...(args.ownerOrgId ? { ownerOrgId: args.ownerOrgId } : {}),
      },
    });

    // Immutable proof the chip was locked and read back (Step 3 §9).
    await tx.cardEncoding.create({
      data: {
        cardId: card.id,
        encoderAccountId: args.encoderId,
        stationId: 'dev-station-01',
        chip: args.chip,
        locked: true,
        verifyReadOk: true,
      },
    });

    // Activation is the first ownership transfer, with no origin.
    await tx.ownershipTransfer.create({
      data: {
        cardId: card.id,
        reason: 'activation',
        ...(args.activatedBy ? { toAccountId: args.activatedBy } : {}),
        ...(args.activatedByOrg ? { toOrgId: args.activatedByOrg } : {}),
      },
    });
  });

  secrets.push({ label: args.label, token, claimCode });
}

/** Order matters: RESTRICT is used throughout, so children go first. */
async function reset() {
  await prisma.$transaction([
    prisma.ownershipTransfer.deleteMany(),
    prisma.cardAssignment.deleteMany(),
    prisma.cardEncoding.deleteMany(),
    prisma.card.deleteMany(),
    prisma.cardBatch.deleteMany(),
    prisma.refreshToken.deleteMany(),
    prisma.session.deleteMany(),
    prisma.otpCode.deleteMany(),
    prisma.subscription.deleteMany(),
    prisma.idempotencyKey.deleteMany(),
    prisma.slug.deleteMany({ where: { kind: { not: 'reserved' } } }),
    prisma.profile.deleteMany(),
    prisma.orgMembership.deleteMany(),
    prisma.organization.deleteMany(),
    prisma.account.deleteMany(),
  ]);
}

function report(ctx: { platformAdmin: { email: string | null }; alicePersonal: { currentSlug: string } }) {
  const line = '─'.repeat(72);
  console.log(`\n${line}\nSeed complete.\n${line}`);
  console.log('\nAccounts (password: password123)');
  console.log('  admin@example.test    super_admin');
  console.log('  encoder@example.test  support / encoding station');
  console.log('  bob@example.test      consumer, owns his own card');
  console.log('  alice@acme.test       Acme employee, holds an org-owned card');

  console.log('\nCard secrets — these are NOT recoverable, only hashes are stored:');
  for (const s of secrets) {
    console.log(`\n  ${s.label}`);
    console.log(`    tap URL:    ${TAP_BASE_URL}/t/${s.token}`);
    console.log(`    claim code: ${s.claimCode}`);
  }

  console.log('\nNote: Alice has two profiles by design (Step 3 / Step 1 §2.6).');
  console.log(`  personal  /u/${ctx.alicePersonal.currentSlug}  hers forever`);
  console.log('  work      /u/acme-alice  owned by Acme, revoked when she leaves');
  console.log(`\n${line}\n`);
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(() => prisma.$disconnect());
`````

## `tools/db-tools.cjs`

`````javascript
/**
 * Derives prisma/schema.prisma from the live PostgreSQL catalog.
 *
 * WHY THIS EXISTS
 * The raw SQL migrations are the source of truth (Step 2 §1). Prisma cannot
 * express several constructs this schema depends on for security — partial
 * unique indexes, a generated column inside a composite foreign key, table
 * partitioning, RLS policies, and column-level grants. So Prisma is used only
 * as a typed query builder, never for schema management.
 *
 * Generating the datamodel from the catalog means it CANNOT drift from the DDL.
 * `check` regenerates and compares against the committed file, so any hand edit
 * or unapplied migration fails CI.
 *
 * SINGLE FILE, ONE DEPENDENCY (pg). It deliberately avoids @mrleebo/prisma-ast
 * and typescript: `npm i typescript` now resolves to 7.x, which is the native
 * port and exposes no JS compiler API, so anything importing it breaks on a
 * fresh install. The .cjs extension means this runs whether or not package.json
 * declares "type": "module".
 *
 * Usage:
 *   node tools/db-tools.cjs generate   rewrite prisma/schema.prisma from the DB
 *   node tools/db-tools.cjs check      validate datamodel + drift + seed.ts
 *
 * Requires DATABASE_URL for both. `check` skips the drift comparison without it.
 */

const { Client } = require('pg');

/** Partitioned parents and their children are excluded: Prisma has no model for
 *  partitioning, and introspecting the children would produce 9 junk models.
 *  These tables are reached through raw SQL in the analytics layer. */
const EXCLUDED_TABLES = new Set(['tap_events', 'audit_log']);

const HEADER = `// ─────────────────────────────────────────────────────────────────────────────
// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Produced by \`npm run prisma:generate-schema\` from the live database catalog.
// The raw SQL migrations in prisma/migrations are the source of truth; this
// datamodel is derived from them so it cannot drift.
//
// Prisma is used here ONLY as a typed query builder. It is never used for schema
// management, because the following security-bearing constructs cannot be
// expressed in a Prisma datamodel:
//
//   * partial unique indexes        (accounts.email live-only uniqueness,
//                                    slugs one-current-per-profile)
//   * generated columns in FKs      (cards.personal_holder_id, which is what
//                                    makes the ownership invariants declarative)
//   * table partitioning            (tap_events by region then month, audit_log
//                                    by month)
//   * row-level security policies   (16 policies across 6 tables)
//   * column-level grants           (app_resolver reads 3 columns of cards)
//
// Consequently NEVER run \`prisma migrate dev\` or \`prisma db push\` against this
// project — either would attempt to drop the constructs above. Schema changes go
// in a new numbered SQL migration, then this file is regenerated.
// ─────────────────────────────────────────────────────────────────────────────

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}
`;

/** Tables excluded from the Prisma model, documented in the output so a reader
 *  is not left wondering where the analytics tables went. */
const EXCLUSION_NOTE = `
// ── Tables deliberately absent from this datamodel ───────────────────────────
// tap_events        partitioned LIST(region) -> RANGE(occurred_at); raw SQL only
// audit_log         partitioned RANGE(occurred_at);                 raw SQL only
// (+ 10 partition children)
//
// cards.personal_holder_id is a STORED GENERATED column and is omitted from the
// Card model. It is unwritable by definition, and it carries the personal
// ownership foreign key. Do not add it.
`;

const pascal = (s) =>
  s.split('_').map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('');

/** Singularises a table name for the model name: profiles -> Profile,
 *  card_batches -> CardBatch (NOT CardBatche). */
function modelName(table) {
  const p = pascal(table);
  if (/ies$/.test(p))              return `${p.slice(0, -3)}y`;
  if (/(ch|sh|ss|x|z)es$/.test(p)) return p.slice(0, -2);
  if (/ss$/.test(p))               return p;
  if (/s$/.test(p))                return p.slice(0, -1);
  return p;
}

const camel = (s) => {
  const p = pascal(s);
  return p.charAt(0).toLowerCase() + p.slice(1);
};

function scalarType(col) {
  const { udt_name, char_len } = col;
  switch (udt_name) {
    case 'uuid':        return ['String', '@db.Uuid'];
    case 'citext':      return ['String', '@db.Citext'];
    case 'text':        return ['String', null];
    case 'bpchar':      return ['String', `@db.Char(${char_len})`];
    case 'varchar':     return ['String', char_len ? `@db.VarChar(${char_len})` : null];
    case 'timestamptz': return ['DateTime', '@db.Timestamptz(6)'];
    case 'timestamp':   return ['DateTime', '@db.Timestamp(6)'];
    case 'date':        return ['DateTime', '@db.Date'];
    case 'bytea':       return ['Bytes', null];
    case 'bool':        return ['Boolean', null];
    case 'int2':        return ['Int', '@db.SmallInt'];
    case 'int4':        return ['Int', null];
    case 'int8':        return ['BigInt', null];
    case 'numeric':     return ['Decimal', '@db.Decimal(65,30)'];
    case 'jsonb':       return ['Json', null];
    case 'json':        return ['Json', '@db.Json'];
    default:            return null; // enum or unsupported; resolved by caller
  }
}

function defaultFor(col, enumNames) {
  const d = col.column_default;
  if (!d) return null;
  if (/^gen_random_uuid\(\)/.test(d))       return '@default(dbgenerated("gen_random_uuid()"))';
  if (/^now\(\)/.test(d) || /CURRENT_TIME/i.test(d)) return '@default(now())';
  if (/^(true|false)$/.test(d))             return `@default(${d})`;
  const num = d.match(/^(-?\d+)$/);
  if (num)                                  return `@default(${num[1]})`;
  // enum default: 'active'::account_status
  const en = d.match(/^'([^']*)'::([A-Za-z_][A-Za-z0-9_]*)$/);
  if (en && enumNames.has(en[2]))           return `@default(${en[1]})`;
  if (en)                                   return `@default("${en[1]}")`;
  // jsonb default: '{}'::jsonb
  const js = d.match(/^'(.*)'::jsonb$/);
  if (js)                                   return `@default("${js[1].replace(/"/g, '\\"')}")`;
  return `@default(dbgenerated("${d.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"))`;
}

async function buildSchema() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error('DATABASE_URL is not set.');
  const db = new Client({ connectionString: url });
  await db.connect();

  // ---- enums ----
  const { rows: enumRows } = await db.query(`
    SELECT t.typname AS name, e.enumlabel AS label
      FROM pg_type t
      JOIN pg_enum e ON e.enumtypid = t.oid
      JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'public'
     ORDER BY t.typname, e.enumsortorder`);

  const enums = new Map();
  for (const r of enumRows) {
    if (!enums.has(r.name)) enums.set(r.name, []);
    enums.get(r.name).push(r.label);
  }
  const enumNames = new Set(enums.keys());

  // ---- tables: ordinary, non-partition, not excluded ----
  const { rows: tableRows } = await db.query(`
    SELECT c.relname AS table_name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND NOT c.relispartition
     ORDER BY c.relname`);
  const tables = tableRows.map((r) => r.table_name).filter((t) => !EXCLUDED_TABLES.has(t));

  // ---- columns (generated columns excluded: unwritable by definition) ----
  const { rows: colRows } = await db.query(`
    SELECT table_name, ordinal_position, column_name, udt_name,
           character_maximum_length AS char_len, is_nullable, column_default,
           is_generated
      FROM information_schema.columns
     WHERE table_schema = 'public'
     ORDER BY table_name, ordinal_position`);

  const columns = new Map();
  const generated = [];
  for (const c of colRows) {
    if (!tables.includes(c.table_name)) continue;
    if (c.is_generated === 'ALWAYS') { generated.push(`${c.table_name}.${c.column_name}`); continue; }
    if (!columns.has(c.table_name)) columns.set(c.table_name, []);
    columns.get(c.table_name).push(c);
  }

  // ---- primary keys ----
  const { rows: pkRows } = await db.query(`
    SELECT c.relname AS table_name, a.attname AS column_name, k.ord
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
     WHERE con.contype = 'p'
     ORDER BY c.relname, k.ord`);
  const pks = new Map();
  for (const r of pkRows) {
    if (!pks.has(r.table_name)) pks.set(r.table_name, []);
    pks.get(r.table_name).push(r.column_name);
  }

  // ---- unique constraints (non-partial only; partial ones are invisible to Prisma) ----
  const { rows: uqRows } = await db.query(`
    SELECT c.relname AS table_name, con.conname,
           array_agg(a.attname::text ORDER BY k.ord) AS cols
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
     WHERE con.contype = 'u'
     GROUP BY c.relname, con.conname
     ORDER BY c.relname, con.conname`);

  // ---- foreign keys ----
  const { rows: fkRows } = await db.query(`
    SELECT con.conname,
           src.relname AS src_table,
           tgt.relname AS tgt_table,
           (SELECT array_agg(a.attname::text ORDER BY k.ord)
              FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS src_cols,
           (SELECT array_agg(a.attname::text ORDER BY k.ord)
              FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS tgt_cols,
           con.confdeltype AS on_delete
      FROM pg_constraint con
      JOIN pg_class src ON src.oid = con.conrelid
      JOIN pg_class tgt ON tgt.oid = con.confrelid
     WHERE con.contype = 'f'
     ORDER BY src.relname, con.conname`);

  const DEL = { a: 'NoAction', r: 'Restrict', c: 'Cascade', n: 'SetNull', d: 'SetDefault' };

  /** Composite ownership FKs get readable field names rather than a camelised
   *  constraint name. Explicit so the output stays reviewable. */
  const FIELD_OVERRIDES = {
    cards_org_profile_belongs_to_org: 'orgProfile',
    cards_org_holder_is_member:       'holderMembership',
  };

  // Keep only FKs whose columns are all present in the model. A composite FK
  // containing a generated column (cards.personal_holder_id) is intentionally
  // dropped here and lives in SQL only.
  const fks = [];
  const skippedFks = [];
  for (const fk of fkRows) {
    if (!tables.includes(fk.src_table) || !tables.includes(fk.tgt_table)) continue;
    const modelCols = (columns.get(fk.src_table) || []).map((c) => c.column_name);
    if (!fk.src_cols.every((c) => modelCols.includes(c))) { skippedFks.push(fk.conname); continue; }
    fks.push(fk);
  }

  // Prisma requires an explicit relation name whenever two models are related
  // more than once IN EITHER DIRECTION, so the key must be UNORDERED. profiles
  // and slugs reference each other, which an ordered key would miss.
  const pairKey = (a, b) => [a, b].sort().join('~');
  const pairCount = new Map();
  for (const fk of fks) {
    const k = pairKey(fk.src_table, fk.tgt_table);
    pairCount.set(k, (pairCount.get(k) || 0) + 1);
  }
  // A self-relation always needs an explicit name, however many there are.
  const needsName = (fk) =>
    fk.src_table === fk.tgt_table || pairCount.get(pairKey(fk.src_table, fk.tgt_table)) > 1;

  // ---- emit ----
  const parts = [HEADER, EXCLUSION_NOTE];

  for (const [name, labels] of [...enums].sort()) {
    parts.push(`enum ${pascal(name)} {\n${labels.map((l) => `  ${l}`).join('\n')}\n\n  @@map("${name}")\n}\n`);
  }

  for (const table of tables) {
    const cols = columns.get(table) || [];
    const lines = [];

    // Field names must be unique within a model, and a relation field must not
    // collide with the scalar FK column it uses -- e.g. approved_by yields the
    // scalar `approvedBy`, so its relation cannot also be `approvedBy`.
    const used = new Set(cols.map((c) => camel(c.column_name)));
    const claim = (base, fallback) => {
      let name = base;
      if (used.has(name)) name = `${base}${pascal(fallback)}`;
      let n = 2;
      while (used.has(name)) name = `${base}${pascal(fallback)}${n++}`;
      used.add(name);
      return name;
    };

    for (const col of cols) {
      let [type, native] = scalarType(col) || [null, null];
      if (!type) {
        if (enumNames.has(col.udt_name)) { type = pascal(col.udt_name); native = null; }
        else { lines.push(`  // ${col.column_name} ${col.udt_name} — unsupported by Prisma`); continue; }
      }
      const optional = col.is_nullable === 'YES' ? '?' : '';
      const attrs = [];
      if (pks.get(table)?.length === 1 && pks.get(table)[0] === col.column_name) attrs.push('@id');
      const def = defaultFor(col, enumNames);
      if (def) attrs.push(def);
      const fieldName = camel(col.column_name);
      if (fieldName !== col.column_name) attrs.push(`@map("${col.column_name}")`);
      if (native) attrs.push(native);
      lines.push(`  ${fieldName.padEnd(26)} ${(type + optional).padEnd(20)} ${attrs.join(' ')}`.trimEnd());
    }

    // ---- outgoing relations ----
    for (const fk of fks.filter((f) => f.src_table === table)) {
      const target = modelName(fk.tgt_table);
      const relName = needsName(fk) ? `, name: "${fk.conname}"` : '';
      const nullable = fk.src_cols.some(
        (c) => cols.find((x) => x.column_name === c)?.is_nullable === 'YES');
      const base = FIELD_OVERRIDES[fk.conname]
        ?? (fk.src_cols.length === 1
              ? camel(fk.src_cols[0].replace(/_id$/, ''))
              : camel(fk.tgt_table));
      const field = claim(base, fk.tgt_table);
      lines.push(
        `  ${field.padEnd(26)} ${(target + (nullable ? '?' : '')).padEnd(20)} ` +
        `@relation(fields: [${fk.src_cols.map(camel).join(', ')}], ` +
        `references: [${fk.tgt_cols.map(camel).join(', ')}]${relName}, ` +
        `onDelete: ${DEL[fk.on_delete] || 'NoAction'})`);
    }

    // ---- incoming relations (Prisma requires the opposite side to exist) ----
    for (const fk of fks.filter((f) => f.tgt_table === table)) {
      const src = modelName(fk.src_table);
      const named = needsName(fk);
      const relName = named ? ` @relation(name: "${fk.conname}")` : '';
      const selfRef = fk.src_table === fk.tgt_table;
      const base = selfRef
        ? camel(`${fk.src_cols[0].replace(/_id$/, '')}_of`)
        : (named ? camel(`${fk.src_table}_via_${fk.src_cols[0]}`) : camel(fk.src_table));
      const field = claim(base, `${fk.src_table}_ref`);
      lines.push(`  ${field.padEnd(26)} ${(src + '[]').padEnd(20)}${relName}`.trimEnd());
    }

    const blocks = [];
    const pk = pks.get(table) || [];
    if (pk.length > 1) blocks.push(`  @@id([${pk.map(camel).join(', ')}])`);
    for (const u of uqRows.filter((r) => r.table_name === table)) {
      blocks.push(`  @@unique([${u.cols.map(camel).join(', ')}], map: "${u.conname}")`);
    }
    blocks.push(`  @@map("${table}")`);

    parts.push(`model ${modelName(table)} {\n${lines.join('\n')}\n\n${blocks.join('\n')}\n}\n`);
  }

  const schema = parts.join('\n');
  await db.end();

  return {
    schema,
    stats: {
      models: tables.length,
      enums: enums.size,
      relations: fks.length,
      excluded: [...EXCLUDED_TABLES],
      generatedColumns: generated,
      sqlOnlyForeignKeys: skippedFks,
    },
  };
}



/* ═══════════════════════════════════════════════════════════════════════════
   Minimal Prisma datamodel parser.

   Deliberately NOT using @mrleebo/prisma-ast or typescript: `npm i typescript`
   now installs 7.x, which is the native port and exposes no JS compiler API, so
   any tool depending on it breaks on a fresh install. schema.prisma here is
   machine-generated in a known shape, so a line parser is exact and has no
   dependencies at all.
   ═══════════════════════════════════════════════════════════════════════════ */

function parseSchema(text) {
  const models = new Map();   // name -> { scalars:Set, relations:Map<field,model>, fields:[] }
  const enums = new Set();
  const modelNames = [];

  // First pass: collect model and enum names so relation targets can be resolved.
  for (const line of text.split('\n')) {
    const m = line.match(/^model\s+([A-Za-z_]\w*)\s*\{/);
    if (m) modelNames.push(m[1]);
    const e = line.match(/^enum\s+([A-Za-z_]\w*)\s*\{/);
    if (e) enums.add(e[1]);
  }
  const isModel = (n) => modelNames.includes(n);

  let current = null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    const open = line.match(/^model\s+([A-Za-z_]\w*)\s*\{/);
    if (open) {
      current = { name: open[1], scalars: new Set(), relations: new Map(), uniques: [], fields: [] };
      models.set(open[1], current);
      continue;
    }
    if (!current) continue;
    if (line === '}') { current = null; continue; }

    const uq = line.match(/^@@(unique|id)\(\[([^\]]+)\]/);
    if (uq) {
      current.uniques.push(uq[2].split(',').map((s) => s.trim()));
      continue;
    }
    if (line.startsWith('@@') || line.startsWith('//') || !line) continue;

    const f = line.match(/^([A-Za-z_]\w*)\s+([A-Za-z_]\w*)(\[\])?(\?)?/);
    if (!f) continue;
    const [, fieldName, typeName] = f;
    current.fields.push(fieldName);
    if (isModel(typeName)) current.relations.set(fieldName, typeName);
    else current.scalars.add(fieldName);
    if (/@id\b/.test(line) || /@unique\b/.test(line)) current.uniques.push([fieldName]);
  }

  return { models, enums, modelNames };
}

/* ═══════════════════════════════════════════════════════════════════════════
   Seed checker.

   Blanks out comments and string CONTENTS while preserving character positions,
   so brace matching and key detection cannot be confused by punctuation inside
   a string literal. Then every `prisma.<model>.<method>({...})` call has its
   object keys checked against THAT model — which is the check that matters,
   because a field name valid on one model is often invalid on another.
   ═══════════════════════════════════════════════════════════════════════════ */

const API_KEYS = new Set([
  'data', 'where', 'select', 'include', 'omit', 'orderBy', 'take', 'skip', 'cursor',
  'distinct', 'create', 'createMany', 'connect', 'connectOrCreate', 'disconnect',
  'update', 'updateMany', 'upsert', 'delete', 'deleteMany', 'set', 'push',
  'increment', 'decrement', 'multiply', 'divide', 'equals', 'not', 'in', 'notIn',
  'lt', 'lte', 'gt', 'gte', 'contains', 'startsWith', 'endsWith', 'mode',
  'some', 'every', 'none', 'is', 'isNot', 'AND', 'OR', 'NOT', 'skipDuplicates',
  '_count', '_sum', '_avg', '_min', '_max', 'by', 'having',
]);

const METHODS = new Set([
  'create', 'createMany', 'createManyAndReturn', 'update', 'updateMany', 'upsert',
  'delete', 'deleteMany', 'findFirst', 'findFirstOrThrow', 'findUnique',
  'findUniqueOrThrow', 'findMany', 'count', 'aggregate', 'groupBy',
]);

/** Replaces comment and string contents with spaces, keeping length identical. */
function blankNoise(src) {
  const out = src.split('');
  let i = 0;
  const blank = (from, to) => { for (let k = from; k < to && k < out.length; k++) if (out[k] !== '\n') out[k] = ' '; };

  while (i < src.length) {
    const c = src[i], d = src[i + 1];
    if (c === '/' && d === '/') { let j = src.indexOf('\n', i); if (j < 0) j = src.length; blank(i, j); i = j; continue; }
    if (c === '/' && d === '*') { const j = src.indexOf('*/', i + 2); const end = j < 0 ? src.length : j + 2; blank(i, end); i = end; continue; }
    if (c === '"' || c === "'" || c === '`') {
      let j = i + 1;
      while (j < src.length) {
        if (src[j] === '\\') { j += 2; continue; }
        if (src[j] === c) break;
        j++;
      }
      blank(i + 1, j);           // keep the quotes, blank the contents
      i = j + 1; continue;
    }
    i++;
  }
  return out.join('');
}

function matchBrace(s, open) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === '{' || s[i] === '[' || s[i] === '(') depth++;
    else if (s[i] === '}' || s[i] === ']' || s[i] === ')') { depth--; if (depth === 0) return i; }
  }
  return -1;
}

function checkSeed(seedText, schema, file, problems) {
  const s = blankNoise(seedText);
  const lineAt = (idx) => seedText.slice(0, idx).split('\n').length;

  /** Iterates the top-level `key:` pairs of the object spanning [open, close]. */
  function eachKey(open, close, visit) {
    let depth = 0;
    for (let i = open + 1; i < close; i++) {
      const c = s[i];
      if (c === '{' || c === '[' || c === '(') { depth++; continue; }
      if (c === '}' || c === ']' || c === ')') { depth--; continue; }
      if (depth !== 0) continue;

      // spread: ...(cond ? { a: 1 } : {})  -> same model context
      if (c === '.' && s[i + 1] === '.' && s[i + 2] === '.') {
        const stop = (() => { // end of this spread element
          let d = 0;
          for (let k = i; k < close; k++) {
            if ('{[('.includes(s[k])) d++;
            else if ('}])'.includes(s[k])) d--;
            else if (s[k] === ',' && d === 0) return k;
          }
          return close;
        })();
        visit(null, i, stop);
        i = stop;
        continue;
      }

      const m = /^([A-Za-z_$][\w$]*)\s*:/.exec(s.slice(i, close));
      if (m && (i === open + 1 || /[\s,{]/.test(s[i - 1]))) {
        const valueStart = i + m[0].length;
        visit(m[1], valueStart, close);
        i = valueStart;
      }
    }
  }

  function checkObject(open, close, model) {
    eachKey(open, close, (key, valueStart, limit) => {
      if (key === null) {                       // spread — same model
        let b = valueStart;
        while (b < limit && s[b] !== '{') b++;
        if (b < limit) {
          let cursor = b;
          while (cursor < limit && s[cursor] === '{') {
            const end = matchBrace(s, cursor);
            if (end < 0 || end > limit) break;
            checkObject(cursor, end, model);
            cursor = end + 1;
            while (cursor < limit && /[\s?:]/.test(s[cursor])) cursor++;
          }
        }
        return;
      }

      const descend = (nextModel) => {
        let b = valueStart;
        while (b < limit && /\s/.test(s[b])) b++;
        if (s[b] === '{') { const e = matchBrace(s, b); if (e > 0) checkObject(b, e, nextModel); return; }
        if (s[b] === '[') {
          const e = matchBrace(s, b);
          let cursor = b + 1;
          while (cursor < e) {
            if (s[cursor] === '{') { const oe = matchBrace(s, cursor); if (oe < 0) break; checkObject(cursor, oe, nextModel); cursor = oe + 1; }
            else cursor++;
          }
        }
      };

      if (API_KEYS.has(key)) return descend(model);
      if (model.scalars.has(key)) return;
      const rel = model.relations.get(key);
      if (rel) return descend(schema.models.get(rel));
      problems.push(`${file}:${lineAt(seedText.length - (s.length - valueStart))}: "${key}" is not a field on model ${model.name}`);
    });
  }

  const callRe = /\b(?:prisma|tx)\.([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)\s*\(/g;
  let hit;
  while ((hit = callRe.exec(s)) !== null) {
    const [, accessor, method] = hit;
    if (!METHODS.has(method)) continue;
    const modelName = accessor.charAt(0).toUpperCase() + accessor.slice(1);
    const model = schema.models.get(modelName);
    if (!model) {
      problems.push(`${file}:${lineAt(hit.index)}: "${accessor}" is not a model in the datamodel`);
      continue;
    }
    let b = hit.index + hit[0].length;
    while (b < s.length && /\s/.test(s[b])) b++;
    if (s[b] !== '{') continue;                 // e.g. deleteMany() with no args
    const end = matchBrace(s, b);
    if (end > 0) checkObject(b, end, model);
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   Structural datamodel validation
   ═══════════════════════════════════════════════════════════════════════════ */

function validateSchema(text, problems) {
  const schema = parseSchema(text);
  const relSides = new Map();
  const pairs = new Map();

  for (const [name, model] of schema.models) {
    const seen = new Set();
    for (const f of model.fields) {
      if (seen.has(f)) problems.push(`${name}.${f}: duplicate field name`);
      seen.add(f);
    }
  }

  const lines = text.split('\n');
  let currentModel = null;
  for (const raw of lines) {
    const line = raw.trim();
    const open = line.match(/^model\s+([A-Za-z_]\w*)\s*\{/);
    if (open) { currentModel = open[1]; continue; }
    if (line === '}') { currentModel = null; continue; }
    if (!currentModel) continue;

    const f = line.match(/^([A-Za-z_]\w*)\s+([A-Za-z_]\w*)(\[\])?(\?)?/);
    if (!f) continue;
    const [, field, type] = f;
    if (!schema.models.has(type)) continue;

    const named = line.match(/name:\s*"([^"]+)"/);
    if (named) {
      if (!relSides.has(named[1])) relSides.set(named[1], []);
      relSides.get(named[1]).push(`${currentModel}.${field}`);
    }
    const key = [currentModel, type].sort().join('~');
    if (!pairs.has(key)) pairs.set(key, []);
    pairs.get(key).push({ named: !!named, model: currentModel, type });

    // referenced fields must be uniquely constrained on the target
    const refs = line.match(/references:\s*\[([^\]]+)\]/);
    if (refs) {
      const cols = refs[1].split(',').map((x) => x.trim());
      const target = schema.models.get(type);
      const ok = target.uniques.some(
        (u) => u.length === cols.length && u.every((c) => cols.includes(c)));
      if (!ok) {
        problems.push(`${currentModel}.${field}: references [${cols.join(', ')}] on ${type}, ` +
                      'which has no matching @id/@unique/@@unique');
      }
      for (const c of cols) {
        if (!target.fields.includes(c)) {
          problems.push(`${currentModel}.${field}: referenced field "${type}.${c}" does not exist`);
        }
      }
    }
  }

  for (const [rel, sides] of relSides) {
    if (sides.length !== 2) {
      problems.push(`relation "${rel}" has ${sides.length} side(s), expected 2 (${sides.join(', ')})`);
    }
  }
  for (const [key, list] of pairs) {
    const [a, b] = key.split('~');
    if (a === b && list.some((x) => !x.named)) problems.push(`self-relation on ${a} must be named`);
    else if (list.length > 2 && list.some((x) => !x.named)) {
      problems.push(`multiple relations between ${a} and ${b} but some are unnamed`);
    }
  }

  return { schema, relations: relSides.size };
}

/* ═══════════════════════════════════════════════════════════════════════════
   CLI
   ═══════════════════════════════════════════════════════════════════════════ */

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const SCHEMA_PATH = path.join(ROOT, 'prisma', 'schema.prisma');
const SEED_PATH = path.join(ROOT, 'prisma', 'seed.ts');

async function cmdGenerate() {
  const { schema, stats } = await buildSchema();
  fs.writeFileSync(SCHEMA_PATH, schema);
  console.log(`wrote ${path.relative(process.cwd(), SCHEMA_PATH)}`);
  console.log(`  models:                    ${stats.models}`);
  console.log(`  enums:                     ${stats.enums}`);
  console.log(`  relations:                 ${stats.relations}`);
  console.log(`  excluded tables:           ${stats.excluded.join(', ')} (+ partitions)`);
  console.log(`  generated columns omitted: ${stats.generatedColumns.join(', ') || 'none'}`);
  console.log(`  SQL-only foreign keys:     ${stats.sqlOnlyForeignKeys.join(', ') || 'none'}`);
}

async function cmdCheck() {
  const problems = [];
  const notes = [];

  if (!fs.existsSync(SCHEMA_PATH)) {
    console.error(`missing ${SCHEMA_PATH} — run: node tools/db-tools.cjs generate`);
    process.exit(1);
  }
  const committed = fs.readFileSync(SCHEMA_PATH, 'utf8');

  const { schema, relations } = validateSchema(committed, problems);
  notes.push(`${schema.models.size} models, ${schema.enums.size} enums, ${relations} named relations`);

  if (process.env.DATABASE_URL) {
    const { schema: regenerated } = await buildSchema();
    if (regenerated !== committed) {
      problems.push('schema.prisma differs from the database — it was hand-edited, or a ' +
                    'migration has not been applied. Run: node tools/db-tools.cjs generate');
      const a = committed.split('\n'), b = regenerated.split('\n');
      for (let i = 0; i < Math.max(a.length, b.length); i++) {
        if (a[i] !== b[i]) {
          console.error(`  first difference at line ${i + 1}:`);
          console.error(`    committed:   ${a[i] ?? '(end of file)'}`);
          console.error(`    regenerated: ${b[i] ?? '(end of file)'}`);
          break;
        }
      }
    } else {
      notes.push('no drift: schema.prisma matches the live database exactly');
    }
  } else {
    notes.push('drift check skipped (DATABASE_URL not set)');
  }

  if (fs.existsSync(SEED_PATH)) {
    checkSeed(fs.readFileSync(SEED_PATH, 'utf8'), schema, 'prisma/seed.ts', problems);
    notes.push('seed.ts model accessors and data keys resolve');
  }

  console.log('\ndatabase layer check');
  for (const n of notes) console.log(`  ok    ${n}`);
  for (const p of problems) console.log(`  FAIL  ${p}`);
  console.log(problems.length ? `\n${problems.length} problem(s)\n` : '\nall checks passed\n');
  process.exit(problems.length ? 1 : 0);
}

const command = process.argv[2] || 'check';

(async () => {
  if (command === 'generate') await cmdGenerate();
  else if (command === 'check') await cmdCheck();
  else {
    console.error('usage: node tools/db-tools.cjs [generate|check]');
    console.error('  generate  rewrite prisma/schema.prisma from the live database');
    console.error('  check     validate the datamodel, drift, and seed.ts (default)');
    process.exit(2);
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
`````

## `tools/prisma-guard.cjs`

`````javascript
/**
 * Wraps the Prisma CLI and refuses the commands that would author their own DDL.
 *
 * `prisma migrate dev` and `prisma db push` both diff the datamodel against the
 * database and generate SQL to reconcile them. Because schema.prisma cannot
 * express partial unique indexes, the generated column inside the ownership
 * foreign key, partitioning, RLS policies, or column grants, either command
 * would silently DROP those constructs — removing the security controls that
 * Step 3 verifies.
 *
 * A comment asking people not to do this is not a control. This is.
 */
const { spawnSync } = require("node:child_process");

const argv = process.argv.slice(2);
const joined = argv.join(' ');

const BLOCKED = [
  { pattern: /^migrate\s+dev/,   reason: 'authors its own migration SQL from the datamodel' },
  { pattern: /^migrate\s+reset/, reason: 'drops the database, including RLS policies and grants' },
  { pattern: /^db\s+push/,       reason: 'reconciles the database to the datamodel, dropping SQL-only constructs' },
  { pattern: /^migrate\s+diff.*--script.*--to-schema-datamodel/,
    reason: 'would emit DDL that drops SQL-only constructs; use --to-url for inspection only' },
];

for (const { pattern, reason } of BLOCKED) {
  if (pattern.test(joined)) {
    console.error(`\nRefusing to run: prisma ${joined}`);
    console.error(`Reason: it ${reason}.\n`);
    console.error('Schema changes in this project go in a new SQL migration:');
    console.error('  1. add prisma/migrations/<timestamp>_<name>/migration.sql');
    console.error('  2. npm run db:migrate            (prisma migrate deploy)');
    console.error('  3. npm run prisma:generate-schema');
    console.error('  4. npm run check                 (drift + seed verification)\n');
    process.exit(1);
  }
}

const r = spawnSync('prisma', argv, { stdio: 'inherit', shell: false });
process.exit(r.status ?? 1);
`````
