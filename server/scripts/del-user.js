#!/usr/bin/env node
// Použití: node scripts/del-user.js <username>
//
// Last-admin guard je sdílený s admin endpointy v db/users.js.

const { deleteUser } = require('../db/users');
const { die, parseArgs, runCli } = require('./_lib');

const { positional } = parseArgs(process.argv.slice(2));
const [username] = positional;

if (!username) die('Použití: node scripts/del-user.js <username>');

runCli(async (db) => {
  await deleteUser(db, username);
  console.log(`✓ Uživatel '${username}' smazán.`);
});
