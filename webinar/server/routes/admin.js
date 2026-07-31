'use strict';
const express = require('express');
const db = require('../db');
const { requireAdmin, publicUser } = require('../auth');
const { toAdmin, derivedState, registrationsFor, stats } = require('../domain');

const router = express.Router();
router.use(requireAdmin);

const findWebinar = (id) => db.data.webinars.find((w) => w.id === id);

const EDITABLE = ['title', 'description', 'host', 'startsAt', 'durationMin', 'capacity', 'joinUrl', 'recordingUrl', 'tags', 'status'];
const STATUSES = ['draft', 'scheduled', 'cancelled'];

function validate(payload, { partial = false } = {}) {
  const errors = [];
  const has = (k) => payload[k] !== undefined;
  const required = (k, label) => {
    if (!partial && !has(k)) errors.push(`${label} is required.`);
  };

  required('title', 'Title');
  required('startsAt', 'Start time');
  if (has('title') && !String(payload.title).trim()) errors.push('Title can\u2019t be empty.');
  if (has('startsAt') && Number.isNaN(new Date(payload.startsAt).getTime())) errors.push('Start time isn\u2019t a valid date.');
  if (has('durationMin') && (!Number.isFinite(+payload.durationMin) || +payload.durationMin <= 0)) {
    errors.push('Duration must be a number of minutes above zero.');
  }
  if (has('capacity') && payload.capacity !== null && (!Number.isFinite(+payload.capacity) || +payload.capacity < 0)) {
    errors.push('Capacity must be zero or more. Leave it blank for unlimited seats.');
  }
  if (has('status') && !STATUSES.includes(payload.status)) {
    errors.push(`Status must be one of: ${STATUSES.join(', ')}.`);
  }
  return errors;
}

/* ---------- sessions ---------- */

router.get('/webinars', (_req, res) => {
  const list = db.data.webinars
    .map((w) => toAdmin(w))
    .sort((a, b) => new Date(b.startsAt) - new Date(a.startsAt));
  res.json({ webinars: list });
});

router.post('/webinars', (req, res) => {
  const errors = validate(req.body || {});
  if (errors.length) return res.status(400).json({ error: errors[0], errors });

  const b = req.body;
  const webinar = {
    id: db.id('web'),
    title: String(b.title).trim(),
    description: String(b.description || '').trim(),
    host: String(b.host || req.user.name).trim(),
    startsAt: new Date(b.startsAt).toISOString(),
    durationMin: Number(b.durationMin) || 60,
    capacity: b.capacity === '' || b.capacity == null ? null : Number(b.capacity),
    joinUrl: String(b.joinUrl || '').trim(),
    recordingUrl: String(b.recordingUrl || '').trim(),
    tags: Array.isArray(b.tags) ? b.tags : String(b.tags || '').split(',').map((t) => t.trim()).filter(Boolean),
    status: STATUSES.includes(b.status) ? b.status : 'draft',
    createdBy: req.user.id,
    createdAt: new Date().toISOString(),
  };
  db.data.webinars.push(webinar);
  db.save();
  res.status(201).json({ webinar: toAdmin(webinar) });
});

router.patch('/webinars/:id', (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w) return res.status(404).json({ error: 'No session with that id.' });

  const errors = validate(req.body || {}, { partial: true });
  if (errors.length) return res.status(400).json({ error: errors[0], errors });

  for (const key of EDITABLE) {
    if (req.body[key] === undefined) continue;
    if (key === 'startsAt') w.startsAt = new Date(req.body.startsAt).toISOString();
    else if (key === 'durationMin') w.durationMin = Number(req.body.durationMin);
    else if (key === 'capacity') w.capacity = req.body.capacity === '' || req.body.capacity == null ? null : Number(req.body.capacity);
    else if (key === 'tags') w.tags = Array.isArray(req.body.tags) ? req.body.tags : String(req.body.tags).split(',').map((t) => t.trim()).filter(Boolean);
    else w[key] = req.body[key];
  }
  w.updatedAt = new Date().toISOString();
  db.save();
  res.json({ webinar: toAdmin(w) });
});

router.delete('/webinars/:id', (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w) return res.status(404).json({ error: 'No session with that id.' });
  db.data.webinars = db.data.webinars.filter((x) => x.id !== w.id);
  db.data.registrations = db.data.registrations.filter((r) => r.webinarId !== w.id);
  db.save();
  res.json({ deleted: w.id });
});

/* ---------- registrants ---------- */

function registrantRows(webinarId) {
  return registrationsFor(webinarId).map((r) => {
    const u = db.data.users.find((x) => x.id === r.userId);
    return {
      registrationId: r.id,
      name: u?.name || 'Deleted account',
      email: u?.email || '',
      company: u?.company || '',
      registeredAt: r.registeredAt,
      attended: r.attended,
      watchedMin: r.watchedMin || 0,
    };
  }).sort((a, b) => new Date(a.registeredAt) - new Date(b.registeredAt));
}

router.get('/webinars/:id/registrants', (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w) return res.status(404).json({ error: 'No session with that id.' });
  res.json({ registrants: registrantRows(w.id), stats: stats(w) });
});

router.get('/webinars/:id/registrants.csv', (req, res) => {
  const w = findWebinar(req.params.id);
  if (!w) return res.status(404).json({ error: 'No session with that id.' });
  const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const header = ['Name', 'Email', 'Company', 'Registered', 'Attended', 'Minutes watched'];
  const body = registrantRows(w.id).map((r) =>
    [r.name, r.email, r.company, r.registeredAt, r.attended ? 'yes' : 'no', r.watchedMin].map(esc).join(',')
  );
  const slug = w.title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  res.set('Content-Type', 'text/csv; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="${slug || 'registrants'}.csv"`);
  res.send([header.join(','), ...body].join('\n'));
});

/* ---------- overview ---------- */

router.get('/overview', (_req, res) => {
  const now = Date.now();
  const all = db.data.webinars;
  const published = all.filter((w) => !['draft', 'cancelled'].includes(w.status));
  const totals = published.reduce(
    (acc, w) => {
      const s = stats(w);
      acc.registrations += s.registered;
      acc.attendance += s.attended;
      return acc;
    },
    { registrations: 0, attendance: 0 }
  );

  res.json({
    counts: {
      sessions: all.length,
      drafts: all.filter((w) => w.status === 'draft').length,
      live: all.filter((w) => derivedState(w, now) === 'live').length,
      upcoming: all.filter((w) => derivedState(w, now) === 'scheduled').length,
      people: db.data.users.filter((u) => u.role === 'user').length,
      registrations: totals.registrations,
      showRate: totals.registrations ? Math.round((totals.attendance / totals.registrations) * 100) : 0,
    },
    today: all
      .map((w) => toAdmin(w, now))
      .filter((w) => new Date(w.startsAt).toDateString() === new Date(now).toDateString())
      .sort((a, b) => new Date(a.startsAt) - new Date(b.startsAt)),
    recent: all
      .map((w) => toAdmin(w, now))
      .filter((w) => w.state === 'ended')
      .sort((a, b) => new Date(b.startsAt) - new Date(a.startsAt))
      .slice(0, 5),
  });
});

router.get('/people', (_req, res) => {
  const rows = db.data.users.map((u) => {
    const regs = db.data.registrations.filter((r) => r.userId === u.id);
    return {
      ...publicUser(u),
      createdAt: u.createdAt,
      registrations: regs.length,
      attended: regs.filter((r) => r.attended).length,
    };
  }).sort((a, b) => b.registrations - a.registrations);
  res.json({ people: rows });
});

module.exports = router;
