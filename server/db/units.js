// CRUD vrstva centrální databáze jednotek (PRD-DB/01-PRD.md, milestone DB2).
// Sdílená mezi API routes (routes/units.js) a testy. Běží nad db/adapter.js,
// takže stejná logika obsluhuje SQLite i MariaDB — asynchronně (MariaDB klient
// synchronní být nemůže).
//
// Zásady:
// - Observed updaty NEgenerují historii (ALIVE chodí à 5 min — byl by šum).
//   Historie vzniká u desired / meta / change-id / delete.
// - Hesla se do historie NIKDY nezapisují — scrubSecrets() maskuje každý
//   klíč obsahující pass/pswd/secret (case-insensitive), rekurzivně.
// - Karta vzniká upsertem při prvním kontaktu (observed) i při prvním
//   zápisu desired/meta — generace se v tom případě odvodí z ID
//   (>= 1000 = nová, jinak stará; stejná heuristika jako v appce).
// - Časové značky zapisuje aplikace jako ISO 8601 (adapter.nowIso), ne SQL
//   funkce — `datetime('now')` a `UTC_TIMESTAMP()` by se lišily formátem.
// - Uvnitř db.transaction(...) se dotazuje přes předaný `tx`, ne přes vnější
//   handle (viz hlavička db/adapter.js).

const { openAdapter, nowIso } = require('./adapter');
const { dataPath } = require('./paths');

// Lazy (ne konstanta při require) kvůli P2L_DATA_DIR — viz db/paths.js.
// Relevantní jen pro SQLite driver.
const unitsDbPath = () => dataPath('units.db');

const VALID_STATUS = ['active', 'faulty', 'stock', 'retired'];

// Retence historie: na jednotku držíme jen posledních N záznamů, zbytek se
// maže (drobné akce, ne archiv). Ořezává se při každém zápisu i jednorázově
// při otevření DB (vyčistí přebytky z doby před retencí).
const HISTORY_RETENTION = 5;

// Strop pro jedno ořezání historie. `LIMIT <n> OFFSET 5` je portable způsob,
// jak vybrat „všechno kromě 5 nejnovějších" — MariaDB nezná SQLite `LIMIT -1`.
const PRUNE_BATCH = 100000;

// Sloupce tabulky units v pořadí pro import/upsert.
const UNIT_COLUMNS = [
  'id', 'generation', 'mac', 'hw_model', 'firmware', 'ip', 'battery',
  'ssid', 'mqtt_server', 'mqtt_port', 'brightness', 'seen_on_broker',
  'unit_config_json', 'unit_config_fetched_at', 'last_seen', 'devices_json',
  'desired_json', 'desired_updated_at', 'desired_updated_by',
  'name', 'location', 'note', 'status', 'created_at', 'updated_at',
];

class UnitOpError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/// Otevře databázi jednotek. Bez argumentu se driver bere z env (DB_DRIVER)
/// a SQLite soubor z data/units.db.
///
/// Pro pohodlí testů přijímá i samotnou cestu k SQLite souboru (`:memory:`).
async function openUnitsDb(optsOrPath) {
  const opts = typeof optsOrPath === 'string' ? { sqliteFile: optsOrPath } : { ...optsOrPath };
  const db = await openAdapter({
    schemas: ['units-schema'],
    sqliteFile: opts.sqliteFile || unitsDbPath(),
    driver: opts.driver,
    config: opts.config,
  });
  await prepareUnitsSchema(db);
  return db;
}

/// Doplnění chybějících sloupců + úklid historie. Vyčleněno, aby to šlo pustit
/// i nad handlem otevřeným jinde (MariaDB má users i units v jedné databázi,
/// takže server otevírá jeden pool — viz db/index.js openDatabases).
async function prepareUnitsSchema(db) {
  await ensureObservedColumns(db);
  await pruneAllHistory(db);
}

// Jednorázový úklid: u každé jednotky nechá jen posledních HISTORY_RETENTION
// záznamů historie. Řeší data z doby před zavedením retence.
async function pruneAllHistory(db) {
  const rows = await db.all(
    'SELECT unit_id FROM unit_history GROUP BY unit_id HAVING COUNT(*) > :keep',
    { keep: HISTORY_RETENTION }
  );
  for (const r of rows) await pruneHistory(db, r.unit_id);
}

