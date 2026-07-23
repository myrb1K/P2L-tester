// CRUD vrstva centrální databáze jednotek (PRD-DB/01-PRD.md, milestone DB2).
// Sdílená mezi API routes (routes/units.js) a testy. better-sqlite3,
// synchronní — stejný vzor jako db/users.js.
//
// Zásady:
// - Observed updaty NEgenerují historii (ALIVE chodí à 5 min — byl by šum).
//   Historie vzniká u desired / meta / change-id / delete.
// - Hesla se do historie NIKDY nezapisují — scrubSecrets() maskuje každý
//   klíč obsahující pass/pswd/secret (case-insensitive), rekurzivně.
// - Karta vzniká upsertem při prvním kontaktu (observed) i při prvním
//   zápisu desired/meta — generace se v tom případě odvodí z ID
//   (>= 1000 = nová, jinak stará; stejná heuristika jako v appce).

const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');

const UNITS_DB_PATH = path.join(__dirname, '..', 'data', 'units.db');
const SCHEMA_PATH = path.join(__dirname, 'units-schema.sql');

const VALID_STATUS = ['active', 'faulty', 'stock', 'retired'];

// Retence historie: na jednotku držíme jen posledních N záznamů, zbytek se
// maže (drobné akce, ne archiv). Ořezává se při každém zápisu i jednorázově
// při otevření DB (vyčistí přebytky z doby před retencí).
const HISTORY_RETENTION = 5;

class UnitOpError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// `:memory:` pro testy, jinak data/units.db.
function openUnitsDb(dbPath = UNITS_DB_PATH) {
  if (dbPath !== ':memory:') {
    const dir = path.dirname(dbPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  }
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.exec(fs.readFileSync(SCHEMA_PATH, 'utf8'));
  ensureObservedColumns(db);
  pruneAllHistory(db);
  return db;
}

// Jednorázový úklid: u každé jednotky nechá jen posledních HISTORY_RETENTION
// záznamů historie. Řeší data z doby před zavedením retence.
function pruneAllHistory(db) {
  db.prepare(
    `DELETE FROM unit_history WHERE id NOT IN (
       SELECT id FROM (
         SELECT id, ROW_NUMBER() OVER (
           PARTITION BY unit_id ORDER BY id DESC
         ) AS rn FROM unit_history
       ) WHERE rn <= ?
     )`
  ).run(HISTORY_RETENTION);
}

// Mini-migrace: CREATE TABLE IF NOT EXISTS existující DB nerozšíří, takže
// nové observed sloupce (DB3: ssid/mqtt_server/mqtt_port/brightness) doplní
// ALTER TABLE. Idempotentní — přidá jen chybějící.
function ensureObservedColumns(db) {
  const existing = new Set(db.pragma('table_info(units)').map((c) => c.name));
  const wanted = {
    ssid: 'TEXT',
    mqtt_server: 'TEXT',
    mqtt_port: 'INTEGER',
    brightness: 'INTEGER',
    // Host brokeru, přes který appka jednotku naposledy viděla (ALIVE).
    // Na rozdíl od mqtt_server (jen z get_param) se plní každým kontaktem —
    // drift „jednotka žije na jiném brokeru" je vidět hned po discovery.
    seen_on_broker: 'TEXT',
    // DB5: poslední UNIT GET-CONFIG 1:1 (nakonfigurováno + actualIp/actualSSID,
    // hesla jako bool) + čas načtení. Bohatší observed než get_param.
    unit_config_json: 'TEXT',
    unit_config_fetched_at: 'TEXT',
  };
  for (const [col, type] of Object.entries(wanted)) {
    if (!existing.has(col)) db.exec(`ALTER TABLE units ADD COLUMN ${col} ${type}`);
  }
}

// 'u0128' / '001209' / '1209' → kanonické '128' / '1209'. Vyhodí při
// neplatném formátu (povolené: volitelné 'u' + 1–6 číslic, ne samé nuly).
function normalizeUnitId(raw) {
  if (typeof raw !== 'string') throw new UnitOpError('invalid_id', `Neplatné ID jednotky: ${raw}`);
  let s = raw.trim().toLowerCase();
  if (s.startsWith('u')) s = s.slice(1);
  if (!/^[0-9]{1,6}$/.test(s)) {
    throw new UnitOpError('invalid_id', `Neplatné ID jednotky: '${raw}' (očekávám 1–6 číslic, volitelně s prefixem 'u')`);
  }
  const stripped = s.replace(/^0+/, '');
  if (stripped === '') throw new UnitOpError('invalid_id', `Neplatné ID jednotky: '${raw}'`);
  return stripped;
}

function deriveGeneration(id) {
  return Number(id) >= 1000 ? 'new' : 'old';
}

// Tri-state ochrana hesel ve snapshotu (PRD-DB v2 §3): pozdější bool `true`
// (odpověď na `{}` / bez creds — třeba od jiného klienta na sběrnici) NESMÍ
// přepsat dřív zachycenou skutečnou hodnotu hesla. Ostatní pole vždy z nové
// odpovědi (běžný merge = replace celého snapshotu, jen tajemství chráníme).
function mergeConfigSecrets(incoming, existingJson) {
  if (!incoming || typeof incoming !== 'object' || Array.isArray(incoming)) return incoming;
  let existing = null;
  if (existingJson) {
    try { existing = JSON.parse(existingJson); } catch { existing = null; }
  }
  if (!existing) return incoming;
  const out = { ...incoming };
  for (const k of Object.keys(out)) {
    if (/pass|pswd|secret/i.test(k) &&
        out[k] === true &&
        typeof existing[k] === 'string' && existing[k].length > 0) {
      out[k] = existing[k];
    }
  }
  return out;
}

// Rekurzivně nahradí hodnoty klíčů vypadajících jako heslo za '•••'.
function scrubSecrets(value) {
  if (Array.isArray(value)) return value.map(scrubSecrets);
  if (value === null || typeof value !== 'object') return value;
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = /pass|pswd|secret/i.test(k) ? '•••' : scrubSecrets(v);
  }
  return out;
}

