# All source files — part 1 — application source (src/)

Every file is in a code block, so it can be copied directly. Create each file at the path in its heading. Plain-text copies are in `copy-paste/`, using `__` where the path has a `/`.

## Quick start

```bash
npm install
cp .env.example .env                     # then edit DATABASE_URL

export DATABASE_URL="postgresql://user:pass@localhost:5432/nfc?schema=public"
npm run db:migrate                       # applies the 4 SQL migrations
node tools/db-tools.cjs check            # datamodel + drift + seed

npm run test:unit                        # no database needed
npm test                                 # full suite (58 assertions)
npm run start:resolver
```

## Never run these

`prisma migrate dev` · `prisma migrate reset` · `prisma db push`

Each reconciles the database *to* the datamodel, dropping the partial unique
indexes, the generated column inside the ownership foreign key, the partitioning,
the 16 RLS policies, and the resolver's column grants. `tools/prisma-guard.cjs`
refuses them.

## Files in this part

| Path | Lines |
| --- | --- |
| `src/config.ts` | 84 |
| `src/db/pools.ts` | 33 |
| `src/db/with-account.ts` | 64 |
| `src/resolver/cache.ts` | 84 |
| `src/resolver/events.ts` | 73 |
| `src/resolver/http.ts` | 142 |
| `src/resolver/main.ts` | 61 |
| `src/resolver/service.ts` | 58 |
| `src/resolver/token.ts` | 32 |
| `src/validation.ts` | 149 |

---

## `src/config.ts`

`````typescript
/**
 * Environment configuration, validated once at boot.
 *
 * Fails loudly and immediately on a missing or malformed value rather than at the
 * first request that needs it. A service that starts with a broken configuration
 * and fails later is harder to diagnose than one that never starts.
 */

function required(name: string): string {
  const v = process.env[name];
  if (!v || !v.trim()) throw new Error(`Missing required environment variable: ${name}`);
  return v;
}

function optionalInt(name: string, fallback: number): number {
  const v = process.env[name];
  if (v === undefined || v === '') return fallback;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
  return n;
}

function url(name: string, value: string): string {
  let parsed: URL;
  try { parsed = new URL(value); } catch { throw new Error(`${name} is not a valid URL: ${value}`); }
  if (parsed.protocol !== 'https:' && parsed.hostname !== 'localhost' && parsed.hostname !== '127.0.0.1') {
    throw new Error(`${name} must be https outside local development`);
  }
  return value.replace(/\/$/, '');
}

export const config = {
  /** app_rw — RLS applies, append-only tables reject UPDATE/DELETE. */
  databaseUrl: () => required('DATABASE_URL'),

  /** app_resolver — column-level SELECT on three columns of cards (ADR-0001). */
  resolverDatabaseUrl: () => process.env.RESOLVER_DATABASE_URL ?? required('DATABASE_URL'),

  /**
   * Where tap URLs point. Step 3 §4 requires this to be a DIFFERENT REGISTRABLE
   * DOMAIN from the dashboard so stored XSS in profile content cannot reach
   * dashboard cookies. Enforced at boot below.
   */
  tapBaseUrl: () => url('TAP_BASE_URL', required('TAP_BASE_URL')),
  appBaseUrl: () => url('APP_BASE_URL', required('APP_BASE_URL')),

  resolverPort: () => optionalInt('RESOLVER_PORT', 3001),

  /** Positive cache TTL. Short, because revocation must take effect quickly. */
  cacheTtlMs: () => optionalInt('RESOLVER_CACHE_TTL_MS', 60_000),

  /**
   * Negative cache TTL (Step 3 §5.3). Shorter than positive, so a newly
   * provisioned token cannot 404 for long if its purge is ever missed.
   */
  negativeCacheTtlMs: () => optionalInt('RESOLVER_NEGATIVE_CACHE_TTL_MS', 10_000),

  cacheMaxEntries: () => optionalInt('RESOLVER_CACHE_MAX_ENTRIES', 100_000),

  /** Event buffer. A full buffer DROPS events — Step 1 §5.5. */
  eventBufferSize: () => optionalInt('RESOLVER_EVENT_BUFFER', 10_000),
  eventFlushMs: () => optionalInt('RESOLVER_EVENT_FLUSH_MS', 1_000),
};

/**
 * Step 3 §4: profile pages must not share a registrable domain with the dashboard.
 * Compared on the last two labels, which is a deliberate approximation — it
 * catches the mistake that matters (app.example.com vs example.com/u) without
 * bundling a public-suffix list. Multi-part TLDs such as .co.uk need the
 * override, and the error message says so.
 */
export function assertOriginSeparation(tapUrl: string, appUrl: string): void {
  if (process.env.ALLOW_SHARED_ORIGIN === '1') return;
  const registrable = (u: string) => new URL(u).hostname.split('.').slice(-2).join('.');
  const tap = registrable(tapUrl);
  const app = registrable(appUrl);
  if (tap === app) {
    throw new Error(
      `TAP_BASE_URL and APP_BASE_URL share the registrable domain "${tap}". ` +
      'Step 3 §4 requires separate registrable domains so stored XSS in profile ' +
      'content cannot reach dashboard cookies. Set ALLOW_SHARED_ORIGIN=1 only if ' +
      'this is a false positive from a multi-part TLD.');
  }
}
`````

