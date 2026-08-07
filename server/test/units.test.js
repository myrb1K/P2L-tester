// Testy centrální DB jednotek (PRD-DB, DB2): CRUD vrstva db/units.js
// + integrační test routes/units.js (auth, seznam bez hesel, change-id).
// Spouští se `npm test` (node --test).
//
// Driver: default SQLite `:memory:` (žádná infrastruktura). Proti reálné
// MariaDB se stejná sada pustí přes `npm run test:mariadb`, tj.
// `TEST_DB_DRIVER=mariadb` + DB_* v .env — POZOR, testovací databáze se před
// každým testem maže, takže nikdy nesmí ukazovat na produkční P2Lunits
// (viz TEST_DB_NAME, default `P2Lunits_test`).

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');

process.env.JWT_SECRET = 't'.repeat(32); // před require routes/auth

const jwt = require('jsonwebtoken');
const express = require('express');
const cookieParser = require('cookie-parser');

const {
  openUnitsDb,
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
  listChanges,
  applySyncOps,
  currentRev,
} = require('../db/units');
const unitsRoutes = require('../routes/units');

const TEST_DRIVER = (process.env.TEST_DB_DRIVER || 'sqlite').trim().toLowerCase();

/// Čistá databáze jednotek pro jeden test. U SQLite stačí `:memory:`;
/// u MariaDB se sdílená testovací databáze vyprázdní.
async function openTestDb() {
  if (TEST_DRIVER === 'mariadb') {
    const db = await openUnitsDb({
      driver: 'mariadb',
      config: { database: process.env.TEST_DB_NAME || 'P2Lunits_test' },
    });
    await db.run('DELETE FROM unit_history');
    await db.run('DELETE FROM units');
    // DB9: sdílená testovací databáze si mezi testy nesmí nést revize ani
    // zpracovaná op_id — jinak by test idempotence viděl cizí operace.
    await db.run('DELETE FROM sync_ops');
    await db.run('UPDATE sync_counter SET value = 0 WHERE id = 1');
    return db;
  }
  return openUnitsDb(':memory:');
}

