#!/usr/bin/env node
// Použití: node scripts/reset-pwd.js <username> <new-password>

const { resetPassword } = require('../db/users');
const { die, parseArgs, runCli } = require('./_lib');

const { positional } = parseArgs(process.argv.slice(2));
const [username, password] = positional;

if (!username || !password) {
  die('Použití: node scripts/reset-pwd.js <username> <new-password>');
}

runCli(async (db) => {
  await resetPassword(db, username, password);
  console.log(`✓ Heslo pro '${username}' změněno.`);
});