## `src/db/pools.ts`

`````typescript
/**
 * Connection pools, one per database role.
 *
 * Each service connects as a login user that INHERITS one of the privilege roles
 * from Step 3 (app_rw, app_resolver, app_admin, app_auth). The privilege roles
 * are NOLOGIN by design: privileges are granted to them, and login users are
 * granted membership. Credential rotation stays independent of the privilege
 * model.
 */

import { Pool, type PoolConfig } from 'pg';

/**
 * PgBouncer transaction mode is mandatory (Step 1 §11), which forbids
 * session-level state. See ADR-0002 for why session-scoped SET is prohibited.
 */
const base: PoolConfig = {
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
  application_name: process.env.SERVICE_NAME ?? 'nfc-identity',
  statement_timeout: Number(process.env.PG_STATEMENT_TIMEOUT_MS ?? 5_000),
};

export function createPool(connectionString: string, overrides: PoolConfig = {}): Pool {
  const pool = new Pool({ ...base, connectionString, ...overrides });
  // An idle-client error would otherwise become an unhandled rejection and take
  // the process down; pg reconnects on next acquire.
  pool.on('error', (err) => {
    console.error(JSON.stringify({ level: 'error', msg: 'idle pg client error', err: err.message }));
  });
  return pool;
}
`````

## `src/db/with-account.ts`

`````typescript
/**
 * The ONLY way to obtain a tenant-scoped database handle (ADR-0002).
 *
 * Step 3 §1.2 requires SET LOCAL app.account_id before any tenant-scoped query,
 * because RLS fails closed: with no setting the predicates compare against NULL
 * and every query returns zero rows. Silently.
 *
 * SET LOCAL is transaction-scoped, so the transaction is not optional. Session-
 * scoped SET is PROHIBITED: under PgBouncer transaction pooling the next
 * transaction on that connection could inherit another user's identity, which is
 * a cross-tenant leak.
 */

import type { Pool, PoolClient } from 'pg';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A transaction-scoped handle. Deliberately narrower than PoolClient: no
 *  release(), so a caller cannot return the connection mid-transaction. */
export interface ScopedClient {
  query: PoolClient['query'];
}

export async function withAccount<T>(
  pool: Pool,
  accountId: string,
  fn: (db: ScopedClient) => Promise<T>,
): Promise<T> {
  // A malformed id means a bug upstream. Surface it as an error rather than as
  // an empty result set, which is what RLS would otherwise produce.
  if (!UUID.test(accountId)) throw new Error('withAccount: accountId is not a UUID');

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // set_config(..., true) is the parameterised equivalent of SET LOCAL.
    await client.query('SELECT set_config($1, $2, true)', ['app.account_id', accountId]);
    const result = await fn({ query: client.query.bind(client) });
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch { /* connection already gone */ }
    throw err;
  } finally {
    client.release();
  }
}

/**
 * For system work with no tenant: reconciliation, the admin surface, migrations.
 * Named to be conspicuous in review and greppable in CI — any use in a request
 * path that handles user data is a finding.
 */
export async function unsafeWithoutAccount<T>(
  pool: Pool,
  fn: (db: ScopedClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  try {
    return await fn({ query: client.query.bind(client) });
  } finally {
    client.release();
  }
}
`````

