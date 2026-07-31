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
npm test         # 51 end-to-end checks against a throwaway data dir

npm run promote -- you@example.com   # make an existing account an admin
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
  cards.js      NFC card tokens, enrolment, tap-to-check-in
  routes/       auth.js · webinars.js (attendee) · admin.js · cards.js
  seed.js       demo data
  promote.js    CLI: promote an account to admin
public/
  stage.css     design tokens + components, shared by both dashboards
  stage.js      API client, session, formatting, the tally rail
  index.html    sign in / sign up
  dashboard.html  attendee dashboard
  admin.html      admin dashboard
  cards.html      card enrolment + tag writing (admin)
  station.html    check-in desk (admin)
  tap.html        where a tag tap lands (no sign-in)
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

---

# NFC card check-in

Tapping a card marks the holder present at whichever session is on air. Three read paths,
because no single one covers every phone.

## The platform problem, and the way round it

| | Read a tag from your own code | Notes |
| --- | --- | --- |
| **Android** | Yes — Web NFC, Chrome 89+ | Needs a secure context: HTTPS, or `http://localhost` |
| **iPhone** | No — Safari has no Web NFC | Core NFC needs a native app |

The way round it is to stop trying to read the tag and let the OS do it. Write a **URL** to
the tag as a single NDEF record, and both platforms handle it with no app:

- **iPhone XS and newer, iOS 13+** — background tag reading. Tap, a banner appears, it opens the link.
- **iPhone 7 to XR, iOS 14+** — same thing via the NFC Tag Reader in Control Centre.
- **Android** — opens the URL directly.

That URL is `/c/<token>`, and the page behind it checks the person in on load. This is the only
path that works on every phone without installing anything.

## Don't use 125 kHz RFID

The cheap "RFID cards" are 125 kHz EM4100/T5577. No phone can read them — not Android, not
iPhone. They need a dedicated reader, which makes them strictly worse than NFC here. NFC *is*
RFID, at 13.56 MHz.

Also avoid **MIFARE Classic**: Android reads it, iPhone can't, and its crypto has been broken
since 2008.

## What to buy

| Item | Spec | Roughly |
| --- | --- | --- |
| Cards | **NTAG213** (144 bytes user memory) — plenty for a URL | 20–40p each in bulk |
| Cards, more room | NTAG215 (504 B) or NTAG216 (888 B) | slightly more |
| Cards, anti-clone | **NTAG424 DNA** — AES-128, rotating cryptogram per tap | £1–2 each |
| Desk reader | Any USB **keyboard-wedge** NFC reader — types the UID and presses Enter | £20–40 |
| Reader/writer | ACR122U if you want to write from a PC | ~£35 |

Prices drift, so treat those as ballpark. NTAG213 in ISO card format is the default choice.

## Writing the tags

Three ways, in order of how many cards you have:

1. **A handful** — open `/cards` in Chrome on Android, hit **Write to tag**, hold a blank
   against the phone. Uses Web NFC directly.
2. **Any platform** — hit **Copy URL** and write it with the **NFC Tools** app (iOS and Android)
   or an ACR122U on a PC.
3. **Hundreds** — send the URL list to a card bureau for bulk encoding, or script an ACR122U
   with `nfcpy`.

Write **one NDEF record, type `url`**. Nothing else. Extra records are what breaks the
no-app-needed behaviour on iOS.

Two things worth doing before handing cards out:

- **Lock the tag** (`makeReadOnly()`, or the lock option in NFC Tools) so nobody rewrites it.
  This is irreversible — test the card first.
- **Never write personal data to the tag.** Only the token goes on there. Cards get lost, and a
  tag is readable by any phone that touches it.

## Security model

The two check-in doors trust different things, on purpose:

| Door | Credential | Auth required | Why |
| --- | --- | --- | --- |
| `POST /api/checkin` with `token` | HMAC-signed, written on the tag | None | The token *is* the credential. No session means it works from a tag tap on any phone. |
| `POST /api/checkin` with `uid` | The chip's serial number | Admin session | A UID is cloneable with a £25 device, so it's only trusted at a staffed desk. |

Revoking a card sets a flag rather than deleting the record — a lost card stops working
immediately, and the tap history stays auditable.

