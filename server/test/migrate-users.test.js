// Testy migrace uživatelů ze SQLite do cílové databáze
// (scripts/migrate-users.js).
//
// Cíl je tady taky SQLite `:memory:` — logika migrace je na driveru nezávislá
// (jde přes db/adapter.js), takže se ověří i to, co poteče do MariaDB.
// Podstatné je, že se přenášejí bcrypt hashe 1:1 (hesla musí dál fungovat)
// a že se existující uživatelé v cíli nepřepisují bez `--overwrite`.

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');

const fs = require('fs');
const os = require('os');
const path = require('path');

const Database = require('better-sqlite3');
const bcrypt = require('bcrypt');

const { openAdapter, nowIso } = require('../db/adapter');
const { migrateUsers, toIso } = require('../scripts/migrate-users');

let tempDir;
let sourcePath;

/// Zdrojová `users.db` ve starém tvaru (created_at jako 'YYYY-MM-DD HH:MM:SS').
function makeSourceDb(users) {
  const db = new Database(sourcePath);
  db.exec(fs.readFileSync(path.join(__dirname, '..', 'db', 'schema.sql'), 'utf8'));
  const ins = db.prepare(
    'INSERT INTO users (username, password_hash, is_admin, created_at) VALUES (?, ?, ?, ?)'
  );
  for (const u of users) ins.run(u.username, u.hash, u.isAdmin ? 1 : 0, u.createdAt);
  db.close();
}

function openTarget() {
  return openAdapter({ driver: 'sqlite', schemas: ['schema'], sqliteFile: ':memory:' });
}

beforeEach(() => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'p2l-migrate-'));
  sourcePath = path.join(tempDir, 'users.db');
});

afterEach(() => {
  try {
    fs.rmSync(tempDir, { recursive: true, force: true });
  } catch {
    // WAL soubory mohou být ještě zamčené — na výsledku testu nezáleží
  }
});

describe('toIso', () => {
  test('starý SQLite tvar převede na ISO 8601 v UTC', () => {
    assert.equal(toIso('2026-05-22 14:09:15'), '2026-05-22T14:09:15.000Z');
  });

  test('ISO nechá být, nesmysl nahradí aktuálním časem', () => {
    assert.equal(toIso('2026-05-22T14:09:15.000Z'), '2026-05-22T14:09:15.000Z');
    for (const bad of ['', null, undefined, 'nedatum']) {
      assert.ok(toIso(bad).endsWith('Z'));
    }
  });
});

describe('migrateUsers', () => {
  test('přenese uživatele včetně hashe — původní heslo dál funguje', async () => {
    const hash = bcrypt.hashSync('tajneheslo', 4); // nízké rounds = rychlý test
    makeSourceDb([
      { username: 'radek', hash, isAdmin: true, createdAt: '2026-05-22 14:09:15' },
      { username: 'michal', hash: bcrypt.hashSync('jine', 4), isAdmin: false, createdAt: '2026-06-12 15:31:52' },
    ]);

    const target = await openTarget();
    const r = await migrateUsers(sourcePath, target);
    assert.deepEqual(r.created.sort(), ['michal', 'radek']);
    assert.equal(r.total, 2);
    assert.deepEqual(r.skipped, []);

    const row = await target.get(
      'SELECT password_hash AS h, is_admin AS a, created_at AS c FROM users WHERE username = :u',
      { u: 'radek' }
    );
    // Hash 1:1 → přihlášení původním heslem projde.
    assert.equal(row.h, hash);
    assert.ok(bcrypt.compareSync('tajneheslo', row.h));
    assert.equal(row.a, 1);
    // created_at se sjednotil na ISO.
    assert.equal(row.c, '2026-05-22T14:09:15.000Z');

    // Příznak admina se nepřebarvuje.
    const michal = await target.get('SELECT is_admin AS a FROM users WHERE username = :u', { u: 'michal' });
    assert.equal(michal.a, 0);
    await target.close();
  });

  test('existujícího uživatele přeskočí, s overwrite přepíše', async () => {
    const oldHash = bcrypt.hashSync('stare', 4);
    makeSourceDb([{ username: 'radek', hash: oldHash, isAdmin: true, createdAt: '2026-05-22 14:09:15' }]);

    const target = await openTarget();
    const otherHash = bcrypt.hashSync('uzjinevcili', 4);
    await target.run(
      `INSERT INTO users (username, password_hash, is_admin, created_at)
       VALUES (:u, :h, 0, :at)`,
      { u: 'radek', h: otherHash, at: nowIso() }
    );

    // Bez overwrite se cíl nesmí dotknout.
    let r = await migrateUsers(sourcePath, target);
    assert.deepEqual(r.skipped, ['radek']);
    assert.deepEqual(r.created, []);
    let row = await target.get('SELECT password_hash AS h, is_admin AS a FROM users WHERE username = :u', { u: 'radek' });
    assert.equal(row.h, otherHash);
    assert.equal(row.a, 0);

    // S overwrite se přepíše hash i příznak admina.
    r = await migrateUsers(sourcePath, target, { overwrite: true });
    assert.deepEqual(r.updated, ['radek']);
    row = await target.get('SELECT password_hash AS h, is_admin AS a FROM users WHERE username = :u', { u: 'radek' });
    assert.equal(row.h, oldHash);
    assert.equal(row.a, 1);

    // Duplikát nevznikl.
    const { n } = await target.get('SELECT COUNT(*) AS n FROM users');
    assert.equal(n, 1);
    await target.close();
  });

  test('dry-run nic nezapíše, ale ohlásí, co by udělal', async () => {
    makeSourceDb([{ username: 'radek', hash: bcrypt.hashSync('x', 4), isAdmin: true, createdAt: '2026-05-22 14:09:15' }]);
    const target = await openTarget();

    const r = await migrateUsers(sourcePath, target, { dryRun: true });
    assert.deepEqual(r.created, ['radek']);
    const { n } = await target.get('SELECT COUNT(*) AS n FROM users');
    assert.equal(n, 0, 'dry-run nesmí zapisovat');
    await target.close();
  });

  test('uživatele, kteří jsou jen v cíli, nemaže', async () => {
    makeSourceDb([{ username: 'radek', hash: bcrypt.hashSync('x', 4), isAdmin: true, createdAt: '2026-05-22 14:09:15' }]);
    const target = await openTarget();
    await target.run(
      'INSERT INTO users (username, password_hash, is_admin, created_at) VALUES (:u, :h, 1, :at)',
      { u: 'jen-v-cili', h: 'hash', at: nowIso() }
    );

    await migrateUsers(sourcePath, target);
    assert.ok(await target.get('SELECT 1 AS x FROM users WHERE username = :u', { u: 'jen-v-cili' }));
    const { n } = await target.get('SELECT COUNT(*) AS n FROM users');
    assert.equal(n, 2);
    await target.close();
  });

  test('chybějící zdroj vyhodí čitelnou chybu', async () => {
    const target = await openTarget();
    await assert.rejects(
      () => migrateUsers(path.join(tempDir, 'neexistuje.db'), target),
      /Zdrojová databáze neexistuje/
    );
    await target.close();
  });
});
