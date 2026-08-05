#!/usr/bin/env node
// Použití: node scripts/add-user.js <username> <password> [--admin]

const { createUser } = require('../db/users');
const { die, parseArgs, runCli } = require('./_lib');

const { positional, flags } = parseArgs(process.argv.slice(2));
const [username, password] = positional;

if (!username || !password) {
  die('Použití: node scripts/add-user.js <username> <password> [--admin]');
}

runCli(async (db) => {
  await createUser(db, {
    username,
    password,
    isAdmin: flags.has('admin'),
  });
  console.log(
    `✓ Uživatel '${username}' vytvořen${flags.has('admin') ? ' jako admin' : ''}.`
  );
});
