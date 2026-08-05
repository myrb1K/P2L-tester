// Testy GET /api/bootstrap-status (bez auth) — podklad pro portable Windows
// EXE, které při první instalaci musí nabídnout založení účtu správce.
//
// Vzor harnessu (express + listen(0) + fetch) je stejný jako v units.test.js.

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

process.env.JWT_SECRET = 't'.repeat(32); // před require routes/auth

const express = require('express');
const cookieParser = require('cookie-parser');

const { openAdapter, nowIso } = require('../db/adapter');
const authRoutes = require('../routes/auth');

/// Uživatelská DB v :memory: se schématem z db/schema.sql. Driver natvrdo
/// sqlite — endpoint testujeme proti schématu, ne proti infrastruktuře.
function makeUsersDb() {
  return openAdapter({ driver: 'sqlite', schemas: ['schema'], sqliteFile: ':memory:' });
}

function makeApp(db) {
  const app = express();
  app.use(express.json());
  app.use(cookieParser());
  app.use('/api', authRoutes.makeRouter(db));
  return app;
}

async function withServer(db, fn) {
  const server = makeApp(db).listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api`;
  try {
    await fn(base);
  } finally {
    server.close();
    await db.close();
  }
}

async function insertUser(db, username, hash) {
  await db.run(
    `INSERT INTO users (username, password_hash, is_admin, created_at)
     VALUES (:username, :hash, 1, :at)`,
    { username, hash, at: nowIso() }
  );
}

describe('GET /api/bootstrap-status', () => {
  test('prázdná DB → hasUsers false (appka nabídne založení správce)', async () => {
    const db = await makeUsersDb();
    await withServer(db, async (base) => {
      const res = await fetch(`${base}/bootstrap-status`);
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), { hasUsers: false });
    });
  });

  test('DB s uživatelem → hasUsers true', async () => {
    const db = await makeUsersDb();
    await insertUser(db, 'radek', 'hash');
    await withServer(db, async (base) => {
      const res = await fetch(`${base}/bootstrap-status`);
      assert.deepEqual(await res.json(), { hasUsers: true });
    });
  });

  test('nevyžaduje přihlášení — klient ho potřebuje před loginem', async () => {
    const db = await makeUsersDb();
    await withServer(db, async (base) => {
      // žádná cookie ani Authorization header
      const res = await fetch(`${base}/bootstrap-status`);
      assert.equal(res.status, 200);
    });
  });

  test('neprozradí nic víc než jeden bool', async () => {
    const db = await makeUsersDb();
    await insertUser(db, 'radek', 'supertajnyhash');
    await withServer(db, async (base) => {
      const body = await (await fetch(`${base}/bootstrap-status`)).text();
      assert.equal(Object.keys(JSON.parse(body)).length, 1);
      assert.ok(!body.includes('radek'));
      assert.ok(!body.includes('supertajnyhash'));
    });
  });
});