// Časové značky pro testy rozhodování „kdo je novější" (posun v sekundách).
function isoOffset(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

let db;
beforeEach(async () => {
  db = await openTestDb();
});
afterEach(async () => {
  // U MariaDB je to nutnost — otevřený pool by držel event loop a `node --test`
  // by nedoběhl.
  await db.close();
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
  test('první kontakt založí kartu, generace odvozená z ID', async () => {
    await upsertObserved(db, '001209', { firmware: 'P2L_26070201NT', battery: 87.5 });
    const unit = await getUnit(db, '1209');
    assert.equal(unit.generation, 'new');
    assert.equal(unit.firmware, 'P2L_26070201NT');
    assert.equal(unit.battery, 87.5);
    assert.ok(unit.last_seen);

    await upsertObserved(db, 'u0128', {});
    assert.equal((await getUnit(db, '128')).generation, 'old');
  });

  test('partial update nemaže dřív dodaná pole (merge)', async () => {
    await upsertObserved(db, '1209', { firmware: 'FW1', mac: 'AA:BB', ip: '10.0.0.5' });
    await upsertObserved(db, '1209', { battery: 50 }); // jen ALIVE
    const unit = await getUnit(db, '1209');
    assert.equal(unit.mac, 'AA:BB');
    assert.equal(unit.ip, '10.0.0.5');
    assert.equal(unit.battery, 50);
  });

  test('devices se ukládají a čtou jako JSON', async () => {
    const devices = [{ type: 'PUM-A', baseAddress: 128, buttons: [0, 1] }];
    await upsertObserved(db, '1209', { devices });
    assert.deepEqual((await getUnit(db, '1209')).devices, devices);
  });

  test('get_param pole (ssid/broker/jas) se ukládají', async () => {
    await upsertObserved(db, '1209', {
      ssid: 'HALA', mqttServer: 'mqtt.firma.cz', mqttPort: 1883, brightness: 80,
    });
    const unit = await getUnit(db, '1209');
    assert.equal(unit.ssid, 'HALA');
    assert.equal(unit.mqtt_server, 'mqtt.firma.cz');
    assert.equal(unit.mqtt_port, 1883);
    assert.equal(unit.brightness, 80);
  });

  test('negeneruje historii', async () => {
    await upsertObserved(db, '1209', { firmware: 'FW1' });
    assert.equal((await getHistory(db, '1209')).length, 0);
  });

  test('GET-CONFIG snapshot se ukládá jako unit_config + fetched_at (DB5)', async () => {
    const cfg = {
      Id: 1209, ver: '26071501NT', mac: 'AA:BB', SSID: 'HALA', PSWD: true,
      mqttAddress: 'mqtt.firma.cz', mqttPort: 1883, mqttUser: 'u', mqttPassword: true,
      mqttInsec: false, mqttCert: false,
      ip: '10.0.0.72', dns: '10.0.0.10', gateway: '10.0.0.10', subnet: '255.255.255.0',
      actualIp: '10.0.0.72', actualSSID: 'HALA',
    };
    await upsertObserved(db, '1209', { unitConfig: cfg, lastSeen: '2026-07-16T10:00:00Z' });
    const unit = await getUnit(db, '1209');
    assert.deepEqual(unit.unit_config, cfg);
    assert.equal(unit.unit_config_fetched_at, '2026-07-16T10:00:00Z');
    assert.equal((await getHistory(db, '1209')).length, 0); // observed → bez historie
  });

  test('GET-CONFIG se skutečnými hesly se uloží 1:1 (interní tool, DB5)', async () => {
    // FW se správnými creds vrací reálná hesla — evidence je drží pro
    // kompletní config/obnovu. Server ukládá snapshot beze změny.
    await upsertObserved(db, '1209', {
      unitConfig: {
        SSID: 'Smartbox', PSWD: 'Smartbox2021', mqttPassword: 'smartbox2022',
        mqttUser: 'smartbox_user', mqttAddress: 'mqtt.config.smartci4.com',
      },
    });
    const cfg = (await getUnit(db, '1209')).unit_config;
    assert.equal(cfg.PSWD, 'Smartbox2021');
    assert.equal(cfg.mqttPassword, 'smartbox2022');
    assert.equal(cfg.mqttUser, 'smartbox_user');
    assert.equal(cfg.mqttAddress, 'mqtt.config.smartci4.com');
  });

  test('pozdější bool heslo NEPŘEPÍŠE zachycenou skutečnou hodnotu (tri-state)', async () => {
    // 1) zachytíme reálná hesla (creds)
    await upsertObserved(db, '1209', {
      unitConfig: { SSID: 'Smartbox', PSWD: 'Smartbox2021', mqttPassword: 'smartbox2022' },
    });
    // 2) přijde odpověď na {} (bool) — třeba od jiného klienta na sběrnici
    await upsertObserved(db, '1209', {
      unitConfig: { SSID: 'Smartbox', PSWD: true, mqttPassword: true, mqttAddress: 'nový.broker' },
    });
    const cfg = (await getUnit(db, '1209')).unit_config;
    assert.equal(cfg.PSWD, 'Smartbox2021'); // skutečné heslo zachováno
    assert.equal(cfg.mqttPassword, 'smartbox2022');
    assert.equal(cfg.mqttAddress, 'nový.broker'); // ne-tajemství z nové odpovědi
  });
});

describe('updateDesired', () => {
  test('uloží desired + historii se scrubnutými hesly', async () => {
    await updateDesired(db, '1209', {
      broker: { address: 'mqtt.firma.cz', port: 1883, user: 'u', password: 'tajne' },
      wifi: { ssid: 'HALA', password: 'wifi123' },
    }, 'radek');
    const unit = await getUnit(db, '1209');
    assert.equal(unit.desired.broker.password, 'tajne'); // karta hesla drží
    assert.equal(unit.desired_updated_by, 'radek');

    const hist = await getHistory(db, '1209');
    assert.equal(hist.length, 1);
    assert.equal(hist[0].action, 'desired');
    assert.equal(hist[0].detail.broker.password, '•••'); // historie NE
    assert.equal(hist[0].detail.wifi.password, '•••');
    assert.equal(hist[0].detail.broker.address, 'mqtt.firma.cz');
  });

  test('ne-objekt vyhodí invalid_body', async () => {
    await assert.rejects(() => updateDesired(db, '1209', 'x', 'radek'), (e) => e.code === 'invalid_body');
  });

  test('merge po top-level klíčích — fragment nepřemaže zbytek desired', async () => {
    await updateDesired(db, '1209', { broker: { address: 'a', password: 'p1' } }, 'radek');
    await updateDesired(db, '1209', { wifi: { ssid: 'HALA', password: 'p2' } }, 'radek');
    await updateDesired(db, '1209', { brightness: 60 }, 'radek');
    const d = (await getUnit(db, '1209')).desired;
    assert.equal(d.broker.address, 'a'); // broker přežil zápis wifi i jasu
    assert.equal(d.wifi.ssid, 'HALA');
    assert.equal(d.brightness, 60);
    // historie: 3 záznamy, každý jen se svým fragmentem
    const hist = await getHistory(db, '1209');
    assert.equal(hist.length, 3);
    assert.deepEqual(Object.keys(hist[2].detail), ['broker']);
    assert.deepEqual(Object.keys(hist[0].detail), ['brightness']);
  });

  test('historie se ořezává na HISTORY_RETENTION nejnovějších', async () => {
    // Retence je od DB9 200 záznamů (audit má být procházitelný), pro test ji
    // snížíme na 5 — hodnota se čte při každém ořezání, ne jednou při require.
    const prev = process.env.HISTORY_RETENTION;
    process.env.HISTORY_RETENTION = '5';
    try {
      for (let i = 1; i <= 8; i++) {
        await updateDesired(db, '1209', { brightness: i }, 'radek');
      }
      const hist = await getHistory(db, '1209');
      assert.equal(hist.length, 5); // 8 zápisů → jen 5 nejnovějších
      // Nejnovější první, nejstarší 3 (jas 1–3) odmazané.
      assert.equal(hist[0].detail.brightness, 8);
      assert.equal(hist[4].detail.brightness, 4);
    } finally {
      if (prev === undefined) delete process.env.HISTORY_RETENTION;
      else process.env.HISTORY_RETENTION = prev;
    }
  });

  test('default retence (200) osm zápisů nemaže', async () => {
    for (let i = 1; i <= 8; i++) {
      await updateDesired(db, '1209', { brightness: i }, 'radek');
    }
    assert.equal((await getHistory(db, '1209')).length, 8);
  });
});

describe('updateMeta', () => {
  test('uloží meta pole + historii', async () => {
    await updateMeta(db, '1209', { name: 'Sklad B', status: 'faulty' }, 'radek');
    const unit = await getUnit(db, '1209');
    assert.equal(unit.name, 'Sklad B');
    assert.equal(unit.status, 'faulty');
    const hist = await getHistory(db, '1209');
    assert.equal(hist[0].action, 'meta');
    assert.deepEqual(hist[0].detail, { name: 'Sklad B', status: 'faulty' });
  });

  test('neplatný status vyhodí invalid_status', async () => {
    await assert.rejects(() => updateMeta(db, '1209', { status: 'rozbite' }, 'r'), (e) => e.code === 'invalid_status');
  });

  test('prázdné body vyhodí invalid_body', async () => {
    await assert.rejects(() => updateMeta(db, '1209', {}, 'r'), (e) => e.code === 'invalid_body');
  });
});

describe('changeUnitId', () => {
  test('přenese kartu včetně historie, přepočítá generaci', async () => {
    await upsertObserved(db, '128', { firmware: 'FW1' });
    await updateMeta(db, '128', { name: 'Regál 12' }, 'radek');
    await changeUnitId(db, '128', '1350', 'radek');

    assert.equal(await getUnit(db, '128'), null);
    const unit = await getUnit(db, '1350');
    assert.equal(unit.name, 'Regál 12');
    assert.equal(unit.generation, 'new');

    const hist = await getHistory(db, '1350');
    assert.equal(hist.length, 2); // meta + change_id
    assert.equal(hist[0].action, 'change_id');
    assert.deepEqual(hist[0].detail, { from: '128', to: '1350' });
  });

  test('kolize s existující kartou → duplicate', async () => {
    await upsertObserved(db, '128', {});
    await upsertObserved(db, '1350', {});
    await assert.rejects(() => changeUnitId(db, '128', '1350', 'r'), (e) => e.code === 'duplicate');
  });

  test('neexistující zdroj → not_found', async () => {
    await assert.rejects(() => changeUnitId(db, '999', '1000', 'r'), (e) => e.code === 'not_found');
  });
});

describe('deleteUnit', () => {
  // DB9 změnilo mazání na tombstone: karta se chová jako smazaná, ale řádek
  // zůstává (jinak by se při syncu vrátila z lokální DB klienta) a historie
  // se zachovává pro audit.
  test('karta se chová jako smazaná, historie zůstává', async () => {
    await updateMeta(db, '1209', { name: 'X' }, 'r');
    await deleteUnit(db, '1209');
    assert.equal(await getUnit(db, '1209'), null);
    assert.equal((await listUnits(db)).length, 0);

    const hist = await getHistory(db, '1209');
    assert.equal(hist[0].action, 'delete');
    assert.equal(hist[0].username, 'system'); // bez uživatele (CLI/test)
  });
});

describe('listUnits', () => {
  test('nevrací desired_json ani devices_json, řadí číselně', async () => {
    await updateDesired(db, '1209', { wifi: { password: 'tajne' } }, 'r');
    await upsertObserved(db, '128', { devices: [{ type: 'DIST' }] });
    await upsertObserved(db, '1209', { unitConfig: { mqttPassword: true, SSID: 'HALA' } });
    const list = await listUnits(db);
    assert.deepEqual(list.map((u) => u.id), ['128', '1209']);
    for (const u of list) {
      assert.ok(!('desired_json' in u) && !('desired' in u));
      assert.ok(!('devices_json' in u) && !('devices' in u));
      assert.ok(!('unit_config_json' in u) && !('unit_config' in u));
    }
  });

  test('drift v2 — kat.2 uloženo↔běží (i bez desired) a kat.1 evidence↔uloženo', async () => {
    // Statická IP nastavená, ale běží jiná (DHCP fallback) → drift i bez desired.
    await upsertObserved(db, '1209', {
      unitConfig: { ip: '10.0.0.72', actualIp: '10.0.0.150', SSID: 'HALA', actualSSID: 'HALA' },
    });
    assert.equal((await listUnits(db))[0].drift, true);

    // "0.0.0.0" = statická IP vypnutá → ip↔actualIp se neporovnává.
    await upsertObserved(db, '128', {
      unitConfig: { ip: '0.0.0.0', actualIp: '10.0.0.150', SSID: 'HALA', actualSSID: 'HALA' },
    });
    const byId = Object.fromEntries((await listUnits(db)).map((u) => [u.id, u]));
    assert.equal(byId['128'].drift, false);

    // Kat.1: evidence broker ≠ uloženo v NVS (mqttAddress z GET-CONFIG).
    await upsertObserved(db, '130', { unitConfig: { mqttAddress: 'mqtt.stary.cz', ip: '0.0.0.0' } });
    await updateDesired(db, '130', { broker: { address: 'mqtt.novy.cz' } }, 'r');
    const drift130 = (await listUnits(db)).find((u) => u.id === '130').drift;
    assert.equal(drift130, true);
  });

  test('drift flag: broker/ssid/jas nesoulad → true, shoda/chybějící → false', async () => {
    // rozpor v brokeru
    await upsertObserved(db, '1209', { mqttServer: 'mqtt.stary.cz' });
    await updateDesired(db, '1209', { broker: { address: 'mqtt.firma.cz' } }, 'r');
    // shoda ve všem
    await upsertObserved(db, '128', { ssid: 'HALA', brightness: 80 });
    await updateDesired(db, '128', { wifi: { ssid: 'HALA' }, brightness: 80 }, 'r');
    // bez desired
    await upsertObserved(db, '129', { ssid: 'HALA' });

    const byId = Object.fromEntries((await listUnits(db)).map((u) => [u.id, u]));
    assert.equal(byId['1209'].drift, true);
    assert.equal(byId['128'].drift, false);
    assert.equal(byId['129'].drift, false);
  });

  test('drift přes seen_on_broker: jednotka se hlásí z jiného brokeru (jen ALIVE, bez get_param)', async () => {
    // Scénář: jednotka přeconfigurovaná mimo appku — desired má starý broker,
    // ALIVE ale přišel přes nový. mqtt_server (get_param) chybí.
    await upsertObserved(db, '1209', { seenOnBroker: 'config.smartbox4you.com' });
    await updateDesired(db, '1209', { broker: { address: 'mqtt.smartbox.smartci4.com' } }, 'r');
    assert.equal((await listUnits(db))[0].drift, true);

    // Po přenastavení brokeru přes appku (desired = nový) drift zmizí.
    await updateDesired(db, '1209', { broker: { address: 'config.smartbox4you.com' } }, 'r');
    assert.equal((await listUnits(db))[0].drift, false);
  });
});

describe('computeDrift — čekající změna (gate na pozorování)', () => {
  test('neviděno od změny → drift false; viděno po změně → true', async () => {
    // observed se starým last_seen, pak evidence změněná „teď" (>> last_seen)
    await upsertObserved(db, '1400', {
      mqttServer: 'mqtt.config.cz',
      lastSeen: '2020-01-01T00:00:00Z',
      generation: 'new',
    });
    await updateDesired(db, '1400', { broker: { address: 'mqtt.dev.cz' } }, 'radek');
    const row1 = (await listUnits(db)).find((x) => x.id === '1400');
    assert.equal(row1.drift, false);
    // Řádek ukazuje ZAMÝŠLENÝ (nový) broker, ne starou observed adresu.
    assert.equal(row1.broker, 'mqtt.dev.cz');

    // Nové pozorování PO změně (broker pořád starý) → teď už skutečný drift
    // a řádek ukazuje realitu (observed).
    await upsertObserved(db, '1400', {
      mqttServer: 'mqtt.config.cz',
      lastSeen: new Date().toISOString(),
    });
    const row2 = (await listUnits(db)).find((x) => x.id === '1400');
    assert.equal(row2.drift, true);
    assert.equal(row2.broker, 'mqtt.config.cz');
  });
});

describe('exportAll / importUnits (záloha / obnova)', () => {
  test('export → import (upsert): existující přepíše, nové přidá, cizí nechá', async () => {
    // Zdrojová DB: dvě jednotky s desired (heslo), meta a historií.
    await upsertObserved(db, '1209', { firmware: 'FW1', generation: 'new' });
    await updateDesired(db, '1209', { broker: { address: 'mqtt.a.cz', password: 'tajne' } }, 'radek');
    await updateMeta(db, '1209', { name: 'Sklad A', status: 'active' }, 'radek');
    await upsertObserved(db, '128', { firmware: 'OLD', generation: 'old' });

    const dump = await exportAll(db);
    assert.equal(dump.length, 2);
    const u1209 = dump.find((u) => u.id === '1209');
    // Kompletní záloha nese reálné heslo i historii.
    assert.equal(u1209.desired.broker.password, 'tajne');
    assert.ok(Array.isArray(u1209.history) && u1209.history.length >= 2);

    // Cílová DB: 1209 s jiným jménem (přepíše se) + cizí 999 (zůstane).
    // U MariaDB je „druhá DB" ta samá — vyprázdníme ji a naplníme cílovým stavem.
    const db2 = await openTestDb();
    await updateMeta(db2, '1209', { name: 'STARÉ' }, 'x');
    await updateMeta(db2, '999', { name: 'Cizí' }, 'x');

    const result = await importUnits(db2, dump, 'importer');
    assert.deepEqual(result, { created: 1, updated: 1, total: 2 });

    // 1209 přepsáno ze zálohy (jméno, heslo v desired).
    const got = await getUnit(db2, '1209');
    assert.equal(got.name, 'Sklad A');
    assert.equal(got.desired.broker.password, 'tajne');
    // 128 nově přidáno.
    assert.equal((await getUnit(db2, '128')).firmware, 'OLD');
    // Cizí 999 (mimo zálohu) zůstalo nedotčené.
    assert.equal((await getUnit(db2, '999')).name, 'Cizí');
    await db2.close();
  });

  test('opakovaný import je idempotentní (historie se neduplikuje)', async () => {
    await upsertObserved(db, '1300', { firmware: 'FW', generation: 'new' });
    await updateDesired(db, '1300', { brightness: 40 }, 'radek');
    const dump = await exportAll(db);
    const histLen = dump[0].history.length;

    const db2 = await openTestDb();
    await importUnits(db2, dump, 'imp');
    await importUnits(db2, dump, 'imp');
    assert.equal((await getHistory(db2, '1300')).length, histLen);
    await db2.close();
  });

  test('importUnits odmítne ne-pole', async () => {
    await assert.rejects(() => importUnits(db, { nope: true }, 'x'), (e) => e.code === 'invalid_body');
  });

  test('exportUnits(ids): jen vybrané, tolerantní k chybějícímu ID', async () => {
    await upsertObserved(db, '1209', { firmware: 'A', generation: 'new' });
    await upsertObserved(db, '1210', { firmware: 'B', generation: 'new' });
    await upsertObserved(db, '1211', { firmware: 'C', generation: 'new' });

    // Podmnožina + normalizace ID + chybějící 9999 se přeskočí.
    const sub = await exportUnits(db, ['001209', '1211', '9999']);
    assert.deepEqual(sub.map((u) => u.id).sort(), ['1209', '1211']);
    // null → celá DB.
    assert.equal((await exportUnits(db, null)).length, 3);
    // prázdný seznam → chyba.
    await assert.rejects(() => exportUnits(db, []), (e) => e.code === 'invalid_body');
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

  test('GET /changes vrací desired vč. hesel; POST /sync je idempotentní', async () => {
    await withServer(async (base) => {
      const h = { Authorization: `Bearer ${tokenFor('radek', false)}`, 'Content-Type': 'application/json' };
      await fetch(`${base}/1209/desired`, {
        method: 'PUT', headers: h,
        body: JSON.stringify({ broker: { address: 'mqtt.x', password: 'tajne' } }),
      });

      // Bootstrap pull: since=0 → celá DB. Na rozdíl od GET / nese hesla,
      // protože lokální DB klienta je potřebuje (viz listChanges).
      const all = await (await fetch(`${base}/changes?since=0`, { headers: h })).json();
      assert.equal(all.units.length, 1);
      assert.equal(all.units[0].desired.broker.password, 'tajne');
      assert.ok(all.maxRev > 0);
      assert.equal(all.more, false);

      // Push jedné operace + její opakování (klient nedostal odpověď).
      const op = {
        opId: 'route-op-1', unitId: '1300', layer: 'meta',
        at: new Date().toISOString(), payload: { location: 'Hala A' },
      };
      const first = await (await fetch(`${base}/sync`, {
        method: 'POST', headers: h, body: JSON.stringify({ ops: [op], sourceDevice: 'exe@NB' }),
      })).json();
      assert.equal(first.results[0].status, 'applied');

      const again = await (await fetch(`${base}/sync`, {
        method: 'POST', headers: h, body: JSON.stringify({ ops: [op] }),
      })).json();
      assert.equal(again.results[0].duplicate, true);
      assert.equal(again.results[0].rev, first.results[0].rev);

      // Audit nese, odkud změna přišla.
      const hist = (await (await fetch(`${base}/1300/history`, { headers: h })).json()).history;
      assert.equal(hist[0].origin, 'sync');
      assert.equal(hist[0].sourceDevice, 'exe@NB');

      // Mazání přes sync smí jen admin.
      const asUser = await (await fetch(`${base}/sync`, {
        method: 'POST', headers: h,
        body: JSON.stringify({ ops: [{ opId: 'del-1', unitId: '1300', layer: 'delete' }] }),
      })).json();
      assert.equal(asUser.results[0].status, 'rejected');

      const adminH = { Authorization: `Bearer ${tokenFor('admin', true)}`, 'Content-Type': 'application/json' };
      const asAdmin = await (await fetch(`${base}/sync`, {
        method: 'POST', headers: adminH,
        body: JSON.stringify({ ops: [{ opId: 'del-2', unitId: '1300', layer: 'delete' }] }),
      })).json();
      assert.equal(asAdmin.results[0].status, 'applied');
      assert.equal((await fetch(`${base}/1300`, { headers: h })).status, 404);
    });
  });
});

// ── Sync vrstva (DB9, PRD-DB/03-PRD-sync.md) ────────────────────────────────

describe('rev (revize)', () => {
  test('každý zápis přiděluje novou, rostoucí revizi', async () => {
    await upsertObserved(db, '1209', { firmware: 'FW1' });
    const r1 = (await getUnit(db, '1209')).rev;
    await updateDesired(db, '1209', { brightness: 40 }, 'radek');
    const r2 = (await getUnit(db, '1209')).rev;
    await updateMeta(db, '1209', { name: 'A' }, 'radek');
    const r3 = (await getUnit(db, '1209')).rev;
    assert.ok(r1 > 0 && r2 > r1 && r3 > r2, `revize nerostou: ${r1}, ${r2}, ${r3}`);
    assert.equal(await currentRev(db), r3);
  });

  test('souběžné zápisy nedostanou stejnou revizi', async () => {
    // 10 paralelních zápisů do různých karet — každý musí mít unikátní rev.
    await Promise.all(
      Array.from({ length: 10 }, (_, i) => upsertObserved(db, String(1400 + i), { firmware: 'F' }))
    );
    const rows = await db.all('SELECT rev FROM units');
    const revs = rows.map((r) => Number(r.rev));
    assert.equal(new Set(revs).size, revs.length, `duplicitní revize: ${revs.join(',')}`);
  });
});

describe('listChanges', () => {
  test('vrací jen karty novější než since', async () => {
    await upsertObserved(db, '1209', { firmware: 'FW1' });
    const first = await listChanges(db, 0);
    assert.equal(first.units.length, 1);

    // Nic nového → prázdno, ale maxRev se nemění.
    const nothing = await listChanges(db, first.maxRev);
    assert.equal(nothing.units.length, 0);
    assert.equal(nothing.deleted.length, 0);

    await updateMeta(db, '1300', { name: 'Nová' }, 'radek');
    const delta = await listChanges(db, first.maxRev);
    assert.equal(delta.units.length, 1);
    assert.equal(delta.units[0].id, '1300');
  });

  test('stránkuje a hlásí more', async () => {
    for (let i = 0; i < 5; i++) await upsertObserved(db, String(1500 + i), { firmware: 'F' });
    const page1 = await listChanges(db, 0, 2);
    assert.equal(page1.units.length, 2);
    assert.equal(page1.more, true);

    const page2 = await listChanges(db, page1.maxRev, 2);
    assert.equal(page2.units.length, 2);
    assert.equal(page2.more, true);

    const page3 = await listChanges(db, page2.maxRev, 2);
    assert.equal(page3.units.length, 1);
    assert.equal(page3.more, false);
  });

  test('smazaná karta jde do deleted, ne do units', async () => {
    await upsertObserved(db, '1209', { firmware: 'FW1' });
    const before = await listChanges(db, 0);
    await deleteUnit(db, '1209', 'admin');

    const after = await listChanges(db, before.maxRev);
    assert.equal(after.units.length, 0);
    assert.equal(after.deleted.length, 1);
    assert.equal(after.deleted[0].id, '1209');
    assert.ok(after.deleted[0].deletedAt);
  });
});

describe('tombstones', () => {
  test('smazaná karta zmizí ze seznamu, detailu i zálohy', async () => {
    await updateMeta(db, '1209', { name: 'Ke smazání' }, 'radek');
    await deleteUnit(db, '1209', 'admin');

    assert.equal((await listUnits(db)).length, 0);
    assert.equal(await getUnit(db, '1209'), null);
    assert.equal((await exportAll(db)).length, 0);
  });

  test('historie mazání zůstává pro audit', async () => {
    await updateMeta(db, '1209', { name: 'X' }, 'radek');
    await deleteUnit(db, '1209', 'admin');
    const hist = await getHistory(db, '1209');
    assert.equal(hist[0].action, 'delete');
    assert.equal(hist[0].username, 'admin');
  });

  test('novější zápis kartu vzkřísí, starší se zahodí', async () => {
    await updateMeta(db, '1209', { name: 'X' }, 'radek');
    await deleteUnit(db, '1209', 'admin');

    // Zápis z doby PŘED smazáním (opozdilý offline outbox) → mazání vyhrává.
    const stale = await applySyncOps(db, [{
      opId: 'stale-1', unitId: '1209', layer: 'observed',
      at: isoOffset(-60), payload: { firmware: 'STARY' },
    }], { username: 'radek' });
    assert.equal(stale.results[0].status, 'superseded');
    assert.equal(await getUnit(db, '1209'), null);

    // Zápis po smazání → karta se vrátí (jednotka fyzicky existuje).
    const fresh = await applySyncOps(db, [{
      opId: 'fresh-1', unitId: '1209', layer: 'observed',
      at: isoOffset(60), payload: { firmware: 'NOVY' },
    }], { username: 'radek' });
    assert.equal(fresh.results[0].status, 'applied');
    const unit = await getUnit(db, '1209');
    assert.ok(unit);
    assert.equal(unit.firmware, 'NOVY');
  });

  test('change-id nechá za starým ID tombstone', async () => {
    await updateMeta(db, '1209', { name: 'Přečíslovaná' }, 'radek');
    await changeUnitId(db, '1209', '1310', 'radek');

    assert.equal(await getUnit(db, '1209'), null);
    assert.equal((await getUnit(db, '1310')).name, 'Přečíslovaná');
    const ch = await listChanges(db, 0);
    assert.ok(ch.deleted.some((d) => d.id === '1209'), 'staré ID musí přijít jako smazané');
    assert.ok(ch.units.some((u) => u.id === '1310'));
  });
});

describe('applySyncOps — rozhodování konfliktů', () => {
  test('observed: starší pozorování se zahodí, novější zapíše', async () => {
    await upsertObserved(db, '1209', { firmware: 'AKTUALNI' }, { at: isoOffset(0) });

    const older = await applySyncOps(db, [{
      opId: 'obs-old', unitId: '1209', layer: 'observed',
      at: isoOffset(-120), payload: { firmware: 'STARSI' },
    }], { username: 'radek' });
    assert.equal(older.results[0].status, 'superseded');
    assert.equal((await getUnit(db, '1209')).firmware, 'AKTUALNI');

    const newer = await applySyncOps(db, [{
      opId: 'obs-new', unitId: '1209', layer: 'observed',
      at: isoOffset(120), payload: { firmware: 'NOVEJSI' },
    }], { username: 'radek' });
    assert.equal(newer.results[0].status, 'applied');
    assert.equal((await getUnit(db, '1209')).firmware, 'NOVEJSI');
  });

  test('desired: prohraná offline změna nezapíše, ale zůstane v historii', async () => {
    // Kolega upravil evidenci online (teď).
    await updateDesired(db, '1209', { broker: { address: 'server.firma.cz' } }, 'kolega');

    // Technik měl offline změnu z dřívějška → prohrává.
    const res = await applySyncOps(db, [{
      opId: 'des-old', unitId: '1209', layer: 'desired',
      at: isoOffset(-3600), payload: { broker: { address: 'stary.broker' } },
    }], { username: 'radek', sourceDevice: 'exe@NB-RADEK' });

    assert.equal(res.results[0].status, 'conflict');
    assert.equal(res.results[0].current.desired.broker.address, 'server.firma.cz');
    assert.equal((await getUnit(db, '1209')).desired.broker.address, 'server.firma.cz');

    const hist = await getHistory(db, '1209');
    const lost = hist.find((h) => h.action === 'superseded_local');
    assert.ok(lost, 'přehlasovaná verze musí být v historii');
    assert.equal(lost.detail.broker.address, 'stary.broker');
    assert.equal(lost.layer, 'desired');
    assert.equal(lost.origin, 'sync');
    assert.equal(lost.sourceDevice, 'exe@NB-RADEK');
  });

  test('meta: novější offline změna vyhraje nad starší serverovou', async () => {
    await updateMeta(db, '1209', { name: 'Stary nazev' }, 'kolega', { at: isoOffset(-3600) });
    const res = await applySyncOps(db, [{
      opId: 'meta-new', unitId: '1209', layer: 'meta',
      at: isoOffset(0), payload: { name: 'Novy nazev' },
    }], { username: 'radek' });
    assert.equal(res.results[0].status, 'applied');
    assert.equal((await getUnit(db, '1209')).name, 'Novy nazev');
  });

  test('vadná operace se odmítne a nezablokuje zbytek dávky', async () => {
    const res = await applySyncOps(db, [
      { opId: 'bad-1', unitId: 'xxx', layer: 'meta', payload: { name: 'A' } },
      { opId: 'ok-1', unitId: '1209', layer: 'meta', payload: { name: 'B' } },
    ], { username: 'radek' });

    assert.equal(res.results[0].status, 'rejected');
    assert.equal(res.results[0].error, 'invalid_id');
    assert.equal(res.results[1].status, 'applied');
    assert.equal((await getUnit(db, '1209')).name, 'B');

    // Odmítnutá operace se nepřehrává znovu — outbox ji smaže podle výsledku.
    const retry = await applySyncOps(db, [
      { opId: 'bad-1', unitId: 'xxx', layer: 'meta', payload: { name: 'A' } },
    ], { username: 'radek' });
    assert.equal(retry.results[0].status, 'rejected');
    assert.equal(retry.results[0].duplicate, true);
  });

  test('neznámá vrstva a chybné opId jsou chyba requestu', async () => {
    await assert.rejects(
      () => applySyncOps(db, [{ opId: 'x', unitId: '1209', layer: 'sabotage' }], {}),
      /Neznámá vrstva/
    );
    await assert.rejects(
      () => applySyncOps(db, [{ unitId: '1209', layer: 'meta' }], {}),
      /opId/
    );
  });

  test('duplicitní op se nezapíše dvakrát do historie', async () => {
    const op = {
      opId: 'dup-1', unitId: '1209', layer: 'meta',
      at: new Date().toISOString(), payload: { note: 'jednou' },
    };
    await applySyncOps(db, [op], { username: 'radek' });
    await applySyncOps(db, [op], { username: 'radek' });
    const hist = await getHistory(db, '1209');
    assert.equal(hist.filter((h) => h.action === 'meta').length, 1);
  });
});
