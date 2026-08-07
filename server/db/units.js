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
// maže. Ořezává se při každém zápisu i jednorázově při otevření DB.
//
// DB9 zvedlo hodnotu z 5 na 200: audit má být procházitelný („kdo kdy co
// změnil", PRD-DB/03-PRD-sync.md §8) a offline klient navíc nahraje celou
// dávku změn najednou — s pěti záznamy by se skoro vše okamžitě zahodilo.
// Přepsatelné env `HISTORY_RETENTION` (0 = bez ořezávání). Čte se při každém
// ořezání, ne jednou při require — jinak by se hodnota nedala změnit v testech
// (a v provozu by vyžadovala restart).
const HISTORY_RETENTION_DEFAULT = 200;

function historyRetention() {
  const raw = parseInt(process.env.HISTORY_RETENTION, 10);
  return Number.isInteger(raw) && raw >= 0 ? raw : HISTORY_RETENTION_DEFAULT;
}

// Strop pro jedno ořezání historie. `LIMIT <n> OFFSET 5` je portable způsob,
// jak vybrat „všechno kromě 5 nejnovějších" — MariaDB nezná SQLite `LIMIT -1`.
const PRUNE_BATCH = 100000;

// Sloupce tabulky units v pořadí pro import/upsert.
// `rev` tu není: importovaná karta musí dostat NOVOU revizi z cílového serveru
// (jinak by si ji klienti nestáhli), nastavuje ji importUnits zvlášť.
const UNIT_COLUMNS = [
  'id', 'generation', 'mac', 'hw_model', 'firmware', 'ip', 'battery',
  'ssid', 'mqtt_server', 'mqtt_port', 'brightness', 'seen_on_broker',
  'unit_config_json', 'unit_config_fetched_at', 'last_seen', 'devices_json',
  'desired_json', 'desired_updated_at', 'desired_updated_by',
  'name', 'location', 'note', 'status', 'created_at', 'updated_at',
  // DB9: časy vrstev se přenášejí, aby po importu dál fungovalo rozhodování
  // „kdo je novější" (bez nich by každý pozdější zápis vyhrál automaticky).
  'observed_updated_at', 'meta_updated_at', 'meta_updated_by',
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
  await ensureSyncSchema(db);
  await pruneAllHistory(db);
}

