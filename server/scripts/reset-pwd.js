#!/usr/bin/env node
// Použití: node scripts/reset-pwd.js <username> <new-password>

const { openDb } = require('../db');
const { resetPassword, UserOpError } = require('../db/users');
const { die, parseArgs } = require('./_lib');

const { positional } = parseArgs(process.argv.slice(2));
const [username, password] = positional;

if (!username || !password) {
  die('Použití: node scripts/reset-pwd.js <username> <new-password>');
}

try {
  resetPassword(openDb(), username, password);
  console.log(`✓ Heslo pro '${username}' změněno.`);
} catch (e) {
  if (e instanceof UserOpError) die(e.message);
  throw e;
}