## `src/resolver/cache.ts`

`````typescript
/**
 * Resolution cache: positive entries, NEGATIVE entries, and single-flight.
 *
 * Step 3 §5.3 identifies the resolver's real threat as adversarial, not organic.
 * An attacker generating random tokens produces a 100% miss rate, so every
 * request falls through to PostgreSQL — modest attacker bandwidth converted into
 * database saturation on the one service whose failure stops every card in the
 * field. Negative caching is therefore a control, not an optimisation.
 *
 * Single-flight (Step 3 §5.4) collapses a burst on one uncached token — a card
 * featured somewhere popular — into a single database read.
 *
 * This is an in-process implementation with a Redis-shaped interface. Production
 * runs Redis so invalidation is fleet-wide; the interface is identical so the
 * swap does not touch the service.
 */

export type Resolution =
  | { found: true; servingState: string; servingSlug: string | null }
  | { found: false };

interface Entry { value: Resolution; expiresAt: number }

export interface ResolutionCache {
  /** Runs `load` only on a miss, and only once for concurrent callers. */
  resolve(token: string, load: () => Promise<Resolution>): Promise<Resolution>;
  /** Called when a card's state changes, and on provisioning to clear a negative. */
  invalidate(token: string): void;
  stats(): { size: number; hits: number; misses: number; inFlightCollapsed: number };
}

export function createCache(opts: {
  ttlMs: number;
  negativeTtlMs: number;
  maxEntries: number;
  now?: () => number;
}): ResolutionCache {
  const now = opts.now ?? Date.now;
  const entries = new Map<string, Entry>();
  const inFlight = new Map<string, Promise<Resolution>>();
  let hits = 0, misses = 0, inFlightCollapsed = 0;

  /** Insertion-ordered Map, so the first key is the oldest — an adequate
   *  approximation of LRU for a bounded cache whose entries also expire. */
  function evictIfFull(): void {
    while (entries.size >= opts.maxEntries) {
      const oldest = entries.keys().next();
      if (oldest.done) break;
      entries.delete(oldest.value);
    }
  }

  return {
    async resolve(token, load) {
      const cached = entries.get(token);
      if (cached && cached.expiresAt > now()) { hits++; return cached.value; }
      if (cached) entries.delete(token);

      const pending = inFlight.get(token);
      if (pending) { inFlightCollapsed++; return pending; }

      misses++;
      const promise = load().then((value) => {
        evictIfFull();
        entries.set(token, {
          value,
          // Negative entries expire sooner: if a purge on provisioning is ever
          // missed, a real card 404s briefly rather than for a full TTL.
          expiresAt: now() + (value.found ? opts.ttlMs : opts.negativeTtlMs),
        });
        return value;
      }).finally(() => {
        inFlight.delete(token);
      });

      inFlight.set(token, promise);
      return promise;
    },

    invalidate(token) { entries.delete(token); },

    stats: () => ({ size: entries.size, hits, misses, inFlightCollapsed }),
  };
}
`````

## `src/resolver/events.ts`