function addHistory(db, unitId, username, action, detail) {
  db.prepare(
    'INSERT INTO unit_history (unit_id, username, action, detail_json) VALUES (?, ?, ?, ?)'
  ).run(unitId, username, action, detail == null ? null : JSON.stringify(scrubSecrets(detail)));
  // Retence: na jednotku držíme jen posledních HISTORY_RETENTION záznamů.
  db.prepare(
    `DELETE FROM unit_history WHERE unit_id = ? AND id NOT IN (
       SELECT id FROM unit_history WHERE unit_id = ? ORDER BY id DESC LIMIT ?
     )`
  ).run(unitId, unitId, HISTORY_RETENTION);
}

function getHistory(db, rawId, limit = 200) {
  const id = normalizeUnitId(rawId);
  return db
    .prepare('SELECT at, username, action, detail_json FROM unit_history WHERE unit_id = ? ORDER BY id DESC LIMIT ?')
    .all(id, limit)
    .map((r) => ({
      at: r.at,
      username: r.username,
      action: r.action,
      detail: r.detail_json ? JSON.parse(r.detail_json) : null,
    }));
}

// Drift v2 (PRD-DB v2 §6): souhrnný boolean pro řádek seznamu. Tři kategorie
// (zrcadlí klientskou UnitDbCard.driftWarnings), počítá se z desired +
// observed sloupců + GET-CONFIG snapshotu (unit_config_json). Bez GET-CONFIG
// (starý FW) degraduje na porovnání proti get_param hodnotám.
//   1) evidence ↔ uloženo v NVS (mqttAddress/SSID z GET-CONFIG)
//   2) uloženo ↔ reálně běží (ip↔actualIp, SSID↔actualSSID) — i bez desired
//   3) evidence ↔ kde ji vidíme (mqtt_server / seen_on_broker)
// SQLite `datetime('now')` ('YYYY-MM-DD HH:MM:SS', UTC bez tz) i ISO string
// z appky ('…T…Z') → Date v UTC. Zrcadlí klientský _parseTime.
function parseTs(v) {
  if (typeof v !== 'string' || !v) return null;
  let s = v.includes('T') ? v : `${v.replace(' ', 'T')}Z`;
  if (!s.endsWith('Z') && !s.includes('+')) s = `${s}Z`;
  const t = new Date(s);
  return Number.isNaN(t.getTime()) ? null : t;
}

