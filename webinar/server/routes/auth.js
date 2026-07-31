'use strict';
const express = require('express');
const db = require('../db');
const { hashPassword, verifyPassword, issueToken, requireAuth, publicUser } = require('../auth');

const router = express.Router();
const normalise = (email) => String(email || '').trim().toLowerCase();

router.post('/signup', (req, res) => {
  const { name, email, password, company } = req.body || {};
  if (!name || !email || !password) {
    return res.status(400).json({ error: 'Name, email and password are all required.' });
  }
  if (String(password).length < 8) {
    return res.status(400).json({ error: 'Password needs at least 8 characters.' });
  }
  if (db.data.users.some((u) => u.email === normalise(email))) {
    return res.status(409).json({ error: 'That email is already registered. Sign in instead.' });
  }

  const user = {
    id: db.id('usr'),
    name: String(name).trim(),
    email: normalise(email),
    company: String(company || '').trim(),
    passwordHash: hashPassword(password),
    role: 'user',
    createdAt: new Date().toISOString(),
  };
  db.data.users.push(user);
  db.save();
  res.status(201).json({ token: issueToken(user), user: publicUser(user) });
});

router.post('/signin', (req, res) => {
  const { email, password } = req.body || {};
  const user = db.data.users.find((u) => u.email === normalise(email));
  if (!user || !verifyPassword(String(password || ''), user.passwordHash)) {
    return res.status(401).json({ error: 'That email and password don\u2019t match an account.' });
  }
  res.json({ token: issueToken(user), user: publicUser(user) });
});

router.get('/me', requireAuth, (req, res) => res.json({ user: publicUser(req.user) }));

module.exports = router;