`````typescript
/**
 * Tap event emission: bounded in-process buffer, flushed in batches.
 *
 * Step 1 §5.5 — "fire and forget" is a lie if it is a synchronous network call.
 * A slow queue would become resolver latency and an unavailable queue would
 * become resolver failure. So emission touches only memory.
 *
 * A FULL BUFFER DROPS EVENTS. That is deliberate and it is the documented
 * trade-off: resolution is a correctness guarantee, analytics are best-effort,
 * and no analytics feature justifies a redirect that fails.
 */

export interface TapEvent {
  occurredAt: Date;
  region: string;
  cardId: string | null;
  profileId: string | null;
  channel: 'nfc' | 'qr' | 'direct';
  country: string | null;
  deviceClass: string | null;
  referrerHost: string | null;
  isBot: boolean;
}

export interface EventSink {
  emit(event: TapEvent): void;
  flush(): Promise<void>;
  stop(): Promise<void>;
  stats(): { buffered: number; delivered: number; dropped: number };
}

export function createEventSink(opts: {
  capacity: number;
  flushMs: number;
  deliver: (batch: TapEvent[]) => Promise<void>;
}): EventSink {
  let buffer: TapEvent[] = [];
  let delivered = 0, dropped = 0;
  let stopped = false;

  const flush = async (): Promise<void> => {
    if (buffer.length === 0) return;
    const batch = buffer;
    buffer = [];
    try {
      await opts.deliver(batch);
      delivered += batch.length;
    } catch (err) {
      // Do NOT requeue: a persistently failing sink would grow the buffer until
      // the process died, converting an analytics outage into a resolver outage.
      dropped += batch.length;
      console.error(JSON.stringify({
        level: 'warn', msg: 'tap event batch dropped',
        count: batch.length, err: (err as Error).message,
      }));
    }
  };

  const timer = setInterval(() => { void flush(); }, opts.flushMs);
  // Never hold the process open for analytics.
  if (typeof timer.unref === 'function') timer.unref();

  return {
    emit(event) {
      if (stopped) return;
      if (buffer.length >= opts.capacity) { dropped++; return; }
      buffer.push(event);
    },
    flush,
    async stop() { stopped = true; clearInterval(timer); await flush(); },
    stats: () => ({ buffered: buffer.length, delivered, dropped }),
  };
}
`````

## `src/resolver/http.ts`

