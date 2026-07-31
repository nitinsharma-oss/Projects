'use strict';
const path = require('path');
const express = require('express');
const { attachUser } = require('./auth');

const app = express();
const PORT = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, '..', 'public');

app.use(express.json());
app.use(attachUser);

app.use('/api/auth', require('./routes/auth'));
app.use('/api/webinars', require('./routes/webinars'));
app.use('/api/me', require('./routes/webinars').mine);
app.use('/api/admin', require('./routes/admin'));
app.use('/api/admin/cards', require('./routes/cards').admin);
app.use('/api', require('./routes/cards'));

app.get('/api/health', (_req, res) => res.json({ ok: true, time: new Date().toISOString() }));

app.use(express.static(PUBLIC_DIR));
app.get('/admin', (_req, res) => res.sendFile(path.join(PUBLIC_DIR, 'admin.html')));
app.get('/dashboard', (_req, res) => res.sendFile(path.join(PUBLIC_DIR, 'dashboard.html')));
app.get('/cards', (_req, res) => res.sendFile(path.join(PUBLIC_DIR, 'cards.html')));
app.get('/station', (_req, res) => res.sendFile(path.join(PUBLIC_DIR, 'station.html')));
// Where an NFC tag's URL lands. The token is in the path; the page reads it and checks in.
app.get('/c/:token', (_req, res) => res.sendFile(path.join(PUBLIC_DIR, 'tap.html')));

app.use('/api', (_req, res) => res.status(404).json({ error: 'No such endpoint.' }));

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error('[error]', err);
  res.status(500).json({ error: 'Something broke on our side. Try again.' });
});

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`\n  Stage is running`);
    console.log(`  Attendee dashboard  http://localhost:${PORT}/dashboard`);
    console.log(`  Admin dashboard     http://localhost:${PORT}/admin\n`);
  });
}

module.exports = app;