// Ořeže historii jedné jednotky na HISTORY_RETENTION nejnovějších záznamů.
//
// Dvoufázově (SELECT id → DELETE ... IN), protože MariaDB nedovolí v subquery
// DELETE odkázat na mazanou tabulku ("You can't specify target table").
// LIMIT/OFFSET jsou vlastní konstanty vložené do SQL, ne parametry: MariaDB
// je v prepared statements přijímá nespolehlivě (a nic tu nepřichází od
// uživatele, takže se nic neriskuje).
async function pruneHistory(db, unitId) {
  const rows = await db.all(
    `SELECT id FROM unit_history WHERE unit_id = :id
     ORDER BY id DESC LIMIT ${PRUNE_BATCH} OFFSET ${HISTORY_RETENTION}`,
    { id: unitId }
  );
  if (rows.length === 0) return;
  const ids = rows.map((r) => r.id);
  await db.run(
    `DELETE FROM unit_history WHERE id IN (${ids.map(() => '?').join(', ')})`,
    ids
  );
}

// Mini-migrace: CREATE TABLE IF NOT EXISTS existující DB nerozšíří, takže
// nové observed sloupce (DB3: ssid/mqtt_server/mqtt_port/brightness) doplní
// ALTER TABLE. Idempotentní — přidá jen chybějící.
async function ensureObservedColumns(db) {
  const existing = await db.columns('units');
  const wanted = {
    ssid: { sqlite: 'TEXT', mariadb: 'VARCHAR(128)' },
    mqtt_server: { sqlite: 'TEXT', mariadb: 'VARCHAR(255)' },
    mqtt_port: { sqlite: 'INTEGER', mariadb: 'INT' },
    brightness: { sqlite: 'INTEGER', mariadb: 'INT' },
    // Host brokeru, přes který appka jednotku naposledy viděla (ALIVE).
    // Na rozdíl od mqtt_server (jen z get_param) se plní každým kontaktem —
    // drift „jednotka žije na jiném brokeru" je vidět hned po discovery.
    seen_on_broker: { sqlite: 'TEXT', mariadb: 'VARCHAR(255)' },
    // DB5: poslední UNIT GET-CONFIG 1:1 (nakonfigurováno + actualIp/actualSSID,
    // hesla jako bool) + čas načtení. Bohatší observed než get_param.
    unit_config_json: { sqlite: 'TEXT', mariadb: 'LONGTEXT' },
    unit_config_fetched_at: { sqlite: 'TEXT', mariadb: 'VARCHAR(32)' },
  };
  for (const [col, types] of Object.entries(wanted)) {
    if (!existing.has(col)) {
      await db.exec(`ALTER TABLE units ADD COLUMN ${col} ${types[db.dialect]}`);
    }
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

async function addHistory(db, unitId, username, action, detail) {
  await db.run(
    `INSERT INTO unit_history (unit_id, at, username, action, detail_json)
     VALUES (:unit_id, :at, :username, :action, :detail_json)`,
    {
      unit_id: unitId,
      at: nowIso(),
      username,
      action,
      detail_json: detail == null ? null : JSON.stringify(scrubSecrets(detail)),
    }
  );
  // Retence: na jednotku držíme jen posledních HISTORY_RETENTION záznamů.
  await pruneHistory(db, unitId);
}

async function getHistory(db, rawId, limit = 200) {
  const id = normalizeUnitId(rawId);
  // LIMIT inline (viz pruneHistory) — hodnota je z kódu, ne z requestu, ale
  // pro jistotu ji stejně protáhneme přes celočíselnou kontrolu.
  const n = Number.isInteger(limit) && limit > 0 ? limit : 200;
  const rows = await db.all(
    `SELECT at, username, action, detail_json FROM unit_history
     WHERE unit_id = :id ORDER BY id DESC LIMIT ${n}`,
    { id }
  );
  return rows.map((r) => ({
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
// Časy jsou ISO 8601 z appky i ze serveru ('…T…Z'); starší SQLite data mohou
// nést `datetime('now')` tvar ('YYYY-MM-DD HH:MM:SS', UTC bez tz) → obojí
// převedeme na Date v UTC. Zrcadlí klientský _parseTime.
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
async function listUnits(db) {
  const rows = await db.all(
    `SELECT id, generation, mac, name, location, status, last_seen, firmware,
            ip, battery, updated_at,
            ssid, mqtt_server, mqtt_port, brightness, seen_on_broker,
            unit_config_json, desired_json, desired_updated_at
     FROM units ORDER BY ${db.sql.castInt('id')}`
  );
  return rows.map((row) => {
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

async function getUnit(db, rawId) {
  const id = normalizeUnitId(rawId);
  const row = await db.get('SELECT * FROM units WHERE id = :id', { id });
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

async function unitExists(db, id) {
  return !!(await db.get('SELECT 1 AS x FROM units WHERE id = :id', { id }));
}

// Založí prázdnou kartu, pokud neexistuje. Vrací kanonické ID.
async function ensureUnit(db, rawId, generation) {
  const id = normalizeUnitId(rawId);
  const gen = generation === 'old' || generation === 'new' ? generation : deriveGeneration(id);
  const now = nowIso();
  await db.run(
    `INSERT INTO units (id, generation, status, created_at, updated_at)
     VALUES (:id, :generation, 'active', :created_at, :updated_at)
     ${db.sql.onConflictDoNothing('id')}`,
    { id, generation: gen, created_at: now, updated_at: now }
  );
  return id;
}

// Observed vrstva — merge: přepisují se jen dodaná pole (partial update,
// např. ALIVE nese jen firmware+baterii, get_param zbytek). Bez historie.
async function upsertObserved(db, rawId, obs = {}) {
  const id = await ensureUnit(db, rawId, obs.generation);
  const sets = [];
  const params = { id };
  // GET-CONFIG snapshot: chraň dřív zachycená skutečná hesla před pozdějším bool.
  let configToStore = obs.unitConfig;
  if (obs.unitConfig !== undefined) {
    const prev = await db.get('SELECT unit_config_json FROM units WHERE id = :id', { id });
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
      sets.push(`${col} = :${col}`);
      params[col] = val;
    }
  }
  if (obs.unitConfig !== undefined) {
    sets.push('unit_config_fetched_at = :unit_config_fetched_at');
    params.unit_config_fetched_at = obs.lastSeen || nowIso();
  }
  if (obs.generation === 'old' || obs.generation === 'new') {
    sets.push('generation = :generation');
    params.generation = obs.generation;
  }
  sets.push('last_seen = :last_seen');
  params.last_seen = obs.lastSeen || nowIso();
  sets.push('updated_at = :updated_at');
  params.updated_at = nowIso();
  await db.run(`UPDATE units SET ${sets.join(', ')} WHERE id = :id`, params);
  return id;
}

// Desired vrstva — merge po top-level klíčích: appka zapisuje po akcích
// (set_Mqtt → {broker}, set_WiFi → {wifi}, …), takže poslaný fragment
// přepíše jen svoje klíče a zbytek desired zůstává. Historie dostává jen
// fragment (se scrubnutými hesly).
async function updateDesired(db, rawId, fragment, username) {
  if (fragment === null || typeof fragment !== 'object' || Array.isArray(fragment)) {
    throw new UnitOpError('invalid_body', 'desired musí být JSON objekt');
  }
  const id = await ensureUnit(db, rawId);
  const row = await db.get('SELECT desired_json FROM units WHERE id = :id', { id });
  const current = row?.desired_json ? JSON.parse(row.desired_json) : {};
  // Hloubkový merge o jednu úroveň: vnořené objekty (broker, wifi) se slévají
  // po podklíčích, ne nahrazují vcelku — jinak by částečný fragment (např. jen
  // {broker:{address}}) u hromadné editace smazal ostatní podpole (port/heslo).
  const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
  const merged = { ...current };
  for (const [k, v] of Object.entries(fragment)) {
    merged[k] = isObj(v) && isObj(merged[k]) ? { ...merged[k], ...v } : v;
  }
  const now = nowIso();
  await db.run(
    `UPDATE units SET desired_json = :desired_json, desired_updated_at = :at,
     desired_updated_by = :by, updated_at = :at WHERE id = :id`,
    { desired_json: JSON.stringify(merged), at: now, by: username, id }
  );
  await addHistory(db, id, username, 'desired', fragment);
  return id;
}

// Meta vrstva — partial update (jen dodaná pole) + historie.
async function updateMeta(db, rawId, meta = {}, username) {
  if (meta.status !== undefined && !VALID_STATUS.includes(meta.status)) {
    throw new UnitOpError('invalid_status', `Neplatný stav '${meta.status}' (povolené: ${VALID_STATUS.join(', ')})`);
  }
  const id = await ensureUnit(db, rawId);
  const sets = [];
  const params = { id };
  const changed = {};
  for (const col of ['name', 'location', 'note', 'status']) {
    if (meta[col] !== undefined) {
      sets.push(`${col} = :${col}`);
      params[col] = meta[col];
      changed[col] = meta[col];
    }
  }
  if (sets.length === 0) {
    throw new UnitOpError('invalid_body', 'Žádné pole ke změně (name / location / note / status)');
  }
  sets.push('updated_at = :updated_at');
  params.updated_at = nowIso();
  await db.run(`UPDATE units SET ${sets.join(', ')} WHERE id = :id`, params);
  await addHistory(db, id, username, 'meta', changed);
  return id;
}

// Přečíslování jednotky (change_ID) — karta se PŘENÁŠÍ včetně historie,
// nezakládá se nová (PRD §7 R6).
async function changeUnitId(db, rawOldId, rawNewId, username) {
  const oldId = normalizeUnitId(rawOldId);
  const newId = normalizeUnitId(rawNewId);
  if (oldId === newId) throw new UnitOpError('same_id', 'Nové ID je shodné se starým.');
  if (!(await unitExists(db, oldId))) throw new UnitOpError('not_found', `Jednotka '${oldId}' v DB není.`);
  if (await unitExists(db, newId)) throw new UnitOpError('duplicate', `Jednotka '${newId}' už v DB existuje.`);
  await db.transaction(async (tx) => {
    await tx.run(
      'UPDATE units SET id = :newId, generation = :generation, updated_at = :updated_at WHERE id = :oldId',
      { newId, generation: deriveGeneration(newId), updated_at: nowIso(), oldId }
    );
    await tx.run('UPDATE unit_history SET unit_id = :newId WHERE unit_id = :oldId', { newId, oldId });
    await addHistory(tx, newId, username, 'change_id', { from: oldId, to: newId });
  });
  return newId;
}

// Smazání karty včetně historie (jen admin — vynucuje route).
async function deleteUnit(db, rawId) {
  const id = normalizeUnitId(rawId);
  if (!(await unitExists(db, id))) throw new UnitOpError('not_found', `Jednotka '${id}' v DB není.`);
  await db.transaction(async (tx) => {
    await tx.run('DELETE FROM unit_history WHERE unit_id = :id', { id });
    await tx.run('DELETE FROM units WHERE id = :id', { id });
  });
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

async function bulkUpdateDesired(db, ids, fragment, username) {
  requireIds(ids);
  await db.transaction(async (tx) => {
    for (const rawId of ids) await updateDesired(tx, rawId, fragment, username);
  });
  return ids.length;
}

async function bulkUpdateMeta(db, ids, meta, username) {
  requireIds(ids);
  await db.transaction(async (tx) => {
    for (const rawId of ids) await updateMeta(tx, rawId, meta, username);
  });
  return ids.length;
}

// Společné hodnoty evidence napříč vybranými jednotkami — pro předvyplnění
// dialogu hromadné editace. Každé pole (i vnořené broker/wifi po podklíčích)
// se zařadí jen když ho mají VŠECHNY vybrané a je shodné; jinak se vynechá
// (v dialogu prázdné). Heslo se vrátí jen když ho mají všichni stejné.
async function commonDesired(db, ids) {
  requireIds(ids);
  const desireds = [];
  for (const rawId of ids) {
    const id = normalizeUnitId(rawId);
    const row = await db.get('SELECT desired_json FROM units WHERE id = :id', { id });
    desireds.push(row && row.desired_json ? JSON.parse(row.desired_json) : {});
  }
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
async function bulkDeleteUnits(db, ids) {
  requireIds(ids);
  let n = 0;
  await db.transaction(async (tx) => {
    for (const rawId of ids) {
      const id = normalizeUnitId(rawId);
      if (!(await unitExists(tx, id))) continue;
      await tx.run('DELETE FROM unit_history WHERE unit_id = :id', { id });
      await tx.run('DELETE FROM units WHERE id = :id', { id });
      n++;
    }
  });
  return n;
}

// ── Export / Import DB (kompletní záloha / obnova) ──────────────────────────
// Export: úplný snímek jednotky (getUnit = všechna pole vč. desired s reálnými
// hesly) + historie. Určeno pro plný backup i přenos mezi servery.
// [ids] === null → celá DB; jinak jen vybrané (tolerantní k chybějícím ID —
// přeskočí je). Formát řádku je stejný, ať jde o jednu jednotku nebo všechny.
async function exportUnits(db, ids = null) {
  let idList;
  if (ids == null) {
    const rows = await db.all(`SELECT id FROM units ORDER BY ${db.sql.castInt('id')}`);
    idList = rows.map((r) => r.id);
  } else {
    if (!Array.isArray(ids) || ids.length === 0) {
      throw new UnitOpError('invalid_body', 'ids musí být neprázdné pole');
    }
    idList = ids.map(normalizeUnitId);
  }
  const out = [];
  for (const id of idList) {
    const unit = await getUnit(db, id);
    if (!unit) continue; // tolerantní k chybějícímu ID
    unit.history = await getHistory(db, id, 10000);
    out.push(unit);
  }
  return out;
}

// Celá DB (zpětně kompatibilní alias).
async function exportAll(db) {
  return exportUnits(db, null);
}

// Import: SLOUČENÍ po ID (upsert) — existující jednotky se přepíšou snímkem ze
// zálohy, nové se přidají, jednotky mimo zálohu zůstanou nedotčené (nic se
// nemaže). Historie importované jednotky se nahradí historií ze zálohy, takže
// opakovaný import téhož souboru je idempotentní (neduplikuje). Vše v jedné
// transakci. Vrací { created, updated, total }.
async function importUnits(db, units, username) {
  if (!Array.isArray(units)) {
    throw new UnitOpError('invalid_body', 'units musí být pole');
  }
  const toJson = (v) => (v === undefined || v === null ? null : JSON.stringify(v));
  // Při konfliktu se přepíše vše kromě PK a created_at (to zůstává původní).
  const updateCols = UNIT_COLUMNS.filter((c) => c !== 'id' && c !== 'created_at');
  const upsertSql =
    `INSERT INTO units (${UNIT_COLUMNS.join(', ')})
     VALUES (${UNIT_COLUMNS.map((c) => `:${c}`).join(', ')})
     ${db.sql.onConflictUpdate('id', updateCols)}`;

  let created = 0;
  let updated = 0;
  await db.transaction(async (tx) => {
    for (const u of units) {
      if (!u || typeof u !== 'object' || Array.isArray(u)) {
        throw new UnitOpError('invalid_body', 'Každá jednotka musí být objekt');
      }
      const id = normalizeUnitId(u.id);
      const existed = await unitExists(tx, id);
      const generation =
        u.generation === 'old' || u.generation === 'new'
          ? u.generation
          : deriveGeneration(id);
      const status = VALID_STATUS.includes(u.status) ? u.status : 'active';
      const now = nowIso();
      await tx.run(upsertSql, {
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
        created_at: u.created_at ?? now,
        updated_at: now,
      });
      // Historie: nahraď snímkem ze zálohy. getHistory vrací DESC → vkládáme
      // vzestupně (reverse), ať auto-increment id kopíruje původní pořadí.
      await tx.run('DELETE FROM unit_history WHERE unit_id = :id', { id });
      const hist = Array.isArray(u.history) ? [...u.history].reverse() : [];
      for (const h of hist) {
        if (!h || typeof h !== 'object') continue;
        await tx.run(
          `INSERT INTO unit_history (unit_id, at, username, action, detail_json)
           VALUES (:unit_id, :at, :username, :action, :detail_json)`,
          {
            unit_id: id,
            at: h.at || nowIso(),
            username: h.username || username,
            action: h.action || 'import',
            detail_json: h.detail == null ? null : JSON.stringify(h.detail),
          }
        );
      }
      await pruneHistory(tx, id);
      if (existed) updated += 1;
      else created += 1;
    }
  });
  return { created, updated, total: created + updated };
}

module.exports = {
  openUnitsDb,
  prepareUnitsSchema,
  unitsDbPath,
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