`````typescript
/**
 * Resolver HTTP layer.
 *
 * Two rules here are load-bearing and both have tests:
 *
 *   302, NEVER 301 (Step 3 §5.2). A 301 is cached by browsers indefinitely and
 *   cannot be recalled, which would make revocation permanently impossible on
 *   every device that had seen the card. There is no remedy short of physically
 *   retrieving it.
 *
 *   NO OPEN REDIRECT (Step 3 §3.2). The Location header is built only from
 *   serving_slug plus the configured base URL. No query parameter is read for
 *   any purpose — not `next`, not `redirect`, not `url`.
 */

import { createServer, type IncomingMessage, type ServerResponse, type Server } from 'node:http';
import type { Decision } from './service.js';
import type { TapEvent } from './events.js';

export interface ResolverHttpDeps {
  resolve(token: unknown): Promise<Decision>;
  emit(event: TapEvent): void;
  appBaseUrl: string;
  /** Where a paused or unknown card sends the visitor. Same origin as profiles. */
  tapBaseUrl: string;
}

/** Slugs are validated at write time by a DB CHECK; re-validated here so a
 *  corrupted row can never produce a header injection or a scheme-relative URL
 *  such as //evil.test that browsers treat as absolute. */
const SLUG_SAFE = /^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/;

const BOT = /bot|crawler|spider|crawling|preview|facebookexternalhit|slackbot|whatsapp/i;

/** Device CLASS, not a fingerprint (Step 3 §8): enough for a dashboard chart,
 *  not enough to identify a person. */
function deviceClass(ua: string | undefined): string | null {
  if (!ua) return null;
  if (/iPhone|iPad|iPod/i.test(ua)) return 'ios';
  if (/Android/i.test(ua)) return 'android';
  if (/Windows|Macintosh|X11|Linux/i.test(ua)) return 'desktop';
  return 'other';
}

/** Host only. A full referrer URL can carry a query string with personal data. */
function referrerHost(referer: string | undefined): string | null {
  if (!referer) return null;
  try { return new URL(referer).hostname || null; } catch { return null; }
}

export function createResolverServer(deps: ResolverHttpDeps): Server {
  return createServer((req: IncomingMessage, res: ServerResponse) => {
    void handle(req, res, deps).catch((err) => {
      console.error(JSON.stringify({ level: 'error', msg: 'resolver failure', err: (err as Error).message }));
      if (!res.headersSent) send(res, 500, 'Temporarily unavailable.');
    });
  });
}

async function handle(req: IncomingMessage, res: ServerResponse, deps: ResolverHttpDeps): Promise<void> {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.setHeader('Allow', 'GET, HEAD');
    return send(res, 405, 'Method not allowed.');
  }

  // Parsed against a dummy base purely to strip any query string safely. The
  // query is then never consulted.
  const path = new URL(req.url ?? '/', 'http://resolver.invalid').pathname;

  if (path === '/healthz') return json(res, 200, { ok: true });

  const match = /^\/t\/([^/]+)$/.exec(path);
  if (!match) return send(res, 404, 'Not found.');

  const decision = await deps.resolve(decodeURIComponent(match[1]!));

  // Emitted for every non-malformed request, including misses, so the
  // enumeration signal in Step 3 §6 (miss ratio) is measurable.
  if (!(decision.kind === 'not_found' && decision.reason === 'malformed')) {
    deps.emit({
      occurredAt: new Date(),
      region: process.env.SERVICE_REGION ?? 'eu',
      cardId: null,       // resolved asynchronously by the ingest worker
      profileId: null,
      channel: 'nfc',
      country: (req.headers['cf-ipcountry'] as string | undefined)?.slice(0, 2) ?? null,
      deviceClass: deviceClass(req.headers['user-agent']),
      referrerHost: referrerHost(req.headers['referer']),
      isBot: BOT.test(req.headers['user-agent'] ?? ''),
    });
  }

  switch (decision.kind) {
    case 'redirect': {
      if (!SLUG_SAFE.test(decision.slug)) {
        console.error(JSON.stringify({ level: 'error', msg: 'unsafe slug refused', slug: decision.slug }));
        return send(res, 500, 'Temporarily unavailable.');
      }
      // 302 + no-store: revocation must take effect immediately.
      res.statusCode = 302;
      res.setHeader('Location', `${deps.appBaseUrl}/u/${decision.slug}`);
      res.setHeader('Cache-Control', 'no-store');
      res.setHeader('Referrer-Policy', 'no-referrer');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.end();
      return;
    }
    case 'paused':
      res.statusCode = 302;
      res.setHeader('Location', `${deps.tapBaseUrl}/paused`);
      res.setHeader('Cache-Control', 'no-store');
      res.end();
      return;
    case 'gone':
      return send(res, 410, 'This card has been deactivated.');
    case 'unclaimed':
      res.statusCode = 302;
      res.setHeader('Location', `${deps.tapBaseUrl}/claim`);
      res.setHeader('Cache-Control', 'no-store');
      res.end();
      return;
    case 'not_found':
      // Identical response for malformed and unknown: distinguishing them would
      // turn the resolver into a token-existence oracle.
      return send(res, 404, 'Not found.');
  }
}

function send(res: ServerResponse, status: number, body: string): void {
  res.statusCode = status;
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.end(body);
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}
`````

## `src/resolver/main.ts`

