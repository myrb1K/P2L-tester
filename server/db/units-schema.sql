-- Schéma centrální databáze jednotek (PRD-DB/01-PRD.md §4, milestone DB2).
-- Samostatný soubor data/units.db vedle users.db — nezávislé zálohy,
-- users schéma se nemění.
--
-- Tři vrstvy karty (PRD §2.1): observed (co jednotka hlásí, opravuje se samo),
-- desired (co appka poslala — hesla jinde neexistují), meta (od uživatele).

CREATE TABLE IF NOT EXISTS units (
  id                 TEXT PRIMARY KEY,  -- normalizované ID bez 'u' a bez leading zeros ('1209')
  generation         TEXT NOT NULL,     -- 'old' | 'new'
  mac                TEXT,              -- sekundární stabilní identifikátor (přežije change-id)
  -- observed
  hw_model           TEXT,
  firmware           TEXT,
  ip                 TEXT,
  battery            REAL,
  ssid               TEXT,              -- aktuální WiFi z get_param (bez hesla)
  mqtt_server        TEXT,              -- aktuální broker z get_param (bez credentials)
  mqtt_port          INTEGER,
  brightness         INTEGER,           -- jas P2L LED z get_param
  seen_on_broker     TEXT,              -- host brokeru, přes který appka jednotku naposledy viděla
  unit_config_json   TEXT,              -- poslední UNIT GET-CONFIG 1:1 (DB5): nakonfigurováno + actualIp/actualSSID, hesla jako bool
  unit_config_fetched_at TEXT,          -- kdy byl GET-CONFIG naposledy načten (ISO 8601)
  last_seen          TEXT,              -- ISO 8601
  devices_json       TEXT,              -- poslední GET-DEVICES, formát PumaModule.toJson
  -- desired
  desired_json       TEXT,              -- {broker:{...}, wifi:{...}, brightness, ...}
  desired_updated_at TEXT,
  desired_updated_by TEXT,
  -- meta
  name               TEXT,
  location           TEXT,
  note               TEXT,
  status             TEXT NOT NULL DEFAULT 'active',  -- active | faulty | stock | retired
  created_at         TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at         TEXT NOT NULL DEFAULT (datetime('now')),
  -- sync (DB9, PRD-DB/03-PRD-sync.md §4.1)
  rev                  INTEGER NOT NULL DEFAULT 0,  -- revize ze sync_counter; podle ní klient pozná, co je nového
  observed_updated_at  TEXT,                        -- čas poslední změny observed vrstvy
  meta_updated_at      TEXT,                        -- čas poslední změny meta vrstvy
  meta_updated_by      TEXT,
  deleted_at           TEXT,                        -- tombstone: karta se nemaže fyzicky, jinak by se vrátila ze lokálu
  deleted_by           TEXT
);

-- Sync: podle rev se stahují rozdíly, proto index.
CREATE INDEX IF NOT EXISTS idx_units_rev ON units(rev);

CREATE TABLE IF NOT EXISTS unit_history (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id     TEXT NOT NULL,
  at          TEXT NOT NULL DEFAULT (datetime('now')),
  username    TEXT NOT NULL,
  action      TEXT NOT NULL,   -- desired | meta | change_id | delete | ... (DB3 doplní set_mqtt apod.)
  detail_json TEXT,            -- detail změny; hesla NIKDY (scrubSecrets v db/units.js)
  -- audit rozšířený pro sync (DB9, PRD §4.2)
  uuid          TEXT,          -- globálně unikátní ID řádku; offline klient si historii generuje sám
  layer         TEXT,          -- observed | desired | meta | change_id | delete
  origin        TEXT,          -- online | sync | mqtt
  source_device TEXT,          -- odkud změna přišla (exe@NB-RADEK, apk@Pixel7, web)
  rev           INTEGER        -- revize, kterou zápis vyrobil — spojka mezi auditem a syncem
);

CREATE INDEX IF NOT EXISTS idx_unit_history_unit ON unit_history(unit_id, at);
CREATE INDEX IF NOT EXISTS idx_unit_history_uuid ON unit_history(uuid);

-- Globální čítač revizí. Jediný řádek (id = 1); inkrement probíhá VŽDY uvnitř
-- transakce zápisu, aby dvě souběžné změny nedostaly stejné rev. Nepoužívá se
-- čas — dva zápisy ve stejné milisekundě musí být rozlišitelné.
CREATE TABLE IF NOT EXISTS sync_counter (
  id    INTEGER PRIMARY KEY,
  value INTEGER NOT NULL
);
INSERT OR IGNORE INTO sync_counter (id, value) VALUES (1, 0);

-- Idempotence pushů: klient posílá operace s vlastním op_id (UUID). Opakované
-- doručení téže operace (spadlá síť, restart appky) nesmí zápis zdvojit.
CREATE TABLE IF NOT EXISTS sync_ops (
  op_id      TEXT PRIMARY KEY,
  unit_id    TEXT NOT NULL,
  layer      TEXT NOT NULL,
  status     TEXT NOT NULL,   -- applied | superseded | rejected
  rev        INTEGER,         -- rev, který operace vyrobila (null u superseded/rejected)
  applied_at TEXT NOT NULL
);
