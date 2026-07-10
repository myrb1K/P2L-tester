// Testy centrální DB jednotek (PRD-DB, DB2): CRUD vrstva db/units.js
// proti :memory: SQLite + integrační test routes/units.js (auth, seznam
// bez hesel, change-id). Spouští se `npm test` (node --test).

const { test, describe, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

process.env.JWT_SECRET = 't'.repeat(32); // před require routes/auth

const jwt = require('jsonwebtoken');
const express = require('express');
const cookieParser = require('cookie-parser');

const {
  openUnitsDb,
  UnitOpError,
  normalizeUnitId,
  scrubSecrets,
  listUnits,
  getUnit,
  upsertObserved,
  updateDesired,
  updateMeta,
  changeUnitId,
  deleteUnit,
  getHistory,
} = require('../db/units');
const unitsRoutes = require('../routes/units');

let db;
beforeEach(() => {
  db = openUnitsDb(':memory:');
});

describe('normalizeUnitId', () => {
  test('strhne u prefix a leading zeros', () => {
    assert.equal(normalizeUnitId('u0128'), '128');
    assert.equal(normalizeUnitId('001209'), '1209');
    assert.equal(normalizeUnitId('1209'), '1209');
  });
  test('neplatné ID vyhodí invalid_id', () => {
    for (const bad of ['', 'abc', '12345678', 'u', '00']) {
      assert.throws(() => normalizeUnitId(bad), (e) => e.code === 'invalid_id');
    }
  });
});

describe('scrubSecrets', () => {
  test('maskuje pass/pswd/secret klíče rekurzivně, ostatní nechá', () => {
    const scrubbed = scrubSecrets({
      broker: { address: 'mqtt.firma.cz', password: 'tajne', user: 'u1' },
      wifi: { ssid: 'HALA', PSWD: 'wifi123' },
      list: [{ apiSecret: 'x' }],
      brightness: 80,
    });
    assert.equal(scrubbed.broker.password, '•••');
    assert.equal(scrubbed.wifi.PSWD, '•••');
    assert.equal(scrubbed.list[0].apiSecret, '•••');
    assert.equal(scrubbed.broker.address, 'mqtt.firma.cz');
    assert.equal(scrubbed.brightness, 80);
  });
});

describe('upsertObserved', () => {
  test('první kontakt založí kartu, generace odvozená z ID', () => {
    upsertObserved(db, '001209', { firmware: 'P2L_26070201NT', battery: 87.5 });
    const unit = getUnit(db, '1209');
    assert.equal(unit.generation, 'new');
    assert.equal(unit.firmware, 'P2L_26070201NT');
    assert.equal(unit.battery, 87.5);
    assert.ok(unit.last_seen);

    upsertObserved(db, 'u0128', {});
    assert.equal(getUnit(db, '128').generation, 'old');
  });

  test('partial update nemaže dřív dodaná pole (merge)', () => {
    upsertObserved(db, '1209', { firmware: 'FW1', mac: 'AA:BB', ip: '10.0.0.5' });
    upsertObserved(db, '1209', { battery: 50 }); // jen ALIVE
    const unit = getUnit(db, '1209');
    assert.equal(unit.mac, 'AA:BB');
    assert.equal(unit.ip, '10.0.0.5');
    assert.equal(unit.battery, 50);
  });

  test('devices se ukládají a čtou jako JSON', () => {
    const devices = [{ type: 'PUM-A', baseAddress: 128, buttons: [0, 1] }];
    upsertObserved(db, '1209', { devices });
    assert.deepEqual(getUnit(db, '1209').devices, devices);
  });

  test('get_param pole (ssid/broker/jas) se ukládají', () => {
    upsertObserved(db, '1209', {
      ssid: 'HALA', mqttServer: 'mqtt.firma.cz', mqttPort: 1883, brightness: 80,
    });
    const unit = getUnit(db, '1209');
    assert.equal(unit.ssid, 'HALA');
    assert.equal(unit.mqtt_server, 'mqtt.firma.cz');
    assert.equal(unit.mqtt_port, 1883);
    assert.equal(unit.brightness, 80);
  });

  test('negeneruje historii', () => {
    upsertObserved(db, '1209', { firmware: 'FW1' });
    assert.equal(getHistory(db, '1209').length, 0);
  });
});

describe('updateDesired', () => {
  test('uloží desired + historii se scrubnutými hesly', () => {
    updateDesired(db, '1209', {
      broker: { address: 'mqtt.firma.cz', port: 1883, user: 'u', password: 'tajne' },
      wifi: { ssid: 'HALA', password: 'wifi123' },
    }, 'radek');
    const unit = getUnit(db, '1209');
    assert.equal(unit.desired.broker.password, 'tajne'); // karta hesla drží
    assert.equal(unit.desired_updated_by, 'radek');

    const hist = getHistory(db, '1209');
    assert.equal(hist.length, 1);
    assert.equal(hist[0].action, 'desired');
    assert.equal(hist[0].detail.broker.password, '•••'); // historie NE
    assert.equal(hist[0].detail.wifi.password, '•••');
    assert.equal(hist[0].detail.broker.address, 'mqtt.firma.cz');
  });

  test('ne-objekt vyhodí invalid_body', () => {
    assert.throws(() => updateDesired(db, '1209', 'x', 'radek'), (e) => e.code === 'invalid_body');
  });

  test('merge po top-level klíčích — fragment nepřemaže zbytek desired', () => {
    updateDesired(db, '1209', { broker: { address: 'a', password: 'p1' } }, 'radek');
    updateDesired(db, '1209', { wifi: { ssid: 'HALA', password: 'p2' } }, 'radek');
    updateDesired(db, '1209', { brightness: 60 }, 'radek');
    const d = getUnit(db, '1209').desired;
    assert.equal(d.broker.address, 'a'); // broker přežil zápis wifi i jasu
    assert.equal(d.wifi.ssid, 'HALA');
    assert.equal(d.brightness, 60);
    // historie: 3 záznamy, každý jen se svým fragmentem
    const hist = getHistory(db, '1209');
    assert.equal(hist.length, 3);
    assert.deepEqual(Object.keys(hist[2].detail), ['broker']);
    assert.deepEqual(Object.keys(hist[0].detail), ['brightness']);
  });
});

describe('updateMeta', () => {
  test('uloží meta pole + historii', () => {
    updateMeta(db, '1209', { name: 'Sklad B', status: 'faulty' }, 'radek');
    const unit = getUnit(db, '1209');
    assert.equal(unit.name, 'Sklad B');
    assert.equal(unit.status, 'faulty');
    const hist = getHistory(db, '1209');
    assert.equal(hist[0].action, 'meta');
    assert.deepEqual(hist[0].detail, { name: 'Sklad B', status: 'faulty' });
  });

  test('neplatný status vyhodí invalid_status', () => {
    assert.throws(() => updateMeta(db, '1209', { status: 'rozbite' }, 'r'), (e) => e.code === 'invalid_status');
  });

  test('prázdné body vyhodí invalid_body', () => {
    assert.throws(() => updateMeta(db, '1209', {}, 'r'), (e) => e.code === 'invalid_body');
  });
});

describe('changeUnitId', () => {
  test('přenese kartu včetně historie, přepočítá generaci', () => {
    upsertObserved(db, '128', { firmware: 'FW1' });
    updateMeta(db, '128', { name: 'Regál 12' }, 'radek');
    changeUnitId(db, '128', '1350', 'radek');

    assert.equal(getUnit(db, '128'), null);
    const unit = getUnit(db, '1350');
    assert.equal(unit.name, 'Regál 12');
    assert.equal(unit.generation, 'new');

    const hist = getHistory(db, '1350');
    assert.equal(hist.length, 2); // meta + change_id
    assert.equal(hist[0].action, 'change_id');
    assert.deepEqual(hist[0].detail, { from: '128', to: '1350' });
  });

  test('kolize s existující kartou → duplicate', () => {
    upsertObserved(db, '128', {});
    upsertObserved(db, '1350', {});
    assert.throws(() => changeUnitId(db, '128', '1350', 'r'), (e) => e.code === 'duplicate');
  });

  test('neexistující zdroj → not_found', () => {
    assert.throws(() => changeUnitId(db, '999', '1000', 'r'), (e) => e.code === 'not_found');
  });
});

describe('deleteUnit', () => {
  test('smaže kartu i historii', () => {
    updateMeta(db, '1209', { name: 'X' }, 'r');
    deleteUnit(db, '1209');
    assert.equal(getUnit(db, '1209'), null);
    assert.equal(db.prepare('SELECT COUNT(*) c FROM unit_history').get().c, 0);
  });
});

describe('listUnits', () => {
  test('nevrací desired_json ani devices_json, řadí číselně', () => {
    updateDesired(db, '1209', { wifi: { password: 'tajne' } }, 'r');
    upsertObserved(db, '128', { devices: [{ type: 'DIST' }] });
    const list = listUnits(db);
    assert.deepEqual(list.map((u) => u.id), ['128', '1209']);
    for (const u of list) {
      assert.ok(!('desired_json' in u) && !('desired' in u));
      assert.ok(!('devices_json' in u) && !('devices' in u));
    }
  });

  test('drift flag: broker/ssid/jas nesoulad → true, shoda/chybějící → false', () => {
    // rozpor v brokeru
    upsertObserved(db, '1209', { mqttServer: 'mqtt.stary.cz' });
    updateDesired(db, '1209', { broker: { address: 'mqtt.firma.cz' } }, 'r');
    // shoda ve všem
    upsertObserved(db, '128', { ssid: 'HALA', brightness: 80 });
    updateDesired(db, '128', { wifi: { ssid: 'HALA' }, brightness: 80 }, 'r');
    // bez desired
    upsertObserved(db, '129', { ssid: 'HALA' });

    const byId = Object.fromEntries(listUnits(db).map((u) => [u.id, u]));
    assert.equal(byId['1209'].drift, true);
    assert.equal(byId['128'].drift, false);
    assert.equal(byId['129'].drift, false);
  });

  test('drift přes seen_on_broker: jednotka se hlásí z jiného brokeru (jen ALIVE, bez get_param)', () => {
    // Scénář: jednotka přeconfigurovaná mimo appku — desired má starý broker,
    // ALIVE ale přišel přes nový. mqtt_server (get_param) chybí.
    upsertObserved(db, '1209', { seenOnBroker: 'config.smartbox4you.com' });
    updateDesired(db, '1209', { broker: { address: 'mqtt.smartbox.smartci4.com' } }, 'r');
    assert.equal(listUnits(db)[0].drift, true);

    // Po přenastavení brokeru přes appku (desired = nový) drift zmizí.
    updateDesired(db, '1209', { broker: { address: 'config.smartbox4you.com' } }, 'r');
    assert.equal(listUnits(db)[0].drift, false);
  });
});

// ─── Integrace: routes/units.js přes reálný HTTP server ────────────────

function makeApp() {
  const app = express();
  app.use(express.json());
  app.use(cookieParser());
  app.use('/api/units', unitsRoutes.makeRouter(db));
  return app;
}

function tokenFor(username, isAdmin) {
  return jwt.sign({ sub: username, isAdmin }, process.env.JWT_SECRET, { expiresIn: 60 });
}

async function withServer(fn) {
  const server = makeApp().listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api/units`;
  try {
    await fn(base);
  } finally {
    server.close();
  }
}

describe('routes/units', () => {
  test('bez tokenu 401, s Bearer projde celý flow', async () => {
    await withServer(async (base) => {
      const noAuth = await fetch(base + '/');
      assert.equal(noAuth.status, 401);

      const h = { Authorization: `Bearer ${tokenFor('radek', false)}`, 'Content-Type': 'application/json' };

      // observed → karta vznikne
      let r = await fetch(`${base}/001209/observed`, { method: 'PUT', headers: h, body: JSON.stringify({ firmware: 'FW1' }) });
      assert.equal(r.status, 200);
      assert.equal((await r.json()).id, '1209');

      // desired + meta
      r = await fetch(`${base}/1209/desired`, { method: 'PUT', headers: h, body: JSON.stringify({ wifi: { ssid: 'HALA', password: 'x' } }) });
      assert.equal(r.status, 200);
      r = await fetch(`${base}/1209/meta`, { method: 'PUT', headers: h, body: JSON.stringify({ name: 'Sklad B' }) });
      assert.equal(r.status, 200);

      // seznam bez desired, detail s desired
      const list = (await (await fetch(base + '/', { headers: h })).json()).units;
      assert.equal(list.length, 1);
      assert.ok(!('desired' in list[0]) && !('desired_json' in list[0]));
      const detail = (await (await fetch(`${base}/1209`, { headers: h })).json()).unit;
      assert.equal(detail.desired.wifi.password, 'x');
      assert.equal(detail.desired_updated_by, 'radek');

      // historie (desired + meta), hesla scrubnutá
      const hist = (await (await fetch(`${base}/1209/history`, { headers: h })).json()).history;
      assert.equal(hist.length, 2);
      assert.equal(hist[1].detail.wifi.password, '•••');

      // change-id
      r = await fetch(`${base}/1209/change-id`, { method: 'POST', headers: h, body: JSON.stringify({ newId: '1350' }) });
      assert.equal(r.status, 200);
      assert.equal((await fetch(`${base}/1209`, { headers: h })).status, 404);

      // delete: non-admin 403, admin 204
      r = await fetch(`${base}/1350`, { method: 'DELETE', headers: h });
      assert.equal(r.status, 403);
      const ha = { Authorization: `Bearer ${tokenFor('admin', true)}` };
      r = await fetch(`${base}/1350`, { method: 'DELETE', headers: ha });
      assert.equal(r.status, 204);
      assert.equal((await fetch(`${base}/1350`, { headers: ha })).status, 404);
    });
  });

  test('validační chyby mapované na 400/404/409', async () => {
    await withServer(async (base) => {
      const h = { Authorization: `Bearer ${tokenFor('radek', false)}`, 'Content-Type': 'application/json' };
      assert.equal((await fetch(`${base}/abc`, { headers: h })).status, 400); // invalid_id
      assert.equal((await fetch(`${base}/999`, { headers: h })).status, 404);
      let r = await fetch(`${base}/1209/meta`, { method: 'PUT', headers: h, body: JSON.stringify({ status: 'rozbite' }) });
      assert.equal(r.status, 400);
      await fetch(`${base}/128/observed`, { method: 'PUT', headers: h, body: '{}' });
      await fetch(`${base}/1350/observed`, { method: 'PUT', headers: h, body: '{}' });
      r = await fetch(`${base}/128/change-id`, { method: 'POST', headers: h, body: JSON.stringify({ newId: '1350' }) });
      assert.equal(r.status, 409);
    });
  });
});