function computeDrift(desiredJson, row) {
  // „Nesoulad" má smysl jen když jsme jednotku viděli AŽ PO poslední změně
  // evidence. Čerstvá, ještě nepozorovaná změna (jednotka přešla na jiný broker
  // / je offline) = čekající → žádný drift (potvrzeno ackem, ale realita ještě
  // nepřečtena). Platí jen když evidence existuje.
  if (desiredJson && row.desired_updated_at) {
    const changed = parseTs(row.desired_updated_at);
    const seen = parseTs(row.last_seen);
    if (changed && (!seen || seen < changed)) return false;
  }

  let cfg = null;
  if (row.unit_config_json) {
    try { cfg = JSON.parse(row.unit_config_json); } catch { cfg = null; }
  }
  const s = (v) => (typeof v === 'string' && v ? v : null);

  // 2) uloženo ↔ běží — čistě observed, ukáže se i u nekonfigurované jednotky.
  if (cfg) {
    const ip = s(cfg.ip);
    const actualIp = s(cfg.actualIp);
    // "0.0.0.0" = statická IP vypnutá (DHCP) → neporovnávat.
    if (ip && ip !== '0.0.0.0' && actualIp && ip !== actualIp) return true;
    const cfgSsid = s(cfg.SSID);
    const actualSsid = s(cfg.actualSSID);
    if (cfgSsid && actualSsid && cfgSsid !== actualSsid) return true;
  }

  if (!desiredJson) return false;
  let d;
  try {
    d = JSON.parse(desiredJson);
  } catch {
    return false;
  }
  const broker = d.broker;
  if (broker && typeof broker.address === 'string' && broker.address) {
    // 1) vs uloženo v NVS (autoritativní z GET-CONFIG).
    if (cfg && s(cfg.mqttAddress) && broker.address !== cfg.mqttAddress) return true;
    // 3) vs kde jednotku vidíme: mqtt_server (get_param) i seen_on_broker (ALIVE).
    if (row.mqtt_server && broker.address !== row.mqtt_server) return true;
    if (row.seen_on_broker && broker.address !== row.seen_on_broker) return true;
  }
  const wifi = d.wifi;
  if (wifi && typeof wifi.ssid === 'string' && wifi.ssid) {
    if (cfg && s(cfg.SSID)) {
      if (wifi.ssid !== cfg.SSID) return true;
    } else if (row.ssid && wifi.ssid !== row.ssid) {
      // Bez GET-CONFIG degraduj na get_param SSID (starý FW).
      return true;
    }
  }
  if (Number.isInteger(d.brightness) && row.brightness != null &&
      d.brightness !== row.brightness) {
    return true;
  }
  return false;
}