If cards need to survive a genuinely hostile crowd, **NTAG424 DNA** is the upgrade: each tap
emits a fresh AES CMAC in the URL, so copying the URL off one tap gets you nothing. The
verification step slots into `resolveToken` in `server/cards.js`.

## Pages and endpoints

| Path | What |
| --- | --- |
| `/cards` | Enrol cards, write tags, revoke. Admin. |
| `/station` | Check-in desk: Web NFC, desk reader, manual entry. Admin. |
| `/c/:token` | Where a tag tap lands. No sign-in. |
| `POST /api/checkin` | `{token}` or `{uid, sessionId?}` |
| `GET /api/checkin/session` | Which session taps count towards |
| `GET/POST /api/admin/cards` · `PATCH/DELETE /api/admin/cards/:id` | Enrolment |

## Testing without hardware

You don't need a card to try the flow. Enrol one at `/cards`, copy the URL, and open it in a
browser — that's exactly what a tap does. At `/station`, type a card number and press Enter;
that's exactly what a desk reader does.

One gotcha for real testing: Web NFC needs a secure context. `http://localhost` qualifies, a
LAN IP like `http://192.168.1.20` does not — which is the usual reason scanning silently does
nothing. Use `chrome://inspect` port forwarding, or put a tunnel with HTTPS in front.

---

# Changelog

Newest first. Every entry records what changed and why, so the reasoning doesn't only live
in a chat window.

## NFC card check-in

**Added** — `server/cards.js`, `server/routes/cards.js`, `public/cards.html`,
`public/station.html`, `public/tap.html`. Tests: 29 → 51.

Tapping a card now marks the holder present at whichever session is on air. Three read paths,
because no single one covers every phone — see the NFC section above for the full detail.

The decision that shaped everything else: **write a URL to the tag rather than reading the tag
from our own code.** Reading requires Web NFC, which is Chrome-on-Android only; iOS Safari has
none. But *both* platforms open a URL from an NDEF record with no app installed. So the tag
carries `/c/<token>` and the OS does the work.

Two corrections to the original plan worth recording:

- 125 kHz RFID would have been worse, not better. No phone can read it. NFC *is* RFID at
  13.56 MHz — the frequency is the whole difference.
- MIFARE Classic is out: iPhone can't read it and its crypto broke in 2008. NTAG213 instead.

The security split is deliberate. Token check-in needs no session because the token *is* the
credential — that's precisely what makes the no-app iPhone path work. UID check-in requires an
admin session because a UID clones with a £25 device, so it's only trusted with staff present.
Revoking sets a flag rather than deleting, so a lost card dies instantly while its tap history
survives for audit.

All of it is testable without hardware: copy a card's URL into a browser (that's a tap), or
type a card number at `/station` and press Enter (that's a desk reader).

## Admin promotion script

**Added** — `server/promote.js`, `npm run promote`.

`/admin` correctly bounces non-admins to `/dashboard`, and sign-up always creates a regular
user with no way to self-promote. That left no route to an admin account other than the seeded
demo one. `npm run promote -- you@example.com` fills the gap.

## Fixed: hidden form fields showing

**Changed** — one line in `public/stage.css`: `[hidden] { display: none !important; }`

The Name and Company fields were visible on the sign-in screen, and the search box appeared on
all three attendee views. Cause: component rules `label { display: grid }` and
`.filters { display: flex }` both outrank the browser's built-in `[hidden] { display: none }`,
so the attribute was applied and then overridden. Worth remembering — any future
`display`-setting component rule will do the same thing.

## Initial build

Backend plus two dashboards, built on an assumed webinar brief.

- Auth: scrypt password hashing, HMAC session tokens, no external auth dependency.
- Session CRUD, registration with capacity limits, attendance tracking, CSV export.
- **Live and ended are derived from the clock, not stored.** An admin sets `draft`,
  `scheduled` or `cancelled`; the rest is computed on read. No cron job, no state that can
  drift out of sync.
- **Two serialisation shapes** in `domain.js`. `toPublic()` strips internal fields and withholds
  the room link until someone holds a seat and it's within 15 minutes of start; `toAdmin()`
  returns everything. Keeping the split in one module means a route can't leak a new field by
  forgetting to filter.
- Storage is a JSON file. `db.js` is the only module that knows that, so swapping in Postgres
  is a single-file change.
