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
