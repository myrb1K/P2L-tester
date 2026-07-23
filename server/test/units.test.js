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
  exportAll,
  exportUnits,
  importUnits,
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

  test('GET-CONFIG snapshot se ukládá jako unit_config + fetched_at (DB5)', () => {
    const cfg = {
      Id: 1209, ver: '26071501NT', mac: 'AA:BB', SSID: 'HALA', PSWD: true,
      mqttAddress: 'mqtt.firma.cz', mqttPort: 1883, mqttUser: 'u', mqttPassword: true,
      mqttInsec: false, mqttCert: false,
      ip: '10.0.0.72', dns: '10.0.0.10', gateway: '10.0.0.10', subnet: '255.255.255.0',
      actualIp: '10.0.0.72', actualSSID: 'HALA',
    };
    upsertObserved(db, '1209', { unitConfig: cfg, lastSeen: '2026-07-16T10:00:00Z' });
    const unit = getUnit(db, '1209');
    assert.deepEqual(unit.unit_config, cfg);
    assert.equal(unit.unit_config_fetched_at, '2026-07-16T10:00:00Z');
    assert.equal(getHistory(db, '1209').length, 0); // observed → bez historie
  });

  test('GET-CONFIG se skutečnými hesly se uloží 1:1 (interní tool, DB5)', () => {
    // FW se správnými creds vrací reálná hesla — evidence je drží pro
    // kompletní config/obnovu. Server ukládá snapshot beze změny.
    upsertObserved(db, '1209', {
      unitConfig: {
        SSID: 'Smartbox', PSWD: 'Smartbox2021', mqttPassword: 'smartbox2022',
        mqttUser: 'smartbox_user', mqttAddress: 'mqtt.config.smartci4.com',
      },
    });
    const cfg = getUnit(db, '1209').unit_config;
    assert.equal(cfg.PSWD, 'Smartbox2021');
    assert.equal(cfg.mqttPassword, 'smartbox2022');
    assert.equal(cfg.mqttUser, 'smartbox_user');
    assert.equal(cfg.mqttAddress, 'mqtt.config.smartci4.com');
  });

  test('pozdější bool heslo NEPŘEPÍŠE zachycenou skutečnou hodnotu (tri-state)', () => {
    // 1) zachytíme reálná hesla (creds)
    upsertObserved(db, '1209', {
      unitConfig: { SSID: 'Smartbox', PSWD: 'Smartbox2021', mqttPassword: 'smartbox2022' },
    });
    // 2) přijde odpověď na {} (bool) — třeba od jiného klienta na sběrnici
    upsertObserved(db, '1209', {
      unitConfig: { SSID: 'Smartbox', PSWD: true, mqttPassword: true, mqttAddress: 'nový.broker' },
    });
    const cfg = getUnit(db, '1209').unit_config;
    assert.equal(cfg.PSWD, 'Smartbox2021'); // skutečné heslo zachováno
    assert.equal(cfg.mqttPassword, 'smartbox2022');
    assert.equal(cfg.mqttAddress, 'nový.broker'); // ne-tajemství z nové odpovědi
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

  test('historie drží jen posledních 5 záznamů (retence)', () => {
    for (let i = 1; i <= 8; i++) {
      updateDesired(db, '1209', { brightness: i }, 'radek');
    }
    const hist = getHistory(db, '1209');
    assert.equal(hist.length, 5); // 8 zápisů → jen 5 nejnovějších
    // Nejnovější první, nejstarší 3 (jas 1–3) odmazané.
    assert.equal(hist[0].detail.brightness, 8);
    assert.equal(hist[4].detail.brightness, 4);
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
    upsertObserved(db, '1209', { unitConfig: { mqttPassword: true, SSID: 'HALA' } });
    const list = listUnits(db);
    assert.deepEqual(list.map((u) => u.id), ['128', '1209']);
    for (const u of list) {
      assert.ok(!('desired_json' in u) && !('desired' in u));
      assert.ok(!('devices_json' in u) && !('devices' in u));
      assert.ok(!('unit_config_json' in u) && !('unit_config' in u));
    }
  });

  test('drift v2 — kat.2 uloženo↔běží (i bez desired) a kat.1 evidence↔uloženo', () => {
    // Statická IP nastavená, ale běží jiná (DHCP fallback) → drift i bez desired.
    upsertObserved(db, '1209', {
      unitConfig: { ip: '10.0.0.72', actualIp: '10.0.0.150', SSID: 'HALA', actualSSID: 'HALA' },
    });
    assert.equal(listUnits(db)[0].drift, true);

    // "0.0.0.0" = statická IP vypnutá → ip↔actualIp se neporovnává.
    upsertObserved(db, '128', {
      unitConfig: { ip: '0.0.0.0', actualIp: '10.0.0.150', SSID: 'HALA', actualSSID: 'HALA' },
    });
    const byId = Object.fromEntries(listUnits(db).map((u) => [u.id, u]));
    assert.equal(byId['128'].drift, false);

    // Kat.1: evidence broker ≠ uloženo v NVS (mqttAddress z GET-CONFIG).
    upsertObserved(db, '130', { unitConfig: { mqttAddress: 'mqtt.stary.cz', ip: '0.0.0.0' } });
    updateDesired(db, '130', { broker: { address: 'mqtt.novy.cz' } }, 'r');
    const drift130 = listUnits(db).find((u) => u.id === '130').drift;
    assert.equal(drift130, true);
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

describe('computeDrift — čekající změna (gate na pozorování)', () => {
  test('neviděno od změny → drift false; viděno po změně → true', () => {
    // observed se starým last_seen, pak evidence změněná „teď" (>> last_seen)
    upsertObserved(db, '1400', {
      mqttServer: 'mqtt.config.cz',
      lastSeen: '2020-01-01T00:00:00Z',
      generation: 'new',
    });
    updateDesired(db, '1400', { broker: { address: 'mqtt.dev.cz' } }, 'radek');
    const row1 = listUnits(db).find((x) => x.id === '1400');
    assert.equal(row1.drift, false);
    // Řádek ukazuje ZAMÝŠLENÝ (nový) broker, ne starou observed adresu.
    assert.equal(row1.broker, 'mqtt.dev.cz');

    // Nové pozorování PO změně (broker pořád starý) → teď už skutečný drift
    // a řádek ukazuje realitu (observed).
    upsertObserved(db, '1400', {
      mqttServer: 'mqtt.config.cz',
      lastSeen: new Date().toISOString(),
    });
    const row2 = listUnits(db).find((x) => x.id === '1400');
    assert.equal(row2.drift, true);
    assert.equal(row2.broker, 'mqtt.config.cz');
  });
});

describe('exportAll / importUnits (záloha / obnova)', () => {
  test('export → import (upsert): existující přepíše, nové přidá, cizí nechá', () => {
    // Zdrojová DB: dvě jednotky s desired (heslo), meta a historií.
    upsertObserved(db, '1209', { firmware: 'FW1', generation: 'new' });
    updateDesired(db, '1209', { broker: { address: 'mqtt.a.cz', password: 'tajne' } }, 'radek');
    updateMeta(db, '1209', { name: 'Sklad A', status: 'active' }, 'radek');
    upsertObserved(db, '128', { firmware: 'OLD', generation: 'old' });

    const dump = exportAll(db);
    assert.equal(dump.length, 2);
    const u1209 = dump.find((u) => u.id === '1209');
    // Kompletní záloha nese reálné heslo i historii.
    assert.equal(u1209.desired.broker.password, 'tajne');
    assert.ok(Array.isArray(u1209.history) && u1209.history.length >= 2);

    // Cílová DB: 1209 s jiným jménem (přepíše se) + cizí 999 (zůstane).
    const db2 = openUnitsDb(':memory:');
    updateMeta(db2, '1209', { name: 'STARÉ' }, 'x');
    updateMeta(db2, '999', { name: 'Cizí' }, 'x');

    const result = importUnits(db2, dump, 'importer');
    assert.deepEqual(result, { created: 1, updated: 1, total: 2 });

    // 1209 přepsáno ze zálohy (jméno, heslo v desired).
    const got = getUnit(db2, '1209');
    assert.equal(got.name, 'Sklad A');
    assert.equal(got.desired.broker.password, 'tajne');
    // 128 nově přidáno.
    assert.equal(getUnit(db2, '128').firmware, 'OLD');
    // Cizí 999 (mimo zálohu) zůstalo nedotčené.
    assert.equal(getUnit(db2, '999').name, 'Cizí');
    db2.close();
  });

  test('opakovaný import je idempotentní (historie se neduplikuje)', () => {
    upsertObserved(db, '1300', { firmware: 'FW', generation: 'new' });
    updateDesired(db, '1300', { brightness: 40 }, 'radek');
    const dump = exportAll(db);
    const histLen = dump[0].history.length;

    const db2 = openUnitsDb(':memory:');
    importUnits(db2, dump, 'imp');
    importUnits(db2, dump, 'imp');
    assert.equal(getHistory(db2, '1300').length, histLen);
    db2.close();
  });

  test('importUnits odmítne ne-pole', () => {
    assert.throws(() => importUnits(db, { nope: true }, 'x'), (e) => e.code === 'invalid_body');
  });

  test('exportUnits(ids): jen vybrané, tolerantní k chybějícímu ID', () => {
    upsertObserved(db, '1209', { firmware: 'A', generation: 'new' });
    upsertObserved(db, '1210', { firmware: 'B', generation: 'new' });
    upsertObserved(db, '1211', { firmware: 'C', generation: 'new' });

    // Podmnožina + normalizace ID + chybějící 9999 se přeskočí.
    const sub = exportUnits(db, ['001209', '1211', '9999']);
    assert.deepEqual(sub.map((u) => u.id).sort(), ['1209', '1211']);
    // null → celá DB.
    assert.equal(exportUnits(db, null).length, 3);
    // prázdný seznam → chyba.
    assert.throws(() => exportUnits(db, []), (e) => e.code === 'invalid_body');
  });
});

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

  test('bulk desired/meta/delete přes /bulk/* endpointy', async () => {
    await withServer(async (base) => {
      const h = { Authorization: `Bearer ${tokenFor('radek', false)}`, 'Content-Type': 'application/json' };
      for (const id of ['1201', '1202', '1203']) {
        await fetch(`${base}/${id}/observed`, { method: 'PUT', headers: h, body: '{}' });
      }

      // bulk desired na 2 z 3
      let r = await fetch(`${base}/bulk/desired`, {
        method: 'POST', headers: h,
        body: JSON.stringify({ ids: ['1201', '1202'], fragment: { wifi: { ssid: 'NovaSit', password: 'x' } } }),
      });
      assert.equal(r.status, 200);
      assert.equal((await r.json()).count, 2);
      let d = (await (await fetch(`${base}/1201`, { headers: h })).json()).unit;
      assert.equal(d.desired.wifi.ssid, 'NovaSit');
      d = (await (await fetch(`${base}/1203`, { headers: h })).json()).unit;
      assert.equal(d.desired, null); // netknuto

      // bulk meta na všechny 3
      r = await fetch(`${base}/bulk/meta`, {
        method: 'POST', headers: h,
        body: JSON.stringify({ ids: ['1201', '1202', '1203'], meta: { status: 'retired', name: 'Zak' } }),
      });
      assert.equal(r.status, 200);
      assert.equal((await r.json()).count, 3);
      d = (await (await fetch(`${base}/1203`, { headers: h })).json()).unit;
      assert.equal(d.status, 'retired');
      assert.equal(d.name, 'Zak');

      // neplatný status → 400 (transakce rollbacknutá)
      r = await fetch(`${base}/bulk/meta`, {
        method: 'POST', headers: h, body: JSON.stringify({ ids: ['1201'], meta: { status: 'xxx' } }),
      });
      assert.equal(r.status, 400);

      // prázdné ids → 400
      r = await fetch(`${base}/bulk/desired`, {
        method: 'POST', headers: h, body: JSON.stringify({ ids: [], fragment: {} }),
      });
      assert.equal(r.status, 400);

      // bulk delete: non-admin 403
      r = await fetch(`${base}/bulk/delete`, {
        method: 'POST', headers: h, body: JSON.stringify({ ids: ['1201', '1202'] }),
      });
      assert.equal(r.status, 403);

      // admin smaže; tolerantní k neexistujícímu ID (9999 přeskočeno)
      const ha = { Authorization: `Bearer ${tokenFor('admin', true)}`, 'Content-Type': 'application/json' };
      r = await fetch(`${base}/bulk/delete`, {
        method: 'POST', headers: ha, body: JSON.stringify({ ids: ['1201', '1202', '9999'] }),
      });
      assert.equal(r.status, 200);
      assert.equal((await r.json()).count, 2);
      assert.equal((await fetch(`${base}/1201`, { headers: ha })).status, 404);
      assert.equal((await fetch(`${base}/1203`, { headers: ha })).status, 200);
    });
  });

  test('desired hloubkový merge + /bulk/common-desired', async () => {
    await withServer(async (base) => {
      const h = { Authorization: `Bearer ${tokenFor('radek', false)}`, 'Content-Type': 'application/json' };
      await fetch(`${base}/1301/desired`, { method: 'PUT', headers: h, body: JSON.stringify({ broker: { address: 'A', port: 1883, password: 'p' }, brightness: 50 }) });
      await fetch(`${base}/1302/desired`, { method: 'PUT', headers: h, body: JSON.stringify({ broker: { address: 'A', port: 8883, password: 'p' }, brightness: 50 }) });

      // Hloubkový merge: pošli jen adresu → port i heslo zůstanou.
      let r = await fetch(`${base}/bulk/desired`, { method: 'POST', headers: h, body: JSON.stringify({ ids: ['1301'], fragment: { broker: { address: 'B' } } }) });
      assert.equal(r.status, 200);
      const d = (await (await fetch(`${base}/1301`, { headers: h })).json()).unit;
      assert.equal(d.desired.broker.address, 'B');
      assert.equal(d.desired.broker.port, 1883);
      assert.equal(d.desired.broker.password, 'p');

      // common-desired: adresa (B/A) i port (1883/8883) se liší → nejsou;
      // heslo a jas shodné → jsou.
      r = await fetch(`${base}/bulk/common-desired`, { method: 'POST', headers: h, body: JSON.stringify({ ids: ['1301', '1302'] }) });
      const common = (await r.json()).common;
      assert.equal(common.brightness, 50);
      assert.equal(common.broker.password, 'p');
      assert.ok(!('address' in (common.broker || {})));
      assert.ok(!('port' in (common.broker || {})));
    });
  });

  test('GET /export + POST /import (round-trip, format check)', async () => {
    await withServer(async (base) => {
      const h = { Authorization: `Bearer ${tokenFor('radek', false)}`, 'Content-Type': 'application/json' };
      await fetch(`${base}/1500/observed`, { method: 'PUT', headers: h, body: JSON.stringify({ firmware: 'FW' }) });
      await fetch(`${base}/1500/desired`, { method: 'PUT', headers: h, body: JSON.stringify({ broker: { address: 'mqtt.x.cz', password: 'p' } }) });

      await fetch(`${base}/1550/observed`, { method: 'PUT', headers: h, body: JSON.stringify({ firmware: 'FW2' }) });

      // GET /export = celá DB (2 jednotky), nese formát + reálné heslo.
      const dump = await (await fetch(`${base}/export`, { headers: h })).json();
      assert.equal(dump.format, 'p2l-tester.unit-db');
      assert.equal(dump.units.length, 2);
      assert.equal(dump.units.find((u) => u.id === '1500').desired.broker.password, 'p');

      // POST /export {ids} = jen vybraná jednotka.
      const sub = await (await fetch(`${base}/export`, {
        method: 'POST', headers: h, body: JSON.stringify({ ids: ['1500'] }),
      })).json();
      assert.equal(sub.units.length, 1);
      assert.equal(sub.units[0].id, '1500');
      // Odeber přidanou jednotku, ať následující round-trip sedí na 1.
      dump.units = dump.units.filter((u) => u.id === '1500');

      // Neznámý formát → 400.
      let r = await fetch(`${base}/import`, { method: 'POST', headers: h, body: JSON.stringify({ units: [] }) });
      assert.equal(r.status, 400);

      // Import upsert: 1500 aktualizuje, 1600 přidá.
      dump.units.push({ id: '1600', generation: 'new', name: 'Nová' });
      r = await fetch(`${base}/import`, { method: 'POST', headers: h, body: JSON.stringify(dump) });
      assert.equal(r.status, 200);
      const body = await r.json();
      assert.equal(body.created, 1);
      assert.equal(body.updated, 1);
      assert.equal((await (await fetch(`${base}/1600`, { headers: h })).json()).unit.name, 'Nová');
    });
  });
});
