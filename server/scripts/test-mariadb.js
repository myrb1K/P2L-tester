#!/usr/bin/env node
// Použití: npm run test:mariadb
//
// Pustí kompletní testovou sadu proti reálné MariaDB. Existuje proto, že
// `TEST_DB_DRIVER=mariadb node --test` je bashová syntax, kterou cmd ani
// PowerShell (Radek jede na Windows) neumí.
//
// POZOR: testy testovací databázi před každým testem MAŽOU. Jméno bere
// z TEST_DB_NAME (default P2Lunits_test) — nikdy nesmí ukazovat na produkci.

const path = require('path');
const { spawnSync } = require('child_process');

require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const dbName = process.env.TEST_DB_NAME || 'P2Lunits_test';
if (/^p2lunits$/i.test(dbName)) {
  console.error(
    `ODMÍTÁM: TEST_DB_NAME='${dbName}' je produkční databáze a testy ji smažou.\n` +
    'Nastav TEST_DB_NAME na oddělenou testovací databázi (např. P2Lunits_test).'
  );
  process.exit(1);
}

console.log(`[test] MariaDB driver, databáze '${dbName}'`);

const res = spawnSync(process.execPath, ['--test'], {
  cwd: path.join(__dirname, '..'),
  stdio: 'inherit',
  env: { ...process.env, TEST_DB_DRIVER: 'mariadb', TEST_DB_NAME: dbName },
});

process.exit(res.status ?? 1);