// Seznam pro přehled/inventuru — BEZ desired_json (hesla!) a bez
// devices_json (objem); detail karty vrací getUnit. Navíc příznak `drift`
// (nesoulad desired vs. observed) spočítaný server-side.
function listUnits(db) {
  return db
    .prepare(
      `SELECT id, generation, mac, name, location, status, last_seen, firmware,
              ip, battery, updated_at,
              ssid, mqtt_server, mqtt_port, brightness, seen_on_broker,
              unit_config_json, desired_json, desired_updated_at
       FROM units ORDER BY CAST(id AS INTEGER)`
    )
    .all()
    .map((row) => {
      const {
        desired_json: desiredJson,
        unit_config_json: unitConfigJson,
        desired_updated_at: desiredUpdatedAt, // jen pro výpočet, nevrací se
        ssid, mqtt_server: mqttServer, mqtt_port: mqttPort, brightness,
        seen_on_broker: seenOnBroker,
        ...rest
      } = row;
      // Adresa brokeru pro řádek seznamu (není tajná — desired_json s hesly
      // dál nevracíme). Když je evidence čerstvě změněná a jednotku jsme od té
      // doby neviděli (odešla na nový broker), ukaž ZAMÝŠLENÝ broker z evidence
      // — jinak by řádek dál svítil starou adresou. Jinak realita: uloženo
      // v NVS (GET-CONFIG) → hlášeno jednotkou (get_param) → kde ji appka viděla.
      let cfgBroker = null;
      let desiredBroker = null;
      if (unitConfigJson) {
        try {
          cfgBroker = JSON.parse(unitConfigJson).mqttAddress || null;
        } catch {
          /* poškozený JSON → ignoruj */
        }
      }
      if (desiredJson) {
        try {
          const d = JSON.parse(desiredJson);
          desiredBroker = (d && d.broker && d.broker.address) || null;
        } catch {
          /* poškozený JSON → ignoruj */
        }
      }
      const observedBroker = cfgBroker || mqttServer || seenOnBroker || null;
      const changed = parseTs(desiredUpdatedAt);
      const seen = parseTs(row.last_seen);
      const pending = desiredBroker && changed && (!seen || seen < changed);
      const broker =
        (pending ? desiredBroker : null) || observedBroker || desiredBroker || null;
      return { ...rest, broker, drift: computeDrift(desiredJson, row) };
    });
}

function getUnit(db, rawId) {
  const id = normalizeUnitId(rawId);
  const row = db.prepare('SELECT * FROM units WHERE id = ?').get(id);
  if (!row) return null;
  const {
    devices_json: devicesJson,
    desired_json: desiredJson,
    unit_config_json: unitConfigJson,
    ...rest
  } = row;
  return {
    ...rest,
    devices: devicesJson ? JSON.parse(devicesJson) : null,
    desired: desiredJson ? JSON.parse(desiredJson) : null,
    unit_config: unitConfigJson ? JSON.parse(unitConfigJson) : null,
  };
}

function unitExists(db, id) {
  return !!db.prepare('SELECT 1 FROM units WHERE id = ?').get(id);
}

// Založí prázdnou kartu, pokud neexistuje. Vrací kanonické ID.
function ensureUnit(db, rawId, generation) {
  const id = normalizeUnitId(rawId);
  const gen = generation === 'old' || generation === 'new' ? generation : deriveGeneration(id);
  db.prepare(
    'INSERT INTO units (id, generation) VALUES (?, ?) ON CONFLICT(id) DO NOTHING'
  ).run(id, gen);
  return id;
}

