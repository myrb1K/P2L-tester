// Testy DB adapteru (db/adapter.js) a uživatelské vrstvy (db/users.js).
//
// Adapter je jediné místo, kde se rozdíl SQLite vs MariaDB řeší, takže se
// testují jeho dialektové fragmenty (skládají SQL v db/units.js), dělení
// schémat na statementy, chování transakce a introspekce sloupců.
// Běží nad sqlite `:memory:` — MariaDB část pokrývá `npm run test:mariadb`
// (viz test/units.test.js).

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const {
  openAdapter,
  resolveDriver,
  splitStatements,
  schemaPathFor,
  DIALECTS,
} = require('../db/adapter');
const {
  createUser,
  getUser,
  listUsers,
  deleteUser,
  resetPassword,
  adminCount,
  UserOpError,
} = require('../db/users');

function openUsers() {
  return openAdapter({ driver: 'sqlite', schemas: ['schema'], sqliteFile: ':memory:' });
}

describe('resolveDriver', () => {
  test('default sqlite, override má přednost před env', () => {
    const saved = process.env.DB_DRIVER;
    delete process.env.DB_DRIVER;
    assert.equal(resolveDriver(), 'sqlite');
    process.env.DB_DRIVER = 'mariadb';
    assert.equal(resolveDriver(), 'mariadb');
    assert.equal(resolveDriver('sqlite'), 'sqlite'); // override vyhrává
    if (saved === undefined) delete process.env.DB_DRIVER;
    else process.env.DB_DRIVER = saved;
  });

  test('neznámý driver vyhodí', () => {
    assert.throws(() => resolveDriver('postgres'), /Neznámý DB_DRIVER/);
  });
});

describe('dialektové fragmenty', () => {
  test('upsert / cast / collate podle dialektu', () => {
    assert.equal(DIALECTS.sqlite.onConflictDoNothing('id'), 'ON CONFLICT(id) DO NOTHING');
    assert.equal(DIALECTS.mariadb.onConflictDoNothing('id'), 'ON DUPLICATE KEY UPDATE id = id');

    assert.equal(
      DIALECTS.sqlite.onConflictUpdate('id', ['a', 'b']),
      'ON CONFLICT(id) DO UPDATE SET a = excluded.a, b = excluded.b'
    );
    assert.equal(
      DIALECTS.mariadb.onConflictUpdate('id', ['a', 'b']),
      'ON DUPLICATE KEY UPDATE a = VALUES(a), b = VALUES(b)'
    );

    assert.equal(DIALECTS.sqlite.castInt('id'), 'CAST(id AS INTEGER)');
    assert.equal(DIALECTS.mariadb.castInt('id'), 'CAST(id AS UNSIGNED)');

    // COLLATE NOCASE je SQLite specialita, MariaDB má ci collation ve schématu.
    assert.equal(DIALECTS.sqlite.collateNoCase, ' COLLATE NOCASE');
    assert.equal(DIALECTS.mariadb.collateNoCase, '');
  });

  test('schemaPathFor volí soubor podle dialektu', () => {
    assert.match(schemaPathFor('units-schema', 'sqlite'), /units-schema\.sql$/);
    assert.match(schemaPathFor('units-schema', 'mariadb'), /units-schema\.mariadb\.sql$/);
  });
});

describe('splitStatements', () => {
  test('odstraní -- komentáře a rozdělí na středníky', () => {
    const out = splitStatements(`
      -- komentář
      CREATE TABLE a (id INT);  -- za příkazem
      CREATE TABLE b (id INT);
    `);
    assert.equal(out.length, 2);
    assert.match(out[0], /^CREATE TABLE a/);
    assert.match(out[1], /^CREATE TABLE b/);
  });

  test('poslední příkaz bez středníku projde taky', () => {
    assert.deepEqual(splitStatements('SELECT 1'), ['SELECT 1']);
  });
});

