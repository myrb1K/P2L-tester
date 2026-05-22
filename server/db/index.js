// Sdílený přístup k SQLite — používá server.js i CLI skripty.
// better-sqlite3 je synchronní, což pro náš case (5-50 uživatelů) ideální:
// žádné callback peklo, řádkový read = jeden SQL volání.

const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');

const DB_PATH = path.join(__dirname, '..', 'data', 'users.db');
const SCHEMA_PATH = path.join(__dirname, 'schema.sql');

function openDb() {
  const dir = path.dirname(DB_PATH);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const db = new Database(DB_PATH);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');

  const schema = fs.readFileSync(SCHEMA_PATH, 'utf8');
  db.exec(schema);

  return db;
}

module.exports = { openDb, DB_PATH };
