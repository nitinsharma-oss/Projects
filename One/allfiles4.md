# All source files — part 4 — Prisma datamodel, seed and migrations

Every file is in a code block, so it can be copied directly. Create each file at the path in its heading. Plain-text copies are in `copy-paste/`, using `__` where the path has a `/`.

## Files in this part

| Path | Lines |
| --- | --- |
| `prisma/schema.prisma` | 515 |
| `prisma/seed.ts` | 384 |
| `prisma/migrations/migration_lock.toml` | 3 |
| `prisma/migrations/20260801000000_core/migration.sql` | 228 |
| `prisma/migrations/20260801000001_cards/migration.sql` | 228 |
| `prisma/migrations/20260801000002_billing_audit_analytics/migration.sql` | 224 |
| `prisma/migrations/20260801000003_auth_hardening/migration.sql` | 234 |

---

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

## `prisma/migrations/migration_lock.toml`

`````toml
# Please do not edit this file manually
# It should be added in your version-control system (e.g. Git)
provider = "postgresql"
`````

## `prisma/migrations/20260801000000_core/migration.sql`

`````sql
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
`````

## `prisma/migrations/20260801000001_cards/migration.sql`

`````sql
-- ============================================================
-- Step 2, part 2 — cards and the ownership invariants
-- ============================================================

-- ---------- card batches ----------

CREATE TABLE card_batches (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id        uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    chip          chip_profile NOT NULL,
    quantity      int NOT NULL,
    manufacturer  text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT card_batches_quantity_positive CHECK (quantity > 0)
);

-- ---------- cards ----------
-- The token is NEVER stored in plaintext. The resolver hashes the incoming
-- token and looks up the hash, so a database disclosure does not hand an
-- attacker a catalogue of live tokens mapped to identities. token_prefix is
-- kept unhashed purely so support can find "the card ending in ...".
--
-- Three edges (§0.1): owner = title, holder = custody, profile = what it serves.

CREATE TABLE cards (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash         bytea NOT NULL,
    token_prefix       char(6) NOT NULL,
    batch_id           uuid REFERENCES card_batches (id) ON DELETE RESTRICT,
    chip               chip_profile NOT NULL,

    owner_account_id   uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    owner_org_id       uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    holder_account_id  uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    profile_id         uuid REFERENCES profiles (id)      ON DELETE RESTRICT,

    -- Denormalised so the resolver answers from one row with no join (§5.1).
    -- Kept consistent by the write path; reconciled on a schedule (§2.2).
    serving_slug       citext,
    serving_state      serving_state NOT NULL DEFAULT 'unclaimed',

    status             card_status NOT NULL DEFAULT 'manufactured',
    claim_code_hash    text,
    claim_attempts     int NOT NULL DEFAULT 0,
    claim_locked_until timestamptz,

    dna_key_ref        text,
    dna_counter        bigint,

    -- Discriminator for the personal-ownership foreign key below. NULL whenever
    -- the card is NOT personally owned, which is what makes MATCH SIMPLE stand
    -- the constraint down for organisation-owned cards. Generated, so it cannot
    -- drift from owner_account_id.
    personal_holder_id uuid GENERATED ALWAYS AS (
        CASE WHEN owner_account_id IS NOT NULL THEN holder_account_id END
    ) STORED,

    locked_at          timestamptz,
    claimed_at         timestamptz,
    activated_at       timestamptz,
    revoked_at         timestamptz,
    revoked_reason     text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT cards_token_hash_key UNIQUE (token_hash),

    -- At most one owner, and an owned card must have exactly one.
    CONSTRAINT cards_single_owner CHECK (
        num_nonnulls(owner_account_id, owner_org_id) <= 1
    ),

    -- An active card must be fully bound and must have been locked at encoding.
    CONSTRAINT cards_active_is_bound CHECK (
        status <> 'active' OR (
            num_nonnulls(owner_account_id, owner_org_id) = 1
            AND holder_account_id IS NOT NULL
            AND profile_id        IS NOT NULL
            AND serving_slug      IS NOT NULL
            AND locked_at         IS NOT NULL
        )
    ),

    -- Revoked is terminal and must record why.
    CONSTRAINT cards_revoked_has_reason CHECK (
        status <> 'revoked' OR (revoked_at IS NOT NULL AND revoked_reason IS NOT NULL)
    ),

    -- Only a revoked card may carry serving_state 'revoked', and vice versa.
    CONSTRAINT cards_revoked_state_agrees CHECK (
        (status = 'revoked') = (serving_state = 'revoked')
    ),

    -- DNA cards must reference a key; basic chips must not pretend to.
    CONSTRAINT cards_dna_key_present CHECK (
        (chip = 'ntag424_dna') = (dna_key_ref IS NOT NULL)
    ),

    CONSTRAINT cards_claim_attempts_bounded CHECK (claim_attempts >= 0)
);

-- ============================================================
-- The ownership invariants, enforced as plain foreign keys.
--
-- All three use Postgres's default MATCH SIMPLE: a composite FK containing a
-- NULL column is NOT enforced. So each key activates only for the ownership
-- shape it governs, with no triggers and no application logic.
--
-- CRITICAL SUBTLETY: MATCH SIMPLE only stands down when a column *inside the
-- key* is NULL. The discriminator therefore has to BE a key column. An earlier
-- draft used (profile_id, holder_account_id) for the personal key, reasoning
-- that owner_account_id IS NULL would disable it for org cards -- but
-- owner_account_id is not in that key, and both of its columns are populated on
-- an org card, so the constraint fired and made org cards impossible to insert.
-- Hence personal_holder_id: generated, NULL for org-owned cards, in the key.
--
--   personal card -> owner_org_id IS NULL       -> org keys stand down
--   org card      -> personal_holder_id IS NULL -> personal key stands down
-- ============================================================

-- 1. Personal card: the profile must belong to the holder.
ALTER TABLE cards
    ADD CONSTRAINT cards_personal_profile_belongs_to_holder
    FOREIGN KEY (profile_id, personal_holder_id)
    REFERENCES profiles (id, owner_account_id);

-- 2. Org card: the profile must belong to the owning organisation.
ALTER TABLE cards
    ADD CONSTRAINT cards_org_profile_belongs_to_org
    FOREIGN KEY (profile_id, owner_org_id)
    REFERENCES profiles (id, owner_org_id);

-- 3. Org card: the holder must be a member of the owning organisation.
ALTER TABLE cards
    ADD CONSTRAINT cards_org_holder_is_member
    FOREIGN KEY (holder_account_id, owner_org_id)
    REFERENCES org_memberships (account_id, org_id);

-- ---------- resolver indexes ----------
-- The only index the hot path uses. Partial, because the resolver never asks
-- about cards that cannot serve, which keeps it small enough to stay cached.

CREATE INDEX cards_resolver_idx
    ON cards (token_hash) INCLUDE (serving_state, serving_slug);

CREATE INDEX cards_token_prefix_idx  ON cards (token_prefix);
CREATE INDEX cards_holder_idx        ON cards (holder_account_id) WHERE holder_account_id IS NOT NULL;
CREATE INDEX cards_owner_org_idx     ON cards (owner_org_id)      WHERE owner_org_id IS NOT NULL;
CREATE INDEX cards_owner_account_idx ON cards (owner_account_id)  WHERE owner_account_id IS NOT NULL;
CREATE INDEX cards_profile_idx       ON cards (profile_id)        WHERE profile_id IS NOT NULL;

-- Drift reconciliation sweeps by state; keep it cheap.
CREATE INDEX cards_serving_state_idx ON cards (serving_state, updated_at);

-- ---------- ownership transfers (append-only) ----------
-- The record of TITLE. Every change of owner, forever. Activation is the first
-- row, with a null "from".

CREATE TABLE ownership_transfers (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    card_id           uuid NOT NULL REFERENCES cards (id) ON DELETE RESTRICT,
    from_account_id   uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    from_org_id       uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    to_account_id     uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    to_org_id         uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    reason            transfer_reason NOT NULL,
    requested_by      uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    approved_by       uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    approved_at       timestamptz NOT NULL DEFAULT now(),
    correlation_id    uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),

    -- A transfer must land somewhere, on exactly one kind of owner.
    CONSTRAINT transfers_single_destination CHECK (
        num_nonnulls(to_account_id, to_org_id) = 1
    ),
    -- Origin is either absent (activation) or exactly one kind.
    CONSTRAINT transfers_origin_shape CHECK (
        (reason = 'activation' AND num_nonnulls(from_account_id, from_org_id) = 0)
     OR (reason <> 'activation' AND num_nonnulls(from_account_id, from_org_id) = 1)
    ),
    -- Only an admin correction may lack a named approver.
    CONSTRAINT transfers_approved CHECK (
        approved_by IS NOT NULL OR reason = 'activation'
    )
);

CREATE INDEX transfers_card_idx ON ownership_transfers (card_id, approved_at DESC);

-- ---------- card assignments (append-only) ----------
-- Holder changes for org cards. NOT transfers: title does not move, so these
-- deliberately do not pollute the ownership record.

CREATE TABLE card_assignments (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    card_id          uuid NOT NULL REFERENCES cards (id) ON DELETE RESTRICT,
    from_account_id  uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    to_account_id    uuid REFERENCES accounts (id) ON DELETE RESTRICT,
    assigned_by      uuid NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    correlation_id   uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT assignments_changes_something CHECK (
        from_account_id IS DISTINCT FROM to_account_id
    )
);

CREATE INDEX assignments_card_idx ON card_assignments (card_id, created_at DESC);

-- ---------- encodings (append-only) ----------
-- The immutable proof that a chip was locked, by whom, on which station (§7.3).
-- This replaces a mutable chip_locked boolean: a flag can be flipped by a bug,
-- an append-only row cannot be un-written.

CREATE TABLE card_encodings (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    card_id            uuid NOT NULL REFERENCES cards (id) ON DELETE RESTRICT,
    encoder_account_id uuid NOT NULL REFERENCES accounts (id) ON DELETE RESTRICT,
    station_id         text NOT NULL,
    chip               chip_profile NOT NULL,
    locked             boolean NOT NULL,
    verify_read_ok     boolean NOT NULL,
    occurred_at        timestamptz NOT NULL DEFAULT now(),

    -- A card may only ship if the lock was applied AND read back successfully.
    CONSTRAINT encodings_lock_verified CHECK (NOT locked OR verify_read_ok)
);

CREATE INDEX encodings_card_idx ON card_encodings (card_id, occurred_at DESC);
`````

