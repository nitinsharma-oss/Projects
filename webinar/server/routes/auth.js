'use strict';
const crypto = require('crypto');
const db = require('./db');

const SECRET = process.env.SESSION_SECRET || 'dev-secret-change-me';
const TOKEN_TTL_MS = 1000 * 60 * 60 * 12; // 12 hours

/* ---------- passwords (scrypt) ---------- */

function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const derived = crypto.scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${derived}`;
}

function verifyPassword(password, stored) {
  const [salt, derived] = String(stored).split(':');
  if (!salt || !derived) return false;
  const candidate = crypto.scryptSync(password, salt, 64);
  const expected = Buffer.from(derived, 'hex');
  return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
}

/* ---------- tokens (HMAC, no external deps) ---------- */

const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
const sign = (payload) => crypto.createHmac('sha256', SECRET).update(payload).digest('base64url');

function issueToken(user) {
  const body = b64({ sub: user.id, role: user.role, exp: Date.now() + TOKEN_TTL_MS });
  return `${body}.${sign(body)}`;
}

function readToken(token) {
  if (typeof token !== 'string' || !token.includes('.')) return null;
  const [body, signature] = token.split('.');
  const expected = sign(body);
  if (signature.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) return null;
  try {
    const claims = JSON.parse(Buffer.from(body, 'base64url').toString());
    if (!claims.exp || claims.exp < Date.now()) return null;
    return claims;
  } catch {
    return null;
  }
}

/* ---------- middleware ---------- */

function attachUser(req, _res, next) {
  const header = req.get('authorization') || '';
  const claims = header.startsWith('Bearer ') ? readToken(header.slice(7)) : null;
  req.user = claims ? db.data.users.find((u) => u.id === claims.sub) || null : null;
  next();
}

function requireAuth(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Sign in to continue.' });
  next();
}

function requireAdmin(req, res, next) {
  if (!req.user) return res.status(401).json({ error: 'Sign in to continue.' });
  if (req.user.role !== 'admin') return res.status(403).json({ error: 'This area is for admins only.' });
  next();
}

const publicUser = (u) => u && ({ id: u.id, name: u.name, email: u.email, role: u.role, company: u.company || '' });

module.exports = { hashPassword, verifyPassword, issueToken, attachUser, requireAuth, requireAdmin, publicUser };