// Jednorázový úklid: u každé jednotky nechá jen posledních HISTORY_RETENTION
// záznamů historie. Řeší data z doby před zavedením retence.
async function pruneAllHistory(db) {
  const keep = historyRetention();
  if (keep === 0) return;
  const rows = await db.all(
    'SELECT unit_id FROM unit_history GROUP BY unit_id HAVING COUNT(*) > :keep',
    { keep }
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
  const keep = historyRetention();
  if (keep === 0) return;
  const rows = await db.all(
    `SELECT id FROM unit_history WHERE unit_id = :id
     ORDER BY id DESC LIMIT ${PRUNE_BATCH} OFFSET ${keep}`,
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

// ── Sync schéma (DB9) ──────────────────────────────────────────────────────
//
// Mini-migrace pro DB, které vznikly před DB9: doplní sync sloupce, pomocné
// tabulky a indexy. Idempotentní — nad novou DB (schéma už vše má) neudělá nic.
//
// Existující karty dostanou `rev = 0`, takže první `listChanges(since=0)`
// vrátí celou databázi — přesně to, co bootstrap klienta potřebuje.
async function ensureSyncSchema(db) {
  const unitCols = await db.columns('units');
  const unitWanted = {
    rev: { sqlite: 'INTEGER NOT NULL DEFAULT 0', mariadb: 'BIGINT NOT NULL DEFAULT 0' },
    observed_updated_at: { sqlite: 'TEXT', mariadb: 'VARCHAR(32)' },
    meta_updated_at: { sqlite: 'TEXT', mariadb: 'VARCHAR(32)' },
    meta_updated_by: { sqlite: 'TEXT', mariadb: 'VARCHAR(64)' },
    deleted_at: { sqlite: 'TEXT', mariadb: 'VARCHAR(32)' },
    deleted_by: { sqlite: 'TEXT', mariadb: 'VARCHAR(64)' },
  };
  for (const [col, types] of Object.entries(unitWanted)) {
    if (!unitCols.has(col)) {
      await db.exec(`ALTER TABLE units ADD COLUMN ${col} ${types[db.dialect]}`);
    }
  }

  const histCols = await db.columns('unit_history');
  const histWanted = {
    uuid: { sqlite: 'TEXT', mariadb: 'VARCHAR(64)' },
    layer: { sqlite: 'TEXT', mariadb: 'VARCHAR(16)' },
    origin: { sqlite: 'TEXT', mariadb: 'VARCHAR(16)' },
    source_device: { sqlite: 'TEXT', mariadb: 'VARCHAR(64)' },
    rev: { sqlite: 'INTEGER', mariadb: 'BIGINT' },
  };
  for (const [col, types] of Object.entries(histWanted)) {
    if (!histCols.has(col)) {
      await db.exec(`ALTER TABLE unit_history ADD COLUMN ${col} ${types[db.dialect]}`);
    }
  }

  // Tabulky pro čítač revizí a idempotenci pushů. Ve schématu jsou taky, tady
  // kvůli DB vzniklým před DB9 (schéma se nad existující DB nepřehrává celé).
  if (db.dialect === 'mariadb') {
    await db.exec(`CREATE TABLE IF NOT EXISTS sync_counter (
      id INT NOT NULL PRIMARY KEY, value BIGINT NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`);
    await db.exec(`CREATE TABLE IF NOT EXISTS sync_ops (
      op_id VARCHAR(64) NOT NULL PRIMARY KEY, unit_id VARCHAR(16) NOT NULL,
      layer VARCHAR(16) NOT NULL, status VARCHAR(16) NOT NULL,
      rev BIGINT, applied_at VARCHAR(32) NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`);
    await db.run('INSERT IGNORE INTO sync_counter (id, value) VALUES (1, 0)');
  } else {
    await db.exec(`CREATE TABLE IF NOT EXISTS sync_counter (
      id INTEGER PRIMARY KEY, value INTEGER NOT NULL
    )`);
    await db.exec(`CREATE TABLE IF NOT EXISTS sync_ops (
      op_id TEXT PRIMARY KEY, unit_id TEXT NOT NULL, layer TEXT NOT NULL,
      status TEXT NOT NULL, rev INTEGER, applied_at TEXT NOT NULL
    )`);
    await db.run('INSERT OR IGNORE INTO sync_counter (id, value) VALUES (1, 0)');
  }

  await ensureIndex(db, 'units', 'idx_units_rev', '(rev)');
  await ensureIndex(db, 'unit_history', 'idx_unit_history_uuid', '(uuid)');
}

// `CREATE INDEX IF NOT EXISTS` MariaDB neumí a duplicitní index je tam chyba
// („Duplicate key name"). Spolknout ji je bezpečnější než introspekce přes
// information_schema — index buď vznikne, nebo už je.
async function ensureIndex(db, table, name, columns) {
  try {
    if (db.dialect === 'mariadb') {
      await db.exec(`CREATE INDEX ${name} ON ${table} ${columns}`);
    } else {
      await db.exec(`CREATE INDEX IF NOT EXISTS ${name} ON ${table} ${columns}`);
    }
  } catch (err) {
    if (!/duplicate key name/i.test(err.message || '')) throw err;
  }
}

// Další revize. MUSÍ se volat uvnitř transakce (`tx`), jinak by dva souběžné
// zápisy mohly dostat totéž číslo: u MariaDB drží `UPDATE` zámek řádku až do
// commitu, u SQLite serializuje zápisy mutex adapteru.
async function nextRev(tx) {
  await tx.run('UPDATE sync_counter SET value = value + 1 WHERE id = 1');
  const row = await tx.get('SELECT value FROM sync_counter WHERE id = 1');
  return Number(row ? row.value : 0);
}

/// Aktuální revize (nejvyšší přidělená) — pro `maxRev` v odpovědích sync API.
async function currentRev(db) {
  const row = await db.get('SELECT value FROM sync_counter WHERE id = 1');
  return Number(row ? row.value : 0);
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

// `meta` (DB9): { layer, origin, sourceDevice, rev, uuid, at } — audit sloupce
// pro obrazovku Změn a pro dohledání, odkud zápis přišel. Volitelné, aby starší
// volání (a testy) fungovala dál; `layer` se pak odvodí z akce.
async function addHistory(db, unitId, username, action, detail, meta = {}) {
  await db.run(
    `INSERT INTO unit_history
       (unit_id, at, username, action, detail_json, uuid, layer, origin, source_device, rev)
     VALUES (:unit_id, :at, :username, :action, :detail_json, :uuid, :layer, :origin,
             :source_device, :rev)`,
    {
      unit_id: unitId,
      at: meta.at || nowIso(),
      username,
      action,
      detail_json: detail == null ? null : JSON.stringify(scrubSecrets(detail)),
      uuid: meta.uuid || null,
      layer: meta.layer || action,
      // Bez explicitního origin je to přímý zápis proti serveru (web/online klient).
      origin: meta.origin || 'online',
      source_device: meta.sourceDevice || null,
      rev: meta.rev == null ? null : meta.rev,
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
    `SELECT at, username, action, detail_json, uuid, layer, origin, source_device, rev
     FROM unit_history
     WHERE unit_id = :id ORDER BY id DESC LIMIT ${n}`,
    { id }
  );
  return rows.map((r) => ({
    at: r.at,
    username: r.username,
    action: r.action,
    detail: r.detail_json ? JSON.parse(r.detail_json) : null,
    // DB9 audit: u záznamů z doby před DB9 jsou null.
    uuid: r.uuid || null,
    layer: r.layer || null,
    origin: r.origin || null,
    sourceDevice: r.source_device || null,
    rev: r.rev == null ? null : Number(r.rev),
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
     FROM units WHERE deleted_at IS NULL ORDER BY ${db.sql.castInt('id')}`
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

/// Detail karty. Tombstone (smazaná karta) se chová jako neexistující —
/// `includeDeleted: true` ji vrátí (používá sync push, aby mohl vrátit
/// `current` stav u konfliktu).
async function getUnit(db, rawId, { includeDeleted = false } = {}) {
  const id = normalizeUnitId(rawId);
  const row = await db.get('SELECT * FROM units WHERE id = :id', { id });
  if (!row) return null;
  if (row.deleted_at && !includeDeleted) return null;
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

// ── Vrstvové zápisy (jádro, DB9) ───────────────────────────────────────────
//
// Každý zápis do karty přiděluje novou revizi (`rev`) a razí čas své vrstvy
// (`observed_updated_at` / `desired_updated_at` / `meta_updated_at`). Podle
// těch časů se rozhoduje o vítězi, když stejnou vrstvu změnil někdo jiný —
// viz PRD-DB/03-PRD-sync.md §5.
//
// `ctx` (volitelný, plní ho sync push):
//   at           čas, kdy změna vznikla u klienta (normalizovaný na serverový
//                čas). Bez něj `nowIso()` → online zápis vždy vyhrává.
//   username, origin ('online' | 'sync' | 'mqtt'), sourceDevice, uuid
//
// Návratový status:
//   applied     zapsáno
//   superseded  zahozeno, protože server má novější stav téže vrstvy
//               (u observed) nebo karta byla mezitím smazána
//   conflict    ruční vrstva (desired/meta) prohrála s novější serverovou verzí
//               — nezapsáno, prohraná verze uložena do historie
function ctxAt(ctx) {
  return (ctx && ctx.at) || nowIso();
}

function historyMeta(ctx, rev, layer) {
  return {
    at: ctxAt(ctx),
    uuid: ctx && ctx.uuid,
    origin: (ctx && ctx.origin) || 'online',
    sourceDevice: ctx && ctx.sourceDevice,
    rev,
    layer,
  };
}

// Novější zápis „vyhrává": vrací true, když už v DB je stav mladší než `at`.
function serverIsNewer(existingAt, at) {
  const a = parseTs(existingAt);
  const b = parseTs(at);
  if (!a || !b) return false; // bez použitelných časů se nikdy neblokuje
  return a > b;
}

// Tombstone: zápis starší než smazání se zahazuje (mazání vyhrává, PRD §5).
// Novější zápis kartu naopak vzkřísí — jednotka fyzicky existuje a evidence se
// plní automaticky, takže trvalý zákaz by byl matoucí. Tombstone je tedy
// doručovací mechanismus pro ostatní klienty, ne permanentní blokace.
function tombstoneBlocks(row, at) {
  if (!row || !row.deleted_at) return false;
  return !serverIsNewer(at, row.deleted_at);
}

// Observed vrstva — merge: přepisují se jen dodaná pole (partial update,
// např. ALIVE nese jen firmware+baterii, get_param zbytek). Bez historie.
async function applyObserved(tx, rawId, obs = {}, ctx = null) {
  const at = ctxAt(ctx);
  const id = await ensureUnit(tx, rawId, obs.generation);
  const row = await tx.get(
    'SELECT unit_config_json, observed_updated_at, deleted_at FROM units WHERE id = :id',
    { id }
  );
  if (tombstoneBlocks(row, at)) return { id, status: 'superseded', rev: null };
  if (serverIsNewer(row && row.observed_updated_at, at)) {
    return { id, status: 'superseded', rev: null };
  }
  const sets = [];
  const params = { id };
  // GET-CONFIG snapshot: chraň dřív zachycená skutečná hesla před pozdějším bool.
  let configToStore = obs.unitConfig;
  if (obs.unitConfig !== undefined) {
    configToStore = mergeConfigSecrets(obs.unitConfig, row && row.unit_config_json);
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
  sets.push('observed_updated_at = :observed_updated_at');
  params.observed_updated_at = at;
  sets.push('updated_at = :updated_at');
  params.updated_at = nowIso();
  const rev = await nextRev(tx);
  sets.push('rev = :rev');
  params.rev = rev;
  // Novější observed zápis vzkřísí smazanou kartu (viz tombstoneBlocks).
  if (row && row.deleted_at) {
    sets.push('deleted_at = NULL', 'deleted_by = NULL');
  }
  await tx.run(`UPDATE units SET ${sets.join(', ')} WHERE id = :id`, params);
  return { id, status: 'applied', rev };
}

/// Observed vrstva jako samostatná operace (route PUT /:id/observed).
/// Transakce kvůli `nextRev` — dva souběžné zápisy nesmí dostat totéž rev.
async function upsertObserved(db, rawId, obs = {}, ctx = null) {
  const res = await db.transaction((tx) => applyObserved(tx, rawId, obs, ctx));
  return res.id;
}

// Desired vrstva — merge po top-level klíčích: appka zapisuje po akcích
// (set_Mqtt → {broker}, set_WiFi → {wifi}, …), takže poslaný fragment
// přepíše jen svoje klíče a zbytek desired zůstává. Historie dostává jen
// fragment (se scrubnutými hesly).
async function applyDesired(tx, rawId, fragment, username, ctx = null) {
  if (fragment === null || typeof fragment !== 'object' || Array.isArray(fragment)) {
    throw new UnitOpError('invalid_body', 'desired musí být JSON objekt');
  }
  const at = ctxAt(ctx);
  const id = await ensureUnit(tx, rawId);
  const row = await tx.get(
    'SELECT desired_json, desired_updated_at, deleted_at FROM units WHERE id = :id',
    { id }
  );
  // Karta smazána novějším mazáním, nebo tuhle vrstvu už někdo změnil později:
  // prohraná verze se nezahazuje mlčky, jde do historie (PRD §5).
  const lost = tombstoneBlocks(row, at)
    ? 'superseded'
    : serverIsNewer(row && row.desired_updated_at, at)
      ? 'conflict'
      : null;
  if (lost) {
    const rev = await nextRev(tx);
    await addHistory(tx, id, username, 'superseded_local', fragment,
      historyMeta(ctx, rev, 'desired'));
    return { id, status: lost, rev: null };
  }
  const current = row?.desired_json ? JSON.parse(row.desired_json) : {};
  // Hloubkový merge o jednu úroveň: vnořené objekty (broker, wifi) se slévají
  // po podklíčích, ne nahrazují vcelku — jinak by částečný fragment (např. jen
  // {broker:{address}}) u hromadné editace smazal ostatní podpole (port/heslo).
  const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
  const merged = { ...current };
  for (const [k, v] of Object.entries(fragment)) {
    merged[k] = isObj(v) && isObj(merged[k]) ? { ...merged[k], ...v } : v;
  }
  const rev = await nextRev(tx);
  await tx.run(
    `UPDATE units SET desired_json = :desired_json, desired_updated_at = :at,
     desired_updated_by = :by, updated_at = :now, rev = :rev,
     deleted_at = NULL, deleted_by = NULL WHERE id = :id`,
    { desired_json: JSON.stringify(merged), at, by: username, now: nowIso(), rev, id }
  );
  await addHistory(tx, id, username, 'desired', fragment, historyMeta(ctx, rev, 'desired'));
  return { id, status: 'applied', rev };
}

async function updateDesired(db, rawId, fragment, username, ctx = null) {
  const res = await db.transaction((tx) => applyDesired(tx, rawId, fragment, username, ctx));
  return res.id;
}

// Meta vrstva — partial update (jen dodaná pole) + historie.
async function applyMeta(tx, rawId, meta = {}, username, ctx = null) {
  if (meta.status !== undefined && !VALID_STATUS.includes(meta.status)) {
    throw new UnitOpError('invalid_status', `Neplatný stav '${meta.status}' (povolené: ${VALID_STATUS.join(', ')})`);
  }
  const at = ctxAt(ctx);
  const id = await ensureUnit(tx, rawId);
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
  const row = await tx.get(
    'SELECT meta_updated_at, deleted_at FROM units WHERE id = :id',
    { id }
  );
  const lost = tombstoneBlocks(row, at)
    ? 'superseded'
    : serverIsNewer(row && row.meta_updated_at, at)
      ? 'conflict'
      : null;
  if (lost) {
    const rev = await nextRev(tx);
    await addHistory(tx, id, username, 'superseded_local', changed,
      historyMeta(ctx, rev, 'meta'));
    return { id, status: lost, rev: null };
  }
  const rev = await nextRev(tx);
  sets.push('meta_updated_at = :meta_updated_at', 'meta_updated_by = :meta_updated_by');
  params.meta_updated_at = at;
  params.meta_updated_by = username || null;
  sets.push('updated_at = :updated_at');
  params.updated_at = nowIso();
  sets.push('rev = :rev');
  params.rev = rev;
  sets.push('deleted_at = NULL', 'deleted_by = NULL');
  await tx.run(`UPDATE units SET ${sets.join(', ')} WHERE id = :id`, params);
  await addHistory(tx, id, username, 'meta', changed, historyMeta(ctx, rev, 'meta'));
  return { id, status: 'applied', rev };
}

async function updateMeta(db, rawId, meta = {}, username, ctx = null) {
  const res = await db.transaction((tx) => applyMeta(tx, rawId, meta, username, ctx));
  return res.id;
}

// Přečíslování jednotky (change_ID) — karta se PŘENÁŠÍ včetně historie,
// nezakládá se nová (PRD §7 R6).
async function changeUnitId(db, rawOldId, rawNewId, username) {
  const oldId = normalizeUnitId(rawOldId);
  const newId = normalizeUnitId(rawNewId);
  if (oldId === newId) throw new UnitOpError('same_id', 'Nové ID je shodné se starým.');
  const oldRow = await db.get('SELECT deleted_at FROM units WHERE id = :id', { id: oldId });
  if (!oldRow || oldRow.deleted_at) {
    throw new UnitOpError('not_found', `Jednotka '${oldId}' v DB není.`);
  }
  // Kolize se hlídá i proti tombstonu — řádek fyzicky existuje, takže by INSERT
  // stejně spadl na primárním klíči; jen bez čitelné hlášky.
  if (await unitExists(db, newId)) throw new UnitOpError('duplicate', `Jednotka '${newId}' už v DB existuje.`);
  await db.transaction(async (tx) => {
    const now = nowIso();
    const rev = await nextRev(tx);
    await tx.run(
      `UPDATE units SET id = :newId, generation = :generation, updated_at = :updated_at,
       rev = :rev WHERE id = :oldId`,
      { newId, generation: deriveGeneration(newId), updated_at: now, rev, oldId }
    );
    await tx.run('UPDATE unit_history SET unit_id = :newId WHERE unit_id = :oldId', { newId, oldId });
    // Pro ostatní klienty staré ID zaniklo — bez tombstonu by jim v lokální DB
    // zůstala navěky (karta se stěhuje, nemaže, takže by o ní nic nedozvěděli).
    const oldRev = await nextRev(tx);
    await tx.run(
      `INSERT INTO units (id, generation, status, created_at, updated_at, rev,
                          deleted_at, deleted_by)
       VALUES (:id, :generation, 'retired', :created_at, :updated_at, :rev, :deleted_at, :deleted_by)
       ${db.sql.onConflictUpdate('id', ['rev', 'deleted_at', 'deleted_by', 'updated_at'])}`,
      {
        id: oldId, generation: deriveGeneration(oldId), created_at: now, updated_at: now,
        rev: oldRev, deleted_at: now, deleted_by: username || null,
      }
    );
    await addHistory(tx, newId, username, 'change_id', { from: oldId, to: newId },
      { rev, layer: 'change_id' });
  });
  return newId;
}

// Smazání karty — tombstone, ne fyzické mazání (DB9). Bez něj by se karta při
// dalším syncu vrátila z lokální DB klienta, který o mazání neví. Historie
// zůstává (audit) a dostane záznam `delete`.
//
// Novější zápis kartu vzkřísí (viz tombstoneBlocks) — tombstone je doručovací
// mechanismus, ne trvalý zákaz.
async function applyDelete(tx, rawId, username, ctx = null) {
  const at = ctxAt(ctx);
  const id = normalizeUnitId(rawId);
  const row = await tx.get('SELECT deleted_at FROM units WHERE id = :id', { id });
  if (!row) throw new UnitOpError('not_found', `Jednotka '${id}' v DB není.`);
  if (row.deleted_at) return { id, status: 'applied', rev: null }; // už smazaná → idempotentní
  const rev = await nextRev(tx);
  await tx.run(
    `UPDATE units SET deleted_at = :at, deleted_by = :by, rev = :rev, updated_at = :now
     WHERE id = :id`,
    { at, by: username || null, rev, now: nowIso(), id }
  );
  // `username` je v historii NOT NULL — u volání bez uživatele (CLI, testy)
  // zapíšeme 'system', ať se audit nerozbije o chybějící jméno.
  await addHistory(tx, id, username || 'system', 'delete', null,
    historyMeta(ctx, rev, 'delete'));
  return { id, status: 'applied', rev };
}

async function deleteUnit(db, rawId, username = null, ctx = null) {
  await db.transaction((tx) => applyDelete(tx, rawId, username, ctx));
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
// zmizet; přeskočíme ho místo abychom shodili celou dávku. Maže tombstonem
// (viz applyDelete).
async function bulkDeleteUnits(db, ids, username = null) {
  requireIds(ids);
  let n = 0;
  await db.transaction(async (tx) => {
    for (const rawId of ids) {
      const id = normalizeUnitId(rawId);
      const row = await tx.get('SELECT deleted_at FROM units WHERE id = :id', { id });
      if (!row || row.deleted_at) continue;
      await applyDelete(tx, id, username);
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
    // Tombstones do zálohy nepatří — obnova by pak vzkřísila „smazáno".
    const rows = await db.all(
      `SELECT id FROM units WHERE deleted_at IS NULL ORDER BY ${db.sql.castInt('id')}`
    );
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
      const rev = await nextRev(tx);
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
        observed_updated_at: u.observed_updated_at ?? u.last_seen ?? null,
        meta_updated_at: u.meta_updated_at ?? null,
        meta_updated_by: u.meta_updated_by ?? null,
      });
      // Nová revize + zrušení případného tombstonu: obnova ze zálohy je zápis,
      // který si klienti musí stáhnout.
      await tx.run(
        'UPDATE units SET rev = :rev, deleted_at = NULL, deleted_by = NULL WHERE id = :id',
        { rev, id }
      );
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

// ── Sync API (DB9, PRD-DB/03-PRD-sync.md §6) ───────────────────────────────

const CHANGES_MAX_LIMIT = 500;

/// Rozdílový pull: karty s `rev > since`, vzestupně po rev.
///
/// POZOR — na rozdíl od `listUnits` vrací i `desired` VČETNĚ hesel. Lokální DB
/// klienta je nese (offline evidence by bez nich nešla zobrazit ani porovnat),
/// takže je to záměr, ne únik: endpoint je za přihlášením stejně jako
/// `GET /units/:id` a `/units/export`, které hesla vracejí taky.
///
/// Tombstones jdou zvlášť v `deleted` — klient podle nich smaže lokální řádek.
/// `more: true` znamená „ber dál od maxRev z této dávky".
async function listChanges(db, since = 0, limit = CHANGES_MAX_LIMIT) {
  const from = Number.isFinite(Number(since)) && Number(since) > 0 ? Math.floor(Number(since)) : 0;
  const n = Number.isInteger(limit) && limit > 0 ? Math.min(limit, CHANGES_MAX_LIMIT) : CHANGES_MAX_LIMIT;
  // LIMIT inline, ne parametrem (viz pruneHistory) — hodnota je ověřené číslo.
  const rows = await db.all(
    `SELECT * FROM units WHERE rev > :since ORDER BY rev ASC LIMIT ${n + 1}`,
    { since: from }
  );
  const more = rows.length > n;
  const page = more ? rows.slice(0, n) : rows;
  const units = [];
  const deleted = [];
  for (const row of page) {
    if (row.deleted_at) {
      deleted.push({ id: row.id, rev: Number(row.rev), deletedAt: row.deleted_at });
      continue;
    }
    const {
      devices_json: devicesJson,
      desired_json: desiredJson,
      unit_config_json: unitConfigJson,
      ...rest
    } = row;
    units.push({
      ...rest,
      rev: Number(row.rev),
      devices: devicesJson ? JSON.parse(devicesJson) : null,
      desired: desiredJson ? JSON.parse(desiredJson) : null,
      unit_config: unitConfigJson ? JSON.parse(unitConfigJson) : null,
    });
  }
  const pageMaxRev = page.length > 0 ? Number(page[page.length - 1].rev) : from;
  return {
    serverTs: nowIso(),
    // Když je stránka plná, `maxRev` je konec dávky (odtud klient pokračuje);
    // u poslední dávky je to skutečné maximum, takže se klient dorovná.
    maxRev: more ? pageMaxRev : Math.max(pageMaxRev, await currentRev(db)),
    more,
    units,
    deleted,
  };
}

const SYNC_LAYERS = ['observed', 'desired', 'meta', 'delete'];

/// Dávkový push z outboxu klienta.
///
/// Každá operace nese `opId` (UUID) a je **idempotentní**: opakované doručení
/// (spadlá síť, restart appky) vrátí původní výsledek a nic nezapíše. Proto se
/// op_id ukládá do `sync_ops`.
///
/// `ctx`: { username, sourceDevice, isAdmin } — `isAdmin` gatuje mazání stejně
/// jako `DELETE /units/:id`.
///
/// Každá operace jede ve VLASTNÍ transakci: jedna vadná op nesmí zneplatnit
/// celou dávku (klient by nevěděl, co přeposlat).
async function applySyncOps(db, ops, ctx = {}) {
  if (!Array.isArray(ops)) throw new UnitOpError('invalid_body', 'ops musí být pole');
  const username = ctx.username || null;
  const results = [];

  for (const op of ops) {
    if (!op || typeof op !== 'object' || Array.isArray(op)) {
      throw new UnitOpError('invalid_body', 'Každá operace musí být objekt');
    }
    const { opId, unitId, layer, at, payload } = op;
    if (typeof opId !== 'string' || opId.length === 0 || opId.length > 64) {
      throw new UnitOpError('invalid_body', 'opId musí být neprázdný string (max 64 znaků)');
    }
    if (!SYNC_LAYERS.includes(layer)) {
      throw new UnitOpError('invalid_body',
        `Neznámá vrstva '${layer}' (povolené: ${SYNC_LAYERS.join(', ')})`);
    }

    // Idempotence: už zpracované op_id vracíme beze změny stavu DB.
    const known = await db.get('SELECT status, rev FROM sync_ops WHERE op_id = :opId', { opId });
    if (known) {
      results.push({
        opId,
        status: known.status,
        rev: known.rev == null ? null : Number(known.rev),
        duplicate: true,
      });
      continue;
    }

    const opCtx = {
      at: typeof at === 'string' && at ? at : nowIso(),
      origin: 'sync',
      sourceDevice: ctx.sourceDevice || null,
      uuid: typeof op.historyUuid === 'string' ? op.historyUuid : null,
    };

    let outcome;
    try {
      outcome = await db.transaction(async (tx) => {
        let res;
        if (layer === 'observed') {
          res = await applyObserved(tx, unitId, payload || {}, opCtx);
        } else if (layer === 'desired') {
          res = await applyDesired(tx, unitId, payload, username, opCtx);
        } else if (layer === 'meta') {
          res = await applyMeta(tx, unitId, payload || {}, username, opCtx);
        } else {
          // Mazání smí jen admin — stejné pravidlo jako u DELETE /units/:id,
          // jinak by se přes sync dala obejít autorizace.
          if (!ctx.isAdmin) {
            res = { id: normalizeUnitId(unitId), status: 'rejected', rev: null };
          } else {
            res = await applyDelete(tx, unitId, username, opCtx);
          }
        }
        await tx.run(
          `INSERT INTO sync_ops (op_id, unit_id, layer, status, rev, applied_at)
           VALUES (:op_id, :unit_id, :layer, :status, :rev, :applied_at)`,
          {
            op_id: opId, unit_id: res.id, layer, status: res.status,
            rev: res.rev, applied_at: nowIso(),
          }
        );
        return res;
      });
    } catch (e) {
      if (e instanceof UnitOpError) {
        // Vadná operace (neplatné ID, neznámý stav, …) klienta neblokuje: zapíše
        // se jako `rejected`, ať ji outbox nepřeposílá donekonečna.
        await db.run(
          `INSERT INTO sync_ops (op_id, unit_id, layer, status, rev, applied_at)
           VALUES (:op_id, :unit_id, :layer, 'rejected', NULL, :applied_at)`,
          { op_id: opId, unit_id: String(unitId || ''), layer, applied_at: nowIso() }
        );
        results.push({ opId, status: 'rejected', rev: null, error: e.code, message: e.message });
        continue;
      }
      throw e;
    }

    const entry = { opId, status: outcome.status, rev: outcome.rev, id: outcome.id };
    // U konfliktu přiloží aktuální serverový stav, aby klient mohl hned zobrazit
    // banner „tvoje verze byla přehlasována" bez čekání na pull.
    if (outcome.status === 'conflict') {
      entry.current = await getUnit(db, outcome.id, { includeDeleted: true });
    }
    results.push(entry);
  }

  return { serverTs: nowIso(), maxRev: await currentRev(db), results };
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
  // sync (DB9)
  listChanges,
  applySyncOps,
  currentRev,
  CHANGES_MAX_LIMIT,
  historyRetention,
};