// Observed vrstva — merge: přepisují se jen dodaná pole (partial update,
// např. ALIVE nese jen firmware+baterii, get_param zbytek). Bez historie.
function upsertObserved(db, rawId, obs = {}) {
  const id = ensureUnit(db, rawId, obs.generation);
  const sets = [];
  const params = { id };
  // GET-CONFIG snapshot: chraň dřív zachycená skutečná hesla před pozdějším bool.
  let configToStore = obs.unitConfig;
  if (obs.unitConfig !== undefined) {
    const prev = db.prepare('SELECT unit_config_json FROM units WHERE id = ?').get(id);
    configToStore = mergeConfigSecrets(obs.unitConfig, prev && prev.unit_config_json);
  }
  const map = {
    mac: obs.mac,
    hw_model: obs.hwModel,
    firmware: obs.firmware,
    ip: obs.ip,
    battery: obs.battery,
    ssid: obs.ssid,
    mqtt_server: obs.mqttServer,
    mqtt_port: obs.mqttPort,
    brightness: obs.brightness,
    seen_on_broker: obs.seenOnBroker,
    unit_config_json: obs.unitConfig === undefined ? undefined : JSON.stringify(configToStore),
    devices_json: obs.devices === undefined ? undefined : JSON.stringify(obs.devices),
  };
  for (const [col, val] of Object.entries(map)) {
    if (val !== undefined) {
      sets.push(`${col} = @${col}`);
      params[col] = val;
    }
  }
  if (obs.unitConfig !== undefined) {
    sets.push(`unit_config_fetched_at = @unit_config_fetched_at`);
    params.unit_config_fetched_at = obs.lastSeen || new Date().toISOString();
  }
  if (obs.generation === 'old' || obs.generation === 'new') {
    sets.push('generation = @generation');
    params.generation = obs.generation;
  }
  sets.push(`last_seen = @last_seen`);
  params.last_seen = obs.lastSeen || new Date().toISOString();
  sets.push(`updated_at = datetime('now')`);
  db.prepare(`UPDATE units SET ${sets.join(', ')} WHERE id = @id`).run(params);
  return id;
}

// Desired vrstva — merge po top-level klíčích: appka zapisuje po akcích
// (set_Mqtt → {broker}, set_WiFi → {wifi}, …), takže poslaný fragment
// přepíše jen svoje klíče a zbytek desired zůstává. Historie dostává jen
// fragment (se scrubnutými hesly).
function updateDesired(db, rawId, fragment, username) {
  if (fragment === null || typeof fragment !== 'object' || Array.isArray(fragment)) {
    throw new UnitOpError('invalid_body', 'desired musí být JSON objekt');
  }
  const id = ensureUnit(db, rawId);
  const row = db.prepare('SELECT desired_json FROM units WHERE id = ?').get(id);
  const current = row?.desired_json ? JSON.parse(row.desired_json) : {};
  // Hloubkový merge o jednu úroveň: vnořené objekty (broker, wifi) se slévají
  // po podklíčích, ne nahrazují vcelku — jinak by částečný fragment (např. jen
  // {broker:{address}}) u hromadné editace smazal ostatní podpole (port/heslo).
  const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
  const merged = { ...current };
  for (const [k, v] of Object.entries(fragment)) {
    merged[k] = isObj(v) && isObj(merged[k]) ? { ...merged[k], ...v } : v;
  }
  db.prepare(
    `UPDATE units SET desired_json = ?, desired_updated_at = datetime('now'),
     desired_updated_by = ?, updated_at = datetime('now') WHERE id = ?`
  ).run(JSON.stringify(merged), username, id);
  addHistory(db, id, username, 'desired', fragment);
  return id;
}

// Meta vrstva — partial update (jen dodaná pole) + historie.
function updateMeta(db, rawId, meta = {}, username) {
  if (meta.status !== undefined && !VALID_STATUS.includes(meta.status)) {
    throw new UnitOpError('invalid_status', `Neplatný stav '${meta.status}' (povolené: ${VALID_STATUS.join(', ')})`);
  }
  const id = ensureUnit(db, rawId);
  const sets = [];
  const params = { id };
  const changed = {};
  for (const col of ['name', 'location', 'note', 'status']) {
    if (meta[col] !== undefined) {
      sets.push(`${col} = @${col}`);
      params[col] = meta[col];
      changed[col] = meta[col];
    }
  }
  if (sets.length === 0) {
    throw new UnitOpError('invalid_body', 'Žádné pole ke změně (name / location / note / status)');
  }
  sets.push(`updated_at = datetime('now')`);
  db.prepare(`UPDATE units SET ${sets.join(', ')} WHERE id = @id`).run(params);
  addHistory(db, id, username, 'meta', changed);
  return id;
}