describe('adapter — základní operace', () => {
  test('run/get/all + pojmenované i pozicové parametry', async () => {
    const db = await openUsers();
    const res = await db.run(
      `INSERT INTO users (username, password_hash, is_admin, created_at)
       VALUES (:u, :h, 0, :at)`,
      { u: 'a', h: 'x', at: '2026-01-01T00:00:00Z' }
    );
    assert.equal(res.changes, 1);
    assert.ok(res.lastInsertId > 0);

    const row = await db.get('SELECT username FROM users WHERE username = ?', ['a']);
    assert.equal(row.username, 'a');
    assert.equal((await db.all('SELECT * FROM users')).length, 1);

    // Dotaz bez parametrů nesmí spadnout na chybějícím bindu.
    assert.equal((await db.get('SELECT COUNT(*) AS n FROM users')).n, 1);
    await db.close();
  });

  test('columns() vrátí sloupce tabulky (podklad pro mini-migrace)', async () => {
    const db = await openUsers();
    const cols = await db.columns('users');
    for (const c of ['id', 'username', 'password_hash', 'is_admin', 'created_at']) {
      assert.ok(cols.has(c), `chybí sloupec ${c}`);
    }
    await db.close();
  });

  test('transakce commituje, při chybě rollbackuje', async () => {
    const db = await openUsers();
    const insert = (tx, u) =>
      tx.run(
        `INSERT INTO users (username, password_hash, is_admin, created_at)
         VALUES (:u, 'x', 0, '2026-01-01T00:00:00Z')`,
        { u }
      );

    await db.transaction(async (tx) => {
      await insert(tx, 'commited1');
      await insert(tx, 'commited2');
    });
    assert.equal((await db.get('SELECT COUNT(*) AS n FROM users')).n, 2);

    await assert.rejects(
      db.transaction(async (tx) => {
        await insert(tx, 'rolled-back');
        throw new Error('bum');
      }),
      /bum/
    );
    // Zápis z odrolované transakce nesmí zůstat.
    assert.equal((await db.get('SELECT COUNT(*) AS n FROM users')).n, 2);
    assert.equal(await db.get('SELECT 1 AS x FROM users WHERE username = :u', { u: 'rolled-back' }), undefined);
    await db.close();
  });
});

describe('db/users.js', () => {
  test('createUser + getUser (case-insensitive) + duplikát', async () => {
    const db = await openUsers();
    const created = await createUser(db, { username: ' radek ', password: 'pw', isAdmin: true });
    assert.equal(created.username, 'radek'); // trim
    assert.equal(!!created.isAdmin, true);

    // Collation sloupce dělá porovnání case-insensitive (COLLATE NOCASE).
    assert.ok(await getUser(db, 'RADEK'));

    await assert.rejects(
      () => createUser(db, { username: 'radek', password: 'pw' }),
      (e) => e instanceof UserOpError && e.code === 'duplicate'
    );
    await db.close();
  });

  test('prázdné jméno / heslo odmítnuto', async () => {
    const db = await openUsers();
    await assert.rejects(() => createUser(db, { username: '  ', password: 'pw' }), (e) => e.code === 'invalid_username');
    await assert.rejects(() => createUser(db, { username: 'x', password: '' }), (e) => e.code === 'invalid_password');
    await db.close();
  });

  test('listUsers řadí adminy první, adminCount počítá', async () => {
    const db = await openUsers();
    await createUser(db, { username: 'zuzana', password: 'p' });
    await createUser(db, { username: 'admin', password: 'p', isAdmin: true });
    await createUser(db, { username: 'ales', password: 'p' });

    const rows = await listUsers(db);
    assert.deepEqual(rows.map((r) => r.username), ['admin', 'ales', 'zuzana']);
    assert.equal(rows[0].isAdmin, true);
    assert.equal(await adminCount(db), 1);
    await db.close();
  });

  test('deleteUser: guardy na self-delete, posledního admina a neexistujícího', async () => {
    const db = await openUsers();
    await createUser(db, { username: 'admin', password: 'p', isAdmin: true });
    await createUser(db, { username: 'user', password: 'p' });

    await assert.rejects(() => deleteUser(db, 'nikdo'), (e) => e.code === 'not_found');
    await assert.rejects(
      () => deleteUser(db, 'admin', { actingUser: 'admin' }),
      (e) => e.code === 'self_delete'
    );
    // Poslední admin nesmí zmizet, i když maže někdo jiný.
    await assert.rejects(() => deleteUser(db, 'admin'), (e) => e.code === 'last_admin');

    await deleteUser(db, 'user');
    assert.equal((await listUsers(db)).length, 1);
    await db.close();
  });

  test('resetPassword změní hash, na neexistujícího 404', async () => {
    const db = await openUsers();
    await createUser(db, { username: 'radek', password: 'stare' });
    const before = (await db.get('SELECT password_hash AS h FROM users WHERE username = :u', { u: 'radek' })).h;

    await resetPassword(db, 'radek', 'nove');
    const after = (await db.get('SELECT password_hash AS h FROM users WHERE username = :u', { u: 'radek' })).h;
    assert.notEqual(before, after);

    await assert.rejects(() => resetPassword(db, 'nikdo', 'x'), (e) => e.code === 'not_found');
    await assert.rejects(() => resetPassword(db, 'radek', ''), (e) => e.code === 'invalid_password');
    await db.close();
  });
});
