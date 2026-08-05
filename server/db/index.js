// Sdílený přístup k databázi — používá server.js i CLI skripty.
//
// Driver se volí přes env `DB_DRIVER` (`sqlite` default | `mariadb`), mechaniku
// řeší db/adapter.js. Datová vrstva je asynchronní (viz tam).
//
// Topologie se mezi drivery liší:
// - sqlite  — dva soubory, data/users.db a data/units.db (nezávislé zálohy)
// - mariadb — jedna databáze (`P2Lunits`) se všemi tabulkami, takže oba
//   „handly" ukazují na jeden connection pool

const { openAdapter, resolveDriver } = require('./adapter');
const { openUnitsDb, prepareUnitsSchema } = require('./units');
const { dataPath } = require('./paths');

// Cesta se čte lazy (ne do konstanty při require), aby šla ovlivnit přes
// P2L_DATA_DIR — portable režim ji nastavuje až při spuštění procesu.
const usersDbPath = () => dataPath('users.db');

/// Databáze uživatelů. U MariaDB otevře pool jen se users schématem —
/// určeno pro CLI skripty, které s jednotkami nepracují. Server používá
/// openDatabases() (jeden pool pro obojí).
async function openDb() {
  return openAdapter({
    schemas: ['schema'],
    sqliteFile: usersDbPath(),
  });
}

/// Obě databáze pro server. U MariaDB je to jeden pool nad jednou databází,
/// u SQLite dva nezávislé soubory. `close()` uklidí obojí právě jednou.
async function openDatabases() {
  if (resolveDriver() === 'mariadb') {
    const db = await openAdapter({ schemas: ['schema', 'units-schema'] });
    await prepareUnitsSchema(db); // mini-migrace observed sloupců, úklid historie
    return { usersDb: db, unitsDb: db, close: () => db.close() };
  }

  const usersDb = await openDb();
  const unitsDb = await openUnitsDb();
  return {
    usersDb,
    unitsDb,
    close: async () => {
      await usersDb.close();
      await unitsDb.close();
    },
  };
}

module.exports = { openDb, openDatabases, usersDbPath };
