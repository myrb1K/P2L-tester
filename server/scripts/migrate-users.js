#!/usr/bin/env node
// Přenese uživatele ze SQLite `users.db` do cílové databáze (typicky MariaDB).
//
// Použití:
//   node scripts/migrate-users.js [--from <cesta k users.db>] [--dry-run] [--overwrite]
//   npm run migrate-users -- --dry-run
//
// Cíl je databáze podle stejné konfigurace jako server (`.env` / env proměnné),
// tj. nastav `DB_DRIVER=mariadb` + `DB_*`. Zdroj se čte **read-only**, takže
// původní `users.db` zůstane nedotčený.
//
// Hesla se přenášejí jako **bcrypt hashe 1:1** — uživatelé se přihlásí stejným
// heslem jako dřív, nic se neresetuje.
//
// Existující uživatele skript **přeskočí** (shodné jméno v cíli), pokud
// nedostane `--overwrite` — ten přepíše hash i příznak admina. Uživatele, kteří
// jsou jen v cíli, nikdy nemaže.
//
// Jednotky se takhle nepřenášejí — na ty je export/import databáze
// (GET /api/units/export → POST /api/units/import, i z UI appky).

const path = require('path');
const fs = require('fs');

const { nowIso } = require('../db/adapter');

/// SQLite ukládalo `created_at` jako 'YYYY-MM-DD HH:MM:SS' (UTC bez zóny),
/// nová vrstva používá ISO 8601. Sjednotíme, ať se časy v UI neliší.
function toIso(value) {
  if (typeof value !== 'string' || value === '') return nowIso();
  if (value.includes('T')) return value;
  const d = new Date(`${value.replace(' ', 'T')}Z`);
  return Number.isNaN(d.getTime()) ? nowIso() : d.toISOString();
}

/// Přečte uživatele ze SQLite souboru (read-only).
function readSourceUsers(sourcePath) {
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Zdrojová databáze neexistuje: ${sourcePath}`);
  }
  const Database = require('better-sqlite3');
  const db = new Database(sourcePath, { readonly: true });
  try {
    return db
      .prepare(
        'SELECT username, password_hash, is_admin, created_at FROM users ORDER BY id'
      )
      .all();
  } finally {
    db.close();
  }
}

/// Zapíše uživatele do cílové databáze. Vrací souhrn pro výpis i testy.
///
/// [targetDb] je handle z db/adapter.js (jakýkoli driver).
async function migrateUsers(sourcePath, targetDb, { overwrite = false, dryRun = false } = {}) {
  const users = readSourceUsers(sourcePath);
  const created = [];
  const updated = [];
  const skipped = [];

  for (const u of users) {
    const existing = await targetDb.get(
      'SELECT id FROM users WHERE username = :username',
      { username: u.username }
    );

    if (existing && !overwrite) {
      skipped.push(u.username);
      continue;
    }

    if (dryRun) {
      (existing ? updated : created).push(u.username);
      continue;
    }

    if (existing) {
      await targetDb.run(
        'UPDATE users SET password_hash = :hash, is_admin = :admin WHERE id = :id',
        { hash: u.password_hash, admin: u.is_admin ? 1 : 0, id: existing.id }
      );
      updated.push(u.username);
    } else {
      await targetDb.run(
        `INSERT INTO users (username, password_hash, is_admin, created_at)
         VALUES (:username, :hash, :admin, :created_at)`,
        {
          username: u.username,
          hash: u.password_hash,
          admin: u.is_admin ? 1 : 0,
          created_at: toIso(u.created_at),
        }
      );
      created.push(u.username);
    }
  }

  return { total: users.length, created, updated, skipped };
}

module.exports = { migrateUsers, readSourceUsers, toIso };

// ── CLI ────────────────────────────────────────────────────────────────────

if (require.main === module) {
  const { die, parseArgs } = require('./_lib');
  const { openDb, usersDbPath } = require('../db');
  const { resolveDriver, mariadbConfigFromEnv } = require('../db/adapter');

  const { positional, flags } = parseArgs(process.argv.slice(2));
  const dryRun = flags.has('dry-run');
  const overwrite = flags.has('overwrite');

  // `--from <cesta>`; bez něj default data/users.db.
  const fromIndex = process.argv.indexOf('--from');
  const sourcePath =
    fromIndex >= 0 && process.argv[fromIndex + 1]
      ? path.resolve(process.argv[fromIndex + 1])
      : usersDbPath();
  // `--from` si vezme svůj argument, takže ho v positional nechceme řešit.
  const extra = positional.filter((p) => p !== process.argv[fromIndex + 1]);
  if (extra.length > 0) {
    die(`Neznámý argument: ${extra.join(' ')}\nPoužití: node scripts/migrate-users.js [--from <users.db>] [--dry-run] [--overwrite]`);
  }

  (async () => {
    const driver = resolveDriver();
    console.log(`Zdroj: ${sourcePath} (SQLite, read-only)`);
    if (driver === 'mariadb') {
      const cfg = mariadbConfigFromEnv();
      console.log(`Cíl:   mariadb ${cfg.user}@${cfg.host}:${cfg.port}/${cfg.database}`);
    } else {
      console.log(`Cíl:   sqlite ${usersDbPath()}`);
      if (path.resolve(usersDbPath()) === sourcePath) {
        die('Zdroj a cíl jsou tentýž soubor. Nastav DB_DRIVER=mariadb (nebo použij --from).');
      }
    }
    if (dryRun) console.log('(--dry-run: nic se nezapíše)');

    const db = await openDb();
    try {
      const r = await migrateUsers(sourcePath, db, { overwrite, dryRun });
      console.log(`\nNalezeno ${r.total} uživatelů.`);
      if (r.created.length) console.log(`  ✓ přeneseno:  ${r.created.join(', ')}`);
      if (r.updated.length) console.log(`  ✓ přepsáno:   ${r.updated.join(', ')}`);
      if (r.skipped.length) {
        console.log(`  – přeskočeno (už v cíli): ${r.skipped.join(', ')}`);
        console.log('    (přepsat je jde s --overwrite)');
      }
      if (!dryRun && (r.created.length || r.updated.length)) {
        console.log('\nHesla zůstávají stejná — hashe se přenesly beze změny.');
      }
    } finally {
      await db.close();
    }
  })().catch((err) => die(`✗ Migrace selhala: ${err.message}`));
}