`````typescript
/**
 * Resolver service entry point.
 *
 * Separate deployable (Step 1 §4): a resolver outage stops every card in the
 * field, so it shares as little as possible with anything else.
 */

import { config, assertOriginSeparation } from '../config.js';
import { createPool } from '../db/pools.js';
import { createCache } from './cache.js';
import { createEventSink } from './events.js';
import { createResolver } from './service.js';
import { createResolverServer } from './http.js';

const tapBaseUrl = config.tapBaseUrl();
const appBaseUrl = config.appBaseUrl();

// Refuse to start if profiles would share a registrable domain with the
// dashboard (Step 3 §4). A misconfiguration here makes stored XSS in profile
// content able to reach dashboard cookies, so it is a boot failure, not a warning.
assertOriginSeparation(tapBaseUrl, appBaseUrl);

const pool = createPool(config.resolverDatabaseUrl());

const cache = createCache({
  ttlMs: config.cacheTtlMs(),
  negativeTtlMs: config.negativeCacheTtlMs(),
  maxEntries: config.cacheMaxEntries(),
});

const sink = createEventSink({
  capacity: config.eventBufferSize(),
  flushMs: config.eventFlushMs(),
  // Wired to the queue in Step 6. Until then events are counted and discarded,
  // which is the documented degraded behaviour rather than a silent gap.
  deliver: async (batch) => {
    console.log(JSON.stringify({ level: 'info', msg: 'tap batch', count: batch.length }));
  },
});

const server = createResolverServer({
  resolve: createResolver({ pool, cache }).resolve,
  emit: sink.emit,
  appBaseUrl,
  tapBaseUrl,
});

const port = config.resolverPort();
server.listen(port, () => {
  console.log(JSON.stringify({ level: 'info', msg: 'resolver listening', port }));
});

async function shutdown(signal: string): Promise<void> {
  console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal }));
  server.close();
  await sink.stop();          // flush buffered events before exit
  await pool.end();
  process.exit(0);
}
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
`````

## `src/resolver/service.ts`

`````typescript
/**
 * Resolution logic. One indexed row read, no joins, no business logic.
 *
 * Step 1 §5.6 forbids subscription checks, Stripe calls, page rendering, joins,
 * and synchronous writes on this path. The subscription question is already
 * answered: cards.serving_state is precomputed by a worker (Step 1 §2.2), so the
 * decision here is one comparison against a column already loaded.
 */

import type { Pool } from 'pg';
import { hashToken, isWellFormedToken } from './token.js';
import type { Resolution, ResolutionCache } from './cache.js';

export type Decision =
  | { kind: 'redirect'; slug: string }
  | { kind: 'paused' }
  | { kind: 'gone' }
  | { kind: 'unclaimed' }
  | { kind: 'not_found'; reason: 'malformed' | 'unknown' };

/** The resolver's entire query. Column list matches the app_resolver grant
 *  exactly (ADR-0001); selecting anything else would be refused. */
const RESOLVE_SQL =
  'SELECT serving_state, serving_slug FROM cards WHERE token_hash = $1';

export function createResolver(deps: { pool: Pool; cache: ResolutionCache }) {
  async function load(token: string): Promise<Resolution> {
    const { rows } = await deps.pool.query<{ serving_state: string; serving_slug: string | null }>(
      { name: 'resolve_card_token', text: RESOLVE_SQL, values: [hashToken(token)] });
    const row = rows[0];
    if (!row) return { found: false };
    return { found: true, servingState: row.serving_state, servingSlug: row.serving_slug };
  }

  return {
    async resolve(token: unknown): Promise<Decision> {
      // Shape check before any I/O — Step 3 §5.3 control 1.
      if (!isWellFormedToken(token)) return { kind: 'not_found', reason: 'malformed' };

      const result = await deps.cache.resolve(token, () => load(token));
      if (!result.found) return { kind: 'not_found', reason: 'unknown' };

      switch (result.servingState) {
        case 'active':
          // A card cannot be active without a slug (cards_active_is_bound, Step 2),
          // so a null here means the invariant was bypassed. Fail closed.
          return result.servingSlug
            ? { kind: 'redirect', slug: result.servingSlug }
            : { kind: 'gone' };
        case 'lapsed':    return { kind: 'paused' };
        case 'revoked':   return { kind: 'gone' };
        case 'suspended': return { kind: 'paused' };
        case 'unclaimed': return { kind: 'unclaimed' };
        default:          return { kind: 'gone' };
      }
    },
  };
}
`````