// Přečíslování jednotky (change_ID) — karta se PŘENÁŠÍ včetně historie,
// nezakládá se nová (PRD §7 R6).
function changeUnitId(db, rawOldId, rawNewId, username) {
  const oldId = normalizeUnitId(rawOldId);
  const newId = normalizeUnitId(rawNewId);
  if (oldId === newId) throw new UnitOpError('same_id', 'Nové ID je shodné se starým.');
  if (!unitExists(db, oldId)) throw new UnitOpError('not_found', `Jednotka '${oldId}' v DB není.`);
  if (unitExists(db, newId)) throw new UnitOpError('duplicate', `Jednotka '${newId}' už v DB existuje.`);
  const tx = db.transaction(() => {
    db.prepare(
      `UPDATE units SET id = ?, generation = ?, updated_at = datetime('now') WHERE id = ?`
    ).run(newId, deriveGeneration(newId), oldId);
    db.prepare('UPDATE unit_history SET unit_id = ? WHERE unit_id = ?').run(newId, oldId);
    addHistory(db, newId, username, 'change_id', { from: oldId, to: newId });
  });
  tx();
  return newId;
}

// Smazání karty včetně historie (jen admin — vynucuje route).
function deleteUnit(db, rawId) {
  const id = normalizeUnitId(rawId);
  if (!unitExists(db, id)) throw new UnitOpError('not_found', `Jednotka '${id}' v DB není.`);
  const tx = db.transaction(() => {
    db.prepare('DELETE FROM unit_history WHERE unit_id = ?').run(id);
    db.prepare('DELETE FROM units WHERE id = ?').run(id);
  });
  tx();
}

// ── Hromadné operace (bulk endpointy) ──────────────────────────────────────
// Vše v jedné transakci (atomické — buď projde vše, nebo nic). desired/meta
// reuse per-unit logiky (ensureUnit + historie per jednotka). Vrací počet
// zpracovaných jednotek.
function requireIds(ids) {
  if (!Array.isArray(ids) || ids.length === 0) {
    throw new UnitOpError('invalid_body', 'ids musí být neprázdné pole');
  }
}

function bulkUpdateDesired(db, ids, fragment, username) {
  requireIds(ids);
  const tx = db.transaction((list) => {
    for (const rawId of list) updateDesired(db, rawId, fragment, username);
  });
  tx(ids);
  return ids.length;
}

function bulkUpdateMeta(db, ids, meta, username) {
  requireIds(ids);
  const tx = db.transaction((list) => {
    for (const rawId of list) updateMeta(db, rawId, meta, username);
  });
  tx(ids);
  return ids.length;
}

// Společné hodnoty evidence napříč vybranými jednotkami — pro předvyplnění
// dialogu hromadné editace. Každé pole (i vnořené broker/wifi po podklíčích)
// se zařadí jen když ho mají VŠECHNY vybrané a je shodné; jinak se vynechá
// (v dialogu prázdné). Heslo se vrátí jen když ho mají všichni stejné.
function commonDesired(db, ids) {
  requireIds(ids);
  const desireds = ids.map((rawId) => {
    const id = normalizeUnitId(rawId);
    const row = db.prepare('SELECT desired_json FROM units WHERE id = ?').get(id);
    return row && row.desired_json ? JSON.parse(row.desired_json) : {};
  });
  const allEqual = (vals) =>
    vals.every((v) => v !== undefined) && vals.every((v) => v === vals[0]);
  const common = {};
  for (const k of ['brightness', 'dispBrightness']) {
    const vals = desireds.map((d) => d[k]);
    if (allEqual(vals)) common[k] = vals[0];
  }
  for (const [grp, subs] of Object.entries({
    broker: ['address', 'port', 'user', 'password'],
    wifi: ['ssid', 'password'],
  })) {
    const obj = {};
    for (const s of subs) {
      const vals = desireds.map((d) =>
        d[grp] && typeof d[grp] === 'object' ? d[grp][s] : undefined
      );
      if (allEqual(vals)) obj[s] = vals[0];
    }
    if (Object.keys(obj).length > 0) common[grp] = obj;
  }
  return common;
}

