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
  updated_at         TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS unit_history (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id     TEXT NOT NULL,
  at          TEXT NOT NULL DEFAULT (datetime('now')),
  username    TEXT NOT NULL,
  action      TEXT NOT NULL,   -- desired | meta | change_id | delete | ... (DB3 doplní set_mqtt apod.)
  detail_json TEXT             -- detail změny; hesla NIKDY (scrubSecrets v db/units.js)
);

CREATE INDEX IF NOT EXISTS idx_unit_history_unit ON unit_history(unit_id, at);
