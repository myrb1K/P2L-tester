#!/usr/bin/env node
// Použití: node scripts/list-users.js

const { listUsers } = require('../db/users');
const { runCli } = require('./_lib');

runCli(async (db) => {
  const rows = await listUsers(db);

  if (rows.length === 0) {
    console.log('(žádní uživatelé)');
    return;
  }

  const padTo = (s, n) => String(s).padEnd(n);
  console.log(padTo('Username', 20) + padTo('Role', 10) + 'Vytvořen');
  console.log('-'.repeat(60));
  for (const r of rows) {
    console.log(
      padTo(r.username, 20) + padTo(r.isAdmin ? 'admin' : 'user', 10) + r.createdAt
    );
  }
  console.log(`\nCelkem: ${rows.length}`);
});