## `src/resolver/token.ts`

`````typescript
/**
 * Token shape validation and hashing.
 *
 * Step 3 §5.3 control 1: reject malformed tokens BEFORE any I/O. A wrong length
 * or an out-of-alphabet character costs one regex test, not a Redis round trip
 * and a database read. That is what makes an unsophisticated flood free to absorb.
 */

import { createHash, timingSafeEqual } from 'node:crypto';

/** 128 bits base62-encoded is 22 characters (ceil(128 / log2(62))). */
export const TOKEN_LENGTH = 22;
const TOKEN_SHAPE = /^[0-9A-Za-z]{22}$/;

export const isWellFormedToken = (token: unknown): token is string =>
  typeof token === 'string' && TOKEN_SHAPE.test(token);

/**
 * Plain SHA-256, no pepper, deliberately (Step 3 §5).
 *
 * The input is 128 bits of uniform randomness, so there is no dictionary and no
 * feasible search — a pepper would add nothing. It would also be UNROTATABLE,
 * because plaintext tokens are never retained and so could never be rehashed. A
 * slow KDF is wrong for the same reason plus one more: this runs on every tap.
 */
export const hashToken = (token: string): Buffer =>
  createHash('sha256').update(token, 'utf8').digest();

/** Constant-time compare, for anywhere a hash is checked against a candidate. */
export function hashesEqual(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b);
}
`````

## `src/validation.ts`

