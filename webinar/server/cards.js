'use strict';
const crypto = require('crypto');
const db = require('./db');
const { derivedState } = require('./domain');

const CARD_SECRET = process.env.CARD_SECRET || 'dev-card-secret-change-me';

/* ---------- card tokens ----------
   The token is what gets written to the tag, inside a URL. It's `cardId.signature`,
   so a token can be verified without a database lookup and can't be guessed from
   a card ID alone. Revocation still needs the lookup — see resolveToken.        */

const sign = (cardId) =>
  crypto.createHmac('sha256', CARD_SECRET).update(cardId).digest('base64url').slice(0, 22);

const mintToken = (cardId) => `${cardId}.${sign(cardId)}`;

function verifyToken(token) {
  if (typeof token !== 'string') return null;
  const dot = token.lastIndexOf('.');
  if (dot < 1) return null;
  const cardId = token.slice(0, dot);
  const provided = token.slice(dot + 1);
  const expected = sign(cardId);
  if (provided.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected))) return null;
  return cardId;
}

/* ---------- lookup ---------- */

/** Normalise UIDs from readers: they arrive as hex with varying case and separators. */
const normaliseUid = (uid) => String(uid || '').replace(/[^0-9a-fA-F]/g, '').toUpperCase();

function resolveToken(token) {
  const cardId = verifyToken(token);
  if (!cardId) return { error: 'That card isn\u2019t recognised.', status: 404 };
  const card = db.data.cards.find((c) => c.id === cardId);
  if (!card) return { error: 'That card isn\u2019t recognised.', status: 404 };
  if (card.revoked) return { error: 'That card has been revoked. See the front desk.', status: 403 };
  return { card };
}

function resolveUid(uid) {
  const clean = normaliseUid(uid);
  if (!clean) return { error: 'No card number was read. Try the tap again.', status: 400 };
  const card = db.data.cards.find((c) => c.uid === clean);
  if (!card) return { error: `Card ${clean} isn\u2019t enrolled yet.`, status: 404, uid: clean };
  if (card.revoked) return { error: 'That card has been revoked. See the front desk.', status: 403 };
  return { card };
}

/* ---------- enrollment ---------- */

function enroll({ userId, uid, label }) {
  const user = db.data.users.find((u) => u.id === userId);
  if (!user) return { error: 'No account with that id.', status: 404 };

  const clean = normaliseUid(uid);
  if (clean && db.data.cards.some((c) => c.uid === clean && !c.revoked)) {
    return { error: `Card ${clean} is already assigned to someone.`, status: 409 };
  }

  const card = {
    id: db.id('card'),
    userId,
    uid: clean || null,
    label: String(label || '').trim() || `${user.name}\u2019s card`,
    revoked: false,
    taps: 0,
    lastTapAt: null,
    createdAt: new Date().toISOString(),
  };
  db.data.cards.push(card);
  db.save();
  return { card };
}

/** Everything needed to write the tag, plus who it belongs to. */
function describe(card, origin) {
  const user = db.data.users.find((u) => u.id === card.userId);
  const token = mintToken(card.id);
  return {
    id: card.id,
    label: card.label,
    uid: card.uid,
    revoked: card.revoked,
    taps: card.taps,
    lastTapAt: card.lastTapAt,
    createdAt: card.createdAt,
    holder: user ? { id: user.id, name: user.name, email: user.email } : null,
    token,
    tapUrl: `${origin}/c/${token}`,
  };
}

/* ---------- check-in ---------- */

/** The session a tap should count towards: whatever is on air, soonest first. */
function activeSession(sessionId = null) {
  if (sessionId) {
    const w = db.data.webinars.find((x) => x.id === sessionId);
    return w || null;
  }
  return db.data.webinars
    .filter((w) => derivedState(w) === 'live')
    .sort((a, b) => new Date(a.startsAt) - new Date(b.startsAt))[0] || null;
}

/**
 * Marks the cardholder present. Walk-ins get a registration created on the spot,
 * and a second tap is reported rather than treated as an error.
 */
function checkIn(card, sessionId = null) {
  const webinar = activeSession(sessionId);
  if (!webinar) return { error: 'No session is on air right now.', status: 409 };
  if (derivedState(webinar) !== 'live') {
    return { error: 'That session isn\u2019t open for check-in yet.', status: 409 };
  }

  const user = db.data.users.find((u) => u.id === card.userId);
  if (!user) return { error: 'The account for this card no longer exists.', status: 404 };

  let reg = db.data.registrations.find((r) => r.webinarId === webinar.id && r.userId === user.id);
  let walkIn = false;

  if (!reg) {
    walkIn = true;
    reg = {
      id: db.id('reg'),
      webinarId: webinar.id,
      userId: user.id,
      registeredAt: new Date().toISOString(),
      attended: false,
      joinedAt: null,
      watchedMin: 0,
    };
    db.data.registrations.push(reg);
  }

  const repeat = reg.attended;
  if (!repeat) {
    reg.attended = true;
    reg.joinedAt = new Date().toISOString();
  }

  card.taps += 1;
  card.lastTapAt = new Date().toISOString();
  db.save();

  return {
    result: {
      status: repeat ? 'already_in' : walkIn ? 'walk_in' : 'checked_in',
      name: user.name,
      company: user.company || '',
      session: webinar.title,
      seatHeld: !walkIn,
      at: reg.joinedAt,
    },
  };
}

module.exports = { mintToken, verifyToken, normaliseUid, resolveToken, resolveUid, enroll, describe, checkIn, activeSession };