// Tolerantní k chybějícím ID — seznam pochází z klienta a mezitím mohlo ID
// zmizet; přeskočíme ho místo abychom shodili celou dávku.
function bulkDeleteUnits(db, ids) {
  requireIds(ids);
  let n = 0;
  const tx = db.transaction((list) => {
    for (const rawId of list) {
      const id = normalizeUnitId(rawId);
      if (!unitExists(db, id)) continue;
      db.prepare('DELETE FROM unit_history WHERE unit_id = ?').run(id);
      db.prepare('DELETE FROM units WHERE id = ?').run(id);
      n++;
    }
  });
  tx(ids);
  return n;
}

// ── Export / Import DB (kompletní záloha / obnova) ──────────────────────────
// Export: úplný snímek jednotky (getUnit = všechna pole vč. desired s reálnými
// hesly) + historie. Určeno pro plný backup i přenos mezi servery.
// [ids] === null → celá DB; jinak jen vybrané (tolerantní k chybějícím ID —
// přeskočí je). Formát řádku je stejný, ať jde o jednu jednotku nebo všechny.
function exportUnits(db, ids = null) {
  let idList;
  if (ids == null) {
    idList = db
      .prepare('SELECT id FROM units ORDER BY CAST(id AS INTEGER)')
      .all()
      .map((r) => r.id);
  } else {
    if (!Array.isArray(ids) || ids.length === 0) {
      throw new UnitOpError('invalid_body', 'ids musí být neprázdné pole');
    }
    idList = ids.map(normalizeUnitId);
  }
  const out = [];
  for (const id of idList) {
    const unit = getUnit(db, id);
    if (!unit) continue; // tolerantní k chybějícímu ID
    unit.history = getHistory(db, id, 10000);
    out.push(unit);
  }
  return out;
}

// Celá DB (zpětně kompatibilní alias).
function exportAll(db) {
  return exportUnits(db, null);
}

