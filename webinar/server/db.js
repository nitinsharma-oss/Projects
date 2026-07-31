'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
const DATA_FILE = path.join(DATA_DIR, 'store.json');

const EMPTY = { users: [], webinars: [], registrations: [], cards: [] };

let cache = null;
let writeQueue = Promise.resolve();

function load() {
  if (cache) return cache;
  fs.mkdirSync(DATA_DIR, { recursive: true });
  if (fs.existsSync(DATA_FILE)) {
    try {
      cache = { ...EMPTY, ...JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')) };
    } catch (err) {
      throw new Error(`Data file at ${DATA_FILE} is not valid JSON. Fix or delete it, then restart.`);
    }
  } else {
    cache = structuredClone(EMPTY);
    flush();
  }
  return cache;
}

// Serialised write-to-temp-then-rename so a crash mid-write can't truncate the store.
function flush() {
  const snapshot = JSON.stringify(cache, null, 2);
  writeQueue = writeQueue.then(() => {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    const tmp = `${DATA_FILE}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, snapshot);
    fs.renameSync(tmp, DATA_FILE);
  }).catch((err) => console.error('[db] write failed:', err.message));
  return writeQueue;
}

const db = {
  get data() { return load(); },
  save: flush,
  id: (prefix) => `${prefix}_${crypto.randomBytes(8).toString('hex')}`,
  reset() {
    cache = structuredClone(EMPTY);
    return flush();
  },
};

module.exports = db;