`````typescript
/**
 * Input validation for user-authored profile content.
 *
 * Step 3 §3.3 identifies stored XSS in profile content as the most probable
 * serious vulnerability in this product: bio, display name and links are
 * attacker-authorable and rendered to strangers.
 *
 * The controls are: no user HTML anywhere, and links restricted to absolute
 * https URLs. Both are enforced here at WRITE time, so a bad value never reaches
 * the database and cannot be served even if a renderer forgets to escape.
 */

export interface Invalid { field: string; message: string }

/* ── slugs ────────────────────────────────────────────────────────────────── */

/**
 * MUST match the database CHECK constraints exactly (Step 2 §4.2):
 *   slugs_shape           ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$
 *   slugs_user_min_length length >= 3 for non-reserved slugs
 *
 * Duplicated deliberately: the database is the guarantee, this is the good error
 * message. A drift test asserts they agree.
 */
const SLUG_SHAPE = /^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/;

export function validateSlug(slug: unknown): Invalid[] {
  if (typeof slug !== 'string') return [{ field: 'slug', message: 'Slug must be text.' }];
  const errors: Invalid[] = [];
  if (slug.length < 3) errors.push({ field: 'slug', message: 'Slug must be at least 3 characters.' });
  if (slug.length > 40) errors.push({ field: 'slug', message: 'Slug must be 40 characters or fewer.' });
  if (!SLUG_SHAPE.test(slug)) {
    errors.push({ field: 'slug',
      message: 'Slug may use lowercase letters, numbers and hyphens, and must start and end with a letter or number.' });
  }
  return errors;
}

/* ── links ────────────────────────────────────────────────────────────────── */

const MAX_LINKS = 20;
const MAX_URL_LENGTH = 2048;
const LABEL_SHAPE = /^[a-z0-9_]{1,32}$/;

/**
 * Absolute https only.
 *
 * `javascript:`, `data:` and `file:` are the classic injection schemes, but an
 * allowlist is used rather than a denylist: the set of dangerous schemes is
 * open-ended (view-source:, blob:, vendor-specific handlers), whereas the set we
 * need is exactly one.
 *
 * Credentials in the URL are rejected too — a link rendered as
 * https://user:pass@host is a phishing primitive.
 */
export function validateLink(label: string, value: unknown): Invalid[] {
  const field = `links.${label}`;
  if (!LABEL_SHAPE.test(label)) {
    return [{ field, message: 'Link labels may use lowercase letters, numbers and underscores.' }];
  }
  if (typeof value !== 'string' || !value.trim()) {
    return [{ field, message: 'Link must be a non-empty URL.' }];
  }
  if (value.length > MAX_URL_LENGTH) {
    return [{ field, message: 'Link is too long.' }];
  }

  let url: URL;
  try { url = new URL(value); }
  catch { return [{ field, message: 'Link must be an absolute URL beginning with https://' }]; }

  if (url.protocol !== 'https:') {
    return [{ field, message: 'Link must use https.' }];
  }
  if (url.username || url.password) {
    return [{ field, message: 'Link must not contain a username or password.' }];
  }
  if (!url.hostname.includes('.') || url.hostname.endsWith('.')) {
    return [{ field, message: 'Link must point at a valid domain.' }];
  }
  return [];
}

export function validateLinks(links: unknown): Invalid[] {
  if (links === undefined || links === null) return [];
  if (typeof links !== 'object' || Array.isArray(links)) {
    return [{ field: 'links', message: 'Links must be an object of label to URL.' }];
  }
  const entries = Object.entries(links as Record<string, unknown>);
  if (entries.length > MAX_LINKS) {
    return [{ field: 'links', message: `At most ${MAX_LINKS} links.` }];
  }
  return entries.flatMap(([label, value]) => validateLink(label, value));
}

/* ── free text ────────────────────────────────────────────────────────────── */

/**
 * Plain text only. No sanitiser, no allowlist of tags — the field is stored and
 * rendered as text, so there is no HTML to sanitise. Control characters are
 * stripped because they serve no purpose in a display name and complicate
 * logging and terminal output.
 */
export function cleanText(value: unknown, field: string, max: number): { value: string; errors: Invalid[] } {
  if (typeof value !== 'string') return { value: '', errors: [{ field, message: 'Must be text.' }] };
  // eslint-disable-next-line no-control-regex
  const stripped = value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim();
  const errors: Invalid[] = [];
  if (stripped.length > max) errors.push({ field, message: `Must be ${max} characters or fewer.` });
  return { value: stripped, errors };
}

export interface ProfileInput {
  displayName?: unknown;
  headline?: unknown;
  bio?: unknown;
  links?: unknown;
}

export function validateProfileInput(input: ProfileInput): {
  errors: Invalid[];
  clean: { displayName?: string; headline?: string; bio?: string; links?: Record<string, string> };
} {
  const errors: Invalid[] = [];
  const clean: { displayName?: string; headline?: string; bio?: string; links?: Record<string, string> } = {};

  if (input.displayName !== undefined) {
    const r = cleanText(input.displayName, 'displayName', 80);
    errors.push(...r.errors);
    if (!r.value) errors.push({ field: 'displayName', message: 'Display name is required.' });
    clean.displayName = r.value;
  }
  if (input.headline !== undefined) {
    const r = cleanText(input.headline, 'headline', 160);
    errors.push(...r.errors); clean.headline = r.value;
  }
  if (input.bio !== undefined) {
    const r = cleanText(input.bio, 'bio', 2000);
    errors.push(...r.errors); clean.bio = r.value;
  }
  if (input.links !== undefined) {
    const linkErrors = validateLinks(input.links);
    errors.push(...linkErrors);
    if (linkErrors.length === 0 && input.links && typeof input.links === 'object') {
      clean.links = input.links as Record<string, string>;
    }
  }
  return { errors, clean };
}
`````
