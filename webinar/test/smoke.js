'use strict';
/* End-to-end smoke test. Runs against a throwaway data dir: npm test */

const path = require('path');
const fs = require('fs');
const os = require('os');

process.env.DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'stage-test-'));
process.env.PORT = '4321';

require(path.join(__dirname, '..', 'server', 'seed.js'));
const app = require('../server/index.js');

let passed = 0;
const failures = [];

function check(label, condition) {
  if (condition) { passed++; console.log(`  ok   ${label}`); }
  else { failures.push(label); console.log(`  FAIL ${label}`); }
}

const base = `http://127.0.0.1:${process.env.PORT}`;

async function call(path, { method = 'GET', body, token } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  let data = null;
  try { data = JSON.parse(text); } catch { data = text; }
  return { status: res.status, data };
}

(async () => {
  const server = app.listen(process.env.PORT);
  await new Promise((r) => server.once('listening', r));
  console.log('\nStage smoke test\n');

  // --- auth ---
  const admin = await call('/api/auth/signin', { method: 'POST', body: { email: 'admin@stage.test', password: 'password123' } });
  check('admin signs in', admin.status === 200 && admin.data.user.role === 'admin');
  const adminToken = admin.data.token;

  const bad = await call('/api/auth/signin', { method: 'POST', body: { email: 'admin@stage.test', password: 'wrong' } });
  check('wrong password is rejected', bad.status === 401);

  const short = await call('/api/auth/signup', { method: 'POST', body: { name: 'X', email: 'x@t.test', password: 'abc' } });
  check('short password is rejected', short.status === 400);

  const signup = await call('/api/auth/signup', { method: 'POST', body: { name: 'Test Person', email: 'test@t.test', password: 'password123', company: 'Testing Co' } });
  check('new attendee signs up', signup.status === 201);
  const userToken = signup.data.token;

  const dupe = await call('/api/auth/signup', { method: 'POST', body: { name: 'Test Person', email: 'test@t.test', password: 'password123' } });
  check('duplicate email is rejected', dupe.status === 409);

  // --- permissions ---
  check('anonymous cannot reach admin', (await call('/api/admin/overview')).status === 401);
  check('attendee cannot reach admin', (await call('/api/admin/overview', { token: userToken })).status === 403);
  check('garbage token is rejected', (await call('/api/auth/me', { token: 'nonsense.sig' })).status === 401);

  // --- catalogue ---
  const list = await call('/api/webinars', { token: userToken });
  check('catalogue loads', list.status === 200 && list.data.webinars.length > 0);
  check('drafts stay hidden from attendees', !list.data.webinars.some((w) => w.state === 'draft'));

  const live = list.data.webinars.find((w) => w.state === 'live');
  check('a live session is derived from the clock', Boolean(live));
  check('room link is withheld before registering', live.joinUrl === null);

  // --- registration flow ---
  const reg = await call(`/api/webinars/${live.id}/register`, { method: 'POST', token: userToken });
  check('attendee registers', reg.status === 201 && reg.data.webinar.isRegistered);

  const twice = await call(`/api/webinars/${live.id}/register`, { method: 'POST', token: userToken });
  check('double registration is blocked', twice.status === 409);

  const join = await call(`/api/webinars/${live.id}/join`, { method: 'POST', token: userToken });
  check('join returns the room link', join.status === 200 && Boolean(join.data.joinUrl));

  const mine = await call('/api/me/registrations', { token: userToken });
  check('session appears in my list, marked attended', mine.data.registrations.some((w) => w.id === live.id && w.attended));

  const ended = list.data.webinars.find((w) => w.state === 'ended');
  if (ended) check('registering for a finished session is refused',
    (await call(`/api/webinars/${ended.id}/register`, { method: 'POST', token: userToken })).status === 409);

  // --- admin CRUD ---
  const created = await call('/api/admin/webinars', {
    method: 'POST', token: adminToken,
    body: { title: 'Capacity test', startsAt: new Date(Date.now() + 7200000).toISOString(), durationMin: 30, capacity: 1, status: 'scheduled', joinUrl: 'https://x.test', tags: 'a, b' },
  });
  check('admin creates a session', created.status === 201 && created.data.webinar.tags.length === 2);
  const newId = created.data.webinar.id;

  check('invalid date is refused',
    (await call('/api/admin/webinars', { method: 'POST', token: adminToken, body: { title: 'Bad', startsAt: 'not-a-date' } })).status === 400);

  check('missing title is refused',
    (await call('/api/admin/webinars', { method: 'POST', token: adminToken, body: { startsAt: new Date().toISOString() } })).status === 400);

  await call(`/api/webinars/${newId}/register`, { method: 'POST', token: userToken });
  const full = await call(`/api/webinars/${newId}/register`, { method: 'POST', token: adminToken });
  check('capacity limit holds', full.status === 409);

  const cancelled = await call(`/api/webinars/${newId}/register`, { method: 'DELETE', token: userToken });
  check('attendee gives up a seat', cancelled.status === 200 && !cancelled.data.webinar.isRegistered);

  const patched = await call(`/api/admin/webinars/${newId}`, { method: 'PATCH', token: adminToken, body: { title: 'Renamed', capacity: null } });
  check('admin edits a session', patched.data.webinar.title === 'Renamed' && patched.data.webinar.capacity === null);

  const csv = await call(`/api/admin/webinars/${live.id}/registrants.csv`, { token: adminToken });
  check('CSV export returns rows', typeof csv.data === 'string' && csv.data.startsWith('Name,Email'));

  const overview = await call('/api/admin/overview', { token: adminToken });
  check('overview reports a live session', overview.data.counts.live >= 1);
  check('overview reports a show rate', typeof overview.data.counts.showRate === 'number');

  check('admin deletes a session', (await call(`/api/admin/webinars/${newId}`, { method: 'DELETE', token: adminToken })).status === 200);
  check('deleted session is gone', (await call(`/api/webinars/${newId}`)).status === 404);
  check('unknown endpoint returns JSON 404', (await call('/api/nope')).status === 404);

  server.close();
  fs.rmSync(process.env.DATA_DIR, { recursive: true, force: true });

  console.log(`\n${passed} passed, ${failures.length} failed\n`);
  process.exit(failures.length ? 1 : 0);
})();
