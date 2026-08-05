// Testy db/paths.js — data adresář a jeho override přes P2L_DATA_DIR.
//
// Proč to má test: portable Windows EXE spouští server s P2L_DATA_DIR mířícím
// do %APPDATA%, aby rozbalení nové verze dist zipu nepřepsalo units.db.
// Kdyby se override rozbil, DB by se tiše vrátila do aplikační složky a
// uživatel by o data přišel při další aktualizaci.

const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const os = require('os');
const fs = require('fs');

const { dataDir, dataPath, ensureDataDir } = require('../db/paths');

function withEnv(value, fn) {
  const previous = process.env.P2L_DATA_DIR;
  if (value === undefined) delete process.env.P2L_DATA_DIR;
  else process.env.P2L_DATA_DIR = value;
  try {
    fn();
  } finally {
    if (previous === undefined) delete process.env.P2L_DATA_DIR;
    else process.env.P2L_DATA_DIR = previous;
  }
}

test('db/paths', async (t) => {
  await t.test('bez override míří do server/data', () => {
    withEnv(undefined, () => {
      const expected = path.join(__dirname, '..', 'data');
      assert.strictEqual(dataDir(), expected);
      assert.strictEqual(dataPath('units.db'), path.join(expected, 'units.db'));
    });
  });

  await t.test('P2L_DATA_DIR přesměruje obě DB', () => {
    const target = path.join(os.tmpdir(), 'p2l-paths-test');
    withEnv(target, () => {
      assert.strictEqual(dataDir(), path.resolve(target));
      assert.strictEqual(dataPath('units.db'), path.join(target, 'units.db'));
      assert.strictEqual(dataPath('users.db'), path.join(target, 'users.db'));
      assert.strictEqual(dataPath('server.pid'), path.join(target, 'server.pid'));
    });
  });

  await t.test('prázdný override se ignoruje (nespadne na "")', () => {
    withEnv('   ', () => {
      assert.strictEqual(dataDir(), path.join(__dirname, '..', 'data'));
    });
  });

  await t.test('relativní cesta se resolvuje na absolutní', () => {
    withEnv('./rel-data', () => {
      assert.ok(path.isAbsolute(dataDir()));
    });
  });

  await t.test('ensureDataDir vytvoří chybějící adresář', () => {
    const target = path.join(
      fs.mkdtempSync(path.join(os.tmpdir(), 'p2l-ensure-')),
      'nested',
      'server-data'
    );
    withEnv(target, () => {
      assert.ok(!fs.existsSync(target));
      const created = ensureDataDir();
      assert.strictEqual(created, path.resolve(target));
      assert.ok(fs.existsSync(target));
    });
    fs.rmSync(path.dirname(path.dirname(target)), { recursive: true, force: true });
  });
});