// Import: SLOUČENÍ po ID (upsert) — existující jednotky se přepíšou snímkem ze
// zálohy, nové se přidají, jednotky mimo zálohu zůstanou nedotčené (nic se
// nemaže). Historie importované jednotky se nahradí historií ze zálohy, takže
// opakovaný import téhož souboru je idempotentní (neduplikuje). Vše v jedné
// transakci. Vrací { created, updated, total }.
function importUnits(db, units, username) {
  if (!Array.isArray(units)) {
    throw new UnitOpError('invalid_body', 'units musí být pole');
  }
  const toJson = (v) => (v === undefined || v === null ? null : JSON.stringify(v));
  const upsert = db.prepare(
    `INSERT INTO units (
       id, generation, mac, hw_model, firmware, ip, battery,
       ssid, mqtt_server, mqtt_port, brightness, seen_on_broker,
       unit_config_json, unit_config_fetched_at, last_seen, devices_json,
       desired_json, desired_updated_at, desired_updated_by,
       name, location, note, status, created_at, updated_at
     ) VALUES (
       @id, @generation, @mac, @hw_model, @firmware, @ip, @battery,
       @ssid, @mqtt_server, @mqtt_port, @brightness, @seen_on_broker,
       @unit_config_json, @unit_config_fetched_at, @last_seen, @devices_json,
       @desired_json, @desired_updated_at, @desired_updated_by,
       @name, @location, @note, @status,
       COALESCE(@created_at, datetime('now')), datetime('now')
     )
     ON CONFLICT(id) DO UPDATE SET
       generation = excluded.generation, mac = excluded.mac,
       hw_model = excluded.hw_model, firmware = excluded.firmware,
       ip = excluded.ip, battery = excluded.battery, ssid = excluded.ssid,
       mqtt_server = excluded.mqtt_server, mqtt_port = excluded.mqtt_port,
       brightness = excluded.brightness, seen_on_broker = excluded.seen_on_broker,
       unit_config_json = excluded.unit_config_json,
       unit_config_fetched_at = excluded.unit_config_fetched_at,
       last_seen = excluded.last_seen, devices_json = excluded.devices_json,
       desired_json = excluded.desired_json,
       desired_updated_at = excluded.desired_updated_at,
       desired_updated_by = excluded.desired_updated_by,
       name = excluded.name, location = excluded.location, note = excluded.note,
       status = excluded.status, updated_at = datetime('now')`
  );
  const delHist = db.prepare('DELETE FROM unit_history WHERE unit_id = ?');
  const insHist = db.prepare(
    'INSERT INTO unit_history (unit_id, at, username, action, detail_json) VALUES (?, ?, ?, ?, ?)'
  );
  const pruneHist = db.prepare(
    `DELETE FROM unit_history WHERE unit_id = ? AND id NOT IN (
       SELECT id FROM unit_history WHERE unit_id = ? ORDER BY id DESC LIMIT ?
     )`
  );
  let created = 0;
  let updated = 0;
  const tx = db.transaction((list) => {
    for (const u of list) {
      if (!u || typeof u !== 'object' || Array.isArray(u)) {
        throw new UnitOpError('invalid_body', 'Každá jednotka musí být objekt');
      }
      const id = normalizeUnitId(u.id);
      const existed = unitExists(db, id);
      const generation =
        u.generation === 'old' || u.generation === 'new'
          ? u.generation
          : deriveGeneration(id);
      const status = VALID_STATUS.includes(u.status) ? u.status : 'active';
      upsert.run({
        id,
        generation,
        mac: u.mac ?? null,
        hw_model: u.hw_model ?? null,
        firmware: u.firmware ?? null,
        ip: u.ip ?? null,
        battery: u.battery ?? null,
        ssid: u.ssid ?? null,
        mqtt_server: u.mqtt_server ?? null,
        mqtt_port: u.mqtt_port ?? null,
        brightness: u.brightness ?? null,
        seen_on_broker: u.seen_on_broker ?? null,
        unit_config_json: toJson(u.unit_config),
        unit_config_fetched_at: u.unit_config_fetched_at ?? null,
        last_seen: u.last_seen ?? null,
        devices_json: toJson(u.devices),
        desired_json: toJson(u.desired),
        desired_updated_at: u.desired_updated_at ?? null,
        desired_updated_by: u.desired_updated_by ?? null,
        name: u.name ?? null,
        location: u.location ?? null,
        note: u.note ?? null,
        status,
        created_at: u.created_at ?? null,
      });
      // Historie: nahraď snímkem ze zálohy. getHistory vrací DESC → vkládáme
      // vzestupně (reverse), ať auto-increment id kopíruje původní pořadí.
      delHist.run(id);
      const hist = Array.isArray(u.history) ? [...u.history].reverse() : [];
      for (const h of hist) {
        if (!h || typeof h !== 'object') continue;
        insHist.run(
          id,
          h.at || new Date().toISOString(),
          h.username || username,
          h.action || 'import',
          h.detail == null ? null : JSON.stringify(h.detail)
        );
      }
      pruneHist.run(id, id, HISTORY_RETENTION);
      if (existed) updated += 1;
      else created += 1;
    }
  });
  tx(units);
  return { created, updated, total: created + updated };
}

module.exports = {
  openUnitsDb,
  UNITS_DB_PATH,
  UnitOpError,
  VALID_STATUS,
  normalizeUnitId,
  deriveGeneration,
  scrubSecrets,
  listUnits,
  getUnit,
  upsertObserved,
  updateDesired,
  updateMeta,
  changeUnitId,
  deleteUnit,
  bulkUpdateDesired,
  bulkUpdateMeta,
  bulkDeleteUnits,
  commonDesired,
  getHistory,
  addHistory,
  exportAll,
  exportUnits,
  importUnits,
};
