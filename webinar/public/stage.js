/* Shared front-end helpers for both dashboards. */

const TOKEN_KEY = 'stage.token';

export const session = {
  get token() { return localStorage.getItem(TOKEN_KEY); },
  set token(v) { v ? localStorage.setItem(TOKEN_KEY, v) : localStorage.removeItem(TOKEN_KEY); },
  signOut() { this.token = null; location.href = '/'; },
};

export async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(`/api${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(session.token ? { Authorization: `Bearer ${session.token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });

  if (res.status === 401) {
    session.token = null;
    location.href = '/';
    throw new Error('Session expired.');
  }
  const data = res.headers.get('content-type')?.includes('json') ? await res.json() : null;
  if (!res.ok) throw new Error(data?.error || 'Request failed.');
  return data;
}

/** Redirects to sign-in if there's no valid session; enforces admin-only pages. */
export async function requireSession({ admin = false } = {}) {
  if (!session.token) { location.href = '/'; return null; }
  const { user } = await api('/auth/me');
  if (admin && user.role !== 'admin') { location.href = '/dashboard'; return null; }
  if (!admin && user.role === 'admin') { location.href = '/admin'; return null; }
  return user;
}

/* ---------- formatting ---------- */

export const fmtDate = (iso) =>
  new Date(iso).toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });

export const fmtTime = (iso) =>
  new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

export function countdown(iso) {
  const diff = new Date(iso).getTime() - Date.now();
  if (diff < 0) return 'started';
  const mins = Math.round(diff / 60000);
  if (mins < 60) return `in ${mins} min`;
  const hrs = Math.round(mins / 60);
  if (hrs < 48) return `in ${hrs} h`;
  return `in ${Math.round(hrs / 24)} days`;
}

export const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export const el = (id) => document.getElementById(id);

export function notify(node, message, kind = 'error') {
  node.innerHTML = message ? `<div class="notice ${kind}">${esc(message)}</div>` : '';
  if (message) node.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

/* ---------- tally rail ----------
   The day at a glance: one row, real hours, a playhead that moves.
   Red only ever appears here when something is genuinely on air. */

const RAIL_START = 6;  // 06:00
const RAIL_END = 23;   // 23:00

export function renderRail(container, sessions, { label = 'Today' } = {}) {
  const now = new Date();
  const today = sessions.filter((s) => new Date(s.startsAt).toDateString() === now.toDateString());
  const live = today.some((s) => s.state === 'live');
  const span = RAIL_END - RAIL_START;
  const pos = (d) => ((d.getHours() + d.getMinutes() / 60 - RAIL_START) / span) * 100;

  const ticks = Array.from({ length: span + 1 }, (_, i) => {
    const hour = RAIL_START + i;
    return `<div class="rail-tick" style="left:${(i / span) * 100}%">${
      hour % 3 === 0 ? `<span>${String(hour).padStart(2, '0')}</span>` : ''
    }</div>`;
  }).join('');

  const blocks = today.map((s) => {
    const start = new Date(s.startsAt);
    const left = Math.max(0, pos(start));
    const width = Math.min(100 - left, (s.durationMin / 60 / span) * 100);
    return `<div class="rail-block" data-state="${s.state}" style="left:${left}%;width:${width}%"
      title="${esc(s.title)} · ${fmtTime(s.startsAt)}">${esc(s.title)}</div>`;
  }).join('');

  const playhead = now.getHours() >= RAIL_START && now.getHours() < RAIL_END
    ? `<div class="playhead" style="left:${pos(now)}%"></div>`
    : '';

  container.innerHTML = `
    <div class="rail-head">
      <span class="eyebrow">${esc(label)} · ${today.length} session${today.length === 1 ? '' : 's'}</span>
      <span class="clock">${live ? 'ON AIR' : fmtTime(now.toISOString())}</span>
    </div>
    ${today.length
      ? `<div class="rail-track">${ticks}${blocks}${playhead}</div>`
      : '<div class="rail-empty">Nothing scheduled today.</div>'}
  `;

  const lamp = document.querySelector('.lamp');
  if (lamp) lamp.dataset.on = String(live);
}

/** Re-renders the rail every 30s so the playhead actually moves. */
export function startRailClock(fn) {
  fn();
  setInterval(fn, 30_000);
}
