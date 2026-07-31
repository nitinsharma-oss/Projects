'use strict';
const db = require('./db');

/**
 * Stored status is what an admin controls (draft / scheduled / cancelled).
 * Live vs ended is derived from the clock so the UI never needs a cron job.
 */
function derivedState(w, now = Date.now()) {
  if (w.status === 'draft') return 'draft';
  if (w.status === 'cancelled') return 'cancelled';
  const start = new Date(w.startsAt).getTime();
  const end = start + w.durationMin * 60_000;
  if (now < start) return 'scheduled';
  if (now <= end) return 'live';
  return 'ended';
}

const registrationsFor = (webinarId) => db.data.registrations.filter((r) => r.webinarId === webinarId);

function stats(w) {
  const regs = registrationsFor(w.id);
  const attended = regs.filter((r) => r.attended);
  const watched = attended.reduce((sum, r) => sum + (r.watchedMin || 0), 0);
  return {
    registered: regs.length,
    attended: attended.length,
    attendanceRate: regs.length ? Math.round((attended.length / regs.length) * 100) : 0,
    avgWatchMin: attended.length ? Math.round(watched / attended.length) : 0,
    seatsLeft: w.capacity ? Math.max(0, w.capacity - regs.length) : null,
  };
}

/** Shape sent to the user dashboard — no internal fields, no join URL until it's earned. */
function toPublic(w, viewerId = null, now = Date.now()) {
  const state = derivedState(w, now);
  const mine = viewerId ? registrationsFor(w.id).find((r) => r.userId === viewerId) : null;
  const s = stats(w);
  return {
    id: w.id,
    title: w.title,
    description: w.description,
    host: w.host,
    tags: w.tags || [],
    startsAt: w.startsAt,
    durationMin: w.durationMin,
    capacity: w.capacity,
    state,
    seatsLeft: s.seatsLeft,
    registeredCount: s.registered,
    isRegistered: Boolean(mine),
    attended: Boolean(mine?.attended),
    // Only hand out the room link to someone holding a seat, and only near start time.
    joinUrl: mine && (state === 'live' || minutesUntil(w, now) <= 15) ? w.joinUrl : null,
    recordingUrl: state === 'ended' ? w.recordingUrl || null : null,
  };
}

/** Everything the admin dashboard needs, including the fields users never see. */
function toAdmin(w, now = Date.now()) {
  return {
    ...w,
    state: derivedState(w, now),
    stats: stats(w),
  };
}

const minutesUntil = (w, now = Date.now()) => Math.round((new Date(w.startsAt).getTime() - now) / 60_000);

module.exports = { derivedState, registrationsFor, stats, toPublic, toAdmin, minutesUntil };
