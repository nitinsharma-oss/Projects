'use strict';
const db = require('./db');
const { hashPassword } = require('./auth');

const HOUR = 3600_000;
const at = (offsetHours, durationMin) => new Date(Date.now() + offsetHours * HOUR).toISOString();

function seed() {
  db.reset();

  const people = [
    ['Ada Okonkwo', 'admin@stage.test', 'admin', 'Stage'],
    ['Marco Ferretti', 'marco@northwind.test', 'user', 'Northwind Retail'],
    ['Priya Raman', 'priya@lumenlabs.test', 'user', 'Lumen Labs'],
    ['Jonas Bergqvist', 'jonas@fika.test', 'user', 'Fika Commerce'],
    ['Yuki Tanabe', 'yuki@orbital.test', 'user', 'Orbital'],
  ].map(([name, email, role, company]) => {
    const user = {
      id: db.id('usr'),
      name,
      email,
      company,
      role,
      passwordHash: hashPassword('password123'),
      createdAt: new Date(Date.now() - 30 * 24 * HOUR).toISOString(),
    };
    db.data.users.push(user);
    return user;
  });

  const admin = people[0];
  const attendees = people.slice(1);

  const sessions = [
    {
      title: 'Lifecycle email that actually converts',
      description: 'A teardown of six retention flows, what each one is really optimising for, and where the drop-offs hide.',
      host: 'Ada Okonkwo',
      startsAt: at(-0.4), durationMin: 60, capacity: 500,
      tags: ['email', 'retention'], status: 'scheduled',
      joinUrl: 'https://meet.stage.test/lifecycle-email',
    },
    {
      title: 'Segmentation without the spreadsheet',
      description: 'Building audience segments from behaviour instead of guesswork, with live examples on a messy dataset.',
      host: 'Priya Raman',
      startsAt: at(26), durationMin: 45, capacity: 300,
      tags: ['segmentation', 'data'], status: 'scheduled',
      joinUrl: 'https://meet.stage.test/segmentation',
    },
    {
      title: 'Deliverability clinic: open Q&A',
      description: 'Bring a bounced campaign. We go through headers, authentication and sender reputation on air.',
      host: 'Marco Ferretti',
      startsAt: at(74), durationMin: 90, capacity: 120,
      tags: ['deliverability'], status: 'scheduled',
      joinUrl: 'https://meet.stage.test/deliverability',
    },
    {
      title: 'Push notifications people don\u2019t mute',
      description: 'Timing, frequency caps and the copy patterns that survive a week on a real device.',
      host: 'Yuki Tanabe',
      startsAt: at(-52), durationMin: 60, capacity: 400,
      tags: ['push', 'mobile'], status: 'scheduled',
      joinUrl: 'https://meet.stage.test/push',
      recordingUrl: 'https://watch.stage.test/push-replay',
    },
    {
      title: 'Reporting that survives a board meeting',
      description: 'Which numbers to lead with, which to bury in the appendix, and how to defend both.',
      host: 'Ada Okonkwo',
      startsAt: at(-170), durationMin: 45, capacity: null,
      tags: ['analytics'], status: 'scheduled',
      joinUrl: 'https://meet.stage.test/reporting',
      recordingUrl: 'https://watch.stage.test/reporting-replay',
    },
    {
      title: 'Untitled: SMS pilot programme',
      description: 'Draft outline. Needs a running order and a co-host before this goes out.',
      host: 'Ada Okonkwo',
      startsAt: at(200), durationMin: 60, capacity: 200,
      tags: ['sms'], status: 'draft',
      joinUrl: '',
    },
  ].map((s) => {
    const webinar = {
      id: db.id('web'),
      recordingUrl: '',
      createdBy: admin.id,
      createdAt: new Date(Date.now() - 10 * 24 * HOUR).toISOString(),
      ...s,
    };
    db.data.webinars.push(webinar);
    return webinar;
  });

  // Registrations: everyone on the live one, thinning out for later dates.
  const pattern = [
    [0, attendees, 0.75],
    [1, attendees.slice(0, 3), 0],
    [2, attendees.slice(1), 0],
    [3, attendees, 0.5],
    [4, attendees.slice(0, 2), 1],
  ];

  for (const [index, group, attendedRatio] of pattern) {
    group.forEach((user, i) => {
      const attended = i / group.length < attendedRatio;
      db.data.registrations.push({
        id: db.id('reg'),
        webinarId: sessions[index].id,
        userId: user.id,
        registeredAt: new Date(Date.now() - (7 - i) * 24 * HOUR).toISOString(),
        attended,
        joinedAt: attended ? sessions[index].startsAt : null,
        watchedMin: attended ? Math.round(sessions[index].durationMin * (0.4 + 0.15 * i)) : 0,
      });
    });
  }

  db.save();
  console.log('Seeded %d people, %d sessions, %d registrations.',
    db.data.users.length, db.data.webinars.length, db.data.registrations.length);
  console.log('Admin  admin@stage.test / password123');
  console.log('Viewer marco@northwind.test / password123');
}

seed();
