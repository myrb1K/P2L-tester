#!/usr/bin/env node
// Použití: node scripts/db-check.js
//
// Ověří, že se server na databázi dostane, a vypíše, co v ní je. Používá
// stejnou konfiguraci jako server (.env / env proměnné), takže je to první
// věc, kterou pustit po nastavení DB_DRIVER=mariadb — vrátí čitelnou chybu
// místo pádu serveru při startu.

const { openDatabases } = require('../db');
const { resolveDriver, mariadbConfigFromEnv } = require('../db/adapter');
const { die } = require('./_lib');

(async () => {
  const driver = resolveDriver();
  if (driver === 'mariadb') {
    const cfg = mariadbConfigFromEnv();
    console.log(`Driver:   mariadb`);
    console.log(`Server:   ${cfg.user}@${cfg.host}:${cfg.port}`);
    console.log(`Databáze: ${cfg.database}`);
  } else {
    const { usersDbPath } = require('../db');
    const { unitsDbPath } = require('../db/units');
    console.log('Driver:   sqlite');
    console.log(`Soubory:  ${usersDbPath()}`);
    console.log(`          ${unitsDbPath()}`);
  }

  const dbs = await openDatabases();
  try {
    const users = await dbs.usersDb.get('SELECT COUNT(*) AS n FROM users');
    const units = await dbs.unitsDb.get('SELECT COUNT(*) AS n FROM units');
    const hist = await dbs.unitsDb.get('SELECT COUNT(*) AS n FROM unit_history');
    console.log('\n✓ Spojení OK, schéma připravené.');
    console.log(`  uživatelé:      ${users.n}`);
    console.log(`  jednotky:       ${units.n}`);
    console.log(`  záznamů historie: ${hist.n}`);
    if (users.n === 0) {
      console.log('\nDB je bez uživatele — správce vznikne při startu serveru');
      console.log('z INITIAL_ADMIN_USER / INITIAL_ADMIN_PASSWORD, nebo ho přidej:');
      console.log('  node scripts/add-user.js <jmeno> <heslo> --admin');
    }
  } finally {
    await dbs.close();
  }
})().catch((err) => {
  die(`✗ Databáze nedostupná: ${err.message}`);
});