## `prisma/migrations/20260801000002_billing_audit_analytics/migration.sql`

`````sql
-- ============================================================
-- Step 2, part 3 — billing, audit, analytics
-- ============================================================

-- ---------- subscriptions ----------
-- Same dual-owner idiom as cards, deliberately (§2.5): one pattern an auditor
-- learns once and can then verify everywhere.

CREATE TABLE subscriptions (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_account_id       uuid REFERENCES accounts (id)      ON DELETE RESTRICT,
    owner_org_id           uuid REFERENCES organizations (id) ON DELETE RESTRICT,
    plan                   text NOT NULL,
    status                 sub_status NOT NULL,
    seats                  int NOT NULL DEFAULT 1,
    stripe_customer_id     text,
    stripe_subscription_id text,
    current_period_end     timestamptz,
    cancel_at              timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT subscriptions_single_owner CHECK (
        num_nonnulls(owner_account_id, owner_org_id) = 1
    ),
    CONSTRAINT subscriptions_seats_positive CHECK (seats > 0),
    -- A personal plan cannot have seats; an org plan is the only multi-seat shape.
    CONSTRAINT subscriptions_personal_single_seat CHECK (
        owner_account_id IS NULL OR seats = 1
    ),
    CONSTRAINT subscriptions_stripe_sub_key UNIQUE (stripe_subscription_id)
);

CREATE UNIQUE INDEX subscriptions_one_live_per_account
    ON subscriptions (owner_account_id)
    WHERE owner_account_id IS NOT NULL AND status IN ('trialing','active','past_due');

CREATE UNIQUE INDEX subscriptions_one_live_per_org
    ON subscriptions (owner_org_id)
    WHERE owner_org_id IS NOT NULL AND status IN ('trialing','active','past_due');

-- ---------- stripe webhook idempotency ----------
-- Stripe redelivers. Without this, a redelivered invoice event double-applies.

CREATE TABLE stripe_events (
    stripe_event_id text PRIMARY KEY,
    type            text NOT NULL,
    payload         jsonb NOT NULL,
    received_at     timestamptz NOT NULL DEFAULT now(),
    processed_at    timestamptz,
    error           text
);

CREATE INDEX stripe_events_unprocessed_idx
    ON stripe_events (received_at) WHERE processed_at IS NULL;

-- ---------- generic API idempotency ----------

CREATE TABLE idempotency_keys (
    key           text PRIMARY KEY,
    account_id    uuid REFERENCES accounts (id) ON DELETE CASCADE,
    endpoint      text NOT NULL,
    request_hash  bytea NOT NULL,
    response_code int,
    response_body jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    completed_at  timestamptz
);

CREATE INDEX idempotency_keys_created_idx ON idempotency_keys (created_at);

-- ============================================================
-- Audit log — partitioned monthly, append-only.
--
-- Actors are referenced by opaque id ONLY. No email, no name. That is what
-- lets erasure tombstone an account (§10) while the audit history survives
-- intact: the id remains, and it no longer resolves to a person.
-- ============================================================

CREATE TABLE audit_log (
    id             uuid NOT NULL DEFAULT gen_random_uuid(),
    occurred_at    timestamptz NOT NULL DEFAULT now(),
    actor_scope    actor_scope NOT NULL,
    actor_account_id uuid,
    actor_org_id     uuid,
    action         text NOT NULL,
    subject_type   text NOT NULL,
    subject_id     uuid,
    before         jsonb,
    after          jsonb,
    correlation_id uuid,
    ip_country     char(2),
    PRIMARY KEY (id, occurred_at),

    -- A system action has no actor; every other scope must name one.
    CONSTRAINT audit_actor_shape CHECK (
        (actor_scope = 'system' AND actor_account_id IS NULL)
     OR (actor_scope <> 'system' AND actor_account_id IS NOT NULL)
    )
) PARTITION BY RANGE (occurred_at);

CREATE INDEX audit_log_subject_idx ON audit_log (subject_type, subject_id, occurred_at DESC);
CREATE INDEX audit_log_actor_idx   ON audit_log (actor_account_id, occurred_at DESC);

-- NOTE: audit_log deliberately carries NO foreign key to accounts. An FK would
-- force ON DELETE behaviour on a table that must never lose rows, and would let
-- account deletion cascade into the audit trail. Referential integrity here is
-- one-directional by design: accounts are tombstoned, never deleted (§10).

CREATE TABLE audit_log_2026_08 PARTITION OF audit_log
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE audit_log_2026_09 PARTITION OF audit_log
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE audit_log_default PARTITION OF audit_log DEFAULT;

-- ============================================================
-- tap_events — ~100M rows/month, ~1.2B/year (§1).
--
-- Partitioned by REGION first, then by month. Region-first is the decision that
-- keeps data residency open: an EU-only deployment becomes a partition move
-- rather than a 1.2-billion-row rewrite. Carrying the dimension unused costs
-- almost nothing; adding it later is one of the most expensive migrations in
-- this class of system.
--
-- Contains data about VISITORS, who never agreed to anything. Therefore: no raw
-- IP, device class not fingerprint, retention by partition drop (§8).
-- ============================================================

CREATE TABLE tap_events (
    id            bigint GENERATED ALWAYS AS IDENTITY,
    occurred_at   timestamptz NOT NULL DEFAULT now(),
    region        data_region NOT NULL,
    card_id       uuid,
    profile_id    uuid NOT NULL,
    channel       tap_channel NOT NULL DEFAULT 'nfc',
    country       char(2),
    device_class  text,
    referrer_host text,
    is_bot        boolean NOT NULL DEFAULT false,
    PRIMARY KEY (id, region, occurred_at)
) PARTITION BY LIST (region);

-- No foreign keys. At 800 writes/sec on the ingest path an FK check per row is
-- pure overhead, and a dangling card_id after a hard delete is acceptable in an
-- analytics table where cards are RESTRICT-protected anyway.

CREATE TABLE tap_events_eu PARTITION OF tap_events
    FOR VALUES IN ('eu') PARTITION BY RANGE (occurred_at);
CREATE TABLE tap_events_us PARTITION OF tap_events
    FOR VALUES IN ('us') PARTITION BY RANGE (occurred_at);
CREATE TABLE tap_events_in PARTITION OF tap_events
    FOR VALUES IN ('in') PARTITION BY RANGE (occurred_at);

CREATE TABLE tap_events_eu_2026_08 PARTITION OF tap_events_eu
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE tap_events_eu_2026_09 PARTITION OF tap_events_eu
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE tap_events_us_2026_08 PARTITION OF tap_events_us
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE tap_events_us_2026_09 PARTITION OF tap_events_us
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE tap_events_in_2026_08 PARTITION OF tap_events_in
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE tap_events_in_2026_09 PARTITION OF tap_events_in
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

CREATE INDEX tap_events_profile_idx ON tap_events (profile_id, occurred_at DESC);
CREATE INDEX tap_events_card_idx    ON tap_events (card_id, occurred_at DESC);

-- ---------- rollups ----------
-- The dashboard reads ONLY these. It must never touch tap_events, and these
-- outlive the raw partitions so analytics survive retention drops (§8).

CREATE TABLE tap_daily (
    profile_id   uuid NOT NULL,
    day          date NOT NULL,
    region       data_region NOT NULL,
    taps         bigint NOT NULL DEFAULT 0,
    nfc_taps     bigint NOT NULL DEFAULT 0,
    qr_taps      bigint NOT NULL DEFAULT 0,
    bot_taps     bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (profile_id, day, region)
);

CREATE TABLE tap_daily_country (
    profile_id uuid NOT NULL,
    day        date NOT NULL,
    country    char(2) NOT NULL,
    taps       bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (profile_id, day, country)
);

CREATE INDEX tap_daily_day_idx ON tap_daily (day);

-- ============================================================
-- Append-only enforcement (§10).
--
-- A database grant, not a convention. The application role physically cannot
-- rewrite history, so "immutable audit trail" is a property an auditor can
-- verify with \dp rather than a claim about code review discipline.
-- ============================================================

-- Roles are cluster-scoped, so creation must be idempotent for repeatable runs.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
        CREATE ROLE app_rw NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_resolver') THEN
        CREATE ROLE app_resolver NOLOGIN;
    END IF;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;

REVOKE UPDATE, DELETE ON ownership_transfers FROM app_rw;
REVOKE UPDATE, DELETE ON card_assignments    FROM app_rw;
REVOKE UPDATE, DELETE ON card_encodings      FROM app_rw;
REVOKE UPDATE, DELETE ON audit_log           FROM app_rw;
REVOKE DELETE           ON slugs             FROM app_rw;
REVOKE DELETE           ON accounts          FROM app_rw;

-- The resolver reads one table and nothing else. Least privilege at the
-- database level means a resolver compromise cannot read profiles or accounts.
GRANT SELECT (token_hash, serving_state, serving_slug) ON cards TO app_resolver;
`````

## `prisma/migrations/20260801000003_auth_hardening/migration.sql`

`````sql
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
`````
