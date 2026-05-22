#!/usr/bin/env node
// Použití: node scripts/del-user.js <username>
//
// Bezpečnostní guard: nelze smazat posledního admina (zachová se invariant
// "vždy alespoň 1 admin v systému", stejný pravidlo jako v M4.5 backendu).

const { openDb } = require('../db');
const { die, parseArgs } = require('./_lib');

const { positional } = parseArgs(process.argv.slice(2));
const [username] = positional;

if (!username) die('Použití: node scripts/del-user.js <username>');

const db = openDb();
const user = db
  .prepare('SELECT id, is_admin FROM users WHERE username = ?')
  .get(username);

if (!user) die(`Uživatel '${username}' neexistuje.`);

if (user.is_admin) {
  const adminCount = db
    .prepare('SELECT COUNT(*) AS n FROM users WHERE is_admin = 1')
    .get().n;
  if (adminCount <= 1) {
    die(`Nelze smazat posledního admina ('${username}'). Vytvoř jiného admina nejdřív.`);
  }
}

db.prepare('DELETE FROM users WHERE id = ?').run(user.id);
console.log(`✓ Uživatel '${username}' smazán.`);
