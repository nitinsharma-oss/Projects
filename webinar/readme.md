# Stage — webinar platform

A backend plus two dashboards: one for attendees, one for the team running the sessions.

I built this against an assumed brief — a webinar platform, since that's what the link pointed at.
If the real product is something else, the shape here (auth → catalogue → registration →
attendance → analytics) transfers with a rename of the domain objects.

## Run it

```bash
npm install
npm run seed     # demo accounts, sessions and registrations
npm start        # http://localhost:3000
npm test         # 29 end-to-end checks against a throwaway data dir
```

| Account | Password | Lands on |
| --- | --- | --- |
| `admin@stage.test` | `password123` | `/admin` — control room |
| `marco@northwind.test` | `password123` | `/dashboard` — attendee view |

The seed puts one session **on air right now**, so the live states and the tally rail have
something to show the moment you open it.

## Layout

```
server/
  index.js      Express app, route mounting, static serving
  db.js         JSON store, atomic temp-file-then-rename writes
  auth.js       scrypt password hashing, HMAC session tokens, guards
  domain.js     derived state, capacity, the two serialisation shapes
  routes/       auth.js · webinars.js (attendee) · admin.js
  seed.js       demo data
public/
  stage.css     design tokens + components, shared by both dashboards
  stage.js      API client, session, formatting, the tally rail
  index.html    sign in / sign up
  dashboard.html  attendee dashboard
  admin.html      admin dashboard
test/smoke.js
```

Two decisions worth knowing about:

**Live is derived, not stored.** An admin sets `draft`, `scheduled` or `cancelled`. Whether a
session is *live* or *ended* is computed from `startsAt + durationMin` on every read, so there's
no cron job and no state that can drift out of sync with the clock.

**Two serialisation shapes.** `toPublic()` is what attendees get — no internal fields, and the
room link is withheld until you hold a seat *and* it's within 15 minutes of start. `toAdmin()`
returns everything plus attendance stats. The split lives in `domain.js` so a new field can't
leak by accident from a route that forgot to filter.

## API

| Method | Path | Who |
| --- | --- | --- |
| POST | `/api/auth/signup` · `/api/auth/signin` | anyone |
| GET | `/api/auth/me` | signed in |
| GET | `/api/webinars` · `/api/webinars/:id` | anyone (published only) |
| POST/DELETE | `/api/webinars/:id/register` | attendee |
| POST | `/api/webinars/:id/join` | attendee, live only — marks attendance |
| GET | `/api/me/registrations` | attendee |
| GET/POST | `/api/admin/webinars` | admin |
| PATCH/DELETE | `/api/admin/webinars/:id` | admin |
| GET | `/api/admin/webinars/:id/registrants[.csv]` | admin |
| GET | `/api/admin/overview` · `/api/admin/people` | admin |

## What each dashboard does

**Attendee** — three views: sessions you hold a seat for, the catalogue to browse and search,
and replays. Registering is one click; the room button turns red and says *Join the room* only
when the session is actually on air. Attendance and watch time are recorded on join.

**Admin** — a control room overview (on air / upcoming / registrations / show rate, today's run
of show, recently finished), full session CRUD in a dialog, a registrant table per session with
CSV export, and a people list with per-person registration and attendance counts.

## Design

The interface is built around a broadcast gallery: cool grey field, near-black chrome,
Bricolage Grotesque for headings against IBM Plex Mono for anything that's data or a control
label. Red is reserved — it appears **only** when something is genuinely on air, nowhere else,
so a glance at the screen tells you the truth about the room.

The signature element is the **tally rail** at the top of both dashboards: the day laid out on
a real 06:00–23:00 timeline, sessions as blocks, a white playhead that moves every 30 seconds,
and a lamp in the sidebar that pulses while a session is live. The attendee sees only their own
day on it; the admin sees the whole schedule.

Both dashboards poll every 60 seconds, so a session going live updates without a refresh.

## Before this goes near production

- Swap the JSON store for Postgres — `db.js` is deliberately the only file that knows about
  storage, so this is one module.
- Move session tokens to httpOnly cookies with CSRF protection. They're in `localStorage`
  now, which is fine for a scaffold and not fine for real accounts.
- Set `SESSION_SECRET`; the fallback is a hardcoded dev value.
- Add rate limiting on `/api/auth/*`, email verification, and password reset.
- Real video: the room link is a plain URL field, ready to point at Zoom, Daily, LiveKit or
  whatever you land on.
