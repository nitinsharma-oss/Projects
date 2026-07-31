'use strict';
const express = require('express');
const db = require('../db');
const { requireAuth } = require('../auth');
const { toPublic, derivedState, registrationsFor, stats } = require('../domain');

const router = express.Router();
const findWebinar = (id) => db.data.webinars.find((w) => w.id === id);

/** Catalogue. Drafts and cancelled sessions never leave the building. */
router.get('/', (req, res) => {
  const { state, tag, q } = req.query;
  const viewerId = req.user?.id || null;
  const list = db.data.webinars
    .filter((w) => !['draft', 'cancelled'].includes(w.status))
    .map((w) => toPublic(w, viewerId))
    .filter((w) => (state ? w.state === state : true))
    .filter((w) => (tag ? w.tags.includes(tag) : true))
    .filter((w) => (q ? `${w.title} ${w.description} ${w.host}`.toLowerCase().includes(String(q).toLowerCase()) : true))
    .sort((a, b) => new Date(a.startsAt) - new Date(b.startsAt));
  res.json({ webinars: list });
});

router.get('/:id', (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w || ['draft', 'cancelled'].includes(w.status)) {
    return res.status(404).json({ error: 'That session isn\u2019t available.' });
  }
  res.json({ webinar: toPublic(w, req.user?.id || null) });
});

router.post('/:id/register', requireAuth, (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w || ['draft', 'cancelled'].includes(w.status)) {
    return res.status(404).json({ error: 'That session isn\u2019t available.' });
  }
  if (derivedState(w) === 'ended') {
    return res.status(409).json({ error: 'This session has already finished. Watch the recording instead.' });
  }
  if (registrationsFor(w.id).some((r) => r.userId === req.user.id)) {
    return res.status(409).json({ error: 'You already have a seat for this session.' });
  }
  if (w.capacity && stats(w).seatsLeft === 0) {
    return res.status(409).json({ error: 'This session is full.' });
  }

  db.data.registrations.push({
    id: db.id('reg'),
    webinarId: w.id,
    userId: req.user.id,
    registeredAt: new Date().toISOString(),
    attended: false,
    joinedAt: null,
    watchedMin: 0,
  });
  db.save();
  res.status(201).json({ webinar: toPublic(w, req.user.id) });
});

router.delete('/:id/register', requireAuth, (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w) return res.status(404).json({ error: 'That session isn\u2019t available.' });
  const before = db.data.registrations.length;
  db.data.registrations = db.data.registrations.filter(
    (r) => !(r.webinarId === w.id && r.userId === req.user.id)
  );
  if (db.data.registrations.length === before) {
    return res.status(404).json({ error: 'You don\u2019t have a seat for this session.' });
  }
  db.save();
  res.json({ webinar: toPublic(w, req.user.id) });
});

/** Marks attendance and hands back the room link. */
router.post('/:id/join', requireAuth, (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w) return res.status(404).json({ error: 'That session isn\u2019t available.' });
  if (derivedState(w) !== 'live') {
    return res.status(409).json({ error: 'The room opens when the session goes live.' });
  }
  const reg = registrationsFor(w.id).find((r) => r.userId === req.user.id);
  if (!reg) return res.status(403).json({ error: 'Register first to get a seat.' });

  if (!reg.attended) {
    reg.attended = true;
    reg.joinedAt = new Date().toISOString();
  }
  reg.watchedMin = Math.min(
    w.durationMin,
    Math.round((Date.now() - new Date(reg.joinedAt).getTime()) / 60_000)
  );
  db.save();
  res.json({ joinUrl: w.joinUrl });
});

module.exports = router;

/** Split out so /api/me can live on its own mount point. */
module.exports.mine = express.Router().get('/registrations', requireAuth, (req, res) => {
  const rows = db.data.registrations
    .filter((r) => r.userId === req.user.id)
    .map((r) => {
      const w = findWebinar(r.webinarId);
      return w ? { ...toPublic(w, req.user.id), registeredAt: r.registeredAt, watchedMin: r.watchedMin } : null;
    })
    .filter(Boolean)
    .sort((a, b) => new Date(a.startsAt) - new Date(b.startsAt));
  res.json({ registrations: rows });
});
