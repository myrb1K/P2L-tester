#!/usr/bin/env node
// Použití: node scripts/list-users.js

const { openDb } = require('../db');
require('./_lib');

const db = openDb();
const rows = db
  .prepare('SELECT username, is_admin, created_at FROM users ORDER BY is_admin DESC, username')
  .all();

if (rows.length === 0) {
  console.log('(žádní uživatelé)');
  process.exit(0);
}

const padTo = (s, n) => String(s).padEnd(n);
console.log(padTo('Username', 20) + padTo('Role', 10) + 'Vytvořen');
console.log('-'.repeat(60));
for (const r of rows) {
  console.log(
    padTo(r.username, 20) +
      padTo(r.is_admin ? 'admin' : 'user', 10) +
      r.created_at
  );
}
console.log(`\nCelkem: ${rows.length}`);
