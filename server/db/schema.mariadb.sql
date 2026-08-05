-- Schéma users tabulky — MariaDB varianta db/schema.sql.
--
-- Rozdíly proti SQLite verzi:
-- - AUTO_INCREMENT místo AUTOINCREMENT
-- - VARCHAR s délkou (TEXT nemůže být PRIMARY KEY / UNIQUE bez prefixu)
-- - case-insensitive jména uživatelů řeší collation utf8mb4_unicode_ci
--   (v SQLite to dělá COLLATE NOCASE)
-- - created_at je ISO 8601 string zapisovaný aplikací (viz db/adapter.js
--   nowIso) — žádný SQL default, aby byl formát v obou driverech stejný
-- - index na username je součástí UNIQUE, samostatný by byl redundantní
--
-- POZOR: `CREATE INDEX IF NOT EXISTS` MariaDB neumí, indexy proto inline
-- v CREATE TABLE.

CREATE TABLE IF NOT EXISTS users (
  id            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username      VARCHAR(64)  NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  is_admin      TINYINT      NOT NULL DEFAULT 0,
  created_at    VARCHAR(32)  NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
