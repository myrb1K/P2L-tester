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
  return db;
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

// Drift (PRD §4.1): desired vs. observed u polí, která jednotka umí ohlásit
// zpět (broker address, WiFi SSID, jas). Zrcadlí klientskou logiku
// UnitDbCard.driftWarnings — tady jen boolean pro označení řádku seznamu,
// aby seznam nemusel nést desired_json (hesla).
function computeDrift(desiredJson, row) {
  if (!desiredJson) return false;
  let d;
  try {
    d = JSON.parse(desiredJson);
  } catch {
    return false;
  }
  const broker = d.broker;
  if (broker && typeof broker.address === 'string' && broker.address) {
    // mqtt_server = co jednotka sama hlásí (get_param); seen_on_broker = přes
    // který broker ji appka naposledy viděla (každé ALIVE). Rozpor v kterémkoli
    // z nich = drift.
    if (row.mqtt_server && broker.address !== row.mqtt_server) return true;
    if (row.seen_on_broker && broker.address !== row.seen_on_broker) return true;
  }
  const wifi = d.wifi;
  if (wifi && typeof wifi.ssid === 'string' && wifi.ssid &&
      row.ssid && wifi.ssid !== row.ssid) {
    return true;
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
              desired_json
       FROM units ORDER BY CAST(id AS INTEGER)`
    )
    .all()
    .map((row) => {
      const {
        desired_json: desiredJson,
        ssid, mqtt_server: mqttServer, mqtt_port: mqttPort, brightness,
        seen_on_broker: seenOnBroker,
        ...rest
      } = row;
      return { ...rest, drift: computeDrift(desiredJson, row) };
    });
}

function getUnit(db, rawId) {
  const id = normalizeUnitId(rawId);
  const row = db.prepare('SELECT * FROM units WHERE id = ?').get(id);
  if (!row) return null;
  const { devices_json: devicesJson, desired_json: desiredJson, ...rest } = row;
  return {
    ...rest,
    devices: devicesJson ? JSON.parse(devicesJson) : null,
    desired: desiredJson ? JSON.parse(desiredJson) : null,
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
    devices_json: obs.devices === undefined ? undefined : JSON.stringify(obs.devices),
  };
  for (const [col, val] of Object.entries(map)) {
    if (val !== undefined) {
      sets.push(`${col} = @${col}`);
      params[col] = val;
    }
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
  const merged = { ...current, ...fragment };
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
  getHistory,
  addHistory,
};
