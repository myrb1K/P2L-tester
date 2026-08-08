// Kde leží data serveru (SQLite DB + PID file).
//
// Při DB_DRIVER=mariadb tu zůstává jen PID file — data jsou v databázi.
//
// Default je `server/data/` vedle kódu — tak to jelo od začátku a pro dev
// (`npm start` v repu) to zůstává.
//
// Override přes `P2L_DATA_DIR` drží data mimo adresář s kódem — dnes ho
// používá Docker (volume `/data`), dřív portable Windows dist appky
// (`%APPDATA%\P2L-Tester\server-data`), aby rozbalení novější verze
// nepřepsalo units.db. Ta cesta zanikla s R6, override zůstává.

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
