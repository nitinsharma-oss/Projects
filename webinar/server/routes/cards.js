'use strict';
const express = require('express');
const db = require('../db');
const { requireAdmin } = require('../auth');
const cards = require('../cards');
const { derivedState } = require('../domain');

const router = express.Router();
const origin = (req) => `${req.protocol}://${req.get('host')}`;

/* ---------- check-in ----------
   Two doors, deliberately different in what they trust.

   token: the signed value written on the tag. It IS the credential, so this needs
          no session — that's what makes self check-in work on an iPhone with no app.
   uid:   the chip's serial number. Trivially cloneable with a £25 device, so it's
          only accepted from a signed-in admin standing at the desk.               */

router.post('/checkin', (req, res) => {
  const { token, uid, sessionId } = req.body || {};

  if (token) {
    const found = cards.resolveToken(token);
    if (found.error) return res.status(found.status).json({ error: found.error });
    const out = cards.checkIn(found.card, sessionId);
    if (out.error) return res.status(out.status).json({ error: out.error });
    return res.json(out.result);
  }

  if (uid) {
    if (!req.user || req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Card-number check-in has to be done from a signed-in station.' });
    }
    const found = cards.resolveUid(uid);
    if (found.error) return res.status(found.status).json({ error: found.error, uid: found.uid });
    const out = cards.checkIn(found.card, sessionId);
    if (out.error) return res.status(out.status).json({ error: out.error });
    return res.json(out.result);
  }

  res.status(400).json({ error: 'Send either a card token or a card number.' });
});

/** What the station shows in its header: which session taps are counting towards. */
router.get('/checkin/session', (_req, res) => {
  const w = cards.activeSession();
  if (!w) return res.json({ session: null });
  res.json({
    session: { id: w.id, title: w.title, startsAt: w.startsAt, state: derivedState(w) },
  });
});

/* ---------- enrollment (admin) ---------- */

const admin = express.Router();
admin.use(requireAdmin);

admin.get('/', (req, res) => {
  res.json({ cards: db.data.cards.map((c) => cards.describe(c, origin(req))) });
});

admin.post('/', (req, res) => {
  const { userId, uid, label } = req.body || {};
  if (!userId) return res.status(400).json({ error: 'Pick who the card belongs to.' });
  const out = cards.enroll({ userId, uid, label });
  if (out.error) return res.status(out.status).json({ error: out.error });
  res.status(201).json({ card: cards.describe(out.card, origin(req)) });
});

/** Attaches a UID to an existing card — used when the desk reader scans a blank. */
admin.patch('/:id', (req, res) => {
  const card = db.data.cards.find((c) => c.id === req.params.id);
  if (!card) return res.status(404).json({ error: 'No card with that id.' });

  if (req.body.uid !== undefined) {
    const clean = cards.normaliseUid(req.body.uid);
    if (clean && db.data.cards.some((c) => c.uid === clean && c.id !== card.id && !c.revoked)) {
      return res.status(409).json({ error: `Card ${clean} is already assigned to someone.` });
    }
    card.uid = clean || null;
  }
  if (req.body.label !== undefined) card.label = String(req.body.label).trim();
  if (req.body.revoked !== undefined) card.revoked = Boolean(req.body.revoked);

  db.save();
  res.json({ card: cards.describe(card, origin(req)) });
});

/** Revoke rather than delete, so a lost card can't be re-enrolled by accident
    and the tap history stays auditable. */
admin.delete('/:id', (req, res) => {
  const card = db.data.cards.find((c) => c.id === req.params.id);
  if (!card) return res.status(404).json({ error: 'No card with that id.' });
  card.revoked = true;
  db.save();
  res.json({ revoked: card.id });
});

module.exports = router;
module.exports.admin = admin;
