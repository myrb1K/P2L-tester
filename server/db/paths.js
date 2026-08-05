// Kde leží data serveru (SQLite DB + PID file).
//
// Při DB_DRIVER=mariadb tu zůstává jen PID file — data jsou v databázi.
//
// Default je `server/data/` vedle kódu — tak to jelo od začátku a pro dev
// (`npm start` v repu) to zůstává.
//
// Override přes `P2L_DATA_DIR` je kvůli portable režimu: Windows EXE si
// spouští Node server přiložený vedle sebe (viz lib/services/local_server_io.dart)
// a data musí ležet MIMO aplikační složku — v `%APPDATA%\P2L-Tester\server-data`.
// Jinak by rozbalení novější verze dist zipu přepsalo/smazalo units.db.

const path = require('path');
const fs = require('fs');

function dataDir() {
  const override = (process.env.P2L_DATA_DIR || '').trim();
  if (override) return path.resolve(override);
  return path.join(__dirname, '..', 'data');
}

function dataPath(fileName) {
  return path.join(dataDir(), fileName);
}

/// Vytvoří data adresář, pokud chybí (první start portable instalace).
function ensureDataDir() {
  const dir = dataDir();
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  return dir;
}

module.exports = { dataDir, dataPath, ensureDataDir };
