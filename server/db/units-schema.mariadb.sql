-- Schéma centrální databáze jednotek — MariaDB varianta db/units-schema.sql.
--
-- Tři vrstvy karty (PRD-DB §2.1): observed (co jednotka hlásí, opravuje se
-- samo), desired (co appka poslala — hesla jinde neexistují), meta (od
-- uživatele). Sémantika sloupců je shodná se SQLite verzí, mění se jen typy.
--
-- Rozdíly proti SQLite verzi:
-- - VARCHAR s délkou u klíčů a krátkých textů, LONGTEXT u JSON snapshotů
--   (devices_json může být velký — až 100 čipů na jednotku)
-- - REAL -> DOUBLE, INTEGER AUTOINCREMENT -> BIGINT AUTO_INCREMENT
-- - časové značky jsou ISO 8601 stringy zapisované aplikací (db/adapter.js
--   nowIso), ne SQL defaulty — formát je pak v obou driverech stejný
-- - index inline v CREATE TABLE (`CREATE INDEX IF NOT EXISTS` MariaDB neumí)

CREATE TABLE IF NOT EXISTS units (
  id                     VARCHAR(16)  NOT NULL PRIMARY KEY,  -- normalizované ID bez 'u' a bez leading zeros ('1209')
  generation             VARCHAR(8)   NOT NULL,              -- 'old' | 'new'
  mac                    VARCHAR(32),                        -- sekundární stabilní identifikátor (přežije change-id)
  -- observed
  hw_model               VARCHAR(64),
  firmware               VARCHAR(64),
  ip                     VARCHAR(64),
  battery                DOUBLE,
  ssid                   VARCHAR(128),                       -- aktuální WiFi z get_param (bez hesla)
  mqtt_server            VARCHAR(255),                       -- aktuální broker z get_param (bez credentials)
  mqtt_port              INT,
  brightness             INT,                                -- jas P2L LED z get_param
  seen_on_broker         VARCHAR(255),                       -- host brokeru, přes který appka jednotku naposledy viděla
  unit_config_json       LONGTEXT,                           -- poslední UNIT GET-CONFIG 1:1 (DB5)
  unit_config_fetched_at VARCHAR(32),                        -- kdy byl GET-CONFIG naposledy načten (ISO 8601)
  last_seen              VARCHAR(32),                        -- ISO 8601
  devices_json           LONGTEXT,                           -- poslední GET-DEVICES, formát PumaModule.toJson
  -- desired
  desired_json           LONGTEXT,                           -- {broker:{...}, wifi:{...}, brightness, ...}
  desired_updated_at     VARCHAR(32),
  desired_updated_by     VARCHAR(64),
  -- meta
  name                   VARCHAR(128),
  location               VARCHAR(128),
  note                   TEXT,
  status                 VARCHAR(16)  NOT NULL DEFAULT 'active',  -- active | faulty | stock | retired
  created_at             VARCHAR(32)  NOT NULL,
  updated_at             VARCHAR(32)  NOT NULL,
  -- sync (DB9, PRD-DB/03-PRD-sync.md §4.1)
  rev                    BIGINT       NOT NULL DEFAULT 0,  -- revize ze sync_counter; podle ní klient pozná, co je nového
  observed_updated_at    VARCHAR(32),                      -- čas poslední změny observed vrstvy
  meta_updated_at        VARCHAR(32),                      -- čas poslední změny meta vrstvy
  meta_updated_by        VARCHAR(64),
  deleted_at             VARCHAR(32),                      -- tombstone: karta se nemaže fyzicky, jinak by se vrátila z lokálu
  deleted_by             VARCHAR(64),
  INDEX idx_units_rev (rev)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS unit_history (
  id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  unit_id     VARCHAR(16)  NOT NULL,
  at          VARCHAR(32)  NOT NULL,
  username    VARCHAR(64)  NOT NULL,
  action      VARCHAR(32)  NOT NULL,   -- desired | meta | change_id | import | ...
  detail_json LONGTEXT,                -- detail změny; hesla NIKDY (scrubSecrets v db/units.js)
  -- audit rozšířený pro sync (DB9, PRD §4.2)
  uuid          VARCHAR(64),           -- globálně unikátní ID řádku; offline klient si historii generuje sám
  layer         VARCHAR(16),           -- observed | desired | meta | change_id | delete
  origin        VARCHAR(16),           -- online | sync | mqtt
  source_device VARCHAR(64),           -- odkud změna přišla (exe@NB-RADEK, apk@Pixel7, web)
  rev           BIGINT,                -- revize, kterou zápis vyrobil — spojka mezi auditem a syncem
  INDEX idx_unit_history_unit (unit_id, at),
  INDEX idx_unit_history_uuid (uuid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Globální čítač revizí. Jediný řádek (id = 1); inkrement probíhá VŽDY uvnitř
-- transakce zápisu, aby dvě souběžné změny nedostaly stejné rev (řádek drží
-- zámek do commitu). Nepoužívá se čas — dva zápisy ve stejné milisekundě musí
-- být rozlišitelné.
CREATE TABLE IF NOT EXISTS sync_counter (
  id    INT    NOT NULL PRIMARY KEY,
  value BIGINT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO sync_counter (id, value) VALUES (1, 0);

-- Idempotence pushů: klient posílá operace s vlastním op_id (UUID). Opakované
-- doručení téže operace (spadlá síť, restart appky) nesmí zápis zdvojit.
CREATE TABLE IF NOT EXISTS sync_ops (
  op_id      VARCHAR(64)  NOT NULL PRIMARY KEY,
  unit_id    VARCHAR(16)  NOT NULL,
  layer      VARCHAR(16)  NOT NULL,
  status     VARCHAR(16)  NOT NULL,   -- applied | superseded | rejected
  rev        BIGINT,                  -- rev, který operace vyrobila (null u superseded/rejected)
  applied_at VARCHAR(32)  NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
